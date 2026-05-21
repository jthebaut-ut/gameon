# Venue Game Card Stability Audit

Date: 2026-05-21

Scope: report-only audit of the Discover venue game card and immediate venue preview container. No implementation changes were made for this audit.

## Executive Summary

The venue game card is fragile because it is not a standalone state consumer. It is a SwiftUI render function (`gameInterestRow(bar:event:)`) that synchronously derives UI from many unrelated `MapViewModel`, `FanUpdatesRealtimeStore`, `ChatViewModel`, prediction-service, map-selection, auth-gate, and local `@State` values. Small updates to any of those sources can re-render the full card subtree, restart child `.task` work, or change the event identity used by Going/avatar/prediction/Fan Chat.

The highest-risk issue is identity drift. The card renders from a `SportsEvent`, then resolves a `venueEventID` through `cachedVenueEventID(for:gameTitle:)` and `liveEnergy(for:event:)`. Going count, "I'm Going", avatar stack, vibes, Fan Chat, and predictions do not all read the same canonical snapshot. If the event ID is missing, stale, or resolves after the card rendered, the attendee row can show old avatars even when counts or optimistic state changed elsewhere.

Remote Going does not reliably refresh the circled attendee/avatar row because that row is primarily profile-driven. It uses `goingProfilesByVenueEventID` through `goingAvatarProfiles(...)` and `liveEnergy(...)`. The existing broad reconcile paths update Going membership/counts, but the avatar stack only changes when the per-event profile cache is refreshed.

## State Sources Read By The Card

Primary card composition lives in `DiscoverScreen.swift`:

- `venuePreviewCard(_:)` resolves `canonicalBarForDiscover`, `gamesForVenuePreview`, `selectedEventForVenue`, visible social prefetch events, `showVenueDetails`, `colorScheme`, `appLanguageRaw`, `canViewDiscoverDetails`, and `isGuestDiscoverMode`.
- `gamesListSection(bar:gamesToday:)` derives `stableEvents`, `stableItems`, `isLoadingEvents`, `isGuestDiscoverMode`, and renders either `guestVenueGamePreviewRow` or `gameInterestRow`.
- `gameInterestRow(bar:event:)` is the full venue game card. It reads `SportsEvent` title/date/sport, `cachedVenueEventID`, `userIsGoingToVenueGame`, `liveEnergy`, prediction visibility, Fan Chat/vibe counts, current user auth state, and local presentation state.

Going and attendee/avatar state:

- `venueEventID`: resolved by `MapViewModel.cachedVenueEventID(for:gameTitle:)` from `venueEventIDsByKey` or `venueEventRows`.
- "I'm Going": `userIsGoingToVenueGame(bar:gameTitle:venueEventID:)` reads `interestedVenueEventKeys`, `venueEventInterestIDs`, `followingTabUserVenueEventInterestIDs`, `venueEventInterestWriteInFlightIDs`, and recent confirmed-going/not-going guards.
- Count row: `gameInterestRow` computes `displayGoingCount = max(energy.goingCount, alreadyInterested ? 1 : 0, visibleAvatarCount)`.
- Avatar stack: `goingAvatarProfiles(for:fallbackProfiles:currentUserGoing:)` reads `goingProfilesByVenueEventID`, fallback `energy.socialPresenceProfiles`, and current user profile data.
- `liveEnergy(for:event:)` reads `goingProfiles(for:)`, `goingProfilesByVenueEventID`, `fanUpdatesDisplayCommentCount(for:)`, event timing, accepted friend IDs from `ChatViewModel.friendshipChipByOtherUserId`, and then derives `goingCount`, friend count, social presence profiles, and labels.

Predictions:

- `venuePredictionVisibility(...)` reads `VenueEventRow` fields (`id`, `sport`, `home_team`, `away_team`, scheduled start) plus `VenueEventPredictionTeams` support/lock rules.
- `VenueEventPredictionModule` reads `venueEventPredictionSummaries[predictionEventID]`, starts its own prediction realtime task through callbacks, and performs quick-save/clear operations through `VenueEventPredictionService`.

Fan Chat, vibes, and mini stats:

- `venueGameCardSocialActionRow(...)` reads `fanUpdatesDisplayCommentCount(for:)` and opens `fanUpdatesSheetEvent`.
- `venuePreviewInteractionStrip(...)` reads `fanUpdatesStore.venueEventVibeCounts[venueEventID]` and `fanUpdatesStore.myVenueEventVibes[venueEventID]`.
- `venuePreviewEnergy(for:energy:)`, `trendingScore(for:goingCount:)`, and `topVibeText(for:)` read `venueEventVibeCounts`, Fan Chat comment counts, and Going-derived energy.

Selected venue/event and overlay dependencies:

