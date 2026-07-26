import 'package:flutter/material.dart';

/// ชื่อ header ที่ใช้ส่ง deviceId ไป server (ป้องกันการเปิดเผยใน URL query
/// string / log). Host app ควร import ค่านี้มาใช้เพื่อให้ตรงกับ header
/// ที่ API คาดหวังเสมอ (เช่น `X-Device-Id`).
const String kDeviceIdHeader = 'X-Device-Id';

/// Data model for a page config, parsed from a page JSON file
/// (e.g. `home.json`, `apps.json`).
///
/// A page config has two starting attributes at the top level:
///   - `title`: shown on the app bar.
///   - `type`: the main render format. Currently one of:
///       * `"route"`   — redirect to a named route (see [route]).
///       * `"widget"`  — render a list of widgets (see [widget]).
///       * `"webview"` — render an in-app web view (see [url]).
///
/// A page config may also declare a top-level `margin` attribute that adds
/// padding around the whole rendered content. It accepts the same format as
/// an item's `padding`:
///   - `"8"`    -> all sides 8
///   - `"8,16"` -> vertical 8, horizontal 16
///
/// Similarly, a top-level `padding` attribute adds inner padding to the whole
/// rendered content, using the same `"8"` / `"8,16"` format.

/// Example (webview):
/// {
///   "title": "เฝ้าระวังน้ำท่วม",
///   "type": "webview",
///   "url": "https://hatyaicityclimate.org"
/// }
class PageConfig {
  const PageConfig({
    required this.type,
    required this.title,
    required this.widget,
    this.route,
    this.routeArgs,
    this.url,
    this.logo,
    this.onLoadUrl,
    this.margin,
    this.padding,
    this.realtime = const RealtimePatchConfig.disabled(),
  });

  /// Optional page-wide margin applied around the whole rendered content.
  /// Accepts the same format as item `padding`:
  ///   - `"8"`    -> all sides 8
  ///   - `"8,16"` -> vertical 8, horizontal 16
  final EdgeInsets? margin;

  /// Optional page-wide padding applied inside the whole rendered content.
  /// Accepts the same format as item `padding`:
  ///   - `"8"`    -> all sides 8
  ///   - `"8,16"` -> vertical 8, horizontal 16
  final EdgeInsets? padding;

  factory PageConfig.fromJson(Map<String, dynamic> json) {
    // The main render type is normally a top-level `type` attribute (per the
    // README). When it is absent, auto-detect: a config that carries a
    // `widget` (legacy nested) or `widgets` (new top-level) object is treated
    // as a `widget` page so existing server JSON keeps rendering.
    String type = (json['type'] as String? ?? '').trim();
    if (type.isEmpty) {
      final bool hasWidget =
          json['widget'] is Map<String, dynamic> ||
          json['widgets'] is Map<String, dynamic>;
      type = hasWidget ? 'widget' : '';
    }

    String? route;
    Map<String, dynamic>? routeArgs;
    String? url;
    PageWidget widget;

    switch (type) {
      case 'route':
        // Redirect to a named route; no widget to render.
        route = json['route'] as String?;
        routeArgs = (json['routeArgs'] as Map<String, dynamic>?)
            ?.cast<String, dynamic>();
        widget = const PageWidget.empty();
      case 'webview':
        // Open an in-app web view from the top-level `url`.
        url = json['url'] as String?;
        widget = const PageWidget.empty();
      case 'widget':
        // Render a list of widgets from the top-level `widgets` field.
        widget = PageWidget.fromJson(json);
      default:
        // Unknown type: render nothing.
        widget = const PageWidget.empty();
    }

    return PageConfig(
      type: type,
      title: json['title'] as String? ?? '',
      margin: _parsePadding(json['margin']),
      padding: _parsePadding(json['padding']),
      widget: widget,
      route: route,
      routeArgs: routeArgs,
      logo: json['logo'] as String?,
      url: url,
      onLoadUrl: json['onLoadUrl'] as String?,
      realtime: RealtimePatchConfig.fromJson(
        json['realtime'] as Map<String, dynamic>?,
      ),
    );
  }

  /// Main render format: `route` / `widget` / `webview`.
  final String type;

  /// Title shown on the app bar.
  final String title;

  /// Widget list to render (used when [type] is `widget`).
  final PageWidget widget;

  /// Named route to redirect to (used when [type] is `route`). The host
  /// performs the actual navigation via the [RenderView.onRoute] callback.
  final String? route;

  /// Optional arguments passed to the route (used when [type] is `route`).
  /// Forwarded to the host via the [RenderView.onRoute] callback so the host
  /// can pass them to `Navigator.pushNamed(route, arguments: routeArgs)`.
  final Map<String, dynamic>? routeArgs;

  /// Web URL to open (used when [type] is `webview`).
  final String? url;

  /// Optional logo URL shown in the app bar. When present, it overrides the
  /// host-provided [RenderView.logo] so the page can supply its own logo.
  final String? logo;

  /// Optional
  /// Optional URL pinged (non-blocking) when this page JSON is loaded.
  final String? onLoadUrl;

