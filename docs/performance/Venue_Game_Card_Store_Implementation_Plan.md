# Venue Game Card Store Implementation Plan

Date: 2026-05-21

Scope: report-only implementation plan. Do not change app behavior in this step.

## Goal

Make the Discover venue game card a stable renderer instead of a live integration point for Going, avatars, predictions, Fan Chat, mini stats, live energy, auth gates, and map selection state.

The target architecture is a `VenueGameCardStore` or `VenueGameCardViewModel` that owns one event-scoped state snapshot. `DiscoverScreen` should render that snapshot and send user intents only. It should not start realtime subscriptions, run row tasks, mutate subscription state, or derive card state from broad global objects during body evaluation.

## One Card Input

Each card should be keyed by one stable identity:

```swift
struct VenueGameCardInput: Equatable, Hashable {
    let venueEventID: UUID
    let barID: UUID
    let title: String
    let date: Date
    let sport: String
    let homeTeam: String?
    let awayTeam: String?
    let scheduledStartAt: Date?
}
```

The input should be built outside the row render path from already-loaded `VenueEventRow` / `SportsEvent` data. Once the card has a `venueEventID`, all downstream reads should use that ID instead of re-resolving by venue name + title inside `gameInterestRow`.

## Stable Output Model

Add a single value model that the card can render without reaching into multiple global stores:

```swift
struct VenueGameCardState: Equatable {
    let input: VenueGameCardInput
    let isCurrentUserGoing: Bool
    let goingCount: Int
    let goingAvatarProfiles: [UserProfileRow]
    let predictionSummary: VenueEventPredictionSummary?
    let fanChatCount: Int
    let miniStats: VenueGameCardMiniStats
    let liveEnergy: FanGeoLiveEnergy
    let isLoading: Bool
    let reconcileStatus: VenueGameCardReconcileStatus
    let lastGoingUpdatedAt: Date?
    let lastAvatarUpdatedAt: Date?
    let lastFanChatUpdatedAt: Date?
    let lastMiniStatsUpdatedAt: Date?
    let lastPredictionUpdatedAt: Date?
}
```

Suggested supporting models:

```swift
struct VenueGameCardMiniStats: Equatable {
    let vibeCounts: [String: Int]
    let selectedVibes: Set<String>
    let topVibeText: String?
    let trendingScore: Int
}

enum VenueGameCardReconcileStatus: Equatable {
    case idle
    case optimistic
    case reconciling
    case failed(String)
}
```

The card should render `VenueGameCardState` only. It should not directly read `venueEventInterestCounts`, `venueEventInterestIDs`, `goingProfilesByVenueEventID`, `venueEventPredictionSummaries`, `FanUpdatesRealtimeStore`, `ChatViewModel`, or map snapshot state.

## Store Responsibilities

Create the store as ViewModel/service-owned, not SwiftUI-row-owned.

Candidate files:

- New file: `GameOn/VenueGameCardStore.swift`
- Optional model file: `GameOn/VenueGameCardState.swift`
- Integration surface: `GameOn/MapViewModel+VenueGameCardStore.swift`

The store should:

- Maintain `[UUID: VenueGameCardState]` keyed by `venueEventID`.
- Accept stable inputs from selected venue/event resolution.
- Reconcile one event at a time.
- Subscribe or reconcile Going outside `DiscoverScreen`.
- Merge optimistic local Going writes with server rows.
- Refresh avatar stack on remote Going changes.
- Read prediction summaries from the existing prediction system.
- Read Fan Chat counts from existing `FanUpdatesRealtimeStore`.
- Read mini stats/vibes from existing `FanUpdatesRealtimeStore`.
- Publish one stable per-event state for the card.

The store should not:

- Reload all venues.
- Reload the map.
- Refresh the full Following tab for venue card state.
- Start or stop subscriptions from SwiftUI body, `ForEach`, row `.task`, row `.onAppear`, overlays, `GeometryReader`, or `PreferenceKey`.
- Own prediction writes, Fan Chat writes, or vibe writes in Phase 1.

## DiscoverScreen Responsibility

`DiscoverScreen` should become a renderer and intent sender.

Allowed responsibilities:

