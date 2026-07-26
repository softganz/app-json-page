import 'package:flutter/material.dart';

import 'package:json_page/src/models/page_model.dart';

/// Renders a feed item of `type: image`.
///
/// Per `.github/instructions`:
/// - A single child is shown as a full-width image.
/// - More than one child is shown in a horizontal scroll row.
/// - If a child has a `url`, tapping it launches that URL externally.
///
/// Tapping a child invokes [onLinkTap] with a [LinkTarget] so the host can
/// decide how to navigate (named route, in-app web view, external launch, ...).
class RenderImageWidget extends StatelessWidget {
  const RenderImageWidget({super.key, required this.item, this.onLinkTap});

  final PageItem item;

  /// Called when a tappable child is tapped. When null, taps are ignored.
  final void Function(BuildContext context, LinkTarget target)? onLinkTap;

  /// Parses the `photoWidth` attribute. A bare number (e.g. "80") is treated
  /// as a pixel width; a percentage (e.g. "80%") is a fraction of the
  /// available width. Returns both interpretations (one will be non-null).
  static ({double? pixels, double? fraction}) _parsePhotoWidth(
    String? photoWidth,
  ) {
    if (photoWidth == null) return (pixels: null, fraction: null);
    final String trimmed = photoWidth.trim();
    final String numeric = trimmed.endsWith('%')
        ? trimmed.substring(0, trimmed.length - 1)
        : trimmed;
    final double? num = double.tryParse(numeric);
    if (num == null || num <= 0) return (pixels: null, fraction: null);
    if (trimmed.endsWith('%')) {
      return (pixels: null, fraction: num / 100);
    }
    return (pixels: num, fraction: null);
  }

  /// Parses the `photoHeight` attribute. A bare number (e.g. "200") is treated
  /// as a pixel height; a percentage (e.g. "50%") is a fraction of the
  /// available width. Returns both interpretations (one will be non-null).
  static ({double? pixels, double? fraction}) _parsePhotoHeight(
    String? photoHeight,
  ) {
    if (photoHeight == null) return (pixels: null, fraction: null);
    final String trimmed = photoHeight.trim();
    final String numeric = trimmed.endsWith('%')
        ? trimmed.substring(0, trimmed.length - 1)
        : trimmed;
    final double? num = double.tryParse(numeric);
    if (num == null || num <= 0) return (pixels: null, fraction: null);
    if (trimmed.endsWith('%')) {
      return (pixels: null, fraction: num / 100);
    }
    return (pixels: num, fraction: null);
  }

  @override
  Widget build(BuildContext context) {
    final List<PageChild> children = item.children
        .where((c) => c.image != null && c.image!.isNotEmpty)
        .toList();

    if (children.isEmpty) {
      return const SizedBox.shrink();
    }

    // Resolves a child's width/height from its own `photoWidth`/`photoHeight`
    // (falling back to the item-level values), relative to [availableWidth].
    ({double? width, double? height}) _resolveSize(
      PageChild child,
      double availableWidth,
    ) {
      final ({double? pixels, double? fraction}) cw = _parsePhotoWidth(
        child.photoWidth ?? item.photoWidth,
      );
      final ({double? pixels, double? fraction}) ch = _parsePhotoHeight(
        child.photoHeight ?? item.photoHeight,
      );
      final double? width =
          cw.pixels ??
          (cw.fraction == null ? null : availableWidth * cw.fraction!);
      final double? height =
          ch.pixels ??
          (ch.fraction == null ? null : availableWidth * ch.fraction!);
      return (width: width, height: height);
    }

    if (children.length == 1) {
      // A single child is full-width; resolve width/height from the available
      // width so a `photoWidth`/`photoHeight` percentage is relative to it.
      return LayoutBuilder(
        builder: (context, constraints) {
          final double w = constraints.maxWidth;
          final ({double? width, double? height}) size = _resolveSize(
            children.first,
            w,
          );
          return _ImageTile(
            child: children.first,
            fullWidth: true,
            width: size.width,
            height: size.height,
            borderRadius: item.photoBorderRadius,
            onLinkTap: onLinkTap,
          );
        },
      );
    }

    final double gap = item.gap ?? 0;
    final bool isGrid = item.layout == 'grid';

    // In a horizontal ListView each item gets an unbounded width, so we read
    // the viewport width from an outer LayoutBuilder and compute fixed tile
    // width/height from `photoWidth`/`photoHeight` per child.
    return LayoutBuilder(
      builder: (context, constraints) {
        final double w = constraints.maxWidth;

        if (isGrid) {
          // Grid tiles are sized from the item-level `photoWidth`/`photoHeight`
          // (a bare number is pixels; a percentage is relative to the available
          // width). Each child may still override its own size. The number of
          // columns auto-fits the tile width, or uses the explicit `columns`
          // attribute when provided (clamped to 1..6).
          final double availableWidth = w - gap * 2;
          final ({double? width, double? height}) base = _resolveSize(
            children.first,
            availableWidth,
          );
          final double baseWidth = base.width ?? 80;
          final double baseHeight = base.height ?? baseWidth;
          final int columns = item.columns != null
              ? item.columns!.clamp(1, 6)
              : ((availableWidth + gap) / (baseWidth + gap)).floor().clamp(
                  1,
                  6,
                );
          final double cellWidth =
              (availableWidth - gap * (columns - 1)) / columns;
          final double cellHeight = cellWidth * (baseHeight / baseWidth);
          return GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            padding: EdgeInsets.all(gap),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: columns,
              mainAxisSpacing: gap,
              crossAxisSpacing: gap,
              childAspectRatio: baseWidth / baseHeight,
            ),
            itemCount: children.length,
            itemBuilder: (context, index) {
              final PageChild child = children[index];
              final ({double? width, double? height}) size = _resolveSize(
                child,
                cellWidth,
              );
              final double tileWidth = size.width ?? cellWidth;
              final double tileHeight = size.height ?? cellHeight;
              return _ImageTile(
                child: child,
                fullWidth: false,
                width: tileWidth,
                height: tileHeight,
                borderRadius: item.photoBorderRadius,
                onLinkTap: onLinkTap,
              );
            },
          );
        }

        // When the item requests `wrap`, lay the images out in a wrapping
        // flow so wide images drop to the next line instead of scrolling
        // horizontally. Otherwise keep the horizontal scroll row.
        final bool wrap = item.wrap;

        if (wrap) {
          return Padding(
            padding: EdgeInsets.all(gap),
            child: Wrap(
              spacing: gap,
              runSpacing: gap,
              children: [
                for (final PageChild child in children)
                  Builder(
                    builder: (context) {
                      final ({double? width, double? height}) size =
                          _resolveSize(child, w);
                      return _ImageTile(
                        child: child,
                        fullWidth: false,
                        width: size.width,
                        height: size.height,
                        borderRadius: item.photoBorderRadius,
                        onLinkTap: onLinkTap,
                      );
                    },
                  ),
              ],
            ),
          );
        }

        // Pre-compute each child's size so the row height can fit the tallest
        // tile (children may now have different heights).
        final List<({double width, double height})> sizes = children.map((c) {
          final ({double? width, double? height}) s = _resolveSize(c, w);
          return (width: s.width ?? 160, height: s.height ?? 120);
        }).toList();
        final double rowHeight = sizes
            .map((s) => s.height)
            .reduce((a, b) => a > b ? a : b);

        return Padding(
          padding: EdgeInsets.symmetric(horizontal: gap),
          child: SizedBox(
            height: rowHeight,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: children.length,
              separatorBuilder: (context, index) => SizedBox(width: gap),
              itemBuilder: (context, index) {
                final PageChild child = children[index];
                final ({double width, double height}) size = sizes[index];
                return _ImageTile(
                  child: child,
                  fullWidth: false,
                  width: size.width,
                  height: size.height,
                  borderRadius: item.photoBorderRadius,
                  onLinkTap: onLinkTap,
                );
              },
            ),
          ),
        );
      },
    );
  }
}

