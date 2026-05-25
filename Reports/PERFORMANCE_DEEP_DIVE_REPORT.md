# FanGeo Performance Deep Dive Report

Date: May 20, 2026

Scope: Static analysis of the FanGeo iOS Swift app, focused on Discover/map, venue cards, pickup games, calendar, fan chats, private DMs, badges, profile/account/business dashboard, images, Supabase/network access, SwiftUI recomputation, and startup/loading.

No app behavior, Supabase SQL, RLS assumptions, migrations, or feature flows were changed for this audit.

Files inspected: 52 relevant Swift and SQL files by direct read and targeted search.

## A. Executive Summary

### Top 10 Performance Risks

1. Discover selected-day and sport changes can still trigger broad `venue_events` refreshes with multiple serial chunks across venue ids, owner emails, and venue names in `MapViewModel+VenueAndGameData.swift`.
2. Map snapshot building is detached and coalesced, but the detached builder still performs repeated event scans per venue in `DiscoverMapRenderSnapshot.swift`, which can grow as venue/event counts rise.
3. Business analytics and manage-games refreshes load comments and vibes per event, creating N+1 style fan-out in `VenueOwnerDashboardView.swift` and `MapViewModel+VenueOwnerAnalyticsRealtime.swift`.
4. Fan Chat full-sheet loading fetches first page comments, report flags, and likes sequentially; realtime count reconcile can add extra exact-count queries in `MapViewModel+CommentsAndVibes.swift`.
5. `VenueEventCommentsView.swift` sorts comments and rebuilds ad-inserted list items from computed properties, so every relevant state update can reprocess the whole thread.
6. DM inbox realtime currently listens to unfiltered `direct_messages` and `conversation_read_state`, relying on RLS, which is simple but may become expensive at scale in `ChatViewModel.swift`.
7. Startup critical bootstrap still awaits cached Discover restore, initial region/preload, auth session, fresh Discover core refresh, and unread DM count before dismissing splash in `BootstrapLoadingCoordinator.swift`.
8. Image caching is strong for Discover venue images, but many avatar/profile surfaces still use `AsyncImage` without the shared cache in `UserAvatarView.swift`, `SocialAvatarRenderer.swift`, and profile views.
9. `MapViewModel.swift` is a very large `@MainActor ObservableObject` with many `@Published` properties; unrelated updates can invalidate large SwiftUI surfaces.
10. Several flows rely on broad foreground refreshes and deferred batches in `MainTabView.swift`, which protects first render but can stack work after app activation.

### Top 10 Safest Quick Wins

1. Add cache-aware early returns to `loadUserProfilesForEmails(_:)` so already loaded normalized emails are not re-fetched.
2. Memoize sorted comments and `VenueCommentsAdPlacement.listItems(for:)` per event revision instead of recomputing in `VenueEventCommentsView`.
3. Cap or window the number of event ids refreshed by venue-owner analytics cards before calling per-event `loadComments` and `loadVibes`.
4. Replace business-dashboard full comment loads with count/preview-only loaders where the UI only needs counts.
5. Add short TTL caching for `loadVibes(for:)` full reloads, matching the existing card prefetch TTL pattern.
6. Move `UserAvatarView` from `AsyncImage` to the existing `DiscoverMapImageCache` or a shared avatar cache.
7. Parallelize independent venue-event query chunks where safe, while preserving request fencing and result merge order.
8. Avoid `select()` wildcard in venue-owner game queries; use explicit columns needed by each screen.
9. Add local revision keys for calendar list/search computed results to reduce repeated filtering while typing.
10. Keep startup warm preload staged, but move unread DM count to post-splash if product accepts badge appearing slightly later.

### Top 10 Risky Changes To Avoid

1. Do not remove optimistic Going state, local reconcile TTLs, or in-flight guards.
2. Do not change private DM active visible thread gating without a full unread regression pass.
3. Do not replace realtime listeners with polling without documenting latency and battery tradeoffs.
4. Do not change Discover selected-date behavior, guest pinned-date behavior, or automatic nearest-game handling casually.
5. Do not change calendar overlay z-index, blur, tab-bar hit testing, or Done-button flow without device testing.
6. Do not alter venue owner game creation/import, cleanup delay, or archived/history semantics as a performance shortcut.
7. Do not change international address/pin persistence or geocoding assumptions during a performance pass.
8. Do not batch or cache Fan Chat likes/report flags in a way that hides moderation or current-user state.
9. Do not weaken Supabase RLS assumptions or add client-side assumptions about rows hidden by policy.
10. Do not remove launch fallback timeout or disk snapshot restore unless first usable screen time is measured on device.

## B. File-by-file Findings

### `GameOn/BootstrapLoadingCoordinator.swift`

- Suspected bottleneck: Critical launch path awaits multiple network-adjacent steps before splash dismissal.
- Evidence: `performCriticalBootstrap` awaits `renderCachedDiscoverCore`, `prepareInitialDiscoverRegionAndPreload`, `bootstrapAuthSessionOnly`, `refreshDiscoverCoreInBackground`, and `refreshUnreadDirectMessageCount`.
- User-visible symptom: Cold start can feel blocked by Discover refresh or badge load even with a 3.8s maximum wait.
- Risk level: Medium.
- Suggested fix: Keep cached Discover restore critical, but move unread DM badge and nonessential fresh Discover refresh to post-splash warm preload if metrics show delay.
- Safe immediately: Medium. Requires launch timing validation.

### `GameOn/ContentView.swift`

- Suspected bottleneck: Debug builds force a minimum 2s splash via `debugSplashMinimumElapsed`.
- Evidence: `.task` sleeps for 2 seconds under DEBUG before clearing `debugSplashMinimumElapsed`.
- User-visible symptom: Debug testing may overstate startup slowness.
- Risk level: Low.
- Suggested fix: Document that DEBUG launch timing includes artificial delay; measure release builds separately.
- Safe immediately: Yes, documentation only.

### `GameOn/LaunchWarmPreloadCoordinator.swift`