- Build or receive stable `VenueGameCardInput`.
- Read `VenueGameCardState` for the visible event.
- Render the card.
- Forward button actions:
  - `toggleGoing(venueEventID)`
  - `openFanChat(venueEventID)`
  - `toggleVibe(venueEventID, vibeType)`
  - `quickVote(venueEventID, prediction)`
  - `openDetails(barID)`

Not allowed:

- No realtime subscription start/stop.
- No async data-fetch tasks in game rows.
- No row lifecycle mutation.
- No `GeometryReader` / `PreferenceKey` for state collection.
- No direct reads from broad global state inside `gameInterestRow` once migrated.

## Migration Strategy

### Phase 1: Read-Only Store Mirror

Goal: no behavior change.

Add `VenueGameCardState` and a read-only builder that mirrors existing state. Keep all existing data sources in place, but centralize reads behind one function.

Files/functions to change:

- Add `GameOn/VenueGameCardState.swift`.
- Add `GameOn/MapViewModel+VenueGameCardStore.swift`.
- Add a pure builder:
  - `MapViewModel.venueGameCardState(input: VenueGameCardInput, friendUserIDs: Set<UUID>) -> VenueGameCardState`
- In `DiscoverScreen.gameInterestRow(bar:event:)`, replace direct reads with a single state read only after the builder exists and is verified.

What not to touch:

- Do not change Supabase queries.
- Do not change Going writes.
- Do not change realtime.
- Do not change prediction lifecycle.
- Do not change Fan Chat/vibe logic.
- Do not add row `.task` or `.onAppear`.

Exit criteria:

- UI behavior unchanged.
- Physical iPhone build passes.
- Card logs/state match previous behavior.

### Phase 2: Move Going Count + Avatar State Into Store

Goal: make Going count and avatar stack coherent per event.

Store responsibilities added:

- `refreshGoing(venueEventID:)`
- `applyOptimisticGoing(venueEventID:isGoing:)`
- `reconcileGoing(venueEventID:)`
- `handleRemoteGoingChange(venueEventID:)`

Data updated together:

- `isCurrentUserGoing`
- `goingCount`
- `goingAvatarProfiles`
- `lastGoingUpdatedAt`
- `lastAvatarUpdatedAt`
- `reconcileStatus`

Files/functions to change:

- `MapViewModel+VenueEventSocial.swift`
  - Keep write methods, but have successful optimistic/reconcile paths notify the card store.
  - Prefer single-event refresh over `loadVisibleVenueEventInterests(...)` for card state.
- `VenueGameCardStore.swift`
  - Add single-event Going refresh that reads `venue_event_interests`, resolves profiles, and publishes one state update.
- `MapViewModel+AuthAndProfile.swift`
  - Clear store state on session clear.

What not to touch:

- Do not route this through `DiscoverScreen`.
- Do not call `refreshFollowingTabDataGlobally()` for card Going state.
- Do not reload map/venues.

### Phase 3: Move Fan Chat And Mini Stat Reads Into Store

Goal: stop `gameInterestRow` from reading `FanUpdatesRealtimeStore` directly.

Store responsibilities added:

- Mirror `fanChatCount` from `fanUpdatesDisplayCommentCount(for:)`.
- Mirror `vibeCounts` and selected vibes from `FanUpdatesRealtimeStore`.
- Derive `topVibeText`, `trendingScore`, and mini stat chip state once.

Files/functions to change:

- `MapViewModel+CommentsAndVibes.swift`
  - After comment/vibe refreshes, notify card store for affected `venueEventID`.
- `FanUpdatesRealtimeStore.swift`
  - No structural change required in Phase 3; the card store can consume existing values through `MapViewModel`.
- `DiscoverScreen.swift`
  - Card should render `state.fanChatCount` and `state.miniStats`, not direct store reads.

What not to touch:

- Do not move Fan Chat sheet logic.
- Do not change `VenueEventCommentsView`.
- Do not change crowd reaction write behavior.

### Phase 4: Optional Prediction Summary Proxy

Goal: make prediction rendering read from the same card state while keeping existing prediction service ownership.

Store responsibilities added:

- Mirror `predictionSummary` from `venueEventPredictionSummaries[venueEventID]`.
- Mirror prediction visibility from stable metadata.
- Optionally publish card state when prediction summary changes.

Files/functions to change:

- `MapViewModel+VenueEventPredictions.swift`
  - After `venueEventPredictionSummaries[eventID] = summary`, notify card store.
