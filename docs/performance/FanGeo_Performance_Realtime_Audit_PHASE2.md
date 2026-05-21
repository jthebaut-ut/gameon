# FanGeo Performance and Realtime Audit - Phase 2

Date: May 21, 2026

Scope: implementation-level static audit of realtime coverage, listener lifecycle, SwiftUI/main-thread hotspots, refresh storms, Discover performance, database hot paths, and the Appearance/Light-mode lifecycle crash chain.

Constraint: report only. No app behavior, UI, architecture, code, or SQL fixes were applied.

## Executive severity summary

### P0 - critical

- Realtime coverage mismatch: iOS subscribes to `conversation_read_state`, `venue_event_vibes`, `venue_event_predictions`, `venue_event_interests`, and `pickup_games`, but tracked migrations only add `direct_messages`, `friendships`, `pickup_game_requests`, `user_profiles`, `venue_event_comments`, and `venue_event_comment_reactions` to `supabase_realtime`.
- Over-broad realtime listeners: DM inbox listens to all visible `direct_messages` and all `conversation_read_state`; Fan Chat reactions listen table-wide to `venue_event_comment_reactions`; friendships listen table-wide to `friendships`.
- High-traffic refresh storms: Fan Chat comment insert and reaction/vibe events repeatedly debounce into REST reads and aggregate reloads, invalidating large published dictionaries.
- Discover map fallback path can still run O(venues * events) filtering on the main actor when snapshot clusters are empty or stale.
- Appearance crash likely chain: Settings writes appearance `@AppStorage` -> root `.preferredColorScheme` flips -> preserved offscreen Discover `Map` and selected venue preview rebuild -> material/ad/window tasks continue during trait transition.

### P1 - high

- Venue preview recomputes game lists, stable IDs, prefetch keys, image prefetch, social prefetch, and full game cards inside a large SwiftUI view.
- Prediction summaries fetch all prediction rows per visible event and aggregate client-side.
- Going/attendance remote freshness is not truly realtime for fan users unless `venue_event_interests` publication exists in production outside migrations.
- Pickup following realtime restarts every sync, even for identical game ID sets.
- Venue owner analytics realtime can debounce one engagement event into `loadInterestCountsForVenueEventIDs` plus `loadComments` and `loadVibes` for every tracked event.

### P2 - polish

- DEBUG logging is dense enough to distort performance measurements on physical devices.
- Fan Chat comment view sorts and rebuilds ad-injected list items from computed properties.
- Calendar dots and calendar list still have several activation paths that can burst refresh work.

## 1. Realtime coverage audit

### Supabase realtime publication coverage found in migrations

Covered by tracked migrations:

- `direct_messages`: `supabase/migrations/20260622_0001_direct_messages_realtime_publication.sql`.
- `friendships`: `supabase/migrations/20260619_0001_friendships_decline_clear_realtime.sql`.
- `pickup_game_requests`: `supabase/migrations/20260627_0001_pickup_game_requests_realtime_publication.sql`.
- `user_profiles`: `supabase/migrations/20260729_0001_user_profiles_active_session.sql`.
- `venue_event_comments`: `supabase/migrations/20260731_0001_venue_event_comments_realtime_publication.sql`.
- `venue_event_comment_reactions`: `supabase/migrations/20260731_0029_venue_event_comment_reactions_realtime.sql`, plus `REPLICA IDENTITY FULL`.

Not covered by tracked publication migrations, but subscribed in iOS:

- `conversation_read_state`
- `venue_event_vibes`
- `venue_event_predictions`
- `venue_event_interests`
- `pickup_games`

Probable failure mode: subscriptions may connect successfully but never receive changes for unpublished tables, so the app silently depends on REST fallback/reconcile paths. This directly threatens the targets for unread badge updates, reaction/vibe updates, prediction aggregate refreshes, venue owner analytics, and pickup following cards.

### iOS subscriptions by table

`direct_messages`

- `DirectChatService.directMessagesInsertChannel(conversationId:)` creates topic `dm-thread-<conversation>` and filters `direct_messages` with `conversation_id = eq.<uuid>` at `GameOn/DirectChatService.swift:226-235`.
- `DirectChatView.runRealtimeSubscriptionAttempt(...)` subscribes with a 15 second timeout, applies inserts, and removes the channel on teardown at `GameOn/DirectChatView.swift:494-611`.
- `ChatViewModel.runInboxRealtimeListenerLoop()` also subscribes to `direct_messages` INSERTs with no filter at `GameOn/ChatViewModel.swift:497-511`.
- Risk: thread listener is correctly filtered; inbox listener is table-wide/RLS-wide and can wake for every row visible to the user. The code explicitly logs `inboxFilter=none` at `GameOn/ChatViewModel.swift:512-515`.

`conversation_read_state`

- `ChatViewModel.runInboxRealtimeListenerLoop()` subscribes to `conversation_read_state` AnyAction with no filter at `GameOn/ChatViewModel.swift:501-505`.
- Events call `scheduleDebouncedUnreadDirectMessageRPCRefresh()` at `GameOn/ChatViewModel.swift:563-570`.
- Publication gap: no tracked `ALTER PUBLICATION` migration found.
- Risk: unread badge read-state realtime likely does not work unless configured manually in production; if it does work, it is broad and every visible read cursor change triggers a badge recount debounce.

`friendships`

