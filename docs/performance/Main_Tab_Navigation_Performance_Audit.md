# Main Tab Navigation Performance Audit

Date: May 21, 2026  
Scope: `MainTabView`, Account/Profile tab loading, Going/Following tab loading, shared `MapViewModel` invalidation, and Chat/badge listeners that can affect tab switches.  
Mode: Report only. No app behavior or UI changes were made.

## Executive Summary

Main tab navigation is already using a lazy sticky mount pattern: tabs mount on first selection and then stay in the hierarchy with `opacity(0)` and hit testing disabled. That preserves state, but it also means every mounted tab still observes the same large `MapViewModel` and can re-evaluate when unrelated `@Published` fields change.

The slowest path is Profile ↔ Going because each side can trigger real network work when selected. Account activates `ProfileIdentityCard` tasks for Pokes and Suggested Fans, while Going activates global Following refreshes plus pickup join-request loads. These loads publish several broad `MapViewModel` fields, so the currently visible tab and already-mounted offscreen tabs can redraw together.

No P0 crash issue was found. The safest next fixes are to avoid reloads on ordinary tab reselects, isolate Going/Profile state into narrower stores, and gate noisy DEBUG logging during tab switches.

## What Runs On Tab Switch

`MainTabView` stores selected tab in `@SceneStorage("selectedMainTab")`. Selecting a tab calls `selectTab(_:animated:reason:)`, which inserts the tab into `mountedTabs` and updates `selectedTabStorage`.

`MainTabView.tabShellWithLifecycleModifiers` reacts to `selectedTabStorage` changes by:
- Updating `AdDebugContext.setVisibleTab`.
- Calling `mountTab`.
- Setting `viewModel.isCalendarTabSelected`.
- Starting Chat realtime or badge recalculation only when Chat is selected.
- Calling `viewModel.noteCalendarTabBecameActive()` only when Calendar is selected.

The Going tab receives `isFollowingTabSelected: selectedTab == .following`. The Account tab receives `isAccountTabSelected: selectedTab == .account`. These booleans are the main switch that starts/stops Profile and Going work.

## Offscreen Preservation

Files/functions:
- `GameOn/MainTabView.swift`
  - `lazyPreservedRoot(tab:content:)`
  - `preservedRoot(tab:content:)`
  - `mountedTabs`

Tabs are not built until first selection. Once mounted, inactive tabs stay in the `ZStack`:

```swift
content()
    .opacity(isSelected ? 1 : 0)
    .allowsHitTesting(isSelected)
    .accessibilityHidden(!isSelected)
```

This preserves view state, but it does not stop view body evaluation when shared observed objects publish. Because Discover, Live, Calendar, Going, Chat, and Account roots all receive shared `MapViewModel` and/or `ChatViewModel`, a publish from a hidden tab can still cause visible and hidden roots to re-evaluate.

## P0 Issues

### None found

No tab-switch crash path was found. The main risks are latency and redraw churn, not immediate data loss or crash behavior.

## P1 Issues

### P1-1: Going tab selection triggers multi-query refreshes and broad publishes

Files/functions:
- `GameOn/FollowingScreen.swift`
  - `body`
  - `.task(id: followingTabTaskIdentity)`
  - `.onAppear`
  - `.onChange(of: scenePhase)`
  - `syncFollowingAfterAuthChange()`
- `GameOn/MapViewModel+FollowingTab.swift`
  - `refreshFollowingTabDataGloballyUnlessFresh()`
  - `refreshFollowingTabDataGlobally()`
- `GameOn/MapViewModel+PickupGameRequests.swift`
  - `loadMyPickupGameJoinRequestsForFollowing()`
- `GameOn/MapViewModel+PickupGames.swift`
  - `loadMyPickupGamesForSettings()`

What runs:
- On Going selection, `followingTabTaskIdentity` becomes the signed-in user id, causing a `.task` that runs:
  - `refreshFollowingTabDataGloballyUnlessFresh()`
  - `loadMyPickupGameJoinRequestsForFollowing()`
- `refreshFollowingTabDataGlobally()` loads favorite venues, venue-event interests, venue event rows in chunks, aggregate interest counts, resolves venue rows, host pickup games, and creator trust stats.
- `loadMyPickupGameJoinRequestsForFollowing()` loads pickup join requests, pickup games, creator profiles, creator ratings, user ratings, and syncs the pickup Following realtime subscription.

