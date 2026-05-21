# Venue Game Card Performance Audit - Phase 2

Date: May 21, 2026  
Scope: Discover venue preview and venue game card after the `VenueGameCardStore` Phase 1/1.5/2A changes.  
Mode: Report only. No app behavior or UI changes were made.

## Executive Summary

The venue preview is stable again after removing the swipe-down dismiss gesture, but the current Phase 2 card path still does too much work while SwiftUI is evaluating `venuePreviewCard`, `gamesListSection`, and `gameInterestRow`. The highest-risk issue is not one single expensive query in `body`; it is the combination of render-path diagnostic logging, per-card state derivation, prediction module lifecycle tasks, and broad `@Published` invalidation from card-only Going/avatar updates.

No P0 issue was found that requires an emergency revert before another build. The smallest safe next step is to remove or gate the render-path DEBUG logs first, then narrow card-only state publications so Going/avatar refreshes do not invalidate the map and unrelated Discover sections.

## P0 Issues

### None found

No remaining P0 crash pattern was found in the focused paths. The previous crash-risk swipe gesture has been removed from `DiscoverScreen.venuePreviewCard`, and the current card does not start Going realtime or mutate observable state directly from `ForEach` or `body`.

Residual P0 watch item: keep new gestures, realtime subscriptions, and direct observable mutations out of `venuePreviewCard`, `gamesListSection`, and `gameInterestRow`. The recent crashes came from this class of change, so it should remain a hard boundary.

## P1 Issues

### P1-1: DEBUG logging still runs from hot render paths

Files/functions:
- `GameOn/DiscoverScreen.swift`
  - `selectedEventSection(bar:selectedEvent:)`
  - `gamesListSection(bar:gamesToday:)`
  - `venuePreviewStableGameItems(for:selectedVenueID:)`
  - `gameInterestRow(bar:event:)`
  - `logVenueGameCardStoreRender(state:)`
  - `logGoingAvatarDebug(currentUserGoing:avatarStackCount:emptyGoingPromptVisible:)`
  - `venueGameCardSocialActionRow(venueEventID:previewEnergy:fanChatCount:)`
  - `venuePreviewInteractionStrip(venueEventID:)`
  - `venuePreviewInteractionStrip(venueEventID:miniStats:)`
  - `logVenueMiniStatsDebug(eventId:counts:)`
- `GameOn/VenueEventPredictionsView.swift`
  - `PredictionTeamDisplayName.compact(_:languageCode:)`
  - `VenueEventPredictionModule.body`
- `GameOn/MapViewModel+VenueGameCardStore.swift`
  - `venueGameCardGoingSnapshotNeedsInitialRefresh(eventID:snapshot:now:)`
  - `refreshInitialVenueGameCardGoingState(reason:)`
  - `refreshVenueGameCardGoingState(venueEventID:)`

Evidence:
- `gameInterestRow` calls `logVenueGameCardStoreRender(state:)` during view construction for every rendered card.
- The Going avatar row calls `logGoingAvatarDebug(...)` inside a `HStack` builder.
- `venuePreviewInteractionStrip` logs mini stats on every render, and `logVenueMiniStatsDebug` emits seven lines per card.
- Guest/full mode logs are inside the `ForEach` branch in `gamesListSection`.
- `VenueEventPredictionModule` emits a large block of layout, team, flag, and score debug logs on appear, while `PredictionTeamDisplayName.compact` logs every computed display name call.
- The initial Going freshness check logs once per resolved visible event whenever the scheduler runs.

Impact:
- DEBUG builds can become meaningfully slower and noisier exactly where the user is testing the venue preview.
- Logging from render builders is especially costly because harmless `@Published` changes can re-run the builders without an actual user action.
- The log volume makes real performance regressions harder to isolate because expected render churn and diagnostic churn are mixed together.

Smallest safe next fix:
- Remove or gate render-path prints first, without changing state or UI.
- Keep at most one explicit lifecycle log per venue preview open and one per network refresh completion.
- Move remaining diagnostics behind a temporary local constant or targeted flag that defaults off in DEBUG builds, for example a private `VenueGameCardDiagnostics.enabled`.

Rollback notes:
- This fix is low risk because it only removes diagnostics.
- Rollback is simply restoring the removed `#if DEBUG print(...)` blocks if a specific diagnostic is still needed.

### P1-2: Card-only Going/avatar snapshots are stored on `MapViewModel` and can invalidate the whole map/discover surface

Files/functions:
- `GameOn/MapViewModel.swift`
  - `@Published var venueGameCardGoingSnapshots`
- `GameOn/MapViewModel+VenueGameCardStore.swift`
  - `refreshVenueGameCardGoingState(venueEventID:)`
  - `refreshInitialVenueGameCardGoingState(reason:)`
  - `venueGameCardState(input:friendUserIDs:)`
