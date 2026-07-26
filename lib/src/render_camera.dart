import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'package:json_page/src/models/page_model.dart';

/// Renders a feed item of `type: cameraSet`.
///
/// Each child camera is shown as a rounded tile with its title. The image URL
/// is built as: `cameraPhoto + cameraLastPhoto + name + ".jpg"`
/// (e.g. `https://hatyaicityclimate.org/floodphoto/last/muangkong.jpg`).
///
/// The tile auto-refreshes every minute (per the realtime cadence described in
/// `.github/instructions`) by appending a cache-busting query param.
class RenderCameraWidget extends StatefulWidget {
  const RenderCameraWidget({
    super.key,
    required this.item,
    required this.cameraPhoto,
    required this.cameraLastPhoto,
    required this.cameraRealtimePhoto,
    this.cameraLogPhoto = '',
    this.reloadTimeSeconds = 60,
    this.externalTick = 0,
    this.realtimeActive = false,
    this.onLinkTap,
  });

  final PageItem item;
  final String cameraPhoto;
  final String cameraLastPhoto;
  final String cameraRealtimePhoto;

  /// Optional log-file name (relative to [cameraPhoto]) that lists each
  /// camera's latest `updateAt`. When non-empty, polling reads this file and
  /// reloads only cameras whose `updateAt` changed since the last poll.
  /// When empty (or the file is unreachable), polling falls back to reloading
  /// every camera image each round.
  final String cameraLogPhoto;

  /// Camera auto-reload interval in seconds (from page `cameraPoolInterval`).
  /// Defaults to 60 when not provided.
  final int reloadTimeSeconds;

  /// When true, a realtime connection (firebase/ws) owns photo updates, so the
  /// periodic 60s poll timer is disabled — the image reloads only on a
  /// `photo.new` event (via [externalTick] or a child's `time` change). In
  /// `poll` mode this stays false and the timer runs as a fallback.
  final bool realtimeActive;

  /// External tick that forces an immediate image reload when it changes.
  /// Driven by realtime photo.new events (e.g. Firebase RTDB push) so the
  /// displayed camera image refreshes the moment a new photo is available,
  /// without waiting for the periodic [reloadTimeSeconds] timer.
  final int externalTick;

  /// Called when a tappable child is tapped. When null, taps are ignored.
  final void Function(BuildContext context, LinkTarget target)? onLinkTap;

  /// How often the camera image is re-fetched (realtime cadence).
  static const Duration refreshInterval = Duration(minutes: 1);

  @override
  State<RenderCameraWidget> createState() => _RenderCameraWidgetState();
}

/// A single in-flight (or recently completed) log fetch, shared across all
/// `cameraSet` widgets that poll the same log URL within [_logCacheTtl].
class _LogCacheEntry {
  const _LogCacheEntry(this.future, this.expiresAt);

  /// The shared fetch result. Widgets awaiting this future all get the same
  /// parsed `name -> updateAt` map without extra network requests.
  final Future<Map<String, String>?> future;

  /// When this entry stops being reused (next poll round re-fetches).
  final DateTime expiresAt;
}

class _RenderCameraWidgetState extends State<RenderCameraWidget> {
  int _tick = 0;
  Timer? _refreshTimer;

  /// Shared, per-URL cache of the most recent log fetch. Collapses concurrent
  /// polls from multiple `cameraSet` widgets into a SINGLE network request
  /// per round (keyed by the log URL). Entries expire after [_logCacheTtl]
  /// so the next poll round re-fetches fresh data from the server.
  static final Map<String, _LogCacheEntry> _logCache = {};

  /// How long a cached log fetch stays valid. Must be shorter than the poll
  /// interval so each round triggers exactly one fresh request, while long
  /// enough to cover the few-millisecond spread between widget timers.
  static const Duration _logCacheTtl = Duration(seconds: 5);

  /// Latest `updateAt` per camera `name`, read from the log file. Used to
  /// detect which cameras changed between polls so only those reload.
  final Map<String, String> _lastUpdateAt = {};