  /// Realtime in-place patch config (parsed from the top-level `realtime`
  /// block). When [RealtimePatchConfig.enabled] is false, the host should not
  /// attempt to patch items from WS events.
  final RealtimePatchConfig realtime;
}

/// Describes how a realtime event (e.g. `photo.new`) is applied to a feed item
/// in-place, without a full refetch.
///
/// Parsed from the top-level `realtime` block in a page JSON:
/// ```jsonc
/// "realtime": {
///   "enabled": true,
///   "matchBy": "name",            // item key used to find the target
///   "patch": {                    // event field → item field mapping
///     "imageUrl": "data.url",
///     "thumbnailUrl": "data.thumbnail",
///     "time": "data.time"
///   }
/// }
/// ```
class RealtimePatchConfig {
  const RealtimePatchConfig({
    required this.enabled,
    required this.matchBy,
    required this.patch,
  });

  /// Empty config (realtime disabled / absent).
  const RealtimePatchConfig.disabled()
    : enabled = false,
      matchBy = '',
      patch = const {};

  factory RealtimePatchConfig.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const RealtimePatchConfig.disabled();
    final bool enabled = json['enabled'] == true;
    if (!enabled) return const RealtimePatchConfig.disabled();
    final String matchBy = (json['matchBy'] as String? ?? '').trim();
    final Map<String, dynamic>? rawPatch =
        json['patch'] as Map<String, dynamic>?;
    final Map<String, String> patch = (rawPatch ?? {}).map(
      (key, value) => MapEntry(key, value.toString()),
    );
    return RealtimePatchConfig(
      enabled: enabled,
      matchBy: matchBy,
      patch: patch,
    );
  }

  /// Whether realtime patching is active for this page.
  final bool enabled;

  /// Item attribute used to locate the target item (e.g. `"name"`).
  final String matchBy;

  /// Mapping of item field → dotted path into the event `data` payload.
  /// e.g. `{"imageUrl": "data.url"}` means: set item's `imageUrl` to
  /// `event.data["url"]`.
  final Map<String, String> patch;
}

class PageWidget {
  const PageWidget({
    required this.show,
    required this.cameraPhoto,
    required this.cameraLastPhoto,
    required this.cameraRealtimePhoto,
    this.cameraReloadTime = 60,
    required this.items,
  });

  /// Empty widget list, used by non-`widget` page types.
  const PageWidget.empty()
    : show = const [],
      cameraPhoto = '',
      cameraLastPhoto = '',
      cameraRealtimePhoto = '',
      cameraReloadTime = 60,
      items = const {};

  factory PageWidget.fromJson(Map<String, dynamic> json) {
    // The widget fields (`show`, `cameraPhoto*`) and the item map live either
    // at the top level (new format) or inside a nested `widget` object
    // (legacy format). The item map is `widgets` (new) or `items` (legacy).
    final Map<String, dynamic> src =
        (json['widget'] as Map<String, dynamic>?) ?? json;
    final Map<String, dynamic>? rawItems =
        (json['widgets'] as Map<String, dynamic>?) ??
        (src['items'] as Map<String, dynamic>?);
    final Map<String, PageItem> items = (rawItems ?? {}).map(
      (key, value) => MapEntry(
        key,
        PageItem.fromJson(value as Map<String, dynamic>? ?? {}),
      ),
    );
    return PageWidget(
      show: (src['show'] as String? ?? '')
          .split(',')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList(),
      cameraPhoto: src['cameraPhoto'] as String? ?? '',
      cameraLastPhoto: src['cameraLastPhoto'] as String? ?? '',
      cameraRealtimePhoto: src['cameraRealtimePhoto'] as String? ?? '',
      cameraReloadTime: _toInt(src['cameraReloadTime']) ?? 60,
      items: items,
    );
  }

  /// Ordered list of item keys to render, as declared by `show`.
  final List<String> show;
  final String cameraPhoto;
  final String cameraLastPhoto;

  /// Camera auto-reload interval in seconds (page-level `cameraReloadTime`).
  /// Defaults to 60 when absent or invalid.
  final int cameraReloadTime;
  final String cameraRealtimePhoto;
  final Map<String, PageItem> items;
}

class PageItem {
  const PageItem({
    required this.type,
    this.title,
    this.url,
    this.webViewUrl,
    required this.children,
    this.padding,
    this.layout,
    this.gap,
    this.columns,
    this.photoWidth,
    this.photoBorderRadius,
    this.photoHeight,
    this.wrap = false,
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
      webViewUrl: json['webViewUrl'] as String?,
      children: children,
      padding: _parsePadding(json['padding']),
      layout: json['layout'] as String?,
      gap: _toDouble(json['gap']),
      columns: _toInt(json['columns']),
      photoWidth: json['photoWidth'] as String?,
      photoHeight: json['photoHeight'] as String?,
      wrap: json['wrap'] as bool? ?? false,
      photoBorderRadius: _toDouble(json['photoBorderRadius']),
    );
  }

  final String type;
  final String? title;

  /// Optional item-level URL (e.g. used by `type: webView`).