- `GameOn/DiscoverScreen.swift`
  - `venuePreviewCard(_:)`
  - `gameInterestRow(bar:event:)`

Evidence:
- `refreshVenueGameCardGoingState` writes `venueGameCardGoingSnapshots[venueEventID]` once to mark `.reconciling` and again after the Supabase/profile load succeeds or fails.
- Because the snapshots live as `@Published` state on the app-wide `MapViewModel`, each write can invalidate every SwiftUI view observing that object, not only the card row that needs the updated Going/avatar data.
- `venuePreviewCard` recomputes `gamesToday`, `selectedVenueEvent`, visible prefetch events, and the social prefetch key whenever the observed object invalidates.

Impact:
- A card-only refresh can trigger expensive unrelated re-evaluation, including map/preview overlay work and full card list rebuilding.
- The issue is more visible after Phase 2A because initial preview open can refresh up to 12 visible event snapshots.
- This is the most likely source of map snapshot rebuilds caused by card-only Going/avatar state.

Smallest safe next fix:
- Keep the existing fetch behavior, but isolate card snapshots into a smaller observable owner used only by the venue preview card.
- If a full store extraction is too large for the next patch, first replace the app-wide `@Published` dictionary with a narrower published token or row-scoped observable object that only the card list observes.
- Avoid changing the Going toggle behavior, Supabase queries, or visible UI in the same patch.

Rollback notes:
- If isolating publication causes stale UI, roll back by restoring `venueGameCardGoingSnapshots` to `@Published` on `MapViewModel`.
- Keep the current `VenueGameCardGoingSnapshot` shape so rollback does not affect persisted data or network response handling.

### P1-3: Prediction module lifecycle can reload user predictions and realtime on card reappearance/rebuild

Files/functions:
- `GameOn/DiscoverScreen.swift`
  - `gameInterestRow(bar:event:)`
  - `venuePredictionVisibility(bar:event:venueEventID:)`
- `GameOn/VenueEventPredictionsView.swift`
  - `VenueEventPredictionModule.body`
  - `userPredictionLoadToken`
  - `loadUserPrediction()`
  - `.task(id: userPredictionLoadToken)`
  - `.task(id: venueEventID)`
  - `.onDisappear`
- `GameOn/MapViewModel+VenueEventPredictions.swift`
  - `startVenueEventPredictionRealtime(for:)`
  - `stopVenueEventPredictionRealtime(for:)`
  - `scheduleVenueEventPredictionRealtimeRefresh(eventID:)`
  - `refreshVenueEventPredictionSummary(eventID:)`

Evidence:
- `VenueEventPredictionModule` starts realtime in `.task(id: venueEventID)` and stops realtime in `.onDisappear`.
- The user prediction load token includes summary-derived values: `venueEventID`, `scoreMode`, and `totalCount`.
- Every summary total/score-mode change can re-run `loadUserPrediction()`, even if the current user's own prediction did not change.
- Card rebuilds can cause module appear/disappear churn, which can start/stop realtime repeatedly. There is duplicate-subscription protection, but churn still creates tasks, logs, and channel cleanup work.

Impact:
- Prediction summary updates can cascade into extra user-prediction reads.
- Card-only Going/avatar updates can indirectly rebuild the prediction module and increase task/log churn.
- The module is shared with venue detail/live screens, so fixes must be scoped carefully.

Smallest safe next fix:
- For Discover venue game cards only, load the current user's prediction with a token that changes only when `venueEventID` changes or after a local save.
- Keep aggregate summary realtime and manual refresh behavior unchanged.
- Consider passing a Discover-specific option into `VenueEventPredictionModule` to disable realtime auto-start for offscreen/list contexts only after measuring whether the current card needs live prediction updates.

Rollback notes:
- If user prediction state becomes stale after a summary refresh, restore the current `userPredictionLoadToken`.
- Do not alter prediction write paths or the shared Supabase realtime publication while tuning Discover card churn.

### P1-4: Going/avatar refresh can repeat profile loads that existing batch prefetch already performs

Files/functions:
- `GameOn/MapViewModel+VenueGameCardStore.swift`
  - `refreshVenueGameCardGoingState(venueEventID:)`
- `GameOn/MapViewModel+VenueEventSocial.swift`
  - `loadGoingUserProfiles(for:)`
  - `prefetchGoingProfilesForVisibleEventBatchIfNeeded(eventIDs:)`
- `GameOn/DiscoverScreen.swift`
  - `venuePreviewCard(_:)`
  - `prefetchVisibleVenueSocialData(bar:events:)`