  /// Whether the log file is currently usable. When false (no `cameraLogPhoto`,
  /// fetch error, or invalid JSON) we fall back to reloading every camera.
  bool _logAvailable = false;

  /// Cameras that changed in the most recent poll and should reload this round.
  final Set<String> _changedNames = {};

  /// Resolves the full log-file URL: `cameraPhoto + cameraLogPhoto`.
  String get _logUrl => '${widget.cameraPhoto}${widget.cameraLogPhoto}';

  /// Fetches and parses the log file into a `name -> updateAt` map.
  ///
  /// Returns `null` on any failure (no log configured, network error, invalid
  /// JSON) so the caller can fall back to reloading every camera.
  Future<Map<String, String>?> _fetchLog() async {
    if (widget.cameraLogPhoto.isEmpty) return null;
    final String url = _logUrl;
    final DateTime now = DateTime.now();
    final _LogCacheEntry? cached = _logCache[url];
    if (cached != null && cached.expiresAt.isAfter(now)) {
      // Another widget already fetched (or is fetching) this URL this round.
      // Reuse the single network request instead of hitting the server again.
      return cached.future;
    }

    // Cache miss (or expired): own this round's fetch so sibling widgets
    // share it. The future is stored immediately so concurrent callers within
    // the TTL reuse the same in-flight request.
    final Completer<Map<String, String>?> completer =
        Completer<Map<String, String>?>();
    _logCache[url] = _LogCacheEntry(completer.future, now.add(_logCacheTtl));

    final String pollStart = _nowHms();
    debugPrint(
      '[log] JSON_PAGE:: RenderCamera fetch log $url (poll start $pollStart)',
    );
    try {
      final http.Response res = await http.get(Uri.parse(url));
      debugPrint(
        '[log] JSON_PAGE:: RenderCamera log response '
        'status=${res.statusCode}',
      );
      if (res.statusCode != 200) {
        completer.complete(null);
        return completer.future;
      }
      final dynamic decoded = json.decode(utf8.decode(res.bodyBytes));
      if (decoded is! Map) {
        completer.complete(null);
        return completer.future;
      }
      final Map<String, String> result = {};
      decoded.forEach((key, value) {
        if (value is Map && value['updateAt'] != null) {
          result[value['name']?.toString() ?? key.toString()] =
              value['updateAt'].toString();
        }
      });
      completer.complete(result);
      return completer.future;
    } catch (_) {
      completer.complete(null);
      return completer.future;
    }
  }

  /// Reloads only the cameras whose `updateAt` changed in the log, or every
  /// camera when the log is unavailable. Returns the names that were reloaded.
  Future<Set<String>> _pollChanged() async {
    final Map<String, String>? log = await _fetchLog();
    if (log == null) {
      // Fallback: reload every camera (no log or fetch failed).
      _logAvailable = false;
      final Set<String> all = {
        for (final PageChild c in widget.item.children)
          if ((c.name ?? '').isNotEmpty) c.name!,
      };
      _changedNames
        ..clear()
        ..addAll(all);
      return all;
    }
    _logAvailable = true;
    final Set<String> changed = {};
    for (final MapEntry<String, String> e in log.entries) {
      final String prev = _lastUpdateAt[e.key] ?? '';
      if (prev != e.value) {
        changed.add(e.key);
        debugPrint(
          '[log] JSON_PAGE:: RenderCamera update image '
          '"${e.key}" updateAt $prev -> ${e.value}',
        );
      }
    }
    _lastUpdateAt
      ..clear()
      ..addAll(log);
    _changedNames
      ..clear()
      ..addAll(changed);
    return changed;
  }

