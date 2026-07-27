import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import 'package:json_page/src/models/page_model.dart';
import 'package:json_page/src/providers/camera_log_poll_provider.dart';

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
    this.cameraThumbPhoto = '',
    this.reloadTimeSeconds = 60,
    this.externalTick = 0,
    this.realtimeActive = false,
    this.pollFallbackInterval = const Duration(seconds: 30),
    this.realtimeMode = 'poll',
    this.logPoll,
    this.onLinkTap,
  });

  /// Optional page-level `last.json` poll state. When non-null, this widget
  /// reconciles against the shared `name -> updateAt` map instead of running
  /// its own poll timer, so a set that scrolls into view updates immediately
  /// without a new `last.json` request. When null, the widget falls back to a
  /// local timer (legacy behaviour / no shared poll available).
  final AsyncValue<CameraLogPollState>? logPoll;

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

  /// Optional thumbnail folder (relative to [cameraPhoto]). When non-empty the
  /// feed loads `{name}-th.jpg` from here instead of the full image, saving
  /// bandwidth and decode memory on the small tiles.
  final String cameraThumbPhoto;

  /// Camera auto-reload interval in seconds (from page `cameraPoolInterval`).
  /// Defaults to 60 when not provided.
  final int reloadTimeSeconds;

  /// Safety-net poll interval used when realtime is active. When the realtime
  /// connection is alive this is just a fallback; when it dies (e.g. after a
  /// long sleep) the images still refresh on this cadence so the feed never
  /// goes permanently blank. From [RealtimeConfig.pollFallbackInterval].
  final Duration pollFallbackInterval;

  /// When true, a realtime connection (firebase/ws) owns photo updates, so the
  /// periodic 60s poll timer is disabled — the image reloads only on a
  /// `photo.new` event (via [externalTick] or a child's `time` change). In
  /// `poll` mode this stays false and the timer runs as a fallback.
  final bool realtimeActive;

  /// The active realtime transport name (`poll`, `firebase`, `ws`) used only
  /// for log labelling so debug output reflects the actual mode instead of a
  /// hard-coded "Poll mode" string.
  final String realtimeMode;

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

class _RenderCameraWidgetState extends State<RenderCameraWidget> {
  /// Latest `updateAt` per camera `name` that we have already shown. Kept
  /// static so it survives widget disposal when a `cameraSet` scrolls
  /// off-screen and back — this is what lets scrolling keep the existing image
  /// instead of reloading every camera on remount. Fed by the shared
  /// page-level [widget.logPoll] map.
  static final Map<String, String> _lastUpdateAt = {};

  /// Per-camera cache-bust tick, keyed by camera `name`. Static so it survives
  /// disposal: a camera's tick only changes when its photo is genuinely new,
  /// so unchanged cameras keep the same image URL and reuse the cached image
  /// (scrolling never triggers a reload for them).
  static final Map<String, int> _cameraTick = {};

  /// Last image URL actually loaded per camera `name`. Static so the
  /// "load image" log only prints when the URL genuinely changes (dedupes
  /// rebuilds/scrolls that reuse the same cached URL).
  static final Map<String, String> _loadedUrl = {};

  /// Reconciles THIS widget's cameras against the shared [updateAt] map.
  ///
  /// Iterates only this widget's own children (not the whole page map) and
  /// looks each camera `name` up in [updateAt]. This keeps each `cameraSet`
  /// independent: a widget only updates its own cameras' last-seen `updateAt`,
  /// so it never clobbers another widget's change detection (which the old
  /// full-map `..clear()..addAll` did, causing only the topmost set to update).
  ///
  /// Returns the set of this widget's camera names whose `updateAt` changed
  /// since the last reconcile. When [updateAt] is empty (no log / fetch
  /// failed) it returns no changes so the currently displayed images are kept
  /// (scrolling never reloads just because the log is temporarily down).
  Set<String> _reconcile(Map<String, String> updateAt) {
    if (updateAt.isEmpty) {
      // No log / fetch failed: keep the currently displayed images and do NOT
      // force a reload. Change detection resumes once the log is available.
      return const {};
    }
    final Set<String> changed = {};
    for (final PageChild c in widget.item.children) {
      final String name = c.name ?? '';
      if (name.isEmpty) continue;
      final String value = updateAt[name] ?? '';
      final String prev = _lastUpdateAt[name] ?? '';
      if (prev != value) {
        changed.add(name);
        // Bump only this camera's cache-bust tick so its image refetches.
        // Cameras that did not change keep their previous tick and reuse the
        // cached image — scrolling never triggers a reload for them.
        _cameraTick[name] = (_cameraTick[name] ?? 0) + 1;
        debugPrint(
          '[log] JSON_PAGE:: ${widget.realtimeMode} mode RenderCamera update image '
          '"$name" updateAt $prev -> $value',
        );
      }
      // Record this camera's last-seen value (per-camera, no full-map clear)
      // so disposal/remount keeps the cached image until a real change.
      _lastUpdateAt[name] = value;
    }
    return changed;
  }

