import 'package:flutter/material.dart';

import 'package:json_page/src/models/page_model.dart';

/// Renders a feed item of `type: sizebox` (or a `show` entry named `sizebox`)
/// as a spacer to add spacing between feed tiles.
///
/// Spacing is read from the first child's `height`/`width` when present:
/// - `height` only  -> vertical spacer (default height if omitted)
/// - `width` only   -> horizontal spacer (useful inside horizontal lists)
/// - both given     -> fixed-size box
class RenderSideboxWidget extends StatelessWidget {
  const RenderSideboxWidget({super.key, required this.item});

  final PageItem item;

  /// Default spacer size when neither `height` nor `width` is provided.
  static const double defaultSize = 12;

  @override
  Widget build(BuildContext context) {
    final PageChild? first = item.children.isNotEmpty
        ? item.children.first
        : null;
    final double? height = first?.height;
    final double? width = first?.width;

    return SizedBox(
      height: height ?? (width == null ? defaultSize : null),
      width: width,
    );
  }
}