  /// Optional item-level web-view URL template (used by `type: cameraSet`).
  /// Supports `{placeholder}` tokens resolved against each child's attributes
  /// (see [PageChild.resolveTemplate]). When a child does not declare its own
  /// `webViewUrl`, this template is used as a fallback.
  final String? webViewUrl;
  final String? url;
  final List<PageChild> children;
  final EdgeInsets? padding;
  final String? layout;
  final double? gap;
  final int? columns;
  final double? photoBorderRadius;
  final String? photoWidth;

  /// When true, the image row wraps to the next line when it exceeds the
  /// screen width (instead of scrolling horizontally). Defaults to false.
  final bool wrap;
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
    this.route,
    this.routeArgs,
    this.title,
    this.code,
    this.name,
    this.height,
    this.width,
    this.photoWidth,
    this.photoHeight,
    this.borderRadius,
  });

  factory PageChild.fromJson(Map<String, dynamic> json) {
    return PageChild(
      image: json['image'] as String?,
      url: json['url'] as String?,
      webViewUrl: json['webViewUrl'] as String?,
      route: json['route'] as String?,
      routeArgs: json['routeArgs'] as Map<String, dynamic>?,
      title: json['title'] as String?,
      code: json['code'] as String?,
      name: json['name'] as String?,
      height: _toDouble(json['height']),
      width: _toDouble(json['width']),
      photoWidth: json['photoWidth'] as String?,
      photoHeight: json['photoHeight'] as String?,
      borderRadius: _toDouble(json['borderRadius']),
    );
  }

  /// Resolves `{placeholder}` tokens in [template] against this child's
  /// attributes. Supported tokens: `{name}`, `{code}`, `{title}`, `{image}`,
  /// `{url}`, `{route}`.
  ///
  /// Returns `null` when [template] is null/empty, or when any *supported*
  /// attribute referenced by a token is missing/empty (so a half-substituted
  /// URL is never produced). Unknown tokens (not in the supported set) are
  /// left untouched in the result.
  String? resolveTemplate(String? template) {
    if (template == null || template.isEmpty) return null;
    final Map<String, String?> values = {
      'name': name,
      'code': code,
      'title': title,
      'image': image,
      'url': url,
      'route': route,
    };
    final RegExp tokenRe = RegExp(r'\{(\w+)\}');
    if (!tokenRe.hasMatch(template)) return template;
    String result = template;
    for (final RegExpMatch m in tokenRe.allMatches(template)) {
      final String key = m.group(1)!;
      // Unknown token (not a supported attribute): leave it untouched.
      if (!values.containsKey(key)) continue;
      final String? value = values[key];
      // Supported token with a null/empty value: refuse to build a broken URL.
      if (value == null || value.isEmpty) return null;
      result = result.replaceAll(m.group(0)!, value);
    }
    return result;
  }

  final String? image;
  final String? url;
  final String? webViewUrl;

  /// Named route to navigate to when the child is tapped (e.g. "/about").
  final String? route;

  /// Optional arguments passed to the route (e.g. {"url": "...", "title": "..."}).
  final Map<String, dynamic>? routeArgs;
  final String? title;
  final String? code;
  final String? name;
  final double? height;
  final double? width;

  /// Per-child image width, mirroring the item-level `photoWidth`. A bare
  /// number is pixels; a percentage (e.g. "80%") is relative to the available
  /// width. Falls back to the item-level `photoWidth` when absent.
  final String? photoWidth;

  /// Per-child image height, mirroring the item-level `photoHeight`. A bare
  /// number is pixels; a percentage (e.g. "50%") is relative to the available
  /// width. Falls back to the item-level `photoHeight` when absent.
  final String? photoHeight;
  final double? borderRadius;

  PageChild copyWith({
    String? image,
    String? url,
    String? webViewUrl,
    String? route,
    Map<String, dynamic>? routeArgs,
    String? title,
    String? code,
    String? name,
    double? height,
    double? width,
    String? photoWidth,
    String? photoHeight,
    double? borderRadius,
  }) {
    return PageChild(
      image: image ?? this.image,
      url: url ?? this.url,
      webViewUrl: webViewUrl ?? this.webViewUrl,
      route: route ?? this.route,
      routeArgs: routeArgs ?? this.routeArgs,
      title: title ?? this.title,
      code: code ?? this.code,
      name: name ?? this.name,
      height: height ?? this.height,
      width: width ?? this.width,
      photoWidth: photoWidth ?? this.photoWidth,
      photoHeight: photoHeight ?? this.photoHeight,
      borderRadius: borderRadius ?? this.borderRadius,
    );
  }
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
    this.route,
    this.routeArgs,
    this.webViewUrl,
    this.url,
    this.title,
  });

  /// Named route to navigate to (e.g. "/about").
  final String? route;

  /// Optional arguments passed to the route.
  final Map<String, dynamic>? routeArgs;

  /// URL to open in an in-app web view.
  final String? webViewUrl;

  /// URL to launch externally.
  final String? url;

  /// Optional title for the target (e.g. web view app bar).
  final String? title;
}
