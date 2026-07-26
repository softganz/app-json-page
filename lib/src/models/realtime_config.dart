/// Realtime configuration + event models for `json_page`.
///
/// These types are transport-agnostic: the host app builds a [RealtimeConfig]
/// (typically from a server `realtime` block) and passes it to [RenderView].
/// `json_page` then owns the connection and applies `photo.new` events in-place.
library;

/// A typed realtime event received from a realtime source (WS or Firebase RTDB).
class RealtimeEvent {
  const RealtimeEvent({required this.type, required this.data});

  factory RealtimeEvent.fromJson(Map<String, dynamic> json) {
    return RealtimeEvent(
      type: (json['type'] as String?) ?? '',
      data: json['data'] as Map<String, dynamic>? ?? {},
    );
  }

  /// Event type, e.g. `photo.new`, `request.status`.
  final String type;

  /// Event payload (the `data` object of the source message).
  final Map<String, dynamic> data;
}

/// Firebase Realtime Database connection details (used when
/// [RealtimeConfig.type] is `firebase`). The app reads RTDB via REST + SSE
/// (no native SDK, so no `google-services.json` / `GoogleService-Info.plist`).
class FirebaseConfig {
  const FirebaseConfig({
    required this.databaseURL,
    required this.feedPath,
    required this.token,
    required this.tokenUrl,
  });

  final String databaseURL;
  final String feedPath;
  final String token;
  final String tokenUrl;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FirebaseConfig &&
          databaseURL == other.databaseURL &&
          feedPath == other.feedPath &&
          token == other.token &&
          tokenUrl == other.tokenUrl;

  @override
  int get hashCode =>
      databaseURL.hashCode ^
      feedPath.hashCode ^
      token.hashCode ^
      tokenUrl.hashCode;
}

/// Server-driven realtime configuration for camera-photo updates.
///
/// The `type` field selects the transport:
/// - `ws`      → WebSocket gateway (home feed broadcast, no auth for feed).
/// - `firebase`→ Firebase RTDB over REST SSE.
/// - `poll`    → legacy HTTP poll / manual refresh (no connection opened).
class RealtimeConfig {
  const RealtimeConfig({
    required this.type,
    this.wsUrl = '',
    this.pollFallbackInterval = const Duration(milliseconds: 30000),
    this.poolInterval = const Duration(seconds: 60),
    this.firebase,
  });

  const RealtimeConfig.disabled()
    : type = 'poll',
      wsUrl = '',
      pollFallbackInterval = const Duration(milliseconds: 30000),
      poolInterval = const Duration(seconds: 60),
      firebase = null;

  /// `ws` | `firebase` | `poll`
  final String type;
  final String wsUrl;
  final Duration pollFallbackInterval;

  /// Poll interval for `poll` mode (camera photo reload cadence). Comes from
  /// the server `realtime.poolInterval` (seconds). Defaults to 60s.
  final Duration poolInterval;
  final FirebaseConfig? firebase;

  bool get isWs => type == 'ws';
  bool get isFirebase => type == 'firebase';
  bool get isPoll => type == 'poll';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RealtimeConfig &&
          type == other.type &&
          wsUrl == other.wsUrl &&
          pollFallbackInterval == other.pollFallbackInterval &&
          poolInterval == other.poolInterval &&
          firebase == other.firebase;

  @override
  int get hashCode =>
      type.hashCode ^
      wsUrl.hashCode ^
      pollFallbackInterval.hashCode ^
      poolInterval.hashCode ^
      firebase.hashCode;
}