- `DiscoverScreen.swift`
  - Pass `state.predictionSummary` to `VenueEventPredictionModule`.

What not to touch:

- Do not rewrite `VenueEventPredictionService`.
- Do not change prediction DB writes.
- Do not change prediction realtime until a separate lifecycle audit is done.

## Exact Files And Functions

Add:

- `GameOn/VenueGameCardState.swift`
- `GameOn/VenueGameCardStore.swift`
- `GameOn/MapViewModel+VenueGameCardStore.swift`

Eventually adjust:

- `GameOn/DiscoverScreen.swift`
  - `gameInterestRow(bar:event:)`
  - `venueGameCardSocialActionRow(...)`
  - `venuePreviewInteractionStrip(venueEventID:)`
  - `venuePredictionVisibility(...)` only after Phase 1 state is stable.
- `GameOn/MapViewModel+VenueEventSocial.swift`
  - `toggleVenueGameGoingFromUI(...)`
  - `setVenueEventInterest(...)`
  - `loadVisibleVenueEventInterests(...)`
  - `loadGoingUserProfiles(for:)`
  - `prefetchGoingProfilesForVisibleEventBatchIfNeeded(eventIDs:)`
- `GameOn/MapViewModel+CommentsAndVibes.swift`
  - `updateVenueEventCommentPreviewCount(...)`
  - `loadFanUpdatesPreviewBatch(for:)`
  - `loadVibes(for:)`
  - `loadVibesBatch(for:)`
  - `toggleVibe(for:vibeType:)`
- `GameOn/MapViewModel+VenueEventPredictions.swift`
  - `loadVenueEventPredictionSummaries(eventIDs:forceRefresh:)`
  - `refreshVenueEventPredictionSummary(eventID:)`
- `GameOn/MapViewModel+AuthAndProfile.swift`
  - `clearAuthenticatedSessionCaches()`

Do not touch for this migration unless separately scoped:

- `LaunchScreen.storyboard`
- map loading/reload logic
- DM/chat inbox realtime
- full Following tab refresh behavior
- backend schema/RLS
- `VenueEventCommentsView` realtime lifecycle
- prediction service internals
- row-level SwiftUI lifecycle in `DiscoverScreen`

## Risk Controls

Feature flag:

- Add a local flag such as `VenueGameCardStoreFeature.isEnabled`.
- Phase 1 can compute store state while rendering old state.
- Later phases can switch one section at a time: Going row first, then Fan Chat/mini stats, then prediction summary.

Build/test gate:

- Run physical iPhone build after every phase:
  - `xcodebuild -project "GameOn.xcodeproj" -scheme "GameOn" -destination 'platform=iOS,name=iPhone 17 Pro Max JT' build`
- Manual smoke after each phase:
  - Open Discover venue preview.
  - Scroll multi-game venue card.
  - Tap Going.
  - Open Fan Chat.
  - Toggle a mini stat/vibe.
  - Render predictions if present.
  - Switch date/sport.
  - Close/reopen preview.

Rollback plan:

- Keep old direct-render reads behind the feature flag until the store is proven.
- Each phase should be reversible by disabling the flag and removing only the phase-specific store notifications.
- Avoid migrations that delete existing state until after store parity is proven.

Hard safety rules:

- No `DiscoverScreen` row `.task`.
- No `DiscoverScreen` row `.onAppear` / `.onDisappear` subscription mutation.
- No `GeometryReader` or `PreferenceKey` for visible event tracking.
- No realtime start/stop from SwiftUI body or overlay builders.
- No broad reloads (`loadVenuesFromSupabase`, map reload, full Following tab refresh) for one card event update.

## Recommended Smallest Next Step

Implement Phase 1 only:

1. Add `VenueGameCardState`.
2. Add a pure read-only state builder in `MapViewModel`.
3. Log parity between old direct card reads and new state for one event.
4. Do not switch UI rendering yet unless parity is confirmed.
5. Run physical iPhone build and manual open/close preview smoke.

This gives the app a stable seam for later fixes without adding more realtime or lifecycle risk.

## Build Verification

Required build:

`xcodebuild -project "GameOn.xcodeproj" -scheme "GameOn" -destination 'platform=iOS,name=iPhone 17 Pro Max JT' build`

Result: passed on physical iPhone target.
