import 'dart:async';

import 'package:flutter/material.dart';

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
    this.reloadTimeSeconds = 60,
    this.externalTick = 0,
    this.onLinkTap,
  });

  final PageItem item;
  final String cameraPhoto;
  final String cameraLastPhoto;
  final String cameraRealtimePhoto;

  /// Camera auto-reload interval in seconds (from page `cameraReloadTime`).
  /// Defaults to 60 when not provided.
  final int reloadTimeSeconds;

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
  int _tick = 0;
  Timer? _refreshTimer;

  @override
  void didUpdateWidget(covariant RenderCameraWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Realtime push: a changed externalTick forces an immediate reload.
    if (widget.externalTick != oldWidget.externalTick) {
      if (mounted) {
        setState(() => _tick++);
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
    if (hasCamera) {
      debugPrint(
        '[log] JSON_PAGE:: RenderCamera start auto-reload every '
        '${widget.reloadTimeSeconds > 0 ? widget.reloadTimeSeconds : 60}s '
        'for "${widget.item.title ?? ''}"',
      );
      _scheduleRefresh();
    }
  }

  void _scheduleRefresh() {
    _refreshTimer?.cancel();
    final int seconds = widget.reloadTimeSeconds > 0
        ? widget.reloadTimeSeconds
        : 60;
    _refreshTimer = Timer(Duration(seconds: seconds), () {
      if (!mounted) return;
      debugPrint(
        '[log] JSON_PAGE:: RenderCamera reload #${_tick + 1} '
        'for "${widget.item.title ?? ''}"',
      );
      setState(() => _tick++);
      _scheduleRefresh();
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  String _buildUrl(PageChild child) {
    final String name = child.name ?? '';
    final String base =
        '${widget.cameraPhoto}${widget.cameraLastPhoto}$name.jpg';
    // Cache-bust so the network image reloads on each tick.
    return '$base?t=$_tick';
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
      errorBuilder: (context, error, stackTrace) =>
          const Center(child: Icon(Icons.broken_image, size: 40)),
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
      errorBuilder: (context, error, stackTrace) =>
          const Center(child: Icon(Icons.broken_image, size: 40)),
    );

    final double radius = borderRadius ?? child.borderRadius ?? 12;
    return ClipRRect(borderRadius: BorderRadius.circular(radius), child: image);
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

      // Overlay the child's `code` as a green, rounded badge at the top-left
      // corner of the image (background label).
      final Widget imageWithBadge =
          (child.code != null && child.code!.isNotEmpty)
          ? Stack(
              children: [
                imageWidget,
                Positioned(
                  top: 6,
                  left: 6,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.green,
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
              ],
            )
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