- `discoverBottomLeadingCard` renders the preview when `viewModel.selectedBar` is set.
- `selectedEventForVenue(gamesToday:)` reads `viewModel.selectedEvent`.
- `showVenueDetails`, `showVenueRatingSheet`, `fanUpdatesSheetEvent`, `predictionSheet`, `fanFeatureGateAlertMessage`, and `pendingResumeVenueIDAfterLogin` can all be changed by card buttons or surrounding overlays.
- Map overlay state can clear or replace the selected venue via `pruneSelectionIfNeededAfterFilterChange`, map display mode changes, focus venue navigation, search, date changes, and auth gate changes.
- Ad/overlay state (`discoverTopAdLoadFailed`, fixed top/bottom overlays, date picker overlay) lives in the same `DiscoverScreen` body and contributes to whole-screen invalidation even though it is not a card-specific state.

## Async, Realtime, And Task Paths

Attached to or near the venue preview/card:

- `venuePreviewCard(_:)` has `.task(id: visibleSocialPrefetchKey)` that prefetches venue images and calls `prefetchVisibleVenueSocialData(...)`.
- `prefetchVisibleVenueSocialData(...)` resolves venue event IDs by calling `venueEventID(for:gameTitle:on:)`, then calls `prefetchVisibleDiscoverSocialData(eventIDs:predictionEventIDs:)`.
- `prefetchVisibleDiscoverSocialData(...)` coalesces by batch key and concurrently runs Fan Chat preview prefetch, Going profile prefetch, and prediction summary prefetch.
- `prefetchFanUpdatesPreviewBatchForVisibleEvents(...)` calls `loadFanUpdatesPreviewBatch` and `loadVibesBatch`.
- `prefetchGoingProfilesForVisibleEventBatchIfNeeded(...)` reads `venue_event_interests`, fetches profiles by email, then updates `goingProfilesByVenueEventID`.
- `prefetchVenuePredictionSummariesForVisibleBatch(...)` updates `venueEventPredictionSummaries`.

Child prediction module paths:

- `VenueEventPredictionModule.body` runs `.task(id: userPredictionLoadToken)` to load the user's prediction.
- It also runs `.task(id: venueEventID)` to start prediction realtime through `onStartRealtime`.
- Its `.onDisappear` stops prediction realtime.
- Quick vote/score callbacks call Supabase service methods and then refresh aggregate summaries.

Current ViewModel-owned realtime paths that feed the card:

- Fan Chat/vibes app-level realtime is scheduled from `venueEventRows.didSet` through `scheduleFanChatAppLevelRealtimeForLoadedVenueEvents`.
- Prediction realtime is started/stopped by `VenueEventPredictionModule`, not by a standalone card store.
- Going realtime currently has ViewModel-owned properties and subscription methods in `MapViewModel+VenueEventSocial.swift`; the risk is that its input is still derived from broad `selectedBar`, `selectedDate`, `selectedSport`, and `venueEventRows` rather than a dedicated card state object.

Screen-wide async/on-change paths that can invalidate card state:

- `DiscoverScreen.discoverScreenCore` has root `.task`, `.onAppear`, and many `.onChange` handlers for scene phase, selected date, search text, map display mode, content mode, following navigation, focus venue, and auth gate.
- Map and search operations set or clear `selectedBar`, `selectedEvent`, `discoverRemotePreviewHoldVenueId`, `showVenueDetails`, and related presentation state.

## State Mutation During Or Near Rendering

No direct database writes were found inside `gameInterestRow` body itself. The fragility comes from several "near render" patterns:

- Debug `let _ = print(...)` statements are embedded inside `selectedEventSection`, `gamesListSection`, and `gameInterestRow`. These do not mutate app state, but they are side effects during SwiftUI evaluation and make render frequency look like behavior.
- `gameInterestRow` computes multiple derived values by calling ViewModel functions from the body (`cachedVenueEventID`, `userIsGoingToVenueGame`, `liveEnergy`, `goingAvatarProfiles`, prediction visibility, comment/vibe helpers). These are currently expected to be read-only, but the body has no compile-time guard preventing a future helper from mutating state.
- `.onAppear` blocks on the card and prediction inset print debug logs. Previous attempts proved that adding subscription mutations in this area is unsafe.
- `venuePreviewCard(_:)` has a `.task(id:)` attached to the preview container. It is not a row task, but it still couples preview rendering identity to network/data prefetch.
- `VenueEventPredictionModule` starts/stops realtime from the child SwiftUI view lifecycle. This is functional today but is the same architectural class of risk as the Going realtime attempts: a render-owned component starts a subscription.
- Buttons mutate state close to the card: Going toggles optimistic state and writes Supabase; Fan Chat opens sheets; predictions mutate local prediction state and remote prediction rows; Details/auth gates mutate sheet state and auth presentation.

