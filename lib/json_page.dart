/// A reusable Flutter page renderer driven by a page JSON file.
///
/// The typical entry point is [RenderView], which fetches and renders a page
/// config (see [PageConfig]) through [pageProvider]. Tapping a feed item
/// produces a [LinkTarget] via the `onLinkTap` callback so the host can decide
/// how to navigate (named route, in-app web view, external launch, ...).
library;

export 'src/models/page_model.dart';
export 'src/models/realtime_config.dart';
export 'src/providers/page_provider.dart';
export 'src/providers/realtime_provider.dart';
export 'src/services/realtime_service.dart';
export 'src/render_view.dart';
export 'src/render_image.dart';
export 'src/render_camera.dart';
export 'src/render_sidebox.dart';
export 'src/render_webview.dart';
