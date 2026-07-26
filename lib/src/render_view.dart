import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:json_page/src/render_camera.dart';
import 'package:json_page/src/render_image.dart';
import 'package:json_page/src/render_sidebox.dart';
import 'package:json_page/src/render_webview.dart';
import 'package:json_page/src/models/page_model.dart';
import 'package:json_page/src/models/realtime_config.dart';
import 'package:json_page/src/providers/page_provider.dart';
import 'package:json_page/src/providers/realtime_provider.dart';
import 'package:json_page/src/providers/camera_log_poll_provider.dart';

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
/// [onRoute] with the configured route name (and optional [routeArgs]) so the
/// host can navigate to its own named route (the library does not know the
/// host's route table).
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
    this.routeBuilder,
    this.webViewHeaders,
    this.realtime,
  });

  /// JSON URL to fetch and render (e.g. `https://example.com/home.json`).
  final String url;

  /// Optional realtime configuration. When provided, `json_page` owns the
  /// realtime connection (poll / firebase / ws) and applies `photo.new`
  /// events in-place to the matching camera child — no host wiring needed.
  final RealtimeConfig? realtime;

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
  /// navigate to the given named [route] (e.g. via `Navigator.pushNamed`),
  /// optionally passing [routeArgs] as the route arguments. When null, route
  /// configs are ignored.
  ///
  /// This is only used as a fallback: when [routeBuilder] is provided and
  /// returns a non-null widget, that widget is rendered inline (keeping this
  /// page's AppBar and the host's main navigation) instead of pushing a
  /// full-screen route.
  final void Function(
    BuildContext context,
    String route, {
    Map<String, dynamic>? routeArgs,
  })?
  onRoute;

  /// Builds the content of a named [route] to render **inline** inside this
  /// page (so the page's AppBar and the host's main navigation stay visible).
  /// Used when the page config declares `type: "route"`.
  ///
  /// Return a non-null widget to render it inline; return `null` (or omit this)
  /// to fall back to [onRoute] (which pushes a full-screen named route). The
  /// host typically maps [route] to one of its own screens in `embedded` mode
  /// (a body-only widget without its own Scaffold/AppBar).
  final Widget? Function(
    BuildContext context,
    String route, {
    Map<String, dynamic>? routeArgs,
  })?
  routeBuilder;

  /// Optional HTTP headers forwarded to every in-app web view opened by this
  /// page (e.g. `{kDeviceIdHeader: deviceId}`). Applied to both the top-level
  /// `type: "webview"` page and any `type: "webView"` item.
  final Map<String, String>? webViewHeaders;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<PageConfig> feed = ref.watch(pageProvider(url));
    // Realtime push: bumping this tick forces camera tiles to reload images.
    final int reloadTick = ref.watch(cameraReloadTickProvider);

    if (realtime != null) {
      ref.listen(realtimeProvider(realtime!), (
        _,
        AsyncValue<RealtimeEvent> event,
      ) {
        final RealtimeEvent? ev = event.valueOrNull;
        if (ev == null) return;
        if (ev.type != 'photo.new') return;
        ref.read(pageProvider(url).notifier).patchItem(ev.data);
      });
    }

    return Scaffold(
      appBar: AppBar(
        elevation: 0,
        automaticallyImplyLeading: false,
        title: Row(
          children: [
            feed.when(
              data: (data) => _AppBarLogo(jsonLogo: data.logo, hostLogo: logo),
              loading: () => _AppBarLogo(hostLogo: logo),
              error: (_, _) => _AppBarLogo(hostLogo: logo),
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
          data: (data) => _renderByType(context, data, ref, reloadTick),
        ),
      ),
    );
  }

  /// Wraps [child] with [margin] when the page declares a top-level `margin`.
  static Widget _withMargin(EdgeInsets? margin, Widget child) {
    if (margin == null) return child;
    return Padding(padding: margin, child: child);
  }

  /// Wraps [child] with [padding] when the page declares a top-level `padding`.
  static Widget _withPadding(EdgeInsets? padding, Widget child) {
    if (padding == null) return child;
    return Padding(padding: padding, child: child);
  }

  /// Dispatches rendering to one of the three top-level render formats.
  Widget _renderByType(
    BuildContext context,
    PageConfig data,
    WidgetRef ref,
    int reloadTick,
  ) {
    switch (data.type) {
      case 'route':
        // Render a named route inline (keeping this page's AppBar and the
        // otherwise fall back to [onRoute], which pushes a full-screen route.
        final String? route = data.route;
        final Map<String, dynamic>? routeArgs = data.routeArgs;
        if (route != null && route.isNotEmpty) {
          if (routeBuilder != null) {
            final Widget? built = routeBuilder!(
              context,
              route,
              routeArgs: routeArgs,
            );
            if (built != null) {
              return _withMargin(
                data.margin,
                _withPadding(data.padding, built),
              );
            }
          }
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (context.mounted) {
              onRoute?.call(context, route, routeArgs: routeArgs);
            }
          });
        }
        return const Center(child: CircularProgressIndicator());

      case 'webview':
        // Render an in-app web view from the top-level `url`.
        final String? url = data.url;
        if (url == null || url.isEmpty) {
          return const Center(child: Text('ไม่มีข้อมูลในขณะนี้'));
        }
        return _withMargin(
          data.margin,
          _withPadding(
            data.padding,
            RenderWebviewWidget(
              item: PageItem(
                type: 'webview',
                // The page AppBar already shows the title, so omit the inner one.
                title: null,
                url: url,
                children: const [],
              ),
              headers: webViewHeaders,
            ),
          ),
        );

      case 'widget':
      default:
        // Page-level `last.json` poll owner (log-driven mode only). A single
        // provider instance fetches the log once per round and shares the
        // parsed `name -> updateAt` map with every cameraSet, so scrolling a
        // new set into view reconciles immediately without a new request.
        final bool useLogPoll =
            data.widget.cameraLogPhoto.isNotEmpty &&
            (realtime == null || realtime!.isPoll);
        final AsyncValue<CameraLogPollState>? logPoll = useLogPoll
            ? ref.watch(
                cameraLogPollProvider(
                  CameraLogPollParams(
                    '${data.widget.cameraPhoto}${data.widget.cameraLogPhoto}',
                    (realtime != null && realtime!.poolInterval.inSeconds > 0)
                        ? realtime!.poolInterval.inSeconds
                        : (data.widget.cameraPoolInterval > 0
                              ? data.widget.cameraPoolInterval
                              : 60),
                  ),
                ),
              )
            : null;

        // Render the list of widgets.
        final Widget list = _RenderList(
          widget: data.widget,
          reloadTick: reloadTick,
          logPoll: logPoll,
          realtimeActive: realtime != null && !realtime!.isPoll,
          poolInterval:
              (realtime != null && realtime!.poolInterval.inSeconds > 0)
              ? realtime!.poolInterval
              : Duration(seconds: data.widget.cameraPoolInterval),
          onLinkTap: onLinkTap,
          onRefresh: () => ref.read(pageProvider(url).notifier).refresh(),
          webViewHeaders: webViewHeaders,
        );
        return _withMargin(data.margin, _withPadding(data.padding, list));
    }
  }
}