- Suspected bottleneck: Warm preload runs personalization, chat refresh, calendar/game loads, pickup metadata, and pokes badge soon after splash.
- Evidence: `runStaggeredWarmPreload` schedules several network tasks within roughly one second of launch.
- User-visible symptom: First screen may render quickly but then feel busy or drop frames during post-splash work.
- Risk level: Medium.
- Suggested fix: Gate warm tasks by visible tab and network priority; keep chat realtime deferred.
- Safe immediately: Medium.

### `GameOn/FanSpotApp.swift`

- Suspected bottleneck: Google Mobile Ads bootstrap runs in app init.
- Evidence: `GoogleMobileAdsBootstrap.startIfNeeded()` runs before `ContentView`.
- User-visible symptom: Possible cold-launch overhead.
- Risk level: Low.
- Suggested fix: Measure ad SDK startup cost; defer if it shows measurable launch impact.
- Safe immediately: No, ad behavior must be regression tested.

### `GameOn/MapViewModel.swift`

- Suspected bottleneck: Large `@MainActor` object with many `@Published` fields shared across tabs.
- Evidence: Map, auth, owner, chat social, profile, calendar, venue event, and pickup state all live on one observable object.
- User-visible symptom: Unrelated state updates can redraw broad SwiftUI surfaces.
- Risk level: High.
- Suggested fix: Phase 3 architecture split into focused stores after tests exist.
- Safe immediately: No.

### `GameOn/MapViewModel+VenueAndGameData.swift`

- Suspected bottleneck: Discover data loading combines fast pins, selected-day event rows, schedule loads, caches, and persistence in one path.
- Evidence: `loadVenuesFromSupabase` fetches viewport venues, supplements venue ids from selected-day events, fetches venue events, maps rows off-main, merges into state, reconciles reminders, persists snapshot, then schedules enrichment.
- User-visible symptom: Date or filter switching can show refresh status, delayed pins, or stale cached results under load.
- Risk level: High.
- Suggested fix: Preserve phase-1 fast pins, then optimize event fetching with better batching/indexes and smaller invalidation scopes.
- Safe immediately: Only logging/measurement and explicit-column cleanup are safe.

### `GameOn/DiscoverMapRenderSnapshot.swift`

- Suspected bottleneck: Detached snapshot builder scans `input.events` per visible venue.
- Evidence: `selectedDayEvents` filters all events for each venue; live-now lookup scans `venueEventRows` through `cachedVenueEventRow`.
- User-visible symptom: Pin redraw lag as venue and event counts grow.
- Risk level: Medium.
- Suggested fix: Pre-index events by day/title and venue-event rows by venue id/name before per-venue loops.
- Safe immediately: Medium if output is covered by Discover regression tests.

### `GameOn/DiscoverScreen.swift`

- Suspected bottleneck: Very large view with many state variables, overlays, sheets, computed card sections, and per-card tasks.
- Evidence: `venuePreviewCard` computes games, selected event, prefetches images, then loops games to prefetch Fan Updates social data.
- User-visible symptom: Preview card expansion/details navigation and selected venue changes may trigger visible work.
- Risk level: Medium.
- Suggested fix: Split card subviews around stable inputs and move prefetch scheduling to a view model function with a small TTL.
- Safe immediately: Low to medium; must preserve Going, Fan Chat, predictions, and guest gating.

### `GameOn/MapViewModel+EventsAndSchedule.swift`

- Suspected bottleneck: Calendar list and dots have cache keys, but tab activation still triggers multiple refresh paths.
- Evidence: `noteCalendarTabBecameActive` clears list cache, loads dots, calls `loadGamesFromSupabase`, and refreshes pickup sources.
- User-visible symptom: Calendar tab may feel busy on entry or foreground.
- Risk level: Medium.
- Suggested fix: Add a short activation TTL for the combined calendar refresh, not just list rows.
- Safe immediately: Medium.

### `GameOn/CalendarScreen.swift`

- Suspected bottleneck: Calendar Done, sport change, region mode change, tab activation, and foreground all trigger cache clears and refreshes.
- Evidence: Multiple `.onChange` handlers call `recomputeCalendarDotDates`, `loadCalendarTabCalendarDotsAroundMonth`, `loadGamesFromSupabase`, and `refreshCalendarTabPickupSources`.
- User-visible symptom: Selected-date switching or overlay Done may feel laggy.
- Risk level: Medium.
- Suggested fix: Coalesce calendar refresh requests by reason and month.
- Safe immediately: Medium; overlay regression testing required.

### `GameOn/EventCalendarView.swift`

- Suspected bottleneck: `calendarDays` rebuilds days from `displayedMonth` in a computed property.
- Evidence: The month grid recomputes on body updates; displayed month changes trigger `onDisplayedMonthChange`.
- User-visible symptom: Low to moderate calendar overlay churn.
- Risk level: Low.
- Suggested fix: Cache month day arrays by month start if profiling shows body churn.
- Safe immediately: Yes, if behavior is unchanged.

### `GameOn/MapViewModel+PickupGames.swift`

- Suspected bottleneck: Pickup map refresh fetches day rows, filters client-side, then optionally loads join requests, pending counts, and creator profiles.
- Evidence: `performRefreshPickupGamesForDiscoverMap` fetches up to 400 rows and follows with additional authenticated queries.
- User-visible symptom: Pickup mode or date switching can feel slower than venue mode.
- Risk level: Medium.
- Suggested fix: Keep coalescing; add TTL for same day/sport/mode and defer personal join-state loads until after pins render.
- Safe immediately: Medium.

### `GameOn/MapViewModel+PickupGameRequests.swift`

- Suspected bottleneck: Join approval/rejection/withdraw flows refresh many caches and lists after mutation.
- Evidence: Approval and rejection refresh map rows, calendar dots, organizer summaries, withdrawn requests, approved joiners, and pending count.
- User-visible symptom: Join management can feel slow after tapping approve/reject.
- Risk level: Medium.
- Suggested fix: Keep correctness first; locally patch visible rows and defer broad refreshes with a debounce.
- Safe immediately: No, pickup join state is fragile.

