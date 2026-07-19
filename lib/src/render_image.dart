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

    final ({double? pixels, double? fraction}) photoWidth = _parsePhotoWidth(
      item.photoWidth,
    );
    final ({double? pixels, double? fraction}) photoHeight = _parsePhotoHeight(
      item.photoHeight,
    );

    if (children.length == 1) {
      // A single child is full-width; resolve width/height from the available
      // width so a `photoWidth`/`photoHeight` percentage is relative to it.
      return LayoutBuilder(
        builder: (context, constraints) {
          final double w = constraints.maxWidth;
          final double? width =
              photoWidth.pixels ??
              (photoWidth.fraction == null ? null : w * photoWidth.fraction!);
          final double? height =
              photoHeight.pixels ??
              (photoHeight.fraction == null ? null : w * photoHeight.fraction!);
          return _ImageTile(
            child: children.first,
            fullWidth: true,
            width: width,
            height: height,
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
    // width/height from `photoWidth`/`photoHeight` once.
    return LayoutBuilder(
      builder: (context, constraints) {
        final double w = constraints.maxWidth;
        final double? tileWidth =
            photoWidth.pixels ??
            (photoWidth.fraction == null ? null : w * photoWidth.fraction!);
        final double? tileHeight =
            photoHeight.pixels ??
            (photoHeight.fraction == null ? null : w * photoHeight.fraction!);

        if (isGrid) {
          // A responsive grid. The number of columns defaults to 2 and can be
          // overridden with the `columns` attribute (clamped to 1..6).
          final int columns = (item.columns ?? 2).clamp(1, 6);
          // Actual grid cell width, accounting for the outer padding and the
          // spacing between columns.
          final double availableWidth = w - gap * 2;
          final double cellWidth =
              (availableWidth - gap * (columns - 1)) / columns;
          // The image's own size comes from `photoWidth`/`photoHeight`: a bare
          // number is pixels; a percentage is relative to the cell width. When
          // omitted the image fills the cell (square by default).
          final double tileWidth =
              photoWidth.pixels ??
              (photoWidth.fraction == null
                  ? cellWidth
                  : cellWidth * photoWidth.fraction!);
          final double tileHeight =
              photoHeight.pixels ??
              (photoHeight.fraction == null
                  ? tileWidth
                  : tileWidth * photoHeight.fraction!);
          // Size each grid cell to the image (`maxCrossAxisExtent`) so tiles
          // pack tightly with no extra whitespace. As many columns fit as the
          // image width allows — defaulting to `columns` when `photoWidth` is
          // omitted — instead of forcing a fixed column count with a centered,
          // smaller image inside a wide cell.
          return GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            padding: EdgeInsets.all(gap),
            gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: tileWidth,
              mainAxisSpacing: gap,
              crossAxisSpacing: gap,
              childAspectRatio: tileWidth / tileHeight,
            ),
            itemCount: children.length,
            itemBuilder: (context, index) => _ImageTile(
              child: children[index],
              fullWidth: false,
              width: tileWidth,
              height: tileHeight,
              borderRadius: item.photoBorderRadius,
              onLinkTap: onLinkTap,
            ),
          );
        }

        return Padding(
          padding: EdgeInsets.symmetric(horizontal: gap),
          child: SizedBox(
            height: tileHeight ?? 120,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: children.length,
              separatorBuilder: (context, index) => SizedBox(width: gap),
              itemBuilder: (context, index) => _ImageTile(
                child: children[index],
                fullWidth: false,
                width: tileWidth,
                height: tileHeight,
                borderRadius: item.photoBorderRadius,
                onLinkTap: onLinkTap,
              ),
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

  Future<void> _onTap(BuildContext context) async {
    final void Function(BuildContext, LinkTarget)? handler = onLinkTap;
    if (handler == null) return;
    // A `page` navigates to a named route in the app (e.g. "/about").
    final String? page = child.page;
    if (page != null && page.isNotEmpty) {
      handler(
        context,
        LinkTarget(page: page, pageArgs: child.pageArgs, title: child.title),
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
    final Widget image = Image.network(
      child.image!,
      fit: BoxFit.cover,
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
        (child.page != null && child.page!.isNotEmpty) ||
        (child.url != null && child.url!.isNotEmpty) ||
        (child.webViewUrl != null && child.webViewUrl!.isNotEmpty);

    if (!tappable) {
      return rounded;
    }

    return GestureDetector(onTap: () => _onTap(context), child: rounded);
  }
}