  @override
  void didUpdateWidget(covariant RenderCameraWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Realtime push: a changed externalTick forces an immediate reload.
    if (widget.externalTick != oldWidget.externalTick) {
      if (mounted) {
        setState(() => _tick++);
      }
    }
    // Realtime photo.new: when a child's photo `time` changes, reload that
    // child's live image immediately (cache-bust via _tick) so the new photo
    // shows without waiting for the periodic timer. Only the affected
    // cameraSet widget reloads — other sets are untouched.
    for (int i = 0; i < widget.item.children.length; i++) {
      final PageChild child = widget.item.children[i];
      final PageChild? oldChild = i < oldWidget.item.children.length
          ? oldWidget.item.children[i]
          : null;
      if (child.time != oldChild?.time && (child.time ?? '').isNotEmpty) {
        if (mounted) {
          setState(() => _tick++);
          debugPrint(
            '[log] JSON_PAGE:: RenderCamera firebase realtime reload '
            '(time=${child.time}) for camera "${child.name ?? ''}"',
          );
        }
        break;
      }
    }
  }

  @override
  void initState() {
    super.initState();
    // Only auto-reload when there is at least one camera (a child with a
    // `name` attribute). Children that use their own `image` are never
    // reloaded, so a timer would be wasted for image-only sets.
    final bool hasCamera = widget.item.children.any(
      (c) => (c.name ?? '').isNotEmpty,
    );
    // In realtime mode (firebase/ws) the connection owns photo updates, so we
    // must NOT run the periodic poll timer — otherwise it would reload every
    // 60s regardless of realtime. Only start the timer when realtime is off.
    if (hasCamera && !widget.realtimeActive) {
      debugPrint(
        '[log] JSON_PAGE:: RenderCamera start auto-reload every '
        '${widget.reloadTimeSeconds > 0 ? widget.reloadTimeSeconds : 60}s '
        'for "${widget.item.title ?? ''}"',
      );
      _scheduleRefresh();
    } else if (hasCamera && widget.realtimeActive) {
      debugPrint(
        '[log] JSON_PAGE:: RenderCamera realtime active — poll timer disabled '
        'for "${widget.item.title ?? ''}"',
      );
    }
  }