  @override
  void didUpdateWidget(covariant RenderCameraWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Realtime push: a changed externalTick forces an immediate reload of every
    // camera in this set (bump each camera's cache-bust tick).
    if (widget.externalTick != oldWidget.externalTick) {
      if (mounted) {
        for (final PageChild c in widget.item.children) {
          final String n = c.name ?? '';
          if (n.isNotEmpty) _cameraTick[n] = (_cameraTick[n] ?? 0) + 1;
        }
        setState(() {});
      }
    }
    // Realtime photo.new: when a child's photo `time` changes, reload that
    // child's live image immediately (bump its cache-bust tick) so the new
    // photo shows without waiting for the periodic timer. Only the affected
    // camera reloads — other cameras keep their cached image.
    for (int i = 0; i < widget.item.children.length; i++) {
      final PageChild child = widget.item.children[i];
      final PageChild? oldChild = i < oldWidget.item.children.length
          ? oldWidget.item.children[i]
          : null;
      if (child.time != oldChild?.time && (child.time ?? '').isNotEmpty) {
        final String n = child.name ?? '';
        if (n.isNotEmpty) _cameraTick[n] = (_cameraTick[n] ?? 0) + 1;
        if (mounted) {
          setState(() {});
          debugPrint(
            '[log] JSON_PAGE:: ${widget.realtimeMode} mode RenderCamera reload '
            '(time=${child.time}) for camera "$n"',
          );
        }
        break;
      }
    }
    // Shared page-level poll: when the poll tick changes, reconcile against the
    // latest shared map so only cameras whose `updateAt` changed reload. This
    // fires for every visible set each round (and for a set that just scrolled
    // into view, because the provider already holds the latest map).
    final int? tick = widget.logPoll?.valueOrNull?.tick;
    final int? oldTick = oldWidget.logPoll?.valueOrNull?.tick;
    if (tick != null && tick != oldTick) {
      _reconcileAndReload(widget.logPoll!.valueOrNull!.updateAt);
    }
  }