- `ChatViewModel.runFriendshipsRealtimeListenerLoop()` subscribes to all `friendships` AnyAction with no filter at `GameOn/ChatViewModel.swift:846-853`.
- Events debounce into `scheduleFriendRequestRealtimeRefresh()` at `GameOn/ChatViewModel.swift:864-874` and `GameOn/ChatViewModel.swift:905-914`.
- Publication exists.
- Risk: broad listener. RLS may scope rows, but every visible friendship insert/update/delete wakes the listener and causes request refresh.

`venue_event_comments`

- App-level preview listener: `runFanChatAppLevelRealtimeLoop(eventIDs:)` subscribes to `venue_event_comments` INSERT with `IN (venue_event_id)` chunks at `GameOn/MapViewModel+CommentsAndVibes.swift:645-663`.
- Sheet listener: `startVenueEventCommentsRealtime(for:)` subscribes to one `venue_event_comments` INSERT filtered by `venue_event_id = eq.<uuid>` at `GameOn/MapViewModel+CommentsAndVibes.swift:1211-1267`.
- Venue owner analytics listener: `runVenueOwnerAnalyticsRealtimeLoop(trackedEventIDs:)` subscribes AnyAction with `IN (venue_event_id)` at `GameOn/MapViewModel+VenueOwnerAnalyticsRealtime.swift:71-87`.
- Publication exists.
- Risk: duplicate app-level plus sheet-level listeners can both see a comment for the active event. Dedupe exists, but both paths can schedule count/profile/reaction work.

`venue_event_comment_reactions`

- `startVenueEventCommentReactionsRealtime(for:)` subscribes to INSERT, UPDATE, and DELETE with no Postgres filter at `GameOn/MapViewModel+CommentsAndVibes.swift:1561-1589`.
- Reactions are then mapped back to visible comment IDs in `handleFanChatReactionRealtimeEvent(...)` at `GameOn/MapViewModel+CommentsAndVibes.swift:1690-1706`.
- Publication exists and replica identity is full.
- Risk: table-wide listener. Every visible reaction row allowed by RLS can wake every open Fan Chat reaction listener. This is a high-risk storm path during large events.

`venue_event_vibes`

- App-level listener: `runFanChatAppLevelRealtimeLoop(eventIDs:)` subscribes AnyAction with `IN (venue_event_id)` at `GameOn/MapViewModel+CommentsAndVibes.swift:664-673`.
- Venue owner analytics listener: AnyAction with same `IN` filter at `GameOn/MapViewModel+VenueOwnerAnalyticsRealtime.swift:88-93`.
- Publication gap: no tracked `ALTER PUBLICATION` migration found.
- Risk: crowd reaction/vibe realtime probably falls back to REST unless production is manually configured.

`venue_event_interests`

- Venue owner analytics listener subscribes AnyAction with `IN (venue_event_id)` at `GameOn/MapViewModel+VenueOwnerAnalyticsRealtime.swift:76-81`.
- No fan-facing realtime listener found for remote Going count updates.
- Publication gap: no tracked `ALTER PUBLICATION` migration found.
- Risk: fan users get optimistic local Going, but other devices are eventually consistent, not guaranteed under 1 second.

`venue_event_predictions`

- `startVenueEventPredictionRealtime(for:)` subscribes AnyAction filtered by `venue_event_id = eq.<uuid>` at `GameOn/MapViewModel+VenueEventPredictions.swift:38-63`.
- Events debounce into `scheduleVenueEventPredictionRealtimeRefresh(eventID:)` at `GameOn/MapViewModel+VenueEventPredictions.swift:101-114`.
- Publication gap: no tracked `ALTER PUBLICATION` migration found.
- Risk: prediction realtime path may never fire outside manually configured DB publication.

`pickup_game_requests`

- Organizer badge listener subscribes AnyAction with `IN (pickup_game_id)` at `GameOn/MapViewModel+PickupGameRequests.swift:866-879`.
- Following requester listener subscribes AnyAction filtered by `requester_user_id = eq.<user>` at `GameOn/MapViewModel+FollowingPickupActivity.swift:206-218`.
- Publication exists.
- Risk: subscription restart is aggressive. `syncPickupJoinRequestBadgeRealtimeSubscription(...)` always calls `stopPickupJoinRequestBadgeRealtime()` before starting at `GameOn/MapViewModel+PickupGameRequests.swift:831-843`. `syncFollowingPickupRealtimeSubscriptionIfNeeded(...)` does the same at `GameOn/MapViewModel+FollowingPickupActivity.swift:190-203`.

`pickup_games`

- Following requester listener subscribes AnyAction with `IN (id)` at `GameOn/MapViewModel+FollowingPickupActivity.swift:220-226`.
- Publication gap: no tracked `ALTER PUBLICATION` migration found.
- Risk: following pickup cards may miss game updates unless production publication is configured manually.

### Duplicate/listener lifecycle findings