### `GameOn/MapViewModel+FollowingPickupActivity.swift`

- Suspected bottleneck: Realtime subscription is restarted whenever following pickup game ids sync.
- Evidence: `syncFollowingPickupRealtimeSubscriptionIfNeeded` always stops and restarts the channel.
- User-visible symptom: Following pickup updates can briefly miss realtime events or churn subscriptions.
- Risk level: Medium.
- Suggested fix: Add equality check against currently tracked ids before restart.
- Safe immediately: Yes if tested with pickup request lifecycle.

### `GameOn/PickupGameMapLocationPickerSheet.swift`

- Suspected bottleneck: Reverse geocode runs on initial task and after pin taps with 320ms debounce.
- Evidence: `scheduleReverseGeocode` cancels prior task, sleeps, then calls `reverseGeocodePin`.
- User-visible symptom: Generally safe; repeated pin taps can still issue geocoding work.
- Risk level: Low.
- Suggested fix: Add a small coordinate-distance threshold before reverse geocoding.
- Safe immediately: Medium due international address/pin flow sensitivity.

### `GameOn/SettingsPickupGamesSheets.swift`

- Suspected bottleneck: Settings pickup list loads all organizer games, summaries, withdrawn requests, approved joiners, and rating stats on sheet task.
- Evidence: `.task` calls `loadMyPickupGamesForSettings` and then public rating stats.
- User-visible symptom: My pickup games sheet may open with delayed content.
- Risk level: Medium.
- Suggested fix: Show cached local rows first, then refresh detail counts.
- Safe immediately: Medium.

### `GameOn/MapViewModel+VenueEventSocial.swift`

- Suspected bottleneck: Going button is already optimized, but follow-up reconciliation and profile prefetch can add network work.
- Evidence: `toggleVenueGameGoingFromUI` applies optimistic UI, then `completeVenueGameGoingToggle` runs asynchronously with local reconcile guards.
- User-visible symptom: Going button is responsive today; regressions are likely if guards are simplified.
- Risk level: High.
- Suggested fix: Do not change optimistic path; measure only.
- Safe immediately: Only log/metric additions.

### `GameOn/MapVenuePreviewCard.swift`

- Suspected bottleneck: Vibe buttons spawn tasks and card state observes the fan updates store.
- Evidence: `Task { await viewModel.toggleVibe(...) }` is used from card controls.
- User-visible symptom: Vibe chip counts can update after a delay.
- Risk level: Low.
- Suggested fix: Keep optimistic vibe state and add TTL around full vibe reloads.
- Safe immediately: Medium.

### `GameOn/VenueEventVibeMeterView.swift`

- Suspected bottleneck: `.task` animates chips visible and `onAppear` prefetches vibes.
- Evidence: The view observes `FanUpdatesRealtimeStore` and calls `prefetchVibesForFanUpdatesCardIfNeeded`.
- User-visible symptom: Minimal, but many visible cards can create many prefetch tasks.
- Risk level: Low.
- Suggested fix: Preserve TTL and cap concurrent vibe prefetches.
- Safe immediately: Medium.

### `GameOn/MapViewModel+CommentsAndVibes.swift`

- Suspected bottleneck: Fan Chat loads and realtime paths can issue exact count, preview rows, first page rows, report flags, like rows, profile rows, and reconcile count queries.
- Evidence: `loadCommentsFirstPage` loads 100 comments then calls report flags and likes; realtime insert schedules count reconcile; app-level realtime tracks up to 160 event ids.
- User-visible symptom: Fan Chat sheet may open slowly and comments may update with delayed count/like state.
- Risk level: High.
- Suggested fix: Prioritize first comments render, then load report flags/likes after first paint; keep realtime fallback unchanged.
- Safe immediately: Medium if visual loading states are preserved.

### `GameOn/VenueEventCommentsView.swift`

- Suspected bottleneck: `comments` sorts on every access and `venueCommentsListItems` maps/inserts ads on every body pass.
- Evidence: `comments` computed property sorts `fanUpdatesStore.venueEventComments[venueEventID]`; list items are recomputed from `comments`.
- User-visible symptom: Larger comment threads can cause scroll or input lag.
- Risk level: Medium.
- Suggested fix: Store sorted comments/list items in local state keyed by event id and revision.
- Safe immediately: Medium.

### `GameOn/VenueEventCommentsSheet.swift`

- Suspected bottleneck: Header subtitle scans `venueEventRows` by id.
- Evidence: `headerSubtitle` uses `first(where:)` on each body evaluation.
- User-visible symptom: Minor; only relevant with large `venueEventRows`.
- Risk level: Low.
- Suggested fix: Pass precomputed title/venue from opener or cache row lookup by id.
- Safe immediately: Yes.

### `GameOn/VenueCommentsAdPlacement.swift`

- Suspected bottleneck: Ad insertion is O(comment count) and recomputed by the view.
- Evidence: `listItems(for:)` loops all comments and inserts one or two ad items.
- User-visible symptom: Minor for small threads, larger for 100+ comment pages.
- Risk level: Low.
- Suggested fix: Memoize with sorted comments.
- Safe immediately: Yes.

### `GameOn/DirectChatService.swift`

- Suspected bottleneck: Good keyset pagination exists, but unread fallback is O(conversations).
- Evidence: `fetchUnreadDirectMessageCount` uses `get_dm_unread_total`, then falls back to `fetchUnreadDirectMessageCountFanOut`.
- User-visible symptom: Badges can become slow if RPC is missing or fails.
- Risk level: Medium.
- Suggested fix: Treat RPC availability as required for scale; alert/log fallback usage.
- Safe immediately: Yes for diagnostics only.

### `GameOn/DirectChatView.swift`

- Suspected bottleneck: Initial open starts conversation RPC, fetches latest messages, starts realtime, marks read, and handles fallback refresh.
- Evidence: `.task(id: presenter.friend.id)` awaits `presenter.onAppear`, then starts realtime and mark-read tasks.
- User-visible symptom: DM opening can pause before history appears, though send path is optimistic.
- Risk level: Medium.
- Suggested fix: Cache conversation ids and last messages in memory from inbox summaries; keep active-thread gating.
- Safe immediately: Medium.