Evidence:
- `refreshVenueGameCardGoingState` queries `venue_event_interests`, then calls `SocialIdentityService().fetchUserProfileRows(forEmails:)` for the event.
- Existing social prefetch paths also load Going profiles for visible events and keep `goingProfilesByVenueEventID` plus freshness timestamps.
- The card state builder falls back to `goingAvatarProfiles(...)`, which reads from the existing profile cache, but the Phase 2A refresh does not appear to reuse the existing batch profile freshness cache before fetching.

Impact:
- Initial venue preview open can do a visible-batch prefetch and a card-store Going refresh for overlapping events.
- The duplicate work is most expensive for venues with several visible games and multiple Going users.
- New `SocialIdentityService()` instances are created for each card-store refresh instead of sharing a cached identity resolver.

Smallest safe next fix:
- Before `refreshVenueGameCardGoingState` fetches profile rows, reuse fresh `goingProfilesByVenueEventID[venueEventID]` when the interest count snapshot is already fresh enough.
- Longer term, route initial card avatar refresh through the existing visible-event batch loader and have the card snapshot consume the batch result.
- Keep the post-toggle single-event refresh because it is the narrowest correctness path after a write.

Rollback notes:
- If avatar ordering or current-user insertion regresses, roll back to the current single-event `SocialIdentityService` fetch.
- Keep count refresh separate from profile cache reuse so Going counts remain authoritative.

## P2 Issues

### P2-1: Fan Chat and mini-stat dictionary reads are improved but still partly duplicated during card render

Files/functions:
- `GameOn/MapViewModel+VenueGameCardStore.swift`
  - `venueGameCardState(input:friendUserIDs:)`
- `GameOn/DiscoverScreen.swift`
  - `gameInterestRow(bar:event:)`
  - `venueGameCardSocialActionRow(venueEventID:previewEnergy:fanChatCount:)`
  - `venuePreviewInteractionStrip(venueEventID:)`
  - `venuePreviewInteractionStrip(venueEventID:miniStats:)`
  - `venuePreviewEnergy(for:energy:)`
  - `trendingScore(for:goingCount:)`

Evidence:
- The card state now packages `fanChatCount` and `miniStats`, and the main card render passes these into the social action row and interaction strip.
- Fallback paths still directly read `viewModel.fanUpdatesDisplayCommentCount(for:)`, `fanUpdatesStore.venueEventVibeCounts`, and `fanUpdatesStore.myVenueEventVibes`.
- `venuePreviewEnergy(for:energy:)` still has a fallback overload that reads vibe counts directly.
- `trendingScore(for:goingCount:)` still reads comment/vibe dictionaries, although it appears outside the primary card-state render path.

Impact:
- This is no longer the top card performance problem, but the view still contains enough fallback dictionary reads to reintroduce render-path work if `cardState` is nil or future code calls the older helpers.
- The split makes ownership harder to reason about because some mini stats come from `VenueGameCardState` and some still come from store/view dictionaries.

Smallest safe next fix:
- Make `VenueGameCardState` the only source for Fan Chat count, mini stats, and preview energy inside `gameInterestRow`.
- Keep fallback helpers for non-card call sites, but do not call them from the venue game card after `venueEventID` resolves.
- Add a DEBUG assertion or one-shot diagnostic if `venueEventID` exists but `cardState` is unexpectedly nil.

Rollback notes:
- If a nil-card edge case appears, restore the current fallback reads in `gameInterestRow` only.
- Do not remove the underlying `fanUpdatesStore` dictionaries; other screens still use them.

### P2-2: Main-thread render helpers do nontrivial collection work

Files/functions:
- `GameOn/DiscoverScreen.swift`
  - `venuePreviewCard(_:)`
  - `gamesListSection(bar:gamesToday:)`
  - `venuePreviewStableGameItems(for:selectedVenueID:)`
  - `venuePreviewNextAvailableGame(for:)`
  - `gameInterestRow(bar:event:)`
- `GameOn/MapViewModel+VenueGameCardStore.swift`
  - `venueGameCardState(input:friendUserIDs:)`
  - `venueGameCardBar(for:)`

Evidence:
- `venuePreviewCard` derives `gamesToday`, selected event, visible social prefetch events, and a prefetch key during view evaluation.
- `gamesListSection` builds stable items every render.
- `venuePreviewStableGameItems` groups event IDs, builds joined ID strings for DEBUG, and maps all visible events.
- `venuePreviewNextAvailableGame` scans `venueEventRows` and fallback `events` when the no-games state renders.
- `venueGameCardState` resolves the bar by scanning `bars`, `filteredBars`, and `followingTabSavedVenues` when `selectedBar` does not match.