## Why Remote Going Does Not Refresh The Circled Attendee/Avatar Row

The attendee row is not driven directly by `venueEventInterestCounts`. It is primarily driven by `goingProfilesByVenueEventID`.

Flow in `gameInterestRow`:

- `liveEnergy(for:event:)` calls `goingProfiles(for:)`.
- `energy.goingCount` is based on profile count when an event ID exists.
- `goingAvatarProfiles(...)` uses `goingProfilesByVenueEventID[venueEventID]`; if empty, it falls back to `energy.socialPresenceProfiles`, which is also derived from profiles.
- The row then takes `max(energy.goingCount, alreadyInterested ? 1 : 0, visibleAvatarCount)`.

Therefore a remote Going write can update Supabase without changing the visible attendee row unless the profile cache for that event is refreshed. Existing reconciles are not card-specific:

- `scheduleDeferredFollowingTabGoingReconcile(...)` waits about 2 seconds and calls `refreshFollowingTabDataGlobally()`, which is broad Following tab state, not the venue card avatar cache.
- `scheduleDeferredVisibleVenueEventInterestsReload()` calls `loadVisibleVenueEventInterests(...)`, which updates `venueEventInterestCounts` and `venueEventInterestIDs`, but not the avatar profile cache.
- `prefetchGoingProfilesForVisibleEventBatchIfNeeded(...)` refreshes avatars, but it is gated by freshness TTL and is triggered from the preview prefetch `.task`, not by a remote Going event.

The card can therefore show stale avatars even when a count or membership reconcile happened elsewhere.

## Why The Card Is Fragile

1. It has too many owners. Discover UI, `MapViewModel`, `FanUpdatesRealtimeStore`, `ChatViewModel`, prediction service, and local `@State` all feed one card.
2. Event identity is resolved repeatedly from title/bar/date caches instead of passed as the single card input.
3. Counts and avatars are separate stores and can become inconsistent.
4. Realtime ownership is inconsistent: Fan Chat app-level realtime is ViewModel-owned, predictions are child-view-owned, and Going has been attempted both render-owned and ViewModel-owned.
5. Root Discover overlays and map state can invalidate the preview/card even when the game card data did not change.
6. Render-time helper calls make it easy to accidentally introduce a mutation in the future.
7. The card is visually nested under `GeometryReader`, map overlays, bottom overlay presentation, date picker overlay, and material backgrounds, increasing redraw cost and making lifecycle timing harder to reason about.

## Safer Architecture

Introduce a `VenueGameCardStore` or `VenueGameCardViewModel` owned by `MapViewModel` or a small service coordinator, not by `DiscoverScreen` body.

Recommended shape:

- Single input: `venueEventID`.
- Stable published state per event:
  - `eventTitle`, `dateText`, `sport`
  - `isCurrentUserGoing`
  - `goingCount`
  - `goingProfiles`
  - `commentCount`
  - `vibeCounts`
  - `predictionSummary`
  - `predictionVisibility`
  - `isLoading` / `lastUpdated`
- Services/realtime update the store outside SwiftUI body:
  - Going interest service updates count + profiles together.
  - Fan Chat/vibe service updates comment/vibe state.
  - Prediction service updates prediction state.
- `DiscoverScreen` only renders `VenueGameCardState` and sends user intents:
  - `toggleGoing(venueEventID)`
  - `openFanChat(venueEventID)`
  - `quickVote(venueEventID, value)`
  - `openPrediction(venueEventID)`
- Realtime subscriptions should be started by a coordinator with explicit lifecycle:
  - active selected preview IDs changed
  - authenticated fan session changed
  - app foreground/background changed
  - preview dismissed
- No realtime starts/stops from `ForEach`, row `.onAppear`, `GeometryReader`, overlay builders, or computed view properties.

This would make the card a passive reader of a small immutable-ish snapshot instead of a live integration point for every feature.

## Smallest Safe Next Implementation Step

Do not add more realtime wiring first. The smallest safe step is to create a read-only `VenueGameCardState` builder for one `venueEventID` and route one card through it without changing behavior.

Concrete next step:

1. Add a `VenueGameCardState` struct.
2. Add a pure `MapViewModel.venueGameCardState(venueEventID:bar:event:) -> VenueGameCardState` builder that only gathers existing state.
3. Replace direct card reads with this state object in `gameInterestRow`.
4. Do not start subscriptions, do not change Supabase writes, and do not change UI.

After that compiles and behavior is unchanged, the next safe phase would be a `VenueGameCardStore` that owns a single-event refresh method for count + avatars together.

## Build Verification

Required build:

`xcodebuild -project "GameOn.xcodeproj" -scheme "GameOn" -destination 'platform=iOS,name=iPhone 17 Pro Max JT' build`

Result: passed on physical iPhone target.
