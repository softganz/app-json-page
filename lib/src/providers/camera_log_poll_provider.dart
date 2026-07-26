import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

/// Page-level owner of the `last.json` (camera log) poll.
///
/// A single provider instance fetches the log file ONCE per
/// [CameraLogPollParams.intervalSeconds] and shares the parsed
/// `name -> updateAt` map with every [RenderCameraWidget] on the page. This
/// guarantees exactly one `last.json` request per poll round regardless of how
/// many `cameraSet` widgets are visible or how often the user scrolls — and
/// lets a `cameraSet` that scrolls into view reconcile against the already
/// fetched map immediately, without triggering a new `last.json` request.
class CameraLogPollParams {
  const CameraLogPollParams(this.logUrl, this.intervalSeconds);

  /// Full log-file URL: `cameraPhoto + cameraLogPhoto`.
  final String logUrl;

  /// Poll interval in seconds (from page `cameraPoolInterval`).
  final int intervalSeconds;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CameraLogPollParams &&
          logUrl == other.logUrl &&
          intervalSeconds == other.intervalSeconds;

  @override
  int get hashCode => Object.hash(logUrl, intervalSeconds);
}

/// Shared state produced by [cameraLogPollProvider].
class CameraLogPollState {
  const CameraLogPollState(this.updateAt, this.tick);

  /// Parsed `name -> updateAt` from the log file. Empty when no log is
  /// configured or the fetch failed (callers fall back to reloading all).
  final Map<String, String> updateAt;

  /// Increments on every poll cycle (whether or not the map changed) so
  /// widgets can reconcile against the latest map each round.
  final int tick;
}

final cameraLogPollProvider =
    AsyncNotifierProvider.family<
      CameraLogPollNotifier,
      CameraLogPollState,
      CameraLogPollParams
    >(CameraLogPollNotifier.new);

class CameraLogPollNotifier
    extends FamilyAsyncNotifier<CameraLogPollState, CameraLogPollParams> {
  Timer? _timer;

  @override
  Future<CameraLogPollState> build(CameraLogPollParams p) async {
    final Map<String, String> map = await _fetch(p.logUrl);
    _start(p);
    ref.onDispose(() => _timer?.cancel());
    return CameraLogPollState(map, 0);
  }

  void _start(CameraLogPollParams p) {
    _timer?.cancel();
    _timer = Timer.periodic(Duration(seconds: p.intervalSeconds), (_) {
      _fetch(p.logUrl).then((map) {
        final int tick = state.valueOrNull?.tick ?? 0;
        state = AsyncValue.data(CameraLogPollState(map, tick + 1));
      });
    });
  }

  /// Fetches and parses the log file into a `name -> updateAt` map. Returns an
  /// empty map on any failure (no log, network error, invalid JSON) so the
  /// caller can fall back to reloading every camera.
  static Future<Map<String, String>> _fetch(String url) async {
    try {
      final http.Response res = await http.get(Uri.parse(url));
      if (res.statusCode != 200) return const {};
      final dynamic decoded = json.decode(utf8.decode(res.bodyBytes));
      if (decoded is! Map) return const {};
      final Map<String, String> out = {};
      decoded.forEach((key, value) {
        if (value is Map && value['updateAt'] != null) {
          out[value['name']?.toString() ?? key.toString()] = value['updateAt']
              .toString();
        }
      });
      return out;
    } catch (_) {
      return const {};
    }
  }
}