  @override
  void initState() {
    super.initState();
    // Only auto-reload when there is at least one camera (a child with a
    // `name` attribute). Children that use their own `image` are never
    // reloaded.
    final bool hasCamera = widget.item.children.any(
      (c) => (c.name ?? '').isNotEmpty,
    );
    if (!hasCamera) return;

    if (widget.realtimeActive) {
      // Realtime (firebase/ws) owns photo updates, but we still run a slow
      // fallback poll (pollFallbackInterval) so the images keep refreshing
      // even if the realtime connection silently dies (e.g. after a long
      // sleep). This is a safety net, not the primary cadence.
      final Duration fallback = widget.pollFallbackInterval;
      if (fallback > Duration.zero) {
        debugPrint(
          '[log] JSON_PAGE:: ${widget.realtimeMode} mode RenderCamera realtime active — fallback poll '
          'every ${fallback.inMilliseconds}ms for "${widget.item.title ?? ''}"',
        );
        _startFallbackTimer(fallback);
      }
      return;
    }

    if (widget.logPoll != null) {
      // Page-level poll owns `last.json`. Reconcile immediately on mount so a
      // set that scrolls into view updates right away (using the map the
      // page-level provider already fetched — no new `last.json` request).
      final Map<String, String> map =
          widget.logPoll!.valueOrNull?.updateAt ?? const {};
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _reconcileAndReload(map);
      });
    } else {
      // No shared poll available: fall back to a local timer (legacy path).
      debugPrint(
        '[log] JSON_PAGE:: ${widget.realtimeMode} mode RenderCamera start local auto-reload every '
        '${widget.reloadTimeSeconds > 0 ? widget.reloadTimeSeconds : 60}s '
        'for "${widget.item.title ?? ''}"',
      );
      _startLocalTimer();
    }
  }

  /// Reconciles the widget's cameras against [updateAt] and reloads only the
  /// cameras whose photo is genuinely new (their cache-bust tick was bumped in
  /// [_reconcile]). When nothing changed, rebuilds so a previous round's green
  /// "updated" highlight clears (badges revert to gray); unchanged cameras keep
  /// their tick and cached image — no network reload.
  void _reconcileAndReload(Map<String, String> updateAt) {
    final Set<String> changed = _reconcile(updateAt);
    if (!mounted) return;
    if (changed.isEmpty) {
      debugPrint(
        '[log] JSON_PAGE:: ${widget.realtimeMode} mode RenderCamera '
        'no camera changed for "${widget.item.title ?? ''}"',
      );
      setState(() {});
      return;
    }
    for (final String name in changed) {
      final PageChild? child = widget.item.children
          .where((c) => (c.name ?? '') == name)
          .firstOrNull;
      final String url = child != null
          ? _buildUrl(child)
          : '${widget.cameraPhoto}${widget.cameraLastPhoto}$name.jpg';
      debugPrint(
        '[log] JSON_PAGE:: ${widget.realtimeMode} mode RenderCamera updating image "$name" -> $url',
      );
    }
    setState(() {});
  }

  /// Legacy fallback: a per-widget timer used only when no shared page-level
  /// poll is available. Fetches `last.json` locally each interval.
  Timer? _localTimer;
  void _startLocalTimer() {
    _localTimer?.cancel();
    final int seconds = widget.reloadTimeSeconds > 0
        ? widget.reloadTimeSeconds
        : 60;
    _localTimer = Timer.periodic(Duration(seconds: seconds), (_) {
      if (!mounted) return;
      // Local fetch via the shared cache so multiple local-timer widgets still
      // collapse into one request per round.
      _fetchLogLocal().then((updateAt) => _reconcileAndReload(updateAt));
    });
  }

  /// Safety-net timer used when realtime is active. Reloads every camera image
  /// on [widget.pollFallbackInterval] so the feed keeps showing fresh photos
  /// even if the realtime connection silently died (e.g. after a long sleep).
  /// It bumps each camera's cache-bust tick and rebuilds, reusing the cached
  /// image when the photo is unchanged.
  Timer? _fallbackTimer;
  void _startFallbackTimer(Duration interval) {
    _fallbackTimer?.cancel();
    _fallbackTimer = Timer.periodic(interval, (_) {
      if (!mounted) return;
      for (final PageChild c in widget.item.children) {
        final String n = c.name ?? '';
        if (n.isNotEmpty) _cameraTick[n] = (_cameraTick[n] ?? 0) + 1;
      }
      setState(() {});
    });
  }

  /// Local `last.json` fetch (legacy fallback path). Returns an empty map on
  /// failure so the caller falls back to reloading every camera.
  Future<Map<String, String>> _fetchLogLocal() async {
    if (widget.cameraLogPhoto.isEmpty) return const {};
    try {
      final http.Response res = await http.get(
        Uri.parse('${widget.cameraPhoto}${widget.cameraLogPhoto}'),
      );
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

  @override
  void dispose() {
    _localTimer?.cancel();
    _fallbackTimer?.cancel();
    super.dispose();
  }

  String _buildUrl(PageChild child) {
    final String name = child.name ?? '';
    // When a thumbnail folder is configured, load `{name}-th.jpg` from it
    // instead of the full `{name}.jpg` — the server pre-generates these small
    // images so the feed never downloads the multi-MB originals.
    final String folder = widget.cameraThumbPhoto.isNotEmpty
        ? widget.cameraThumbPhoto
        : widget.cameraLastPhoto;
    final String suffix = widget.cameraThumbPhoto.isNotEmpty
        ? '-th.jpg'
        : '.jpg';
    final String base = '${widget.cameraPhoto}$folder$name$suffix';
    // Cache-bust per camera. A camera's tick only changes when its photo is
    // genuinely new (bumped in [_reconcile] or by a realtime event), so
    // unchanged cameras keep the same URL and reuse the cached image — scrolling
    // never triggers a reload for them.
    final int tick = _cameraTick[name] ?? 0;
    return '$base?t=$tick';
  }

  /// Builds the full (non-thumbnail) image URL for [child], always from
  /// [cameraLastPhoto] + `{name}.jpg`. Used as the fallback when a thumbnail
  /// is missing on the server.
  String _buildFullUrl(PageChild child) {
    final String name = child.name ?? '';
    final String base =
        '${widget.cameraPhoto}${widget.cameraLastPhoto}$name.jpg';
    final int tick = _cameraTick[name] ?? 0;
    return '$base?t=$tick';
  }

  Widget _cameraImage(
    PageChild child, {
    double? height,
    double? borderRadius,
    int? cacheWidth,
  }) {
    final String url = _buildUrl(child);
    final String fullUrl = _buildFullUrl(child);
    // When a thumbnail is configured and differs from the full image, fall
    // back to the full image if the thumbnail is missing on the server.
    final bool canFallback =
        widget.cameraThumbPhoto.isNotEmpty && url != fullUrl;
    // Log the image URL actually being loaded, but only when it changes for
    // this camera (deduped via a static map) so scrolling/rebuilds that reuse
    // the same cached URL stay quiet.
    final String name = child.name ?? '';
    if (_loadedUrl[name] != url) {
      _loadedUrl[name] = url;
      debugPrint(
        '[log] JSON_PAGE:: ${widget.realtimeMode} mode RenderCamera load image "$name" -> $url',
      );
    }
    final Widget image = Image.network(
      url,
      fit: BoxFit.cover,
      width: double.infinity,
      height: height,
      // Cap the decoded bitmap to the on-screen pixel width so even if a full
      // image slips through, it is decoded small (saves GPU/memory).
      cacheWidth: cacheWidth,
      // Keep showing the previous frame until the new image is fully loaded,
      // then swap in place (no clearing/placeholder between refreshes).
      gaplessPlayback: true,
      errorBuilder: (context, error, stackTrace) {
        if (canFallback) {
          // Thumbnail missing → load the full image instead.
          debugPrint(
            '[log] JSON_PAGE:: ${widget.realtimeMode} mode RenderCamera thumbnail missing for "$name", '
            'fallback to full -> $fullUrl',
          );
          return Image.network(
            fullUrl,
            fit: BoxFit.cover,
            width: double.infinity,
            height: height,
            cacheWidth: cacheWidth,
            gaplessPlayback: true,
            errorBuilder: (context, error, stackTrace) =>
                _imagePlaceholder(height),
          );
        }
        return _imagePlaceholder(height);
      },
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
      final int? cacheWidth = hasImage
          ? null
          : (tileWidth * MediaQuery.of(context).devicePixelRatio).ceil();
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
              cacheWidth: cacheWidth,
            );

      // A camera is "live" (green) when we have ever seen a photo for it —
      // tracked in the static [_lastUpdateAt] map, which survives widget
      // disposal so scrolling a set off-screen and back keeps its green badge
      // and time instead of reverting to gray/empty. A realtime `time` also
      // marks it live. Cameras that have never reported a photo stay gray.
      final String name = child.name ?? '';
      final bool hasRealtimeTime = child.time != null && child.time!.isNotEmpty;
      final bool hasLogTime = (_lastUpdateAt[name] ?? '').isNotEmpty;
      final bool isUpdated = hasRealtimeTime || hasLogTime;
      final Color badgeColor = isUpdated ? Colors.green : Colors.grey;
      // Time to display: prefer the realtime `time`; fall back to the log's
      // `updateAt` so poll-mode updates also show (and persist across scroll).
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