### `GameOn/ChatViewModel.swift`

- Suspected bottleneck: Inbox realtime listens unfiltered for direct messages and conversation read state; badge recalculation can call RPC or full inbox refresh.
- Evidence: `runInboxRealtimeListenerLoop` subscribes without filters and logs reliance on RLS; `requestBadgeRecalculation` may call `refreshInboxSummaries`.
- User-visible symptom: Badge updates may be accurate but expensive at scale.
- Risk level: High.
- Suggested fix: Consider user-scoped realtime/broadcast later; keep current logic until unread tests exist.
- Safe immediately: No for architecture change; logging safe.

### `GameOn/MainTabView.swift`

- Suspected bottleneck: Foreground handling performs session checks, owner refreshes, single-session checks, admin checks, pokes, chat realtime, fan chat verification, pickup refreshes, then deferred batch.
- Evidence: `handleAppBecameActive` has a critical batch and schedules `runForegroundDeferredBatch`.
- User-visible symptom: App foreground can feel busy or badge updates may lag.
- Risk level: Medium.
- Suggested fix: Add a foreground refresh budget and skip unchanged/healthy subsystems.
- Safe immediately: Medium.

### `GameOn/MapViewModel+ProfilePokes.swift`

- Suspected bottleneck: Pokes badge refresh is polled from `MainTabView`.
- Evidence: Main tab has a poll loop with idle/active intervals.
- User-visible symptom: Badge sync may lag or consume periodic network.
- Risk level: Low.
- Suggested fix: Keep polling interval conservative; avoid adding more foreground badge polls.
- Safe immediately: Yes.

### `GameOn/NotificationSettingsStore.swift`

- Suspected bottleneck: No major bottleneck found in searched usage.
- Evidence: Notification settings are state-backed and read by reminder code.
- User-visible symptom: Low.
- Risk level: Low.
- Suggested fix: No immediate work.
- Safe immediately: Yes.

### `GameOn/DiscoverMapImageCache.swift`

- Suspected bottleneck: Cache is useful but small and serial prefetches only first 8 URLs.
- Evidence: `maxEntries = 72`; `prefetch(urls:)` loops sequentially.
- User-visible symptom: Discover venue images mostly improve, but rapid venue switching can still show placeholders.
- Risk level: Low.
- Suggested fix: Keep max bounded; optionally prefetch concurrently with a small limit.
- Safe immediately: Medium.

### `GameOn/UserAvatarView.swift`

- Suspected bottleneck: Uses `AsyncImage`, not the shared in-memory image cache.
- Evidence: Avatar URL is built with `ImageDisplayURL.forListDisplay`, then rendered through `AsyncImage`.
- User-visible symptom: Avatar flicker/refetch in chat, profile, tab bar, and lists.
- Risk level: Medium.
- Suggested fix: Introduce shared cached avatar loader or reuse `DiscoverCachedRemoteImage` for circular avatars.
- Safe immediately: Medium.

### `GameOn/SocialAvatarRenderer.swift`

- Suspected bottleneck: Uses `AsyncImage` for social avatars.
- Evidence: Search found `AsyncImage(url:)` in social avatar rendering.
- User-visible symptom: Repeated avatar loads in chat/comment surfaces.
- Risk level: Medium.
- Suggested fix: Use shared avatar cache.
- Safe immediately: Medium.

### `GameOn/ImageCompression.swift`

- Suspected bottleneck: Compression runs synchronously in call sites.
- Evidence: `jpegDataForUpload` decodes and re-encodes `UIImage` using `UIGraphicsImageRenderer`.
- User-visible symptom: Large image upload flows may block if called on main actor.
- Risk level: Medium.
- Suggested fix: Ensure all call sites run compression off-main before storage upload.
- Safe immediately: Medium after call-site review.

### `GameOn/SettingsScreen.swift`

- Suspected bottleneck: Account screen includes large hero/body and inline business dashboard refresh task.
- Evidence: `settingsInlineBusinessDashboard` has `.task(id:)` and computes fans/chats/predictions from event ids and shared stores.
- User-visible symptom: Account tab can trigger business dashboard network and redraw work.
- Risk level: Medium.
- Suggested fix: Cache inline dashboard data per owner venue and only refresh on visible tab or explicit action.
- Safe immediately: Medium.

### `GameOn/ProfileIdentityCard.swift`

- Suspected bottleneck: Profile stats, pokes, avatar replacement, favorite teams, and identity edits share one card.
- Evidence: Multiple `.task`, `.onChange`, and network calls are attached to profile card lifecycle.
- User-visible symptom: Account tab may load stats/pokes after appearing and redraw card.
- Risk level: Medium.
- Suggested fix: Keep stats TTL; avoid forced refreshes unless account tab is active and data stale.
- Safe immediately: Medium.

### `GameOn/ProfileStatsService.swift`

- Suspected bottleneck: Stats load performs four parallel queries, but some fetch up to 1,000 rows then count client-side.
- Evidence: `loadPickupGamesCount` and `loadVenueGamesCount` load rows and count distinct ids in Swift.
- User-visible symptom: Profile stats can be slow for active users.
- Risk level: Medium.
- Suggested fix: Add count/distinct RPC later; for now keep 300s cache.
- Safe immediately: No SQL/RPC change in this task.

### `GameOn/PublicUserProfileService.swift`

- Suspected bottleneck: Public profile load chains profile row, XP, organizer stats, favorite teams, business resolution, preferences, and home crowd.
- Evidence: `loadProfile` reads several independent sources; some are sequential.
- User-visible symptom: Public profile preview may open slower than expected.
- Risk level: Medium.
- Suggested fix: Parallelize independent queries after profile visibility/business gate is known.
- Safe immediately: Medium.

### `GameOn/PublicUserProfilePreviewView.swift`