Impact:
- The first Going selection is legitimately heavy.
- Returning to Going can still reload pickup join requests even when the global Following refresh is skipped as fresh.
- These calls publish `followingTabSavedVenues`, `followingTabGoingItems`, `followingTabGoingInterestCounts`, `followingTabUserVenueEventInterestIDs`, `myPickupGameJoinRequestCards`, `pickupJoinRequestLatestByPickupGameIdForFan`, pickup activity fields, and organizer-related pickup fields.
- Since `MainTabView`, `SettingsScreen`, `DiscoverScreen`, and `FollowingScreen` observe the same `MapViewModel`, these Going-only publishes can redraw unrelated mounted tabs.

Smallest safe fixes:
- Add a short freshness gate for `loadMyPickupGameJoinRequestsForFollowing()` similar to `lastFollowingTabGlobalRefreshAt`.
- Split Going tab display state into a smaller `FollowingTabStore` observed only by `FollowingScreen` and the Going badge.
- Keep `refreshFollowingTabDataGlobally()` behavior and Supabase queries unchanged at first; only change when they run and who observes the results.

### P1-2: Account/Profile selection triggers Pokes and Suggested Fans loads

Files/functions:
- `GameOn/SettingsScreen.swift`
  - `body`
  - `.onAppear` on the main `List`
  - `ProfileIdentityCard(viewModel:isAccountTabActive:)`
- `GameOn/ProfileIdentityCard.swift`
  - `.task(id: profilePersonalizationLoadToken)`
  - `.task(id: pokesLiveRefreshLoopToken)`
  - `refreshIncomingPokesLive(reason:)`
  - `loadIncomingPokes(ignoreCache:)`
  - `loadSuggestedFans(ignoreCache:)`
- `GameOn/FriendSuggestionsService.swift`
  - `fetchSuggestions(limit:radiusMiles:centerLat:centerLng:)`

What runs:
- When Account becomes active, `ProfileIdentityCard` changes `profilePersonalizationLoadToken` to `active=true`.
- That task calls `refreshIncomingPokesLive(reason: "accountVisible")` and `loadSuggestedFans()`.
- `refreshIncomingPokesLive` calls `loadIncomingPokes(ignoreCache: true)`, so it bypasses the cache every Account activation.
- `loadSuggestedFans` has a 10-minute cache gate, but after the mutual-fans upgrade the RPC does more relationship work and returns avatar payloads.
- `SettingsScreen` main `.onAppear` also loads pickup creator pending count and `loadMyPickupGamesForSettings()` when fan pickup UI is enabled.

Impact:
- Profile re-entry can perform network work even when the user is only switching tabs.
- Pokes always refresh on Account activation because `ignoreCache` is true.
- Suggested Fans is cached, but when it does run it can be expensive and its DEBUG logs now print per suggestion.
- Account `ProfileIdentityCard.reputation` reads `followingTabGoingItems`, `myPickupGamesForSettings`, `myPickupGameJoinRequestCards`, and `fanUpdatesStore` aggregate dictionaries, so unrelated Going/Fan Updates publishes can re-evaluate Profile reputation and cards.

Smallest safe fixes:
- Make Account activation use cache-aware Pokes loading unless the user pulls to refresh or opens Pokes history.
- Defer Suggested Fans until after the first Account frame, or load it only when its section scrolls near visibility.
- Move Suggested Fans and Pokes state into a profile personalization store so their publishes do not redraw the whole account tab.

### P1-3: Shared `MapViewModel` publishes redraw every mounted tab

Files/functions:
- `GameOn/MainTabView.swift`
  - `@ObservedObject var viewModel: MapViewModel`
  - `lazyPreservedRoot(tab:content:)`
  - `preservedRoot(tab:content:)`
- `GameOn/MapViewModel.swift`
  - broad `@Published` state for Discover, Account, Going, pickup, venue owner, profile, and social state