- `ChatViewModel.ensureSignedInSocialRealtimeIfNeeded()` starts inbox and friendships listeners and intentionally does not stop on tab switches at `GameOn/ChatViewModel.swift:231-242`. This is correct for badges, but listeners survive outside Chat.
- `ChatViewModel.scheduleEnsureSocialRealtimeAfterForeground()` stops and restarts both listeners after foreground at `GameOn/ChatViewModel.swift:244-272`. This prevents stale channels but can cause reconnect bursts if foreground events are noisy.
- `DirectChatView.runRealtimeSubscription()` tears down and restarts when reconnecting at `GameOn/DirectChatView.swift:616-658`. Guarding is present, but any view lifecycle duplication around the presenter can create additional subscribe attempts.
- `startVenueEventCommentsRealtime(for:)` stops other sheet listeners first at `GameOn/MapViewModel+CommentsAndVibes.swift:1211-1214`, which prevents multiple sheet listeners. App-level listener remains separate.
- `syncVenueEventCommentReactionsRealtime(for:)` avoids duplicate reaction subscription if task and channel exist at `GameOn/MapViewModel+CommentsAndVibes.swift:1517-1523`, but `startVenueEventCommentReactionsRealtime(for:)` first stops and restarts at `GameOn/MapViewModel+CommentsAndVibes.swift:1561-1563`.
- `VenueEventPredictionModule.body` starts prediction realtime in `.task(id: venueEventID)` and stops on disappear at `GameOn/VenueEventPredictionsView.swift:122-173`. If the view is preserved offscreen instead of disappearing, realtime may remain alive.

## 2. Main-thread and SwiftUI hotspots

### Discover map O(n²) path

`MapViewModel+EventsAndSchedule.swift`

- `matchingEventsForDiscoverFilter(bar:)` scans `events` for each bar at `GameOn/MapViewModel+EventsAndSchedule.swift:406-423`.
- `shouldShowVenueOnMap(_:)` calls `selectedDayEventsForMap(...)` two to three times per venue at `GameOn/MapViewModel+EventsAndSchedule.swift:429-447`.
- `mapVisibleBars` filters every `bar` through `shouldShowVenueOnMap` at `GameOn/MapViewModel+EventsAndSchedule.swift:450-452`.
- `filteredBars` filters every `bar` through `matchingEventsForDiscoverFilter` at `GameOn/MapViewModel+EventsAndSchedule.swift:454-457`.
- `selectedDayEventsForMap(_:)` scans all `events` per venue at `GameOn/MapViewModel+EventsAndSchedule.swift:487-495`.

Probable scaling failure: with 300 venues and 2,000 events, a single `mapVisibleBars` read can perform hundreds of thousands of date/title checks on the main actor. `DiscoverScreen` reads cluster counts and empty hints in body-adjacent computed properties, so a single state change can re-run this path.

### Discover map snapshot still repeats scans

`DiscoverMapRenderSnapshot.swift`

- Detached builder is better than main actor, but `build(input:)` calls `shouldShowVenueOnMap(...)` for every bar at `GameOn/DiscoverMapRenderSnapshot.swift:95-101`.
- `shouldShowVenueOnMap(...)` calls `selectedDayEvents(...)` twice at `GameOn/DiscoverMapRenderSnapshot.swift:210-216`.
- Pin construction then calls `selectedDayEvents(...)` again for each visible bar at `GameOn/DiscoverMapRenderSnapshot.swift:107-130`.
- `selectedDayEvents(...)` scans all input events at `GameOn/DiscoverMapRenderSnapshot.swift:230-247`.
- `cachedVenueEventRow(...)` scans all `venueEventRows` for each live-now game at `GameOn/DiscoverMapRenderSnapshot.swift:345-356`.

Probable scaling failure: detached work protects the main actor but still burns CPU and can delay snapshot publish under heavy schedule data.

### Main-actor fallback cluster path

- `DiscoverScreen.discoverVenueClustersForMap` uses snapshot clusters when available, otherwise falls back to `viewModel.clusteredBars()` at `GameOn/DiscoverScreen.swift:1240-1252`.
- `clusteredBars()` immediately reads `mapVisibleBars` at `GameOn/MapViewModel+GeocodingAndMapBounds.swift:183-185`, returning to the O(venues * events) main-actor path.
- `mapLayer` computes both pickup and venue clusters before rendering the `Map` at `GameOn/DiscoverScreen.swift:1288-1298`.

Root cause: the fallback is safe for correctness but dangerous for stutter. If snapshot is empty during selected-date or appearance rebuild, Map body can trigger expensive synchronous filtering.

### Selected venue preview recomputation

`DiscoverScreen.venuePreviewCard(_:)`

- Recomputes `canonicalBarForDiscover`, `gamesForVenuePreview`, selected event, visible social prefetch events, and a prefetch key every render at `GameOn/DiscoverScreen.swift:3226-3242`.
- Runs image and social prefetch in `.task(id: visibleSocialPrefetchKey)` at `GameOn/DiscoverScreen.swift:3291-3295`.
- Renders full game cards in `gamesListSection(...)` at `GameOn/DiscoverScreen.swift:3453-3508`.
- Computes duplicate-aware stable IDs each render at `GameOn/DiscoverScreen.swift:3510-3528`.
- `venuePreviewNoGamesForSelectedDayView(...)` computes next game by scanning/sorting future rows at `GameOn/DiscoverScreen.swift:3531-3575` and `GameOn/DiscoverScreen.swift:3607-3663`.

`MapViewModel.gamesForVenuePreview(...)`

- Builds a title allowlist by scanning `venueEventRows` at `GameOn/MapViewModel+EventsAndSchedule.swift:717-740`.
- Then scans all `events` for date/sport/title matches at `GameOn/MapViewModel+EventsAndSchedule.swift:744-763`.

Probable scaling failure: opening a venue preview during a live match with many visible events causes immediate map state reads, event scans, image prefetch, Fan Updates prefetch, prediction summary prefetch, and card rendering in one SwiftUI update.

### Fan Chat sheet body churn

`VenueEventCommentsView`