- Suspected bottleneck: Opening profile can refresh chat state and friend actions.
- Evidence: Searched usage shows `chatViewModel.loadIfNeeded`, friend request send, inbox refresh, realtime ensure.
- User-visible symptom: Public profile overlay actions can feel delayed.
- Risk level: Low to medium.
- Suggested fix: Keep UI optimistic where safe; avoid full chat refresh after small social actions.
- Safe immediately: Medium.

### `GameOn/PublicProfileEditorialCards.swift`

- Suspected bottleneck: Venue tiles use cached remote images, which is good; layout uses container width state.
- Evidence: `DiscoverCachedRemoteImage` is used for public profile venue images.
- User-visible symptom: Low; image cache helps.
- Risk level: Low.
- Suggested fix: No immediate change beyond shared image-cache consistency.
- Safe immediately: Yes.

### `GameOn/VenueOwnerDashboardView.swift`

- Suspected bottleneck: Large SwiftUI file and heavy dashboard/analytics refresh fan-out.
- Evidence: `refreshManageGamesList` loads scheduled games, interest counts, then per id loads comments and vibes. Analytics caps rows at 1500 but refreshes engagement for displayed ids.
- User-visible symptom: Business dashboard/manage games/analytics can feel slow for venues with many games.
- Risk level: High.
- Suggested fix: Replace per-event comments/vibes with aggregate count RPCs in Phase 2/3; short term cap visible engagement refreshes.
- Safe immediately: Low for behavior changes; documentation and measurement safe.

### `GameOn/BusinessVenueDashboardOverviewView.swift`

- Suspected bottleneck: Current overview is light after recent cleanup.
- Evidence: View renders quick actions and up to 3 games; no remote image loading remains.
- User-visible symptom: Low.
- Risk level: Low.
- Suggested fix: No performance work needed beyond avoiding reintroducing remote hero images.
- Safe immediately: Yes.

### `GameOn/MapViewModel+VenueOwnerAndClaims.swift`

- Suspected bottleneck: Venue owner game queries use `select()` and engagement counts fetch all interest rows for ids.
- Evidence: `loadMyVenueScheduledGames`, `loadMyVenueGamesForAnalytics`, and debug refreshes select full rows; `loadInterestCountsForVenueEventIDs` pulls `venue_event_id` rows and counts client-side.
- User-visible symptom: Owner dashboards slow as history/engagement grows.
- Risk level: Medium.
- Suggested fix: Explicit columns and count/group RPC for engagement.
- Safe immediately: Explicit columns are medium; RPC requires SQL review later.

### `GameOn/MapViewModel+VenueOwnerAnalyticsRealtime.swift`

- Suspected bottleneck: Realtime updates debounce then fully reload interest counts, comments, and vibes for tracked ids.
- Evidence: `applyVenueOwnerRealtimeEngagementRefresh` calls `loadInterestCountsForVenueEventIDs`, then loops ids and calls `loadComments` and `loadVibes`.
- User-visible symptom: Analytics realtime can become expensive with many tracked games.
- Risk level: High.
- Suggested fix: Use aggregate deltas or count RPCs; short term reduce tracked ids to visible cards.
- Safe immediately: No, analytics regression testing required.

### `GameOn/VenueEventPredictionsView.swift`

- Suspected bottleneck: Prediction row loads summary per event via tasks.
- Evidence: Discover calls `loadVenueEventPredictionSummaries` from card task and prediction sheet refreshes on save.
- User-visible symptom: Prediction row can appear late on cards.
- Risk level: Medium.
- Suggested fix: Batch prediction summary loads at the card-list level and rely on 45s cache.
- Safe immediately: Medium.

### `GameOn/VenueEventPredictionService.swift`

- Suspected bottleneck: Prediction summaries fetch all prediction rows for event ids then filter per event in Swift; avatars are a second query.
- Evidence: `fetchPredictionSummary` runs one `.in("venue_event_id")`, then `rows.filter` per event and `loadAvatars`.
- User-visible symptom: Slow summaries for high-participation events.
- Risk level: Medium.
- Suggested fix: Add aggregate summary RPC later; short term keep cache and batch ids.
- Safe immediately: No SQL change now.

### `GameOn/VenueDetailView.swift`

- Suspected bottleneck: Venue detail uses cached remote images for hero/inside photos.
- Evidence: Search found `DiscoverCachedRemoteImage` for hero and inside venue images.
- User-visible symptom: Good relative to `AsyncImage`; placeholder still appears until cache fills.
- Risk level: Low.
- Suggested fix: Prewarm only hero/thumbnail, not heavier menu/crowd images on map preview.
- Safe immediately: Yes.

### `GameOn/FollowingScreen.swift`

- Suspected bottleneck: Large view, pickup following realtime, and venue cards with cached images.
- Evidence: Search found many view sections and cached remote image usage.
- User-visible symptom: Following tab can redraw when social/pickup state changes.
- Risk level: Medium.
- Suggested fix: Split large sections into stable subviews and keep realtime id restart guard.
- Safe immediately: Medium.

### `GameOn/LiveScreen.swift`

- Suspected bottleneck: Live auto-refresh loop and prediction summary loads.
- Evidence: Search found auto-refresh task and prediction summary callbacks.
- User-visible symptom: Live tab can consume network and CPU while visible.
- Risk level: Medium.
- Suggested fix: Keep auto-refresh visible-tab gated and avoid prediction loads for offscreen rows.
- Safe immediately: Medium.

### `GameOn/AdaptiveBannerView.swift`, `GameOn/CompactNativeAdCard.swift`, `GameOn/AdMobBannerView.swift`

- Suspected bottleneck: Ads add geometry/layout work and SDK callbacks.
- Evidence: Search found `GeometryReader` in adaptive banner and `onAppear` ad diagnostics.
- User-visible symptom: Comment feeds and Discover top sections may shift or delay as ads load.
- Risk level: Low to medium.
- Suggested fix: Reserve stable dimensions and keep ads out of first critical render.
- Safe immediately: Medium.

### `supabase/migrations/20260523_0001_gameon_calendar_dot_dates_rpc.sql`

