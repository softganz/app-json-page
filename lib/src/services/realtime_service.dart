import 'dart:async';
import 'dart:convert';
import 'dart:developer';

import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

import 'package:json_page/src/models/realtime_config.dart';

/// Single WebSocket connection to the gateway.
///
/// - Optionally performs an auth handshake when [authMessage] is provided
///   (e.g. a host that needs the `device:{deviceId}` channel).
/// - When [authMessage] is `null`, the connection subscribes to the public
///   `feed` channel only (no auth) — used for camera-photo home feed updates.
/// - Emits decoded [RealtimeEvent]s through [events].
/// - Auto-reconnects with exponential backoff when the connection drops.
/// - Sends periodic ping frames to keep the connection alive.
class RealtimeService {
  RealtimeService({
    required this.wsUrl,
    this.authMessage,
    this.onConnectionState,
  });

  final String wsUrl;

  /// Optional auth message sent after connect. May be a `Future` (e.g. when the
  /// host must sign it with a device key). When `null`, no auth is sent.
  final Future<Map<String, dynamic>>? authMessage;

  final void Function(bool connected)? onConnectionState;

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _sub;
  final StreamController<RealtimeEvent> _eventController =
      StreamController<RealtimeEvent>.broadcast();
  Timer? _pingTimer;
  Timer? _reconnectTimer;
  bool _disposed = false;
  bool _connected = false;
  int _reconnectAttempts = 0;

  /// Stream of decoded realtime events.
  Stream<RealtimeEvent> get events => _eventController.stream;

  bool get isConnected => _connected;

  /// Normalizes a wsUrl into a Uri with an explicit port (Dart's `Uri.parse`
  /// yields port 0 for `ws://host/ws`, which the websocket package rejects).
  static Uri _normalizeWsUri(String wsUrl) {
    final Uri raw = Uri.parse(wsUrl);
    final int port = raw.port == 0
        ? (raw.scheme == 'wss' ? 443 : 80)
        : raw.port;
    return raw.replace(port: port);
  }

  /// Opens the connection and optionally performs the auth handshake.
  Future<void> connect() async {
    if (_disposed) return;
    _cancelReconnect();
    try {
      log('JSON_PAGE_WS :: connecting to $wsUrl');
      final Uri uri = _normalizeWsUri(wsUrl);
      _channel = WebSocketChannel.connect(uri);
      _sub = _channel!.stream.listen(
        _onMessage,
        onError: _onError,
        onDone: _onDone,
      );
      if (authMessage != null) {
        final Map<String, dynamic> msg = await authMessage!;
        log('JSON_PAGE_WS :: sending auth');
        _channel!.sink.add(jsonEncode(msg));
      }
      _startPing();
      _reconnectAttempts = 0;
    } catch (e, stack) {
      log('JSON_PAGE_WS :: connect error', error: e, stackTrace: stack);
      _scheduleReconnect();
    }
  }

  void _onMessage(dynamic message) {
    if (message is! String) return;
    Map<String, dynamic>? json;
    try {
      json = jsonDecode(message) as Map<String, dynamic>;
    } catch (e) {
      log('JSON_PAGE_WS :: failed to decode message: $message');
      return;
    }
    final String type = json['type'] as String? ?? '';
    if (type == 'auth.ok') {
      _connected = true;
      _reconnectAttempts = 0;
      onConnectionState?.call(true);
      log('JSON_PAGE_WS :: auth.ok');
      return;
    }
    if (type == 'auth.error') {
      log('JSON_PAGE_WS :: auth.error ${json['message']}');
      _connected = false;
      onConnectionState?.call(false);
      disconnect();
      return;
    }
    if (type == 'pong') return;
    // photo.new / request.status / etc.
    _eventController.add(RealtimeEvent.fromJson(json));
  }

  void _onError(Object error, StackTrace stack) {
    log('JSON_PAGE_WS :: stream error', error: error, stackTrace: stack);
    _connected = false;
    onConnectionState?.call(false);
    _scheduleReconnect();
  }