- `comments` sorts the full event thread every time it is read at `GameOn/VenueEventCommentsView.swift:141-149`.
- `venueCommentsListItems` maps or ad-injects comments every time it is read at `GameOn/VenueEventCommentsView.swift:151-156`.
- `latestCommentId` and `latestComment` read `comments` again at `GameOn/VenueEventCommentsView.swift:158-164`.
- The body uses outer `GeometryReader`, inner `GeometryReader`, coordinate space, and `PreferenceKey` updates at `GameOn/VenueEventCommentsView.swift:186-205`.
- `onChange(of: latestCommentId)` can read sorted comments again at `GameOn/VenueEventCommentsView.swift:223-225`.

Probable scaling failure: at 10k comments this is not viable. Even at hundreds of comments, every realtime insert, reaction update, ad insertion toggle, or scroll geometry update can re-sort/rebuild the list.

### Prediction module churn

`VenueEventPredictionsView`

- `userPredictionLoadToken` includes aggregate summary fields at `GameOn/VenueEventPredictionsView.swift:176-178`.
- `.task(id: userPredictionLoadToken)` reloads the user prediction whenever summary mode/count changes at `GameOn/VenueEventPredictionsView.swift:122-126`.
- The prediction card uses material, gradient, overlays, and shadow at `GameOn/VenueEventPredictionsView.swift:180-218`.
- Debug logs emit many layout lines on appear at `GameOn/VenueEventPredictionsView.swift:137-168`.

Root cause: aggregate refresh should not necessarily reload the current user's prediction. This can create redundant network reads and view churn during prediction spikes.

### Large `@Published` invalidation surface

`MapViewModel`

- `venueEventInterestCounts` publishes and schedules map snapshot rebuilds at `GameOn/MapViewModel.swift:173-178`.
- `bars` publishes and schedules map snapshot rebuilds at `GameOn/MapViewModel.swift:393-397`.
- `venueEventRows` publishes, schedules Fan Chat app-level realtime, and schedules map snapshot rebuilds at `GameOn/MapViewModel.swift:417-421`.
- `FanUpdatesRealtimeStore` publishes comments, vibes, preview counts, previews, reaction counts, and viewer reaction sets at `GameOn/FanUpdatesRealtimeStore.swift:5-17`.

Root cause: social/realtime changes can invalidate Discover, venue cards, map annotations, Fan Chat, and prediction-adjacent UI through shared observable state.

### Ad and UIKit layout churn

`AdaptiveBannerView`

- `updateUIView(...)` calls `container.layoutIfNeeded()` when ad size or slot size changes at `GameOn/AdaptiveBannerView.swift:141-150`.
- It loads/reloads the banner after size changes at `GameOn/AdaptiveBannerView.swift:164-179`.
- `loadBannerIfNeeded(...)` assigns `rootViewController` from current top view controller at `GameOn/AdaptiveBannerView.swift:182-196`.

Root cause: trait/size changes during an Appearance flip can force synchronous UIKit layout and AdMob root-controller updates while SwiftUI is rebuilding preserved tabs.

## 3. Refresh storm analysis

### Fan Chat comment insert chain

Chain:

1. `venue_event_comments` realtime insert arrives in app-level listener.
2. `applyFanChatAppLevelRealtimeInsert(...)` patches comments/previews at `GameOn/MapViewModel+CommentsAndVibes.swift:787-857`.
3. It always calls `scheduleFanChatCommentCountServerReconcile(for:)` at `GameOn/MapViewModel+CommentsAndVibes.swift:852`.
4. Reconcile sleeps for `FanChatAppLevelRealtimeConfig.countReconcileDebounceNs`, then calls exact count query at `GameOn/MapViewModel+CommentsAndVibes.swift:859-875`.
5. Exact count query is `.select("id", head: true, count: .exact)` on `venue_event_comments` at `GameOn/MapViewModel+CommentsAndVibes.swift:2599-2618`.

Storm risk: every burst of comments per event collapses to one debounce, but across many events this becomes many exact count queries. Exact counts are costly under 10k comments unless strongly indexed and cached.

### Fan Chat sheet reconnect/fallback chain

Chain:

1. Sheet listener subscribes at `GameOn/MapViewModel+CommentsAndVibes.swift:1211-1279`.
2. On subscribe, it schedules a receiver refresh burst at `GameOn/MapViewModel+CommentsAndVibes.swift:1281`.
3. `scheduleFanChatReceiverRefreshBurst(...)` waits, then can poll up to three times if realtime is not healthy at `GameOn/MapViewModel+CommentsAndVibes.swift:1052-1104`.
4. Each fallback calls `fetchRecentVenueEventCommentsForRealtimeFallback(...)`, then may load reactions/report flags through refresh paths at `GameOn/MapViewModel+CommentsAndVibes.swift:962-1008`.

Storm risk: a reconnect during major traffic can start fallback polling while realtime events are also arriving. In-flight guards exist, but profile/reaction/exact count work can still stack around the same event.

### Fan Chat reaction chain

Chain:

1. Any table-wide `venue_event_comment_reactions` event arrives at `GameOn/MapViewModel+CommentsAndVibes.swift:1575-1608`.
2. It decodes the row and calls `handleFanChatReactionRealtimeEvent(...)`.
3. Per-comment debounce sleeps, then calls `loadSingleCommentReactionSummary(...)` at `GameOn/MapViewModel+CommentsAndVibes.swift:1690-1706`.
4. `loadSingleCommentReactionSummary(...)` fetches every reaction row for that comment and aggregates client-side at `GameOn/MapViewModel+CommentsAndVibes.swift:1709-1747`.