- Suspected bottleneck: Calendar dot RPC depends on indexes for `games` and active `venue_events`.
- Evidence: Migration adds `idx_games_game_date_sport`, `idx_venue_events_active_event_date_sport`, and `idx_venue_events_active_venue_id_event_date_sport`.
- User-visible symptom: Calendar dots should be reasonably supported; owner email/name legacy paths may still need review.
- Risk level: Medium.
- Suggested fix: Consider indexes for legacy `owner_email` and `venue_name` active date/sport paths if RPC plans show scans.
- Safe immediately: No SQL changes in this audit.

### `supabase/migrations/20260510_0001_private_messaging_safety.sql`

- Suspected bottleneck: DM safety migration adds moderation indexes, not necessarily message timeline indexes.
- Evidence: Found report indexes but no proof here of composite `direct_messages(conversation_id, created_at, id)` index.
- User-visible symptom: DM pagination/unread counts may slow without timeline/read-state indexes.
- Risk level: Medium.
- Suggested fix: Review database indexes for direct message timeline and unread paths.
- Safe immediately: No SQL changes in this audit.

### `supabase/migrations/20260629_0001_discover_anon_venue_events_pickup_select.sql`

- Suspected bottleneck: Adds anon read policies for Discover tables.
- Evidence: Policies grant anon select to `venue_events`, `pickup_games`, and `venues`.
- User-visible symptom: Guest Discover depends on RLS and indexes; avoid changing assumptions casually.
- Risk level: High.
- Suggested fix: Measure query plans with anon role before any RLS/index work.
- Safe immediately: No.

### `supabase/migrations/20260717_0001_pickup_games_cleanup_delay_hours_eq_12.sql`

- Suspected bottleneck: Cleanup is handled by `remove_after_at`, but client still filters cleanup locally.
- Evidence: Trigger forces `remove_after_at = game_start_at + 12h`; app queries also filter `remove_after_at`.
- User-visible symptom: Correct but duplicate client filtering work.
- Risk level: Low.
- Suggested fix: Keep duplicate client guard for safety; database index on `remove_after_at` may matter for large pickup tables.
- Safe immediately: No SQL changes in this audit.

## C. Feature-specific Sections

### Discover/map

- Current strengths: Disk snapshot restore, phase-1 fast pin loading, viewport venue cache, request IDs, stale result guards, detached snapshot builds, and rebuild coalescing are all present.
- Main risks: Event lookup and snapshot building still rely on repeated scans; selected-day refresh may fetch via venue ids, owner emails, and names; force refresh clears several caches together.
- Safe next work: Add metrics around selected-date switch time, event rows fetched, chunk counts, and snapshot detached build time. Optimize indexes and pre-index in memory only after measuring.

### Venue games

- Current strengths: Going button uses optimistic UI and local reconcile guards; prediction summaries have a 45s cache; venue images often use cached loader.
- Main risks: Fan Updates and prediction prefetch happen per visible event; card expansion can trigger social prefetch loops.
- Safe next work: Batch prediction summary loads and add a prefetch budget for Fan Updates social data.

### Pickup games

- Current strengths: Discover pickup map refresh is coalesced; creator profiles are batched; reverse geocode is debounced.
- Main risks: Authenticated pickup refresh adds join-state, pending counts, and creator profiles after map query; organizer mutation flows refresh many caches.
- Safe next work: Add same-day/sport TTL for pickup map rows and defer personal state until pins render.

### Calendar

- Current strengths: Calendar list rows have TTL, dot RPC exists, and hidden Calendar tab work is deferred.
- Main risks: Calendar tab activation, sport changes, region mode changes, Done button, and foreground can all trigger refreshes.
- Safe next work: Coalesce calendar refreshes by month/filter/reason and keep overlay behavior untouched.

### Fan chats/comments

- Current strengths: Initial page is limited, older pages use keyset pagination, realtime has duplicate suppression and fallback recovery.
- Main risks: First page load does comments, report flags, and likes; realtime count reconcile adds count queries; sorted/ad-inserted list recomputes in view.
- Safe next work: First paint comments before report/like enrichment, and memoize sorted comments/list items.

### Private DMs

- Current strengths: Send is optimistic, per-thread realtime exists, timeline display is maintained outside body, and keyset pagination is used.
- Main risks: Inbox realtime is unfiltered; unread fallback can fan out per conversation; opening a thread does start conversation and fetch latest messages before realtime.
- Safe next work: Add diagnostics for RPC fallback usage and cache conversation ids from inbox summaries.

### Badges

- Current strengths: Badge recalculation is debounced; app icon sync is centralized; pokes polling intervals are conservative.
- Main risks: Foreground can trigger several badge and social refresh paths; unread correctness is fragile.
- Safe next work: Keep badge correctness; only add skip logic when data is fresh and no visible thread gate is active.

### Business dashboard

- Current strengths: Current overview is light and no longer loads remote dashboard hero imagery.
- Main risks: Data feeding the dashboard, manage games, and analytics still loads per-event comments/vibes and prediction summaries.
- Safe next work: For dashboard metrics, use counts/previews instead of full comment/vibe rows.

### Images/photos

- Current strengths: Venue thumbnails in Discover and venue detail use `DiscoverCachedRemoteImage`; upload compression creates thumbnails.
- Main risks: Avatars still use `AsyncImage`; image compression may block if called from main; cache max/prefetch strategy is small and per-process only.
- Safe next work: Shared cached avatar image loader and off-main upload compression call-site review.

### Startup/loading

- Current strengths: Cached Discover core and warm preload exist; launch has a timeout fallback; debug logs identify critical/warm tasks.
- Main risks: Critical bootstrap still includes fresh Discover core and unread badge; warm preload may cause post-splash churn.
- Safe next work: Measure release first usable screen time and defer unread badge if it is a material contributor.

## D. Query/Network Audit

### Repeated fetches

- `loadGamesFromSupabase` can be requested from Discover, Calendar, and warm preload. It is coalesced, but still fetches official games and venue events when it runs.
- `refreshPickupGamesForDiscoverMap` is coalesced, but can be forced after pickup mutations, Calendar activation, and Discover pickup mode.
- `loadComments(for:)` and `loadVibes(for:)` are called per event in business analytics/manage games.
- `loadUserProfilesForEmails(_:)` batches inputs, but does not skip already cached emails before querying.
- Fan Chat realtime count reconcile can call exact visible count after realtime inserts.

