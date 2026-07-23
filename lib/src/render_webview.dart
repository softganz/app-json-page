import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'package:json_page/src/models/page_model.dart';

/// Renders a feed item of `type: webView` as an embedded in-app web view
/// (via `flutter_inappwebview`).
///
/// The web view opens a single URL read from the item's `url` field. When the
/// item also declares a `title`, it is shown on an `AppBar` above the web
/// view. The web view fills the full available display height.
class RenderWebviewWidget extends StatelessWidget {
  const RenderWebviewWidget({super.key, required this.item, this.headers});

  final PageItem item;

  /// Optional HTTP headers sent with every request made by this web view
  /// (e.g. `{kDeviceIdHeader: deviceId}`). Applied to the initial load and to
  /// every in-web-view navigation via [shouldOverrideUrlLoading], so the
  /// server receives the header on every open.
  final Map<String, String>? headers;

  String? _resolveUrl() {
    // Open a single URL from the item's `url` field (per the webView spec).
    final String? itemUrl = item.url;
    if (itemUrl != null && itemUrl.isNotEmpty) return itemUrl;
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final String? url = _resolveUrl();
    debugPrint('[RenderWebview] title="${item.title}" url="$url"');
    if (url == null || url.isEmpty) {
      return const SizedBox.shrink();
    }

    // Fill the full display area: screen height minus the page AppBar and the
    // safe-area insets (the web view is already rendered inside the page's
    // SafeArea, so we subtract those to avoid overflow).
    final MediaQueryData mq = MediaQuery.of(context);
    final double fullHeight =
        mq.size.height - mq.padding.top - mq.padding.bottom - kToolbarHeight;
    final String? title = item.title;

    // `InAppWebView` needs an explicit, bounded size to render; wrap it in a
    // `SizedBox` rather than relying on `Expanded` inside a `Column`.
    final Widget webView = SizedBox(
      width: double.infinity,
      height: double.infinity,
      child: InAppWebView(
        initialUrlRequest: URLRequest(url: WebUri(url), headers: headers),
        initialSettings: InAppWebViewSettings(
          javaScriptEnabled: true,
          useShouldOverrideUrlLoading: true,
        ),
        // Re-apply [headers] on every in-web-view navigation so the server
        // receives the deviceId header on each subsequent request too.
        shouldOverrideUrlLoading: (controller, navigationAction) async {
          final WebUri? navUrl = navigationAction.request.url;
          if (navUrl != null && headers != null && headers!.isNotEmpty) {
            await controller.loadUrl(
              urlRequest: URLRequest(url: navUrl, headers: headers),
            );
            return NavigationActionPolicy.CANCEL;
          }
          return NavigationActionPolicy.ALLOW;
        },
      ),
    );

    if (title == null || title.isEmpty) {
      return SizedBox(
        height: math.max(0, fullHeight),
        width: double.infinity,
        child: webView,
      );
    }

    const double titleBarHeight = kToolbarHeight;
    return SizedBox(
      height: math.max(0, fullHeight),
      width: double.infinity,
      child: Column(
        children: [
          SizedBox(
            height: titleBarHeight,
            child: AppBar(
              title: Text(title),
              automaticallyImplyLeading: false,
              elevation: 0,
            ),
          ),
          SizedBox(
            height: math.max(0, fullHeight - titleBarHeight),
            width: double.infinity,
            child: webView,
          ),
        ],
      ),
    );
  }
}
