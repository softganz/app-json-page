import 'dart:convert';
import 'dart:developer';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import 'package:json_page/src/models/page_model.dart';

/// Async provider that fetches and parses a page JSON file (e.g. `home.json`).
///
/// Keyed by the full JSON [url] so any screen can render its own config file.
/// The caller is responsible for supplying the complete URL (including any
/// dev/production base), so the provider does not depend on app-specific
/// server-mode state.
final pageProvider =
    AsyncNotifierProviderFamily<PageNotifier, PageConfig, String>(
      PageNotifier.new,
    );

class PageNotifier extends FamilyAsyncNotifier<PageConfig, String> {
  late final String _url;

  @override
  Future<PageConfig> build(String url) async {
    _url = url;
    return _fetch();
  }

  Future<PageConfig> _fetch() async {
    log('JSON_PAGE :: pageProvider: loading json from $_url');
    try {
      final http.Response response = await http.get(Uri.parse(_url));
      if (response.statusCode != 200) {
        throw Exception('Failed to load page (status ${response.statusCode})');
      }
      final String raw = utf8.decode(response.bodyBytes);
      final Map<String, dynamic> json =
          jsonDecode(_stripComments(raw)) as Map<String, dynamic>;
      final PageConfig feed = PageConfig.fromJson(json);
      _pingOnLoadUrl(feed.onLoadUrl);
      return feed;
    } catch (e, stack) {
      log('pageProvider: error fetching page', error: e, stackTrace: stack);
      rethrow;
    }
  }

  /// Manually refresh the current page.
  Future<void> refresh() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(_fetch);
  }

  /// Applies a realtime event payload to the loaded page config in-place.
  ///
  /// Finds the matching feed item by [RealtimePatchConfig.matchBy] (e.g. the
  /// item's `name`) and applies the `patch` field mappings from [eventData]
  /// (the `data` object of a `photo.new` event). The result is a new
  /// [PageConfig] with the patched item — no network call.
  ///
  /// No-op when realtime is disabled or no item matches.
  void patchItem(Map<String, dynamic> eventData) {
    final AsyncValue<PageConfig> current = state;
    if (current is! AsyncData<PageConfig>) return;
    final PageConfig config = current.value;
    if (!config.realtime.enabled) return;

    final String matchBy = config.realtime.matchBy;
    final String? matchValue = eventData[matchBy]?.toString();
    if (matchValue == null || matchValue.isEmpty) return;

    final Map<String, PageItem> patchedItems = {
      for (final MapEntry<String, PageItem> e in config.widget.items.entries)
        e.key: e.value,
    };

    bool patched = false;
    for (final MapEntry<String, PageItem> e in patchedItems.entries) {
      final PageItem item = e.value;
      final String? itemMatch = _itemField(item, matchBy);
      if (itemMatch != matchValue) continue;
      patchedItems[e.key] = _applyPatch(item, config.realtime.patch, eventData);
      patched = true;
      break;
    }

    if (!patched) return;

    final PageConfig newConfig = PageConfig(
      type: config.type,
      title: config.title,
      margin: config.margin,
      padding: config.padding,
      widget: PageWidget(
        show: config.widget.show,
        cameraPhoto: config.widget.cameraPhoto,
        cameraLastPhoto: config.widget.cameraLastPhoto,
        cameraRealtimePhoto: config.widget.cameraRealtimePhoto,
        cameraReloadTime: config.widget.cameraReloadTime,
        items: patchedItems,
      ),
      route: config.route,
      routeArgs: config.routeArgs,
      logo: config.logo,
      url: config.url,
      onLoadUrl: config.onLoadUrl,
      realtime: config.realtime,
    );
    state = AsyncValue.data(newConfig);
  }

  /// Reads a top-level field from a [PageItem] by name.
  String? _itemField(PageItem item, String field) {
    switch (field) {
      case 'name':
        return item.children
            .map((c) => c.name)
            .where((n) => n != null && n.isNotEmpty)
            .join(',');
      case 'title':
        return item.title;
      case 'type':
        return item.type;
      default:
        return null;
    }
  }

  /// Applies [patchMap] (itemField → dotted event path) to [item] using values
  /// from [eventData]. Returns a new [PageItem] with updated child attributes.
  PageItem _applyPatch(
    PageItem item,
    Map<String, String> patchMap,
    Map<String, dynamic> eventData,
  ) {
    // Resolve event values from dotted paths (e.g. "data.url").
    final Map<String, String?> resolved = {};
    for (final MapEntry<String, String> e in patchMap.entries) {
      resolved[e.key] = _resolvePath(eventData, e.value);
    }

    // Apply to children: imageUrl/thumbnailUrl → child.image; time → child.title suffix.
    final List<PageChild> newChildren = item.children.map((child) {
      return child.copyWith(
        image: resolved['imageUrl'] ?? resolved['thumbnailUrl'] ?? child.image,
      );
    }).toList();

    return PageItem(
      type: item.type,
      title: item.title,
      url: item.url,
      webViewUrl: item.webViewUrl,
      children: newChildren,
      padding: item.padding,
      layout: item.layout,
      gap: item.gap,
      columns: item.columns,
      photoWidth: item.photoWidth,
      photoHeight: item.photoHeight,
      wrap: item.wrap,
      photoBorderRadius: item.photoBorderRadius,
    );
  }

  /// Resolves a dotted path (e.g. `data.url`) inside [root].
  String? _resolvePath(Map<String, dynamic> root, String path) {
    final List<String> parts = path.split('.');
    dynamic cursor = root;
    for (final String part in parts) {
      if (cursor is Map<String, dynamic> && cursor.containsKey(part)) {
        cursor = cursor[part];
      } else {
        return null;
      }
    }
    if (cursor == null) return null;
    return cursor.toString();
  }

  /// Fires a non-blocking GET to [onLoadUrl] when a page JSON is loaded.
  /// Appends a `time` query parameter set to the current epoch milliseconds.
  /// Used as a side-effect ping (e.g. analytics/notify) and never blocks
  /// rendering or throws into the page load.
  void _pingOnLoadUrl(String? onLoadUrl) {
    if (onLoadUrl == null || onLoadUrl.isEmpty) return;
    final DateTime now = DateTime.now();
    final String time =
        '${now.year.toString().padLeft(4, '0')}-'
        '${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')} '
        '${now.hour.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')}:'
        '${now.second.toString().padLeft(2, '0')}';
    final Uri uri = Uri.parse(onLoadUrl).replace(
      queryParameters: <String, String>{
        ...Uri.parse(onLoadUrl).queryParameters,
        'time': time,
      },
    );
    http
        .get(uri)
        .then((_) {
          /* response intentionally ignored */
        })
        .catchError((Object e, StackTrace stack) {
          log(
            'pageProvider: onLoadUrl ping failed',
            error: e,
            stackTrace: stack,
          );
        });
  }
}