### N+1 patterns

- Venue-owner analytics: one count batch plus per-event comments and vibes.
- Manage games refresh: per scheduled game comments and vibes.
- Prediction summaries are batched at service level, but card-level calls can still trigger repeated one-id requests when cache is cold.
- Profile stats count rows client-side for pickup and venue games instead of using aggregate counts.
- Public profile load performs several independent queries per opened profile.

### Unbatched requests

- `loadVibes(for:)` is per event.
- `loadComments(for:)` is per event.
- `VenueOwnerAnalyticsRealtime` refreshes all tracked event ids on any relevant realtime change.
- `DirectChatService` unread fallback counts per conversation if RPC fails.

### Missing cache opportunities

- User/profile rows by email should skip cached profiles.
- Vibe full loads need short TTL or in-flight coalescing beyond prefetch task scope.
- Calendar activation needs combined TTL for dots, games, and pickup sources.
- Dashboard metrics should cache per owner venue for a short interval.
- Avatar image loads need shared cache.

### Possible Supabase indexes to consider

Do not add these without query plans and migration review:

- `venue_events (owner_email, event_date, sport) WHERE admin_status = 'active' AND venue_id IS NULL`
- `venue_events (venue_name, event_date, sport) WHERE admin_status = 'active' AND venue_id IS NULL`
- `venue_events (venue_id, scheduled_start_at) WHERE admin_status = 'active'`
- `venue_event_comments (venue_event_id, created_at DESC, id DESC) WHERE is_moderation_hidden IS DISTINCT FROM true`
- `venue_event_comment_likes (comment_id, user_id)`
- `venue_event_vibes (venue_event_id, user_email, vibe_type)`
- `venue_event_interests (venue_event_id)`
- `direct_messages (conversation_id, created_at DESC, id DESC) WHERE deleted_at IS NULL`
- `conversation_read_state (conversation_id, user_id)`
- `pickup_games (game_start_at, sport) WHERE status = 'active' AND is_visible = true`
- `pickup_games (remove_after_at)`
- `pickup_game_requests (pickup_game_id, status)` and `(requester_user_id, updated_at DESC)`

### RPCs that may need review

- `gameon_calendar_dot_dates`: review owner email/name legacy path plans.
- `get_dm_inbox_summaries`: critical for Chat tab open and warm preload.
- `get_dm_unread_total`: critical for badge scale; fallback should be rare.
- `start_direct_conversation`: called on thread open.
- `pickup_creator_public_rating_stats`: profile/pickup related.
- Future candidate: venue owner engagement aggregate RPC for counts/comments/vibes.
- Future candidate: prediction summary aggregate RPC.
- Future candidate: profile stats aggregate RPC.

## E. SwiftUI Audit

### Large View bodies

- `DiscoverScreen.swift`: high complexity, many overlays/sheets/state variables.
- `VenueEventCommentsView.swift`: full chat/feed/composer/ad layout in one view.
- `DirectChatView.swift`: presenter plus large view, message list, composer, overflow menus, reporting.
- `VenueOwnerDashboardView.swift`: dashboard, profile editor, analytics, manage games, import, schedule picker.
- `SettingsScreen.swift`: account hero, business dashboard, reports, venue owner sheets.
- `FollowingScreen.swift`: following hub, pickup, saved venues, going plans.
- `LiveScreen.swift`: live feed, auto refresh, business claim flows.

### Expensive recomputations

- `DiscoverMapRenderSnapshotBuilder.selectedDayEvents` filters all events for each venue.
- `VenueEventCommentsView.comments` sorts every access.
- `VenueCommentsAdPlacement.listItems` rebuilds list items every access.
- Calendar list filtering builds hashes over pickup rows for cache keys.
- Dashboard metrics reduce over event ids on body computations.
- `VenueEventCommentsSheet.headerSubtitle` scans event rows.

### Unstable ForEach IDs

- Most important lists use stable ids. Lower-risk uses of `Array(...enumerated())` with stable element ids are present in business dashboard.
- `ForEach(..., id: \.self)` is common for static filters and primitive picker options; acceptable.
- Avoid adding `UUID()` as a view id in body. Existing `UUID()` usage is mostly model/token generation, not row identity.

### Unnecessary redraw triggers

- Broad `@Published` updates in `MapViewModel` can redraw unrelated surfaces.
- `venueEventInterestCounts` triggers snapshot rebuilds on every assignment.
- Chat and fan update stores publish data used by large views.
- Foreground batch updates several top-level states in quick succession.

### MainActor risks

- `MapViewModel` is `@MainActor`; many network functions update state on main after awaits, which is fine, but synchronous preprocessing in main functions should remain small.
- Image compression call sites must stay off-main where possible.
- Realtime apply paths update arrays/dictionaries on main; keep per-event work minimal.

### Places to split views without behavior change

- `DiscoverScreen`: split preview card, map overlay controls, calendar overlay host, and game row social controls.
- `VenueEventCommentsView`: split sorted-list model from UI, composer, comment row, quick chips, and ad rows.
- `DirectChatView`: split report/overflow UI from message timeline and composer.
- `VenueOwnerDashboardView`: split analytics data loader from cards; split manage games list/add/import.
- `SettingsScreen`: isolate account hero and inline business dashboard data source.

## F. Regression-risk Warning Section

These features are fragile and must not be changed casually:

