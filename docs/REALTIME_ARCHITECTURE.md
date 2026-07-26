# Realtime Architecture — json_page

> Status: **IMPLEMENTED** (2026-07-26)
> Owner: `json_page` lib handles all camera-photo realtime (poll / firebase / ws).
> The host app keeps its own `realtimeProvider` **only** for `request.status`
> (capture-request lifecycle), per agreed split.

## Goal
Move all realtime camera-photo handling into `json_page` so host apps only pass
a `RealtimeConfig` to `RenderView`. `json_page` then:
1. selects the transport (`poll` | `firebase` | `ws`),
2. connects / listens on its own,
3. renders, and
4. applies `photo.new` events **in-place to the single matching camera child**
   (no full refetch, no global reload tick).

## Transport selection (`RealtimeConfig.type`)
- `poll`    → no connection; `RenderCameraWidget` reloads images on its periodic
  timer (default 60s) as before.
- `firebase`→ REST + SSE stream to Firebase RTDB (`FirebaseRealtimeService`).
  Token comes from the app-loading endpoint; refreshed via `tokenUrl`.
- `ws`      → WebSocket gateway (`RealtimeService`). Connects to the public
  `feed` channel **without auth** (home feed is public). Optional `authMessage`
  may be supplied by a host that also needs the `device:{deviceId}` channel.

## Data flow
```
host app
  ├─ realtimeConfigProvider  → fetch config + firebase token (host-owned)
  └─ RenderView(url, realtime: config)
                                    │
json_page
  ├─ realtimeProvider(config)  → Stream<RealtimeEvent>  (ws | firebase | empty)
  └─ RenderView listens → photo.new
        └─ pageProvider(url).patchItem(event.data)
              └─ match child by realtime.matchBy (default "name")
                    └─ set child.image = url (+ cache-bust ?t=)  ← ONLY that camera
                    └─ append time to child.title (if patch has "time")
```

## Files
- `lib/src/models/realtime_config.dart` — `RealtimeConfig`, `FirebaseConfig`, `RealtimeEvent`.
- `lib/src/services/realtime_service.dart` — `RealtimeService` (WS), `FirebaseRealtimeService` (SSE).
- `lib/src/providers/realtime_provider.dart` — `realtimeProvider` (StreamNotifier family).
- `lib/src/providers/page_provider.dart` — `patchItem()` (per-child in-place patch).
- `lib/src/render_view.dart` — `RenderView.realtime` param + listener wiring.

## Per-child patch (not global)
`patchItem` matches the **child** whose `name` equals `eventData[matchBy]`, and
updates only that child's `image` (with `?t=<epoch>` cache-bust) and `title`
(time suffix). Other cameras are untouched — satisfying "update only the image
that changed".

## Backend
Unchanged. Server still emits `photo.new` to `flood_event_log` (WS) and writes
RTDB (firebase); the app-loading endpoint returns the `realtime` config block.