/// Global tick that forces every [RenderCameraWidget] to reload its image.
///
/// Incremented by the host when a realtime photo event arrives (e.g. a
/// Firebase RTDB `photo.new` push). [RenderView] reads this and forwards the
/// value to each camera tile, which reloads the displayed image immediately
/// instead of waiting for its periodic timer.
final cameraReloadTickProvider = StateProvider<int>((ref) => 0);

/// Removes `//` and `/* ... */` comments from a JSONC-like string while keeping
/// `//` that appears inside string literals (e.g. `"https://..."`).
String _stripComments(String source) {
  final StringBuffer buffer = StringBuffer();
  bool inString = false;
  bool inLineComment = false;
  bool inBlockComment = false;
  int i = 0;
  while (i < source.length) {
    final String char = source[i];
    final String next = i + 1 < source.length ? source[i + 1] : '';

    if (inLineComment) {
      if (char == '\n') {
        inLineComment = false;
        buffer.write(char);
      }
      i++;
      continue;
    }

    if (inBlockComment) {
      if (char == '*' && next == '/') {
        inBlockComment = false;
        i += 2;
        continue;
      }
      if (char == '\n') buffer.write(char);
      i++;
      continue;
    }

    if (inString) {
      buffer.write(char);
      // Handle escape sequences so an escaped quote doesn't end the string.
      if (char == '\\' && next.isNotEmpty) {
        buffer.write(next);
        i += 2;
        continue;
      }
      if (char == '"') inString = false;
      i++;
      continue;
    }

    if (char == '"') {
      inString = true;
      buffer.write(char);
      i++;
      continue;
    }

    if (char == '/' && next == '/') {
      inLineComment = true;
      i += 2;
      continue;
    }

    if (char == '/' && next == '*') {
      inBlockComment = true;
      i += 2;
      continue;
    }

    buffer.write(char);
    i++;
  }
  return buffer.toString();
}