Impact:
- None of these are individually alarming with a 12-card cap, but they compound with the `MapViewModel` invalidation issue.
- The DEBUG joined-ID strings are particularly wasteful because they are created before printing.

Smallest safe next fix:
- Remove the DEBUG ID string construction from `venuePreviewStableGameItems`.
- Cache or precompute the visible card inputs when `selectedBar`, `selectedDate`, `selectedSport`, or `venueEventRows` changes, not when unrelated published fields change.
- Add this only after P1 logging and publication isolation are complete.

Rollback notes:
- If precomputed card inputs cause stale filtering, roll back to current direct derivation.
- Preserve the 12-card cap and stable duplicate-ID behavior.

### P2-3: Initial Going refresh scheduler may still do more events than the visible card list needs

Files/functions:
- `GameOn/MapViewModel+VenueGameCardStore.swift`
  - `scheduleInitialVenueGameCardGoingRefresh(reason:)`
  - `refreshInitialVenueGameCardGoingState(reason:)`
  - `resolvedInitialVenueGameCardGoingRefreshIDs()`
- `GameOn/DiscoverScreen.swift`
  - `venuePreviewCard(_:)`
  - `visibleVenuePreviewEventsForSocialPrefetch(...)`

Evidence:
- `resolvedInitialVenueGameCardGoingRefreshIDs` derives up to 12 IDs from all matching active `venueEventRows`.
- The actual preview card separately derives visible social prefetch events from `gamesToday` and selected event state.
- These two visibility definitions can drift, especially after the date-filter relaxation made the initial resolver include future active venue rows.

Impact:
- Initial refresh can fetch Going/avatar data for rows that are valid for the venue but not currently rendered in the preview.
- This increases profile/network work and amplifies the `@Published` invalidation issue.

Smallest safe next fix:
- Feed the exact visible venue-event IDs from the preview selection pipeline into the initial refresh scheduler.
- Do this from a non-render lifecycle hook or existing selection method, not from inside `ForEach` or `gameInterestRow`.
- Keep the relaxed date matching only if needed for correctness, but intersect it with the visible card IDs.

Rollback notes:
- If initial counts stop appearing for selected/future games, restore `resolvedInitialVenueGameCardGoingRefreshIDs` as the fallback.
- Keep the debounce and TTL behavior unchanged.

## What Not To Touch

- Do not reintroduce the swipe-down dismiss gesture, `@GestureState`, or any preview drag gesture until a separate stability design exists.
- Do not start or manage Going realtime from `DiscoverScreen`, `gameInterestRow`, `ForEach`, `.onAppear`, or card body builders.
- Do not move Supabase writes, optimistic Going toggles, or post-toggle single-event refresh behavior in the same patch as performance cleanup.
- Do not change card UI, layout, copy, prediction controls, Fan Chat entry behavior, or the venue detail navigation flow.
- Do not remove shared prediction realtime behavior for venue detail/live screens while tuning Discover card behavior.
- Do not remove the existing visible-event social prefetch caches until the card store owns equivalent freshness and batching semantics.

## Recommended Fix Order

1. Remove or hard-gate render-path DEBUG logs in `DiscoverScreen`, `VenueEventPredictionsView`, and `MapViewModel+VenueGameCardStore`.
2. Isolate `venueGameCardGoingSnapshots` publication so card-only Going/avatar changes do not invalidate the app-wide `MapViewModel` observation graph.
3. Narrow Discover prediction reload tokens so summary aggregate changes do not repeatedly reload the current user's prediction.
4. Reuse existing Going profile batch freshness before `refreshVenueGameCardGoingState` performs per-event profile fetches.
5. Move remaining Fan Chat count, mini stats, and preview energy reads fully behind `VenueGameCardState`.
6. Precompute visible card inputs only after the above changes prove stable.

## Rollback Plan

- Logging cleanup rollback: restore the removed `#if DEBUG print(...)` blocks only for the diagnostic being actively used.
- Snapshot isolation rollback: move `VenueGameCardGoingSnapshot` storage back to `@Published` on `MapViewModel` and keep the existing Phase 2A refresh methods unchanged.
- Prediction churn rollback: restore the current `userPredictionLoadToken` and auto-realtime lifecycle behavior.
- Profile reuse rollback: bypass the cache/freshness reuse and call `SocialIdentityService().fetchUserProfileRows(forEmails:)` as the current code does.
- Card-state ownership rollback: restore direct fallback reads in `gameInterestRow` while keeping the `VenueGameCardState` type available for another phased attempt.

## Build Verification

Build command requested:

```sh
xcodebuild -project "GameOn.xcodeproj" -scheme "GameOn" -destination 'platform=iOS,name=iPhone 17 Pro Max JT' build
```

Result: passed.
