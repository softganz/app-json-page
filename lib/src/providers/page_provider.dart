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