Heavy published fields involved in tab switching:
- Following/Going: `followingTabSavedVenues`, `followingTabGoingItems`, `followingTabGoingInterestCounts`, `followingTabUserVenueEventInterestIDs`, `myPickupGameJoinRequestCards`, `pickupJoinRequestLatestByPickupGameIdForFan`, `hasUnreadPickupActivity`, `pickupActivityCount`, `isPickupFollowingJoinListRefreshing`.
- Account/Profile: `hasUnseenPokes`, `currentUserFanXP`, `currentUserFanIdentityPreferences`, `currentUserHomeCrowdVenue`, profile identity fields, pickup creator fields.
- Discover/map: `bars`, `venueEventRows`, `venueEventInterestCounts`, `pickupGamesForDiscoverMap`, `discoverMapRenderSnapshot`.

Impact:
- Offscreen preservation avoids rebuild-from-scratch, but every mounted root still receives invalidation from the same object.
- Going refreshes can redraw Profile; Profile Pokes/Suggested Fans can redraw Discover/Going wrappers; pickup badge updates can redraw the floating tab bar and every mounted root.

Smallest safe fixes:
- Split hot tab-owned data into narrower observable stores: `FollowingTabStore`, `ProfilePersonalizationStore`, and possibly `PickupActivityBadgeStore`.
- Keep `MapViewModel` as the orchestrator initially, but publish tab-local result arrays from those smaller stores.
- Convert read-only tab badges to observe a lightweight badge state instead of full `MapViewModel`.

### P1-4: Settings account root does pickup work unrelated to visible Profile content

Files/functions:
- `GameOn/SettingsScreen.swift`
  - main `.onAppear`
  - `loadPendingPickupGameJoinRequestCountForCreator(resyncRealtimeSubscription:)`
  - `loadMyPickupGamesForSettings()`
- `GameOn/MapViewModel+PickupGames.swift`
  - `loadMyPickupGamesForSettings()`
- `GameOn/MapViewModel+PickupGameRequests.swift`
  - `loadPendingPickupGameJoinRequestCountForCreator(resyncRealtimeSubscription:)`

What runs:
- On first Account mount, the Settings root starts pending pickup badge count loading and hosted pickup games loading.
- `loadMyPickupGamesForSettings()` then loads organizer summaries, withdrawn requests, approved joiners, and pending count/realtime.

Impact:
- Switching to Profile can pay for organizer pickup data even if the user is not looking at pickup management.
- Some of these publishes also affect the Going tab and account reputation.

Smallest safe fixes:
- Defer `loadMyPickupGamesForSettings()` until the pickup management section is visible or the user opens the related sheet.
- Keep the lightweight pending count for the badge if needed, but do not load all organizer request summaries on ordinary Account entry.

## P2 Issues

### P2-1: Chat/badge listeners can add small but visible tab-switch work

Files/functions:
- `GameOn/MainTabView.swift`
  - `updateDirectChatReadStateVisibility()`
  - `.onChange(of: selectedTabStorage)`
  - `runPokesBadgeRefreshLoop()`
  - `startChatSocialRealtimeIfNeeded(reason:)`
- `GameOn/ChatViewModel.swift`
  - `setDirectChatReadStateVisibility(chatTabVisible:privateChatUnlocked:)`
  - `requestBadgeRecalculation(reason:includeInboxSummaries:)`
  - `loadIfNeeded()`
  - `refreshInboxSummaries()`
  - `ensureSignedInSocialRealtimeIfNeeded()`

What runs:
- Every selected-tab change updates direct-chat read-state visibility.
- Selecting Chat starts social realtime if needed and schedules badge recalculation with inbox summaries.
- The Pokes badge loop runs from `MainTabView` while profile pokes are enabled, independent of Account visibility.

Impact:
- This is probably not the main Profile ↔ Going slowdown, but it contributes to broad root invalidation and DEBUG output.
- Chat badge recalculation is correctly scoped to Chat selection, but `unreadDirectMessageCount` changes still re-render the floating tab bar.

Smallest safe fixes:
- Keep Chat realtime lifecycle unchanged.
- Ensure badge recalculation is not requested on non-Chat tab switches.
- Gate high-frequency badge DEBUG logs behind a diagnostics flag.

### P2-2: Discover map/ad context still updates during unrelated tab switches

Files/functions:
- `GameOn/MainTabView.swift`
  - `.onChange(of: selectedTabStorage)`
  - `AdDebugContext.setVisibleTab(_:)`
  - `AdDebugDiagnostics.logEvent(event: "lazyTabMountState", ...)`
- `GameOn/AdaptiveBannerView.swift`
  - `.onAppear`