Storm risk: for a hot comment receiving many reactions, debounce helps. For many hot comments, each comment causes a separate REST query. Because realtime is table-wide, unrelated visible rows can wake listeners too.

### Fan Chat reaction fallback polling

- If reaction realtime is not ready, `startVenueEventCommentReactionFallbackReadinessWatchIfNeeded(...)` polls `loadCommentReactions(for:)` repeatedly at `GameOn/MapViewModel+CommentsAndVibes.swift:1526-1558`.
- `loadCommentReactions(for:)` chunks visible comment IDs and loads all reactions for those comments at `GameOn/MapViewModel+CommentsAndVibes.swift:1768-1859`.

Storm risk: if realtime publication or subscription fails, every open sheet can poll full visible reaction summaries.

### Vibe/reaction app-level chain

- App-level vibe events call `scheduleCrowdReactionVibeRealtimeRefresh(eventIDs:)` at `GameOn/MapViewModel+CommentsAndVibes.swift:720-739`.
- After 300 ms, it calls `loadVibes(for:)` for every tracked event in a task group at `GameOn/MapViewModel+CommentsAndVibes.swift:733-750`.

Storm risk: one vibe event can refresh all tracked event vibes, not just the changed event, because payload handling does not decode/filter to the specific changed event in `consumeCrowdReactionAppLevelRealtimeStream(...)`.

### Prediction realtime chain

- `venue_event_predictions` event arrives at `GameOn/MapViewModel+VenueEventPredictions.swift:61-69`.
- It debounces 250 ms at `GameOn/MapViewModel+VenueEventPredictions.swift:101-114`.
- It invalidates summary cache and calls `loadVenueEventPredictionSummaries(eventIDs: [eventID], forceRefresh: true)` at `GameOn/MapViewModel+VenueEventPredictions.swift:17-25`.
- `VenueEventPredictionService.fetchPredictionSummary(...)` fetches all rows for the event and aggregates client-side at `GameOn/VenueEventPredictionService.swift:132-157` and `GameOn/VenueEventPredictionService.swift:274-317`.

Storm risk: for large prediction counts, every realtime burst causes full event-row download and CPU aggregation.

### Going chain

- `setVenueEventInterest(...)` writes insert/delete at `GameOn/MapViewModel+VenueEventSocial.swift:796-823`.
- On success it applies local state again and can trigger `loadGoingUserProfiles`, following derived snapshots, deferred visible interest reload, following reconcile, XP award, and game reminder scheduling at `GameOn/MapViewModel+VenueEventSocial.swift:855-899`.
- `scheduleDeferredVisibleVenueEventInterestsReload()` sleeps 2 seconds then calls `loadVisibleVenueEventInterests(...)` at `GameOn/MapViewModel+VenueEventSocial.swift:727-731`.
- `loadVisibleVenueEventInterests(...)` queries all visible event interest rows in chunks and computes counts client-side at `GameOn/MapViewModel+VenueEventSocial.swift:1350-1467`.

Storm risk: local Going feels instant, but remote count refresh can become a broad visible-event interest reload, downloading raw user emails.

### Venue owner analytics chain

- Any interest/comment/vibe realtime event for tracked owned events calls `scheduleDebouncedVenueOwnerAnalyticsRefresh(...)` at `GameOn/MapViewModel+VenueOwnerAnalyticsRealtime.swift:117-123`.
- The debounced refresh calls `loadInterestCountsForVenueEventIDs`, then loops every tracked event and calls `loadComments` and `loadVibes` at `GameOn/MapViewModel+VenueOwnerAnalyticsRealtime.swift:44-51`.

Storm risk: one event can cause N event-level REST loads for owner analytics.

### Pickup badge/following chain

- Organizer `pickup_game_requests` event debounces into badge count plus organizer summaries/withdrawn/approved joiners at `GameOn/MapViewModel+PickupGameRequests.swift:847-863`.
- Following requester events debounce into `loadMyPickupGameJoinRequestsForFollowing()` at `GameOn/MapViewModel+FollowingPickupActivity.swift:177-187`.

Storm risk: counts are correct but broad refreshes can fire during heavy join request traffic.

## 4. Discover performance deep audit

### Annotation generation

Exact hot paths:

- `DiscoverScreen.mapLayer` computes pickup and venue clusters before `Map` construction at `GameOn/DiscoverScreen.swift:1288-1298`.
- `discoverPickupClustersForMap` filters all pickup rows for valid coordinates every body read at `GameOn/DiscoverScreen.swift:1232-1238`.
- `discoverVenueClustersForMap` falls back to main-actor `clusteredBars()` when snapshot clusters are empty at `GameOn/DiscoverScreen.swift:1240-1252`.
- `Map` `ForEach(venueClusters)` and `ForEach(pickupClusters)` rebuild annotations at `GameOn/DiscoverScreen.swift:1303-1330`.
- Camera end events debounce 400 ms and call `loadVenuesFromSupabase()` at `GameOn/DiscoverScreen.swift:1346-1368`.

Likely failure at scale: panning/zooming can cause cluster recompute, map annotation rebuild, and eventual venue reload. Snapshot coalescing helps, but fallback makes first/stale frames risky.

### Selected venue preview rendering

Exact hot paths:

- `venuePreviewCard(_:)`: `GameOn/DiscoverScreen.swift:3226-3306`.
- `gamesListSection(...)`: `GameOn/DiscoverScreen.swift:3453-3508`.
- `venuePreviewStableGameItems(...)`: `GameOn/DiscoverScreen.swift:3510-3528`.
- `gamesForVenuePreview(...)`: `GameOn/MapViewModel+EventsAndSchedule.swift:744-763`.
- `cachedVenueEventID(...)` can scan `venueEventRows` on cache miss at `GameOn/MapViewModel+VenueEventSocial.swift:957-969`.

Likely failure at scale: preview open time exceeds 300 ms when event arrays are large and social/prediction prefetch starts immediately.

### Image prefetch

- Preview `.task(id: visibleSocialPrefetchKey)` calls `prefetchDiscoverVenueImages(for:)` at `GameOn/DiscoverScreen.swift:3291-3293`.
- `DiscoverMapImageCache.prefetch(urls:)` loads up to 8 URLs sequentially at `GameOn/DiscoverMapImageCache.swift:69-73`.
- `DiscoverCachedRemoteImage` starts a `.task(id: url?.absoluteString)` for each hero/card image at `GameOn/DiscoverMapImageCache.swift:107-129`.

Risk: in-flight cache coalescing is good, but selected preview changes can still start image tasks during map and appearance rebuilds.

### Fan update/social prefetch

- `prefetchVisibleVenueSocialData(...)` resolves venue event IDs for each visible preview event and calls `prefetchVisibleDiscoverSocialData(...)` at `GameOn/DiscoverScreen.swift:929-950`.
- Fan Updates preview batch loads all visible comments for event IDs in one query and computes counts/previews client-side at `GameOn/MapViewModel+CommentsAndVibes.swift:2562-2597`.
- Single-event preview loads exact count and latest rows concurrently at `GameOn/MapViewModel+CommentsAndVibes.swift:2544-2560`.

Risk: preview open can create exact count queries and multi-event comment batch loads while the card is rendering.

### Prediction prefetch

- Visible prediction event IDs are passed through preview social prefetch at `GameOn/DiscoverScreen.swift:941-950`.
- `prefetchVenuePredictionSummariesForVisibleBatch(eventIDs:)` calls `loadVenueEventPredictionSummaries(...)` at `GameOn/MapViewModel+VenueEventPredictions.swift:28-36`.
- `fetchPredictionSummary(...)` downloads all prediction rows for those event IDs at `GameOn/VenueEventPredictionService.swift:132-139`.

Risk: visible venue previews with multiple prediction modules can download all prediction rows repeatedly after cache invalidation.

### Calendar dots and date switching

- Discover date change starts selected-day refresh at `GameOn/MapViewModel+EventsAndSchedule.swift:593-640`.
- Sport change clears selected venue and schedules selected-day refresh at `GameOn/MapViewModel+EventsAndSchedule.swift:677-698`.
- Calendar tab activation clears list cache, loads dots, loads games, and refreshes pickup sources at `GameOn/MapViewModel+EventsAndSchedule.swift:220-233`.
- `fetchVenueEventRowsForDiscover(...)` performs three serial chunk families over `venueIds`, `ownerEmails`, and `venueNames` at `GameOn/MapViewModel+VenueAndGameData.swift:1654-1699`.

Likely failure at scale: date/sport changes can still be bottlenecked by serial PostgREST chunks, especially with legacy owner/name matching.

## 5. Database hot paths

### 1k concurrent users

Likely stress points:

- DM inbox unfiltered realtime plus unread recounts.
- Fan Chat comment app-level listeners over up to many visible event IDs.
- Exact count queries on comments after bursts.
- Pickup discovery queries with 400-row limit and client filtering.

Exact query risks:

- `DirectChatService.fetchUnreadDirectMessageCountFanOut(...)` is O(conversations) if RPC fails at `GameOn/DirectChatService.swift:255-294`.
- `DirectChatService.fetchMyConversationIds(...)` uses `.or(user_a_id.eq...,user_b_id.eq...)` at `GameOn/DirectChatService.swift:303-311`; tracked migrations show RLS but no visible participant indexes for `direct_conversations`.
- `pickup_games` Discover query filters `game_start_at`, `remove_after_at OR null`, `status`, `is_visible`, and optional sport, then client-filters rows at `GameOn/MapViewModel+PickupGames.swift:293-343`.

### 10k comments

Likely stress points:

- `loadFanUpdatesExactVisibleCommentCount(...)` uses exact count on `venue_event_comments` at `GameOn/MapViewModel+CommentsAndVibes.swift:2599-2618`.
- `loadFanUpdatesPreviewBatch(...)` downloads all visible comment rows for all event IDs before grouping in memory at `GameOn/MapViewModel+CommentsAndVibes.swift:2562-2597`.
- `VenueEventCommentsView.comments` sorts full in-memory comment arrays every render at `GameOn/VenueEventCommentsView.swift:141-149`.
- `loadCommentReactions(for:)` downloads all reactions for visible comment IDs and aggregates client-side at `GameOn/MapViewModel+CommentsAndVibes.swift:1768-1859`.

Existing indexes:

- `idx_venue_event_comments_event_created_id_desc` exists.
- `idx_venue_event_comments_not_hidden` exists but uses `(venue_event_id, created_at DESC)` and `WHERE is_moderation_hidden = false`.

Likely missing/weak:

- Visible keyset partial index with `(venue_event_id, created_at DESC, id DESC) WHERE is_moderation_hidden IS NOT TRUE`.
- Server RPC for preview counts and latest comments grouped by `venue_event_id`.

### Large prediction counts

Exact hot path:

- `VenueEventPredictionService.fetchPredictionSummary(...)` selects all rows by `venue_event_id IN (...)` at `GameOn/VenueEventPredictionService.swift:132-139`.
- `buildSummary(...)` filters rows three times by prediction type at `GameOn/VenueEventPredictionService.swift:274-293`.
- Avatar load then queries recent participant profiles by user ID at `GameOn/VenueEventPredictionService.swift:241-263`.

Existing indexes:

- `idx_venue_event_predictions_event_type` exists on `(venue_event_id, prediction_type)`.
- `idx_venue_event_predictions_user` exists on `(user_id, updated_at DESC)`.

Likely missing:

- Unique/index support for `(venue_event_id, user_id, prediction_type)` if not already created by a constraint outside inspected lines.
- SQL aggregate RPC returning winner counts, first-score counts, score mode/top scores, and recent avatar IDs without downloading all prediction rows.

### Going/attendance

Exact hot path:

- `loadVisibleVenueEventInterests(...)` queries `venue_event_interests` by visible IDs in chunks of 90 and downloads `venue_event_id,user_email` rows at `GameOn/MapViewModel+VenueEventSocial.swift:1350-1467`.

Existing indexes:

- `idx_venue_event_interests_venue_event_id`.
- `idx_venue_event_interests_user_email_venue_event_id`.
- `idx_venue_event_interests_event_email`.

Risk:

- Raw email rows are fetched for counts. At major events, this should be count/grouped RPC, not row download.
- Publication gap means remote Going counts are not guaranteed realtime.

### RLS speed risks

- `venue_event_comment_reactions` RLS checks `EXISTS` against `venue_event_comments` for every reaction row at `supabase/migrations/20260731_0027_venue_event_comment_reactions.sql:86-128`. This is correct for visibility but costly under table-wide realtime and reaction summary reads.
- `direct_conversations` and `conversation_read_state` RLS exists in `20260731_0009_private_dm_rls_report_validation.sql`, but no visible participant indexes were found in migrations. Participant lookup and unread fallback can degrade.
- `user_profiles` is published to realtime for active session tracking. This is risky if any broad profile select policy exists; a narrow session table would be safer and lighter.

## 6. Appearance/lifecycle crash root cause

### Exact likely crash chain

1. User taps Light in `FanGeoAppearanceSelectionView`; `selectionRaw = preference.rawValue` writes `@AppStorage` immediately at `GameOn/SettingsScreen.swift:3993-3999`.
2. `FanSpotApp` observes `@AppStorage(FanGeoAppearancePreference.appStorageKey)` and reapplies `.preferredColorScheme(appearancePreference.colorScheme)` to `ContentView` at `GameOn/FanSpotApp.swift:5-35`.
3. `MainTabView` preserves mounted tabs with `.opacity(isSelected ? 1 : 0)` rather than unmounting at `GameOn/MainTabView.swift:601-628`.
4. Discover is always mounted at launch and remains mounted offscreen at `GameOn/MainTabView.swift:23-24`, `GameOn/MainTabView.swift:102-108`, and `GameOn/MainTabView.swift:165-180`.
5. Root color-scheme change rebuilds offscreen `DiscoverScreen` including `GeometryReader`, `Map`, annotations, material overlays, selected venue preview, AdMob banner, and active `.task` work.
6. If `selectedBar` is non-nil, `discoverBottomLeadingCard` renders `venuePreviewCard(selectedBar)` at `GameOn/DiscoverScreen.swift:2010-2015`.
7. `venuePreviewCard` starts/continues image/social prefetch tasks, material background rebuild, full game card rendering, and possibly prediction realtime at `GameOn/DiscoverScreen.swift:3226-3306`.
8. If a prediction module is visible, `.task(id: venueEventID)` and `.onDisappear` start/stop realtime asynchronously at `GameOn/VenueEventPredictionsView.swift:122-173`.
9. If ads are mounted, `AdaptiveBannerView.updateUIView(...)` can synchronously `layoutIfNeeded()` and re-resolve `rootViewController` during the same trait transition at `GameOn/AdaptiveBannerView.swift:141-196`.
10. If public profile overlay is open, `PublicProfileOverlayWindowPresenter` has a separate key `UIWindow` with `overrideUserInterfaceStyle` set only at creation at `GameOn/PublicProfileOverlayWindowPresenter.swift:79-87`.

Most probable crash class: SwiftUI/MapKit/UIKit trait transition invalidation while preserved offscreen views and UIKit-owned ad/window views are simultaneously rebuilding.

### High-risk views/functions

- `FanSpotApp.body`: root `.preferredColorScheme(...)` at `GameOn/FanSpotApp.swift:20-30`.
- `FanGeoAppearanceSelectionView.body`: immediate AppStorage write at `GameOn/SettingsScreen.swift:3993-3999`.
- `MainTabView.preservedRoot(...)`: offscreen preservation via opacity at `GameOn/MainTabView.swift:618-628`.
- `DiscoverScreen.discoverScreenCore`: root `GeometryReader` and stacked overlays at `GameOn/DiscoverScreen.swift:520-545`.
- `DiscoverScreen.mapLayer`: MapKit annotations and camera handlers at `GameOn/DiscoverScreen.swift:1288-1369`.
- `DiscoverScreen.venuePreviewCard(_:)`: selected venue preview material/scroll/task surface at `GameOn/DiscoverScreen.swift:3226-3306`.
- `VenueEventPredictionModule.body`: realtime task start/stop and material card at `GameOn/VenueEventPredictionsView.swift:122-218`.
- `AdaptiveBannerView.Coordinator.update(...)`: synchronous layout and ad load on trait/size update at `GameOn/AdaptiveBannerView.swift:126-180`.
- `PublicProfileOverlayWindowPresenter.present(...)`: custom UIWindow trait state at `GameOn/PublicProfileOverlayWindowPresenter.swift:49-93`.

