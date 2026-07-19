import 'package:flutter/material.dart';

/// Data model for a page config, parsed from a page JSON file
/// (e.g. `home.json`, `apps.json`).
///
/// JSON shape (see `.github/instructions`):
/// {
///   "title": "...",
///   "onLoadUrl": "https://...",   // optional: pinged (non-blocking) on load
///   "widget": {
///     "show": "itemA,itemB,...",
///     "cameraPhoto": "...",
///     "cameraLastPhoto": "...",
///     "cameraRealtimePhoto": "...",
///     "items": { "itemA": { "type": "image", "children": [ ... ] }, ... }
///   }
/// }
class PageConfig {
  const PageConfig({required this.title, required this.widget, this.onLoadUrl});

  factory PageConfig.fromJson(Map<String, dynamic> json) {
    final Map<String, dynamic>? widgetJson =
        json['widget'] as Map<String, dynamic>?;

    // Support a flat, single-item page where `type`/`url`/`title` live at the
    // root (no `widget`/`show`/`items` wrapper). Normalize it into a synthetic
    // widget so the rest of the rendering pipeline is unchanged.
    final PageWidget widget;
    if (widgetJson != null && widgetJson.isNotEmpty) {
      widget = PageWidget.fromJson(widgetJson);
    } else if (json['type'] != null) {
      const String rootKey = '_root';
      widget = PageWidget(
        show: const [rootKey],
        cameraPhoto: '',
        cameraLastPhoto: '',
        cameraRealtimePhoto: '',
        items: <String, PageItem>{
          rootKey: PageItem(
            type: json['type'] as String? ?? '',
            // The title is shown by the page AppBar, so omit it here to avoid a
            // second (inner) AppBar inside the web view.
            title: null,
            url: json['url'] as String?,
            children: const [],
          ),
        },
      );
    } else {
      widget = PageWidget.fromJson(const <String, dynamic>{});
    }

    return PageConfig(
      title: json['title'] as String? ?? '',
      widget: widget,
      onLoadUrl: json['onLoadUrl'] as String?,
    );
  }

  final String title;
  final PageWidget widget;

  /// Optional URL pinged (non-blocking) when this page JSON is loaded.
  final String? onLoadUrl;
}

class PageWidget {
  const PageWidget({
    required this.show,
    required this.cameraPhoto,
    required this.cameraLastPhoto,
    required this.cameraRealtimePhoto,
    required this.items,
  });

  factory PageWidget.fromJson(Map<String, dynamic> json) {
    final Map<String, dynamic> rawItems =
        json['items'] as Map<String, dynamic>? ?? {};
    final Map<String, PageItem> items = rawItems.map(
      (key, value) => MapEntry(
        key,
        PageItem.fromJson(value as Map<String, dynamic>? ?? {}),
      ),
    );

    return PageWidget(
      show: (json['show'] as String? ?? '')
          .split(',')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList(),
      cameraPhoto: json['cameraPhoto'] as String? ?? '',
      cameraLastPhoto: json['cameraLastPhoto'] as String? ?? '',
      cameraRealtimePhoto: json['cameraRealtimePhoto'] as String? ?? '',
      items: items,
    );
  }

  /// Ordered list of item keys to render, as declared by `show`.
  final List<String> show;
  final String cameraPhoto;
  final String cameraLastPhoto;
  final String cameraRealtimePhoto;
  final Map<String, PageItem> items;
}

class PageItem {
  const PageItem({
    required this.type,
    this.title,
    this.url,
    required this.children,
    this.padding,
    this.layout,
    this.gap,
    this.columns,
    this.photoWidth,
    this.photoBorderRadius,
    this.photoHeight,
  });

  factory PageItem.fromJson(Map<String, dynamic> json) {
    final List<dynamic> rawChildren = json['children'] as List<dynamic>? ?? [];
    final List<PageChild> children = rawChildren
        .map((e) => PageChild.fromJson(e as Map<String, dynamic>? ?? {}))
        .toList();

    return PageItem(
      type: json['type'] as String? ?? '',
      title: json['title'] as String?,
      url: json['url'] as String?,
      children: children,
      padding: _parsePadding(json['padding']),
      layout: json['layout'] as String?,
      gap: _toDouble(json['gap']),
      columns: _toInt(json['columns']),
      photoWidth: json['photoWidth'] as String?,
      photoHeight: json['photoHeight'] as String?,
      photoBorderRadius: _toDouble(json['photoBorderRadius']),
    );
  }

  final String type;
  final String? title;

  /// Optional item-level URL (e.g. used by `type: webView`).
  final String? url;
  final List<PageChild> children;
  final EdgeInsets? padding;
  final String? layout;
  final double? gap;
  final int? columns;
  final double? photoBorderRadius;
  final String? photoWidth;
  final String? photoHeight;
}

/// Parses a padding attribute.
/// - `"8"`     -> all sides 8
/// - `"8,16"`  -> vertical 8, horizontal 16
EdgeInsets? _parsePadding(dynamic value) {
  if (value == null) return null;
  final List<String> parts = value
      .toString()
      .split(',')
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList();
  if (parts.isEmpty) return null;
  final List<double> nums = parts.map((e) => double.tryParse(e) ?? 0).toList();
  if (nums.length == 1) {
    return EdgeInsets.all(nums.first);
  }
  return EdgeInsets.symmetric(vertical: nums[0], horizontal: nums[1]);
}

class PageChild {
  const PageChild({
    this.image,
    this.url,
    this.webViewUrl,
    this.page,
    this.pageArgs,
    this.title,
    this.code,
    this.name,
    this.height,
    this.width,
    this.borderRadius,
  });

  factory PageChild.fromJson(Map<String, dynamic> json) {
    return PageChild(
      image: json['image'] as String?,
      url: json['url'] as String?,
      webViewUrl: json['webViewUrl'] as String?,
      page: json['page'] as String?,
      pageArgs: json['pageArgs'] as Map<String, dynamic>?,
      title: json['title'] as String?,
      code: json['code'] as String?,
      name: json['name'] as String?,
      height: _toDouble(json['height']),
      width: _toDouble(json['width']),
      borderRadius: _toDouble(json['borderRadius']),
    );
  }

  final String? image;
  final String? url;
  final String? webViewUrl;

  /// Named route to navigate to when the child is tapped (e.g. "/about").
  final String? page;

  /// Optional arguments passed to the route (e.g. {"url": "...", "title": "..."}).
  final Map<String, dynamic>? pageArgs;
  final String? title;
  final String? code;
  final String? name;
  final double? height;
  final double? width;
  final double? borderRadius;
}

double? _toDouble(dynamic value) {
  if (value == null) return null;
  if (value is num) return value.toDouble();
  return double.tryParse(value.toString());
}

int? _toInt(dynamic value) {
  if (value == null) return null;
  if (value is num) return value.toInt();
  return int.tryParse(value.toString());
}

/// Describes a navigation target produced when a feed item (image/camera) is
/// tapped. The host decides how to handle it (named route, in-app web view,
/// external launch, ...), so the renderer stays decoupled from any specific
/// navigation implementation.
class LinkTarget {
  const LinkTarget({
    this.page,
    this.pageArgs,
    this.webViewUrl,
    this.url,
    this.title,
  });

  /// Named route to navigate to (e.g. "/about").
  final String? page;

  /// Optional arguments passed to the route.
  final Map<String, dynamic>? pageArgs;

  /// URL to open in an in-app web view.
  final String? webViewUrl;

  /// URL to launch externally.
  final String? url;

  /// Optional title for the target (e.g. web view app bar).
  final String? title;
}
