import 'dart:async';
import 'dart:developer';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:json_page/src/models/realtime_config.dart';
import 'package:json_page/src/services/realtime_service.dart';

/// Riverpod provider that owns the realtime connection lifecycle for camera
/// photos, driven entirely by a [RealtimeConfig].
///
/// - `poll`    → emits nothing (no connection; [RenderCameraWidget] reloads on
///   its own periodic timer).
/// - `firebase`→ opens an SSE stream to Firebase RTDB.
/// - `ws`      → opens a WebSocket to the gateway `feed` channel (no auth).
///
/// The host app passes its server-fetched [RealtimeConfig]; `json_page` does
/// the rest and exposes a stream of [RealtimeEvent]s (typically `photo.new`).
final realtimeProvider =
    StreamNotifierProvider.family<
      RealtimeNotifier,
      RealtimeEvent,
      RealtimeConfig
    >(RealtimeNotifier.new);

class RealtimeNotifier
    extends FamilyStreamNotifier<RealtimeEvent, RealtimeConfig>
    with WidgetsBindingObserver {
  RealtimeService? _wsService;
  FirebaseRealtimeService? _fbService;

  @override
  Stream<RealtimeEvent> build(RealtimeConfig config) {
    if (config.isPoll) {
      // Legacy poll mode: no connection. The camera tiles reload on their own
      // timer, so there is nothing to stream here.
      return const Stream.empty();
    }
    final StreamController<RealtimeEvent> controller =
        StreamController<RealtimeEvent>.broadcast();
    if (config.isWs) {
      _startWs(config, controller);
    } else if (config.isFirebase && config.firebase != null) {
      _startFirebase(config.firebase!, controller);
    }
    // React to app lifecycle changes (e.g. resume after a long sleep) so the
    // realtime connection is re-established and camera images reload.
    WidgetsBinding.instance.addObserver(this);
    ref.onDispose(() {
      WidgetsBinding.instance.removeObserver(this);
      _wsService?.dispose();
      _wsService = null;
      _fbService?.dispose();
      _fbService = null;
      controller.close();
    });
    return controller.stream;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      log('JSON_PAGE_RT :: app resumed — reconnecting realtime');
      // Force an immediate reconnect of whichever transport is active. This
      // recovers from a silently-dropped socket after the device slept.
      _fbService?.reconnectNow();
      _wsService?.reconnectNow();
    }
  }

  void _startWs(
    RealtimeConfig config,
    StreamController<RealtimeEvent> controller,
  ) {
    _wsService = RealtimeService(
      wsUrl: config.wsUrl,
      onConnectionState: (connected) =>
          log('JSON_PAGE_RT :: ws ${connected ? 'connected' : 'disconnected'}'),
    );
    _wsService!.events.listen(
      (event) => controller.add(event),
      onError: (e) => log('JSON_PAGE_RT :: ws event error: $e'),
    );
    _wsService!.connect();
  }

  void _startFirebase(
    FirebaseConfig fb,
    StreamController<RealtimeEvent> controller,
  ) {
    _fbService = FirebaseRealtimeService(
      databaseURL: fb.databaseURL,
      feedPath: fb.feedPath,
      token: fb.token,
      tokenUrl: fb.tokenUrl,
      onConnectionState: (connected) => log(
        'JSON_PAGE_RT :: firebase ${connected ? 'connected' : 'disconnected'}',
      ),
    );
    _fbService!.events.listen(
      (event) => controller.add(event),
      onError: (e) => log('JSON_PAGE_RT :: firebase event error: $e'),
    );
    _fbService!.connect();
  }
}