### Race-condition candidates

- `.preferredColorScheme` flips while `mapVenueReloadTask` is sleeping and later calls `loadVenuesFromSupabase()` at `GameOn/DiscoverScreen.swift:1351-1367`.
- `.preferredColorScheme` flips while selected venue preview `.task(id: visibleSocialPrefetchKey)` is prefetching image/social data at `GameOn/DiscoverScreen.swift:3291-3295`.
- `.preferredColorScheme` flips while prediction `.task(id: venueEventID)` starts realtime and `onDisappear` asynchronously stops it at `GameOn/VenueEventPredictionsView.swift:127-173`.
- `.preferredColorScheme` flips while Fan Chat sheet has `GeometryReader`/PreferenceKey scroll tracking active at `GameOn/VenueEventCommentsView.swift:186-205`.
- `.preferredColorScheme` flips while AdMob banner or native ad host is resolving root view controller or laying out UIKit views at `GameOn/AdaptiveBannerView.swift:182-196` and `GameOn/CompactNativeAdCard.swift:210-235`.
- `.preferredColorScheme` flips while custom public profile overlay window remains key and uses stale `overrideUserInterfaceStyle`.

### Async tasks that may survive teardown

- `DiscoverScreen.mapVenueReloadTask` sleeps 400 ms after camera end, then loads venues at `GameOn/DiscoverScreen.swift:1351-1367`.
- `venuePreviewCard` prefetch task runs off selected preview key at `GameOn/DiscoverScreen.swift:3291-3295`.
- Fan Chat app-level realtime task survives outside the sheet and is tied to loaded venue events at `GameOn/MapViewModel+CommentsAndVibes.swift:621-624`.
- Prediction realtime task is stored in `venueEventPredictionRealtimeTasks` at `GameOn/MapViewModel+VenueEventPredictions.swift:50-85`.
- DM and friendship listeners intentionally survive tab changes at `GameOn/ChatViewModel.swift:231-242`.
- `LaunchWarmPreloadCoordinator` and foreground deferred batch can run while tabs are preserved.

## 7. Highest ROI fixes, not implemented

### P0 fixes to validate first

- Add a migration or production verification for realtime publication coverage of `conversation_read_state`, `venue_event_vibes`, `venue_event_predictions`, `venue_event_interests`, and `pickup_games`.
- Add exact runtime diagnostics that print subscribed table, filter, topic, publication expectation, and first-event timestamp for each realtime listener.
- Filter or replace table-wide `venue_event_comment_reactions` realtime.
- Add Appearance crash logs and reproduce with Discover selected venue open vs closed.
- During Appearance change, temporarily log whether Discover is preserved offscreen, selected venue is open, Map annotations count, AdMob banner mounted, public profile overlay active, and prediction module visible.

### P1 fixes after measurement

- Pre-index selected-day events and venue event rows once per generation; stop calling `selectedDayEventsForMap` repeatedly per venue.
- Remove main-actor fallback clustering or make fallback use the last known snapshot/placeholder instead of `clusteredBars()`.
- Replace Fan Chat exact count and preview batch with grouped RPC.
- Replace prediction summary row downloads with aggregate RPC.
- Replace visible Going count raw row downloads with aggregate RPC.
- Add equality guards before restarting pickup following and organizer realtime channels.
- Gate Discover preview prefetches by selected tab and a short event-ID TTL.

### P2 fixes

- Memoize `VenueEventCommentsView.comments` and ad list items by event revision.
- Split `MapViewModel` publishers by domain once regression tests exist.
- Move profile/avatars/image and social prefetches into dedicated stores with independent invalidation.
- Sample or disable high-volume DEBUG logs during performance profiling.

## 8. Exact likely scaling failures

- At 1k concurrent users: table-wide reaction and inbox listeners cause unnecessary wakeups; unread and friendship refreshes remain best-effort and can burst after foreground.
- At 10k comments: exact count queries and full comment-row preview batches become expensive; sorting comments in view computed properties becomes visible jank.
- At large prediction counts: each aggregate refresh downloads and filters all prediction rows for the event.
- During major live events: Going counts are locally instant but remote users may not see sub-1-second updates because `venue_event_interests` realtime is not confirmed in tracked migrations.
- During Appearance switch: preserved offscreen Discover Map and selected venue preview can rebuild during a global trait flip even while the user is in Account settings.

## 9. Bottom line

The highest concrete risk is not missing optimism. FanGeo already does many local-first updates correctly. The risk is that realtime events frequently trigger broad REST aggregate reloads, and several subscribed tables do not have tracked realtime publication coverage. On the UI side, Discover still has exact O(venues * events) fallback paths and a selected venue preview that starts image/social/prediction work inside a color-scheme-sensitive Map overlay. Those are the places most likely to produce stutter, delayed updates, or transient SwiftUI/MapKit crashes during major sports traffic.
