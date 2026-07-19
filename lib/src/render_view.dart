import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:json_page/src/render_camera.dart';
import 'package:json_page/src/render_image.dart';
import 'package:json_page/src/render_sidebox.dart';
import 'package:json_page/src/render_webview.dart';
import 'package:json_page/src/models/page_model.dart';
import 'package:json_page/src/providers/page_provider.dart';

/// A reusable page renderer that fetches and renders a page JSON file
/// (e.g. `home.json`, `apps.json`) through [pageProvider].
///
/// Used by both the Feed tab and the Apps tab so they share the same
/// rendering pipeline (image / cameraSet / sizebox items, pull-to-refresh,
/// and error/retry states).
///
/// The renderer is decoupled from any host-specific navigation: when a feed
/// item is tapped it invokes [onLinkTap] with a [LinkTarget] so the host can
/// decide how to navigate (named route, in-app web view, external launch, ...).
///
/// When the page config declares `type: "route"`, the renderer invokes
/// [onRoute] with the configured route name so the host can navigate to its
/// own named route (the library does not know the host's route table).
class RenderView extends ConsumerWidget {
  const RenderView({
    super.key,
    required this.url,
    this.title,
    this.defaultTitle,
    this.logo,
    this.actions,
    this.onLinkTap,
    this.onRoute,
  });

  /// JSON URL to fetch and render (e.g. `https://example.com/home.json`).
  final String url;

  /// Title shown in the app bar; falls back to the JSON `title` field.
  final String? title;

  /// Title used when neither [title] nor the JSON `title` is available.
  final String? defaultTitle;

  /// Optional logo widget shown in the app bar (defaults to none).
  final Widget? logo;

  /// Optional trailing app-bar actions (e.g. a settings/about popup menu).
  final List<Widget>? actions;

  /// Called when a tappable feed item is tapped. When null, taps are ignored.
  final void Function(BuildContext context, LinkTarget target)? onLinkTap;

  /// Called when the page config declares `type: "route"`. The host should
  /// navigate to the given named [route] (e.g. via `Navigator.pushNamed`).
  /// When null, route configs are ignored.
  final void Function(BuildContext context, String route)? onRoute;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<PageConfig> feed = ref.watch(pageProvider(url));

    return Scaffold(
      appBar: AppBar(
        elevation: 0,
        automaticallyImplyLeading: false,
        title: Row(
          children: [
            if (logo != null)
              SizedBox(
                height: 36,
                child: Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: logo,
                ),
              ),
            Expanded(
              child: feed.when(
                data: (data) => Text(
                  data.title.isNotEmpty
                      ? data.title
                      : (title ?? defaultTitle ?? ''),
                ),
                loading: () => Text(title ?? defaultTitle ?? ''),
                error: (_, _) => Text(title ?? defaultTitle ?? ''),
              ),
            ),
          ],
        ),
        actions: actions,
      ),
      body: SafeArea(
        child: feed.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, stack) => _RenderError(
            message: error.toString(),
            onRetry: () => ref.read(pageProvider(url).notifier).refresh(),
          ),
          data: (data) => _renderByType(context, data, ref),
        ),
      ),
    );
  }

  /// Dispatches rendering to one of the three top-level render formats.
  Widget _renderByType(BuildContext context, PageConfig data, WidgetRef ref) {
    switch (data.type) {
      case 'route':
        // Redirect to a named route instead of rendering a widget.
        final String? route = data.route;
        if (route != null && route.isNotEmpty) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (context.mounted) onRoute?.call(context, route);
          });
        }
        return const Center(child: CircularProgressIndicator());

      case 'webview':
        // Render an in-app web view from the top-level `url`.
        final String? url = data.url;
        if (url == null || url.isEmpty) {
          return const Center(child: Text('ไม่มีข้อมูลในขณะนี้'));
        }
        return RenderWebviewWidget(
          item: PageItem(
            type: 'webview',
            // The page AppBar already shows the title, so omit the inner one.
            title: null,
            url: url,
            children: const [],
          ),
        );

      case 'widget':
      default:
        // Render the list of widgets.
        return _RenderList(
          widget: data.widget,
          onLinkTap: onLinkTap,
          onRefresh: () => ref.read(pageProvider(url).notifier).refresh(),
        );
    }
  }
}

class _RenderList extends StatelessWidget {
  const _RenderList({
    required this.widget,
    required this.onRefresh,
    this.onLinkTap,
  });

  final PageWidget widget;
  final Future<void> Function() onRefresh;
  final void Function(BuildContext context, LinkTarget target)? onLinkTap;

  /// Wraps [child] with [padding] when the item declares one.
  static Widget _withPadding(EdgeInsets? padding, Widget child) {
    if (padding == null) return child;
    return Padding(padding: padding, child: child);
  }

  @override
  Widget build(BuildContext context) {
    final List<Widget> tiles = <Widget>[];
    for (final String key in widget.show) {
      final PageItem? item = widget.items[key];
      if (item == null) continue;
      switch (item.type) {
        case 'image':
          tiles.add(
            _withPadding(
              item.padding,
              RenderImageWidget(item: item, onLinkTap: onLinkTap),
            ),
          );
        case 'sizebox':
          tiles.add(RenderSideboxWidget(item: item));
        case 'cameraSet':
          tiles.add(
            _withPadding(
              item.padding,
              RenderCameraWidget(
                item: item,
                cameraPhoto: widget.cameraPhoto,
                cameraLastPhoto: widget.cameraLastPhoto,
                cameraRealtimePhoto: widget.cameraRealtimePhoto,
                onLinkTap: onLinkTap,
              ),
            ),
          );
        case 'webView':
          tiles.add(
            _withPadding(item.padding, RenderWebviewWidget(item: item)),
          );
        default:
          break;
      }
    }

    if (tiles.isEmpty) {
      return const Center(child: Text('ไม่มีข้อมูลในขณะนี้'));
    }

    // A single full-screen web view must not be wrapped in a scrollable
    // `ListView`: the parent would intercept the vertical drag gesture and the
    // inner web view could no longer scroll its own content. Other single
    // tiles keep the `ListView` so they can still scroll if taller than screen.
    if (tiles.length == 1 && tiles.single is RenderWebviewWidget) {
      return tiles.single;
    }

    return RefreshIndicator(
      onRefresh: onRefresh,
      child: ListView(children: tiles),
    );
  }
}

class _RenderError extends StatelessWidget {
  const _RenderError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 48, color: Colors.red),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            ElevatedButton(onPressed: onRetry, child: const Text('ลองใหม่')),
          ],
        ),
      ),
    );
  }
}