  void _onDone() {
    log('JSON_PAGE_WS :: connection closed');
    _connected = false;
    onConnectionState?.call(false);
    _stopPing();
    _scheduleReconnect();
  }

  void _startPing() {
    _stopPing();
    _pingTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (_connected) {
        try {
          _channel?.sink.add(jsonEncode({'type': 'ping'}));
        } catch (e) {
          log('JSON_PAGE_WS :: ping failed: $e');
        }
      }
    });
  }

  void _stopPing() {
    _pingTimer?.cancel();
    _pingTimer = null;
  }

  void _scheduleReconnect() {
    if (_disposed) return;
    _cancelReconnect();
    final int delay = [1, 2, 4, 8, 16, 30][_reconnectAttempts.clamp(0, 5)];
    _reconnectAttempts++;
    log('JSON_PAGE_WS :: reconnect in ${delay}s (attempt $_reconnectAttempts)');
    _reconnectTimer = Timer(Duration(seconds: delay), () {
      if (!_disposed) connect();
    });
  }

  void _cancelReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
  }

  /// Closes the connection and stops reconnecting.
  void disconnect() {
    _disposed = true;
    _cancelReconnect();
    _stopPing();
    _sub?.cancel();
    _sub = null;
    try {
      _channel?.sink.close();
    } catch (e) {
      // ignore
    }
    _channel = null;
    _connected = false;
    onConnectionState?.call(false);
  }

  /// Disposes the service (also stops reconnect).
  void dispose() {
    disconnect();
    _eventController.close();
  }
}

/// Read-only Firebase RTDB listener over REST Server-Sent Events (SSE).
///
/// Connects to `{databaseURL}/{feedPath}.json?access_token={token}` with the
/// `Accept: text/event-stream` header and emits a [RealtimeEvent] per `put`
/// event. Each camera is a child under `feedPath`, so a single SSE stream
/// delivers updates for every camera (home feed shows the latest per camera).
///
/// The token comes from the app-loading endpoint (`firebase.token`) and is
/// refreshed via `firebase.tokenUrl` when the stream closes with an auth error.
class FirebaseRealtimeService {
  FirebaseRealtimeService({
    required this.databaseURL,
    required this.feedPath,
    required this.token,
    required this.tokenUrl,
    this.onConnectionState,
  });

  final String databaseURL;
  final String feedPath;
  final String token;
  final String tokenUrl;
  final void Function(bool connected)? onConnectionState;

  final StreamController<RealtimeEvent> _eventController =
      StreamController<RealtimeEvent>.broadcast();
  http.Client? _client;
  StreamSubscription<String>? _sub;
  Timer? _reconnectTimer;
  bool _disposed = false;
  bool _connected = false;
  int _reconnectAttempts = 0;

  Stream<RealtimeEvent> get events => _eventController.stream;
  bool get isConnected => _connected;

  Uri get _streamUri {
    final String base = databaseURL.endsWith('/')
        ? databaseURL.substring(0, databaseURL.length - 1)
        : databaseURL;
    return Uri.parse('$base/$feedPath.json?access_token=$token');
  }

  Future<void> connect() async {
    if (_disposed) return;
    _cancelReconnect();
    try {
      log(
        'JSON_PAGE_FB :: connecting SSE to ${_streamUri.toString().replaceAll(token, '***')}',
      );
      _client = http.Client();
      final http.Request request = http.Request('GET', _streamUri)
        ..headers['Accept'] = 'text/event-stream';
      final http.StreamedResponse response = await _client!.send(request);
      if (response.statusCode != 200) {
        log('JSON_PAGE_FB :: HTTP ${response.statusCode}, will reconnect');
        _scheduleReconnect();
        return;
      }
      _connected = true;
      onConnectionState?.call(true);
      _reconnectAttempts = 0;
      _sub = response.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(
            _onLine,
            onError: _onError,
            onDone: _onDone,
            cancelOnError: false,
          );
    } catch (e, stack) {
      log('JSON_PAGE_FB :: connect error', error: e, stackTrace: stack);
      _scheduleReconnect();
    }
  }