class _RenderList extends StatelessWidget {
  const _RenderList({
    required this.widget,
    required this.reloadTick,
    this.logPoll,
    this.realtimeActive = false,
    this.poolInterval = const Duration(seconds: 60),
    required this.onRefresh,
    this.onLinkTap,
    this.webViewHeaders,
  });

  final PageWidget widget;
  final int reloadTick;

  /// Page-level `last.json` poll state (log-driven mode). When non-null, the
  /// per-camera widget reconciles against this shared map instead of running
  /// its own poll timer, so scrolling a new set into view updates immediately
  /// without a new `last.json` request.
  final AsyncValue<CameraLogPollState>? logPoll;

  /// When true, realtime (firebase/ws) owns photo updates, so the per-camera
  /// 60s poll timer is disabled (passed down to [RenderCameraWidget]).
  final bool realtimeActive;

  /// Poll interval for `poll` mode, from [RealtimeConfig.poolInterval].
  final Duration poolInterval;
  final Future<void> Function() onRefresh;
  final void Function(BuildContext context, LinkTarget target)? onLinkTap;

  /// Optional HTTP headers forwarded to every in-app web view item.
  final Map<String, String>? webViewHeaders;

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
                realtimeActive: realtimeActive,
                cameraPhoto: widget.cameraPhoto,
                cameraLastPhoto: widget.cameraLastPhoto,
                cameraRealtimePhoto: widget.cameraRealtimePhoto,
                cameraLogPhoto: widget.cameraLogPhoto,
                cameraThumbPhoto: widget.cameraThumbPhoto,
                reloadTimeSeconds: poolInterval.inSeconds,
                externalTick: reloadTick,
                logPoll: logPoll,
                onLinkTap: onLinkTap,
              ),
            ),
          );
        case 'webView':
          tiles.add(
            _withPadding(
              item.padding,
              RenderWebviewWidget(item: item, headers: webViewHeaders),
            ),
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

/// App-bar logo that prefers the logo declared by the page JSON ([jsonLogo]).
///
/// When the JSON supplies a logo URL it overrides the host-provided [hostLogo]
/// (which is only used as a fallback when the JSON has none). A `http(s)` URL
/// is loaded over the network; any other non-empty string is treated as a
/// local asset path. Returns an empty widget when no logo is available.
class _AppBarLogo extends StatelessWidget {
  const _AppBarLogo({this.jsonLogo, this.hostLogo});

  final String? jsonLogo;
  final Widget? hostLogo;

  @override
  Widget build(BuildContext context) {
    final String? logoUrl = jsonLogo?.trim();
    if (logoUrl != null && logoUrl.isNotEmpty) {
      final Widget image = logoUrl.startsWith('http')
          ? Image.network(logoUrl, fit: BoxFit.contain)
          : Image.asset(logoUrl, fit: BoxFit.contain);
      return SizedBox(
        height: 36,
        child: Padding(padding: const EdgeInsets.only(right: 8), child: image),
      );
    }
    if (hostLogo != null) {
      return SizedBox(
        height: 36,
        child: Padding(
          padding: const EdgeInsets.only(right: 8),
          child: hostLogo,
        ),
      );
    }
    return const SizedBox.shrink();
  }
}