- `GameOn/CompactNativeAdCard.swift`
  - `.onAppear`
  - `CompactNativeAdRepresentable.makeUIView/updateUIView`

What runs:
- Every tab switch updates ad debug visible-tab context and logs lazy mount state.
- Ad views in mounted tabs remain in the hierarchy. They should not request new ads solely because a tab becomes hidden, but first mount or body updates can still produce diagnostics and UIView updates.

Impact:
- Ad work is likely secondary for Profile ↔ Going, but ad diagnostics are noisy enough to hide the true tab switch cost.

Smallest safe fixes:
- Keep visible-tab context updates.
- Gate nonessential ad diagnostics during tab switching.
- Avoid loading or refreshing ad views for offscreen-preserved tabs unless the tab is selected.

### P2-3: Excessive DEBUG logs during tab switches

Files/functions:
- `GameOn/MainTabView.swift`
  - `[PerfLazyTab]`, `[LiveTabDebug]`, `[NavigationDebug]`, `[BadgeArchitectureDebug]`, `[ChatTabBadge]`, `[PokesBadgeUI]`
- `GameOn/ProfileIdentityCard.swift`
  - `[ProfileIdentityCardDebug]`, `[ProfileBioDebug]`, `[ProfileHierarchyDebug]`, `[PokeUIFlowDebug]`, `[SuggestedFansUI]`, `[FriendSuggestionsDebug]`, `[FavoriteTeamsDebug]`, `[ProfileStatsDebug]`
- `GameOn/FollowingScreen.swift`
  - `logGoingHubDebug(reason:)`
- `GameOn/MapViewModel+FollowingTab.swift`
  - `[FollowingRegression]`, `[FollowingState]`
- `GameOn/MapViewModel+PickupGameRequests.swift`
  - `[GamesToPlayDebug]`, `[PickupFollowingActivity]`, `[PickupJoinRefresh]`
- `GameOn/MapViewModel+PickupGames.swift`
  - `[PickupPerf]`, `[DiscoverPickupDiag]`

Impact:
- DEBUG logging is not release behavior, but most manual performance testing happens in DEBUG builds.
- Render-path logs in Profile/Going make tab switching feel worse and make Instruments/Console harder to read.

Smallest safe fixes:
- Add a `MainTabNavigationDiagnostics.enabled = false` gate for tab-switch logs.
- Preserve true error logs and manual action logs.
- Remove per-row/per-card logs from Profile and Following render paths.

## What Not To Touch

- Do not change tab UI, tab order, or offscreen state preservation yet.
- Do not change Going write behavior, pickup join/withdraw behavior, or realtime subscriptions as part of navigation cleanup.
- Do not change Suggested Fans ranking/RPC semantics while optimizing when it loads.
- Do not change Discover map loading, venue loading, or ad serving behavior while addressing Profile ↔ Going slowness.
- Do not remove Chat realtime or unread badge behavior; only gate when it is started or recalculated.

## Recommended Fix Order

1. Add freshness gates for Going pickup join-card refresh and Account Pokes activation refresh.
2. Gate DEBUG logs for tab switching, Profile render paths, and Going refresh diagnostics.
3. Move Suggested Fans/Pokes into a `ProfilePersonalizationStore` observed only by Profile sections.
4. Move Following/Going arrays and pickup activity state into a `FollowingTabStore` observed by `FollowingScreen` and the tab badge.
5. Defer Account pickup organizer loading until the pickup-management section or sheet is visible.
6. Review offscreen ad rendering after the above changes, using Instruments to verify whether ad views still update while hidden.

## Rollback Plan

- Freshness gates rollback: restore current unconditional Account Pokes refresh and Going pickup join-card refresh.
- Diagnostics gating rollback: flip `MainTabNavigationDiagnostics.enabled` to `true` or restore the removed logs.
- Store isolation rollback: move tab-local published properties back to `MapViewModel` while keeping existing network methods unchanged.
- Deferred Account pickup loading rollback: call `loadMyPickupGamesForSettings()` from `SettingsScreen.onAppear` again.
- Ad gating rollback: restore current ad diagnostics and offscreen behavior.

## Build Verification

Build command requested:

```sh
xcodebuild -project "GameOn.xcodeproj" -scheme "GameOn" -destination 'platform=iOS,name=iPhone 17 Pro Max JT' build
```

Result: passed on physical iPhone destination `iPhone 17 Pro Max JT`.
