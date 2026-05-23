# FanGeo UI Smoothness Lag Report

## Scope

This pass is report + instrumentation only. No UI design, backend, Supabase, realtime behavior, rendering behavior, or `MapViewModel` architecture was changed.

Runtime diagnostics are controlled by:

```swift
UIPerformanceDiagnostics.uiPerformanceDiagnosticsEnabled
```

Default is `false` in DEBUG and Release builds. Manually flip it to `true` in `RealtimeDiagnosticLogging.swift` for a profiling run.

## Instrumentation Added

- `[UIPerf] tabSwitch from= to= ms=` in `MainTabView`.
- `[UIPerf] visibleTabForegroundRefresh ms=` in `MainTabView`.
- `[UIPerf] venueDetailOpen ms=` in `DiscoverScreen`.
- `[UIPerf] venueCardBodyBuild eventId=` in Discover venue cards and Venue Detail rows.
- `[UIPerf] discoverScrollFrameDrop suspected=` when a measured card/row body build exceeds one 60 FPS frame budget.
- `os_signpost` events for tab switch, Discover card open, Venue detail open, Fan Chat open, DM inbox open, and Profile tab open.

## Files Inspected

- `GameOn/MainTabView.swift`
- `GameOn/DiscoverScreen.swift`
- `GameOn/VenueDetailView.swift`
- `GameOn/RecoveredSocialChatViews.swift`
- `GameOn/SettingsScreen.swift`
- `GameOn/FanUpdatesTapPerf.swift`
- `GameOn/RealtimeDiagnosticLogging.swift`
- `GameOn/MapViewModel.swift`
- `GameOn/DiscoverMapRenderSnapshot.swift`
- `GameOn/DiscoverMapImageCache.swift`
- `GameOn/MapViewModel+VenueAndGameData.swift`
- `GameOn/MapViewModel+VenueEventSocial.swift`
- `GameOn/SocialAvatarRenderer.swift`
- `GameOn/UserAvatarView.swift`
- `GameOn/VenueEventPredictionsView.swift`

## Likely Lag Sources

### Repeated SwiftUI Body Recomposition

`DiscoverScreen` observes the full `MapViewModel`, which has many `@Published` properties spanning auth, venue owner state, Discover map state, venue events, social counts, predictions, pickup games, profile state, and loading flags. Any change can invalidate broad portions of Discover even when the visible surface only needs a small subset.

Exact hotspots:

- `DiscoverScreen.venuePreviewCard(_:)` recomputes venue games, fan-zone data, identity banner state, and game rows from shared model state.
- `DiscoverScreen.venuePreviewHeroGameCard(...)` and `venuePreviewCompactGameCard(...)` resolve teams, themes, attendance, status, avatars, and social footer state during body construction.
- `VenueDetailView.gameRow(_:)` resolves matchup/theme/display text for each row during body construction.

### Heavy Gradients and Cards in Scroll Views

The venue preview still renders premium matchup cards in the Discover bottom sheet. Those cards include gradients, shadows, overlays, flags/orbs, attendance footer views, and social controls inside a scrollable container. Even with safe rendering, this is a likely source of dropped frames during vertical scroll because SwiftUI may rebuild visible rows repeatedly.

Exact hotspots:

- `VenueMatchupCardView` usage from `DiscoverScreen.venuePreviewHeroGameCard(...)`.
- `VenueMatchupCardView` usage from `DiscoverScreen.venuePreviewCompactGameCard(...)`.
- `DiscoverScreen.gamesListSection(...)`, which can render multiple card variants in the preview.

### Map Overlay Work

Discover map rendering has improved with detached snapshots, but the visible `Map` still renders clusters, annotations, live energy styling, selected marker animation, and overlay controls from changing state. Snapshot publication also updates `discoverMapRenderSnapshot`, which invalidates the view.

Exact hotspots:

- `DiscoverScreen.discoverMap`
- `DiscoverScreen.discoverVenueClustersForMap`
- `DiscoverMapRenderSnapshotBuilder.build(input:)`
- `MapViewModel.applyDiscoverMapRenderSnapshot(...)`

### Image Loading and Decoding