  void _scheduleRefresh() {
    _refreshTimer?.cancel();
    final int seconds = widget.reloadTimeSeconds > 0
        ? widget.reloadTimeSeconds
        : 60;
    _refreshTimer = Timer(Duration(seconds: seconds), () {
      if (!mounted) return;
      // This branch only runs when the poll timer is active (realtime off),
      // so the reload log reflects genuine periodic polling — never a
      // realtime-driven refresh.
      _pollChanged().then((changed) {
        if (!mounted) return;
        if (changed.isEmpty) {
          debugPrint(
            '[log] JSON_PAGE:: RenderCamera poll #${_tick + 1} '
            'no camera changed for "${widget.item.title ?? ''}"',
          );
          // No camera updated this round: rebuild so the green "updated"
          // highlight from a previous round is cleared and badges revert to
          // gray. We do NOT bump [_tick], so unchanged cameras keep showing
          // their last loaded frame (no extra network reload).
          if (mounted) setState(() {});
          _scheduleRefresh();
          return;
        }
        for (final String name in changed) {
          debugPrint(
            '[log] JSON_PAGE:: RenderCamera updating image "$name" '
            '-> ${widget.cameraPhoto}${widget.cameraLastPhoto}$name.jpg',
          );
        }
        setState(() => _tick++);
        _scheduleRefresh();
      });
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  /// Current time formatted as `HH:MM:SS`, used for poll-start timestamps.
  String _nowHms() {
    final DateTime n = DateTime.now();
    String p(int v) => v.toString().padLeft(2, '0');
    return '${p(n.hour)}:${p(n.minute)}:${p(n.second)}';
  }

  String _buildUrl(PageChild child) {
    final String name = child.name ?? '';
    final String base =
        '${widget.cameraPhoto}${widget.cameraLastPhoto}$name.jpg';
    // Cache-bust so the network image reloads on each tick. When log-driven
    // polling is active, only cameras in [_changedNames] get a fresh tick;
    // others keep showing their last loaded frame (no extra network hit).
    final int tick = (_logAvailable && !_changedNames.contains(name))
        ? _tick - 1
        : _tick;
    return '$base?t=$tick';
  }

  Widget _cameraImage(PageChild child, {double? height, double? borderRadius}) {
    final Widget image = Image.network(
      _buildUrl(child),
      fit: BoxFit.cover,
      width: double.infinity,
      height: height,
      // Keep showing the previous frame until the new image is fully loaded,
      // then swap in place (no clearing/placeholder between refreshes).
      gaplessPlayback: true,
      errorBuilder: (context, error, stackTrace) => _imagePlaceholder(height),
    );

    // Round by default (12). An item-level `photoBorderRadius` or a
    // child-level `borderRadius` overrides the default; item takes precedence.
    final double radius = borderRadius ?? child.borderRadius ?? 12;
    return ClipRRect(borderRadius: BorderRadius.circular(radius), child: image);
  }

  /// Renders a child's own `image` attribute (when present) the same way the
  /// `image` feed type does: a network image with a loading spinner and a
  /// broken-image fallback. Used instead of the camera feed when a child
  /// declares an `image` URL.
  Widget _childImage(PageChild child, {double? height, double? borderRadius}) {
    final Widget image = Image.network(
      child.image!,
      fit: BoxFit.cover,
      width: double.infinity,
      height: height,
      loadingBuilder: (context, widget, loadingProgress) {
        if (loadingProgress == null) return widget;
        return const Center(child: CircularProgressIndicator());
      },
      errorBuilder: (context, error, stackTrace) => _imagePlaceholder(height),
    );

    final double radius = borderRadius ?? child.borderRadius ?? 12;
    return ClipRRect(borderRadius: BorderRadius.circular(radius), child: image);
  }

  /// A neutral empty placeholder that keeps the exact image dimensions
  /// (`height`, full width) so the layout never shifts when a camera photo
  /// fails to load (broken/incomplete image). Uses a gray background close to
  /// the time badge's `Colors.grey` instead of a broken-image icon so the
  /// tile stays clean.
  Widget _imagePlaceholder(double? height) {
    return Container(
      width: double.infinity,
      height: height,
      color: Colors.grey.shade400,
    );
  }

  @override
  Widget build(BuildContext context) {
    final List<PageChild> children = widget.item.children
        .where((c) => (c.name ?? '').isNotEmpty || (c.image ?? '').isNotEmpty)
        .toList();

    if (children.isEmpty) {
      return const SizedBox.shrink();
    }

    final bool horizontal = widget.item.layout == 'horizontal';
    final double gap = widget.item.gap ?? 0;

    // Photo width from the `photoWidth` attribute. A bare number (e.g. "80")
    // is treated as a pixel width; a percentage (e.g. "80%") is a fraction of
    // the available width. Defaults to 1/3 of the available width.
    double? photoWidthPixels;
    double photoWidthFraction = 1 / 3;
    final String? photoWidth = widget.item.photoWidth;
    if (photoWidth != null) {
      final String trimmed = photoWidth.trim();
      final String numeric = trimmed.endsWith('%')
          ? trimmed.substring(0, trimmed.length - 1)
          : trimmed;
      final double? num = double.tryParse(numeric);
      if (num != null && num > 0) {
        if (trimmed.endsWith('%')) {
          photoWidthFraction = num / 100;
        } else {
          photoWidthPixels = num;
        }
      }
    }

    // Fixed image height so all cameras share the same frame; the image is
    // cropped to its center (BoxFit.cover) instead of being stretched.
    // Overridden by the item-level `photoHeight` attribute (a bare number is
    // treated as pixels; a percentage is a fraction of the tile width).
    final double defaultHeight = horizontal ? 180 : 200;
    double? photoHeightPixels;
    double? photoHeightFraction;
    final String? photoHeight = widget.item.photoHeight;
    if (photoHeight != null) {
      final String trimmed = photoHeight.trim();
      final String numeric = trimmed.endsWith('%')
          ? trimmed.substring(0, trimmed.length - 1)
          : trimmed;
      final double? num = double.tryParse(numeric);
      if (num != null && num > 0) {
        if (trimmed.endsWith('%')) {
          photoHeightFraction = num / 100;
        } else {
          photoHeightPixels = num;
        }
      }
    }

    // Resolve the photo height (in pixels) from the tile width so a
    // `photoHeight` percentage is relative to the actual image width.
    // When `photoHeight` is not set, fall back to the default per-layout height.
    double resolveHeight(double tileWidth) =>
        photoHeightPixels ??
        (photoHeightFraction == null
            ? defaultHeight
            : tileWidth * photoHeightFraction);
    Future<void> onTap(PageChild child) async {
      final void Function(BuildContext, LinkTarget)? handler = widget.onLinkTap;
      if (handler == null) return;
      // A `route` navigates to a named route in the app (e.g. "/about").
      final String? route = child.route;
      if (route != null && route.isNotEmpty) {
        handler(
          context,
          LinkTarget(
            route: route,
            routeArgs: child.routeArgs,
            title: child.title,
          ),
        );
        return;
      }

      // A `webViewUrl` opens the in-app WebScreen; otherwise fall back to the
      // item-level `webViewUrl` template (resolved against this child's
      // attributes), and finally launch `url` externally when present.
      final String? webViewUrl = child.webViewUrl;
      if (webViewUrl != null && webViewUrl.isNotEmpty) {
        handler(
          context,
          LinkTarget(webViewUrl: webViewUrl, title: child.title),
        );
        return;
      }

      final String? itemTemplate = widget.item.webViewUrl;
      final String? resolvedTemplate =
          itemTemplate != null && itemTemplate.isNotEmpty
          ? child.resolveTemplate(itemTemplate)
          : null;
      if (resolvedTemplate != null && resolvedTemplate.isNotEmpty) {
        handler(
          context,
          LinkTarget(webViewUrl: resolvedTemplate, title: child.title),
        );
        return;
      }

      final String? url = child.url;
      if (url == null || url.isEmpty) return;
      handler(context, LinkTarget(url: url, title: child.title));
    }

    Widget cameraTile(PageChild child, double tileWidth) {
      // If the child declares its own `image`, render it like the `image`
      // type; otherwise render the live camera feed built from `name`.
      final bool hasImage = child.image != null && child.image!.isNotEmpty;
      final Widget imageWidget = hasImage
          ? _childImage(
              child,
              height: resolveHeight(tileWidth),
              borderRadius: widget.item.photoBorderRadius,
            )
          : _cameraImage(
              child,
              height: resolveHeight(tileWidth),
              borderRadius: widget.item.photoBorderRadius,
            );

      // A camera is "updated" when it changed in the latest poll round
      // (log-driven mode, tracked in [_changedNames]) OR when a realtime
      // photo event set its `time` (realtime mode). Updated cameras show a
      // green background on BOTH the code badge and the time pill; otherwise
      // they stay gray (initial state). Cameras that never change keep gray.
      final String name = child.name ?? '';
      final bool changedThisRound = _changedNames.contains(name);
      final bool hasRealtimeTime = child.time != null && child.time!.isNotEmpty;
      final bool isUpdated = changedThisRound || hasRealtimeTime;
      final Color badgeColor = isUpdated ? Colors.green : Colors.grey;
      // Time to display: prefer the realtime `time`; fall back to the log's
      // `updateAt` so poll-mode updates also show when the photo changed.
      final String displayTime = hasRealtimeTime
          ? child.time!
          : (_lastUpdateAt[name] ?? '');
      // Overlay the child's `code` as a rounded badge at the top-left corner
      // of the image (background label), and the photo `time` as a small pill
      // at the top-right corner (smallest font).
      final List<Widget> overlays = [];
      if (child.code != null && child.code!.isNotEmpty) {
        overlays.add(
          Positioned(
            top: 6,
            left: 6,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: badgeColor,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                child.code!,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 8,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
        );
      }
      if (isUpdated && displayTime.isNotEmpty) {
        overlays.add(
          Positioned(
            top: 6,
            right: 6,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: badgeColor,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                displayTime,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 7,
                  fontWeight: FontWeight.w400,
                ),
              ),
            ),
          ),
        );
      }
      final Widget imageWithBadge = overlays.isNotEmpty
          ? Stack(children: [imageWidget, ...overlays])
          : imageWidget;

      final Widget tile = Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          imageWithBadge,
          if (child.title != null && child.title!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
              child: SizedBox(
                width: double.infinity,
                height: 24,
                child: Text(
                  child.title!,
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ),
        ],
      );

      // If the child has a `url` or `webViewUrl`, or the item declares a
      // `webViewUrl` template that resolves for this child, tapping the tile
      // opens it (just like the `image` type).
      final bool tappable =
          (child.url != null && child.url!.isNotEmpty) ||
          (child.webViewUrl != null && child.webViewUrl!.isNotEmpty) ||
          (widget.item.webViewUrl != null &&
              widget.item.webViewUrl!.isNotEmpty &&
              child.resolveTemplate(widget.item.webViewUrl) != null);
      if (!tappable) return tile;
      return GestureDetector(onTap: () => onTap(child), child: tile);
    }

    final bool isGrid = widget.item.layout == 'grid';

    final Widget body = isGrid
        ? LayoutBuilder(
            builder: (context, constraints) {
              // A responsive grid. The number of columns defaults to 2 and can
              // be overridden with the `columns` attribute (clamped to 1..6).
              final int columns = (widget.item.columns ?? 2).clamp(1, 6);
              // Actual grid cell width, accounting for the outer padding and
              // the spacing between columns.
              final double availableWidth = constraints.maxWidth - gap * 2;
              final double cellWidth =
                  (availableWidth - gap * (columns - 1)) / columns;
              // Resolve tile width relative to the cell. A bare-number
              // `photoWidth` is used directly; a percentage is relative to the
              // cell; when `photoWidth` is omitted the tile fills the cell.
              final double fraction = widget.item.photoWidth != null
                  ? photoWidthFraction
                  : 1.0;
              final double tileWidth = photoWidthPixels ?? cellWidth * fraction;
              // Match the grid cell height to the tile's actual image height
              // (`resolveHeight`, which already honours `photoHeight`) plus the
              // title row below it, so the tile fills the cell exactly.
              final double tileHeight = resolveHeight(tileWidth);
              const double titleHeight = 36;
              final double cellHeight = tileHeight + titleHeight;
              return Padding(
                padding: EdgeInsets.all(gap),
                child: GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: columns,
                    mainAxisSpacing: gap,
                    crossAxisSpacing: gap,
                    childAspectRatio: tileWidth / cellHeight,
                  ),
                  itemCount: children.length,
                  itemBuilder: (context, index) =>
                      cameraTile(children[index], tileWidth),
                ),
              );
            },
          )
        : horizontal
        ? LayoutBuilder(
            builder: (context, constraints) {
              final double tileWidth =
                  photoWidthPixels ?? constraints.maxWidth * photoWidthFraction;
              return Padding(
                padding: EdgeInsets.symmetric(horizontal: gap),
                child: SizedBox(
                  height: 220,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: children.length,
                    separatorBuilder: (context, index) => SizedBox(width: gap),
                    itemBuilder: (context, index) => SizedBox(
                      width: tileWidth,
                      child: cameraTile(children[index], tileWidth),
                    ),
                  ),
                ),
              );
            },
          )
        : LayoutBuilder(
            builder: (context, constraints) {
              final double tileWidth =
                  photoWidthPixels ?? constraints.maxWidth * photoWidthFraction;
              return Padding(
                padding: EdgeInsets.symmetric(vertical: gap),
                child: ListView.separated(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: children.length,
                  separatorBuilder: (context, index) => SizedBox(height: gap),
                  itemBuilder: (context, index) => SizedBox(
                    width: tileWidth,
                    child: cameraTile(children[index], tileWidth),
                  ),
                ),
              );
            },
          );

    final bool isDark = Theme.of(context).brightness == Brightness.dark;
    final Color backgroundColor = isDark
        ? const Color(0xFF333333)
        : Colors.white;

    return Container(
      color: backgroundColor,
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.item.title != null && widget.item.title!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
              child: Row(
                children: [
                  const Icon(Icons.videocam, size: 26),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      widget.item.title!,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                ],
              ),
            ),
          body,
        ],
      ),
    );
  }
}