  String? _eventType;
  StringBuffer _dataBuf = StringBuffer();

  void _onLine(String line) {
    if (line.startsWith('event:')) {
      _eventType = line.substring(6).trim();
      return;
    }
    if (line.startsWith('data:')) {
      _dataBuf.write(line.substring(5).trim());
      return;
    }
    if (line.isEmpty) {
      final String raw = _dataBuf.toString();
      _dataBuf = StringBuffer();
      final String? type = _eventType;
      _eventType = null;
      if (raw.isEmpty) return;
      _dispatch(type, raw);
    }
  }

  void _dispatch(String? type, String raw) {
    dynamic decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (e) {
      log('JSON_PAGE_FB :: failed to decode data: $raw');
      return;
    }
    if (decoded == null) return;
    if (decoded is! Map<String, dynamic>) return;
    final Map<String, dynamic> json = decoded;

    if (type == 'put' || type == 'patch') {
      final String path = (json['path'] as String?) ?? '/';
      final dynamic data = json['data'];
      if (data is Map<String, dynamic>) {
        final List<(String, Map<String, dynamic>)> pairs =
            _extractCameraPayloads(path, data);
        for (final (String camera, Map<String, dynamic> payload) in pairs) {
          _eventController.add(
            RealtimeEvent(
              type: 'photo.new',
              data: <String, dynamic>{
                'name': payload['camera'] ?? camera,
                'url': payload['url'] ?? '',
                'thumbnail': payload['thumbnail'] ?? '',
                'time': payload['time'] ?? '',
              },
            ),
          );
        }
      }
    }
  }

  List<(String, Map<String, dynamic>)> _extractCameraPayloads(
    String path,
    Map<String, dynamic> data,
  ) {
    final List<(String, Map<String, dynamic>)> out = [];
    final bool isRoot = path == '/' || path.isEmpty;
    final String cameraFromPath = isRoot ? '' : path.replaceFirst('/', '');

    if (isRoot) {
      data.forEach((String camera, dynamic payload) {
        if (payload is Map<String, dynamic>) {
          out.add((payload['camera'] ?? camera, payload));
        }
      });
    } else if (data.containsKey(cameraFromPath) &&
        data[cameraFromPath] is Map<String, dynamic>) {
      data.forEach((String camera, dynamic payload) {
        if (payload is Map<String, dynamic>) {
          out.add((payload['camera'] ?? camera, payload));
        }
      });
    } else {
      out.add((data['camera'] ?? cameraFromPath, data));
    }
    return out;
  }

  void _onError(Object error, StackTrace stack) {
    log('JSON_PAGE_FB :: stream error', error: error, stackTrace: stack);
    _connected = false;
    onConnectionState?.call(false);
    _scheduleReconnect();
  }

  void _onDone() {
    log('JSON_PAGE_FB :: stream closed');
    _connected = false;
    onConnectionState?.call(false);
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_disposed) return;
    _cancelReconnect();
    final int delay = [1, 2, 4, 8, 16, 30][_reconnectAttempts.clamp(0, 5)];
    _reconnectAttempts++;
    log('JSON_PAGE_FB :: reconnect in ${delay}s (attempt $_reconnectAttempts)');
    _reconnectTimer = Timer(Duration(seconds: delay), () {
      if (!_disposed) connect();
    });
  }

  void _cancelReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
  }

  void disconnect() {
    _disposed = true;
    _cancelReconnect();
    _sub?.cancel();
    _sub = null;
    _client?.close();
    _client = null;
    _connected = false;
    onConnectionState?.call(false);
  }

  void dispose() {
    disconnect();
    _eventController.close();
  }
}