`DiscoverMapImageCache` decodes venue images off-main, which is good. Some visible surfaces still use `AsyncImage` directly, and avatar/venue image changes can trigger network and decode work during scrolling or sheet presentation.

Exact hotspots:

- `DiscoverScreen` avatar `AsyncImage` usage for going avatars.
- `SocialAvatarRenderer`
- `UserAvatarView`
- `VenueEventPredictionsView`
- `SettingsScreen` reported comment avatars.

### Foreground Refreshes

When returning to foreground, `MainTabView.handleAppBecameActive()` can perform session validation, owner refreshes, single-session checks, admin checks, pokes badge refreshes, chat realtime checks, fan chat verification, and pickup refreshes before scheduling a deferred batch. This can compete with first visible frame after foregrounding.

Exact hotspot:

- `MainTabView.handleAppBecameActive()`

### Debug Print Spam

There are many `#if DEBUG print(...)` calls in hot UI paths, especially Discover card, map marker, layout, image cache, and venue debug paths. In DEBUG, print I/O can make smoothness feel worse than Release.

Exact hotspots:

- `DiscoverScreen` map marker/card/layout `print(...)` calls.
- `DiscoverMapImageCache` cache hit/fetch logs.
- `DiscoverMapRenderSnapshot` snapshot timing logs.
- `VenueDetailView.gameRow(_:)` row appear logs.

### Offscreen Tab Work

Tabs are preserved after first mount. That preserves state, but mounted offscreen tabs can still observe model changes and may do work through `.task`, `.onAppear`, or observed-object invalidations. The code already avoids some Account and Chat work unless selected, but broad model invalidation remains a risk.

Exact hotspots:

- `MainTabView.lazyPreservedRoot(...)`
- `FriendsTabView.onAppear` / `onChange(of: isTabSelected)`
- `SettingsScreen.onAppear`

### Broad `@Published` Invalidations

`MapViewModel` is the highest-probability systemic source. It publishes many unrelated properties from a single object observed by major tabs. This makes a tiny auth/profile/social/map change able to invalidate large SwiftUI trees.

Exact hotspots:

- `MapViewModel.bars`
- `MapViewModel.venueEventRows`
- `MapViewModel.venueEventInterestCounts`
- `MapViewModel.selectedBar`
- `MapViewModel.favoriteVenueIDs`
- `MapViewModel.discoverMapRenderSnapshot`
- Auth/profile/owner `@Published` fields observed by tabs that do not always need them.

## No-Risk Fixes

- Keep `[UIPerf]` logs enabled for one DEBUG session and record tab switch, venue detail open, foreground refresh, and card body build timings.
- Temporarily turn noisy existing DEBUG log groups off while measuring UI smoothness.
- Compare simulator DEBUG, device DEBUG, and device Release/TestFlight feel before optimizing; DEBUG print overhead may be a large part of the perceived lag.
- Capture Instruments Time Profiler + SwiftUI template while reproducing: tab switch, Discover vertical scroll, venue detail open, Fan Chat open.

## Medium-Risk Fixes

- Split Discover-facing state into smaller observable slices so venue/social/profile updates do not invalidate the entire Discover surface.
- Memoize venue preview presentation models per venue/date/sport/event row revision.
- Cache resolved `TeamTheme`, matchup display titles, and status presentation for visible venue cards.
- Replace direct `AsyncImage` in scroll rows with the existing image cache or a shared cached image view.
- Gate more offscreen tab work behind selected-tab checks.
- Replace hot-path `print(...)` calls with `DebugLogGate.noisy(...)` or the new diagnostics flag.

## High-Risk Fixes

- Refactor `MapViewModel` into domain view models for Discover, auth/profile, owner tools, social, and realtime.
- Replace the current map/annotation composition with a more isolated map rendering model.
- Rebuild premium card rendering around pre-rendered/static layers or lower-cost card variants in scrolling contexts.
- Rework foreground refresh orchestration so visible tab frame readiness and network refreshes are explicitly separated.

## Recommended Next Step

Run one device DEBUG session with `uiPerformanceDiagnosticsEnabled = true`, reproduce the lag, and collect the `[UIPerf]` lines plus Instruments signposts. Optimize only the highest measured offender first, likely either venue card body rebuilds, foreground refresh time, or broad `MapViewModel` invalidation.