- Going button state: Optimistic UI, in-flight ids, local reconcile TTL, following sync, calendar reminders, and XP side effects are intertwined.
- Private chat unread logic: `activeVisibleConversationId`, `directChatReadVisibilityVersion`, read-state upserts, inbox local patching, badge RPCs, and app icon sync must stay consistent.
- Active visible conversation gating: Do not mark a conversation read unless `canMarkActiveDirectThreadRead` says it is safe.
- Realtime badge lifecycle: Inbox/friendship listeners intentionally stay active beyond the Chat tab; disabling on tab switch would regress badges.
- Discover selected-date behavior: Guest pinned-date behavior, nearest-event behavior, selected-day event refresh, and map calendar Done flow are linked.
- Calendar overlay: Done button, blur, tab-bar hit testing, z-index, and minimum selectable day should be tested on device before changes.
- Venue owner business flows: Game creation/import, cleanup delay, analytics, claims, and owner venue id/email fallback are sensitive.
- International address/pin flow: Country/region labels, pin coordinates, formatted address, and reverse geocode should not be altered during performance-only work.
- Prediction module: Lock timing, summary cache, save refresh, and card visibility must remain stable.

## G. Recommended Phased Plan

### Phase 1: Safe low-risk fixes only

- Add performance-only logging around selected-day switch, calendar Done, Fan Chat first paint, DM thread first paint, and dashboard refresh duration.
- Skip already cached emails in `loadUserProfilesForEmails(_:)`.
- Memoize `VenueEventCommentsView` sorted comments/list items.
- Add equality guard before restarting following pickup realtime subscriptions.
- Add diagnostics when DM unread fallback fan-out is used.
- Explicitly document DEBUG splash delay and measure release builds separately.
- Keep business dashboard image-free and avoid adding remote hero images back.

### Phase 2: Medium-risk performance improvements

- Batch prediction summary loads at list/card-container level.
- Add short TTL and in-flight coalescing for full vibe loads.
- Defer Fan Chat likes/report flags until after initial comments render.
- Coalesce calendar activation refreshes and avoid duplicate game/pickup reloads.
- Limit venue-owner analytics engagement refresh to visible rows first.
- Replace avatar `AsyncImage` surfaces with a shared cached loader.
- Use explicit Supabase column selects in owner scheduled/history queries.

### Phase 3: Larger architecture changes requiring testing

- Split `MapViewModel` into smaller observable stores for Discover, account/profile, venue owner, pickup, and social.
- Add aggregate RPCs for venue owner engagement, prediction summaries, and profile stats.
- Rework realtime to user-scoped broadcasts or edge-driven deltas for DM inbox and fan chat counts.
- Add database indexes after query-plan review and migration approval.
- Introduce persistent image cache if memory-only cache is not enough.
- Add automated UI regression tests for Going, Fan Chat, DM unread, calendar overlay, pickup flows, business dashboard, and prediction locking.

## H. Testing Checklist

### Going button

- Tap Going on a Discover venue game while signed in.
- Verify immediate visual toggle, count change, and no double tap while in flight.
- Leave and return to Discover; verify local reconcile prevents flicker.
- Toggle off; verify count decreases and Following tab updates.
- Test guest and business account gates.

### Fan Chat

- Open Fan Chat from a venue game card and measure first visible comments.
- Post a comment and verify optimistic row, realtime echo dedupe, fallback recovery, and count update.
- Like/unlike comments and verify counts persist after refresh.
- Report/unreport a comment and verify report flags.
- Scroll with 8+ and 20+ comments to verify ad insertion does not jump the thread.

### Private DM send/receive

- Open a DM thread from Chat and from a public profile.
- Send a message and verify optimistic append, server confirmation, and realtime dedupe.
- Receive a message on another device and verify thread update latency.
- Pull to refresh and verify no duplicate messages.
- Background/foreground while thread is visible and while thread is hidden.

### Badge update

- Receive a DM while not in the thread; verify Chat tab badge and app icon.
- Receive a DM while viewing that exact thread; verify no unread increment.
- Accept/reject/cancel friend requests and verify pending badge.
- Receive pokes and verify account/profile badge.
- Foreground app after badge changes and confirm no stale counts.

### Venue game date switching

- Switch Discover selected date with venue mode active.
- Switch sport filters quickly.
- Confirm gray/no-game venue behavior remains correct.
- Confirm selected venue preview clears or updates correctly.
- Confirm calendar dots are not stale after date/sport changes.

### Pickup games

- Toggle Discover to pickup mode and verify pins appear quickly.
- Switch date and sport filters.
- Create pickup game, choose pin/address, and verify pin appears.
- Edit pickup game date/location and verify map/calendar update.
- Cancel pickup game and verify removal/history behavior.
- Approve/reject/withdraw join requests and verify Following/Calendar badges.

### Calendar Done button

- Open Discover calendar overlay.
- Select future date and tap Done.
- Verify overlay dismisses, tab bar hit testing returns, selected date applies, and dots remain visible.
- Test Calendar tab sheet Done separately.
- Test minimum selectable day clamp.

### Business venue game import

- Open business dashboard/manage games.
- Switch to Import From Live Games.
- Filter by sport and import a live game.
- Verify scheduled game appears and Discover displays it when appropriate.
- Confirm cleanup/retention controls remain intact.

### International address pin

- Create or edit business venue address outside US.
- Use pin picker and reverse geocode.
- Confirm country/region/postal labels stay correct.
- Save and reopen venue; verify coordinates and formatted address persist.
- Confirm Discover pin uses saved coordinates.

### Business dashboard

- Open Account as business owner.
- Verify unified hero and green business icon remain.
- Verify no fan XP/Fan Level card renders.
- Verify quick actions, manage games, statistics, and flagged comments navigation.
- Verify dashboard metrics load without blocking the whole Account tab.

### Profile switching

- Switch between fan account, business account, and signed-out/guest modes.
- Verify avatar/profile cache clears or updates correctly.
- Edit fan bio and verify public profile shows fresh bio.
- Open public profile preview for a friend and for a non-friend.
- Verify business accounts are hidden or gated as intended.

## Immediate Safe Recommendations

1. Cache-skip `loadUserProfilesForEmails(_:)` for emails already present in `userProfilesByEmail`.
2. Memoize Fan Chat sorted comments and ad list items by event id plus comment revision.
3. Add a guard before restarting following pickup realtime when the tracked id set has not changed.
4. Add diagnostics for DM unread RPC fallback and treat fallback as a scale warning.
5. Replace business dashboard metric refreshes that only need counts with preview/count loaders instead of full comment/vibe loads.