class _ImageTile extends StatelessWidget {
  const _ImageTile({
    required this.child,
    required this.fullWidth,
    this.width,
    this.height,
    this.borderRadius,
    this.onLinkTap,
  });

  final PageChild child;
  final bool fullWidth;
  final double? width;
  final double? height;
  final double? borderRadius;
  final void Function(BuildContext context, LinkTarget target)? onLinkTap;

  /// Stable `NetworkImage` per URL. Non-camera images never change, so we
  /// memoize the provider in a static map keyed by URL. This guarantees the
  /// same `ImageProvider` instance is reused across rebuilds and scroll
  /// remounts, so the `ImageCache` keeps serving the cached bytes and the
  /// image is never re-fetched just because the widget was rebuilt or scrolled
  /// off-screen and back.
  static final Map<String, NetworkImage> _imageCache = {};

  NetworkImage _resolveImage() {
    final String url = child.image!;
    return _imageCache.putIfAbsent(url, () => NetworkImage(url));
  }

  Future<void> _onTap(BuildContext context) async {
    final void Function(BuildContext, LinkTarget)? handler = onLinkTap;
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

    // A `webViewUrl` opens the in-app WebScreen; otherwise launch `url`
    // externally when present.
    final String? webViewUrl = child.webViewUrl;
    if (webViewUrl != null && webViewUrl.isNotEmpty) {
      handler(context, LinkTarget(webViewUrl: webViewUrl, title: child.title));
      return;
    }

    final String? url = child.url;
    if (url == null || url.isEmpty) return;
    handler(context, LinkTarget(url: url, title: child.title));
  }

  @override
  Widget build(BuildContext context) {
    final Widget image = Image(
      image: _resolveImage(),
      fit: BoxFit.cover,
      gaplessPlayback: true,
      loadingBuilder: (context, widget, loadingProgress) {
        if (loadingProgress == null) return widget;
        return const Center(child: CircularProgressIndicator());
      },
      errorBuilder: (context, error, stackTrace) =>
          const Center(child: Icon(Icons.broken_image, size: 40)),
    );

    final Widget body = fullWidth
        ? (width == null && height == null
              ? image
              : SizedBox(width: width, height: height, child: image))
        : SizedBox(width: width ?? 160, height: height ?? 120, child: image);

    // Round when the item (`photoBorderRadius`) or the child (`borderRadius`)
    // declares a radius. The item-level value takes precedence.
    final double? radius = borderRadius ?? child.borderRadius;
    final Widget rounded = radius == null
        ? body
        : ClipRRect(borderRadius: BorderRadius.circular(radius), child: body);

    final bool tappable =
        (child.route != null && child.route!.isNotEmpty) ||
        (child.url != null && child.url!.isNotEmpty) ||
        (child.webViewUrl != null && child.webViewUrl!.isNotEmpty);

    if (!tappable) {
      return rounded;
    }

    return GestureDetector(onTap: () => _onTap(context), child: rounded);
  }
}
