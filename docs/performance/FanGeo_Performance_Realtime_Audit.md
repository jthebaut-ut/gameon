# FanGeo Performance and Realtime Audit

Date: May 21, 2026

Scope: Report-only static audit of FanGeo iOS performance, speed, realtime behavior, responsiveness, Supabase/backend query shape, main-thread/SwiftUI risk, and the reported `EXC_BAD_ACCESS` crash when switching Appearance to Light mode.

Constraints honored: no app behavior changes, no UI redesigns, no architecture refactors, no feature removals, and no SQL changes were applied. This report recommends fixes and instrumentation only.

Verification status: fresh physical-device `xcodebuild -project "GameOn.xcodeproj" -scheme "GameOn" -destination 'platform=iOS,name=iPhone 17 Pro Max JT' build` succeeded. `deno lint "supabase/functions"` was attempted because the workspace enables Deno linting for Supabase functions, but `deno` is not installed on this machine. No SwiftLint configuration was found.

## 1. Executive summary

FanGeo already has the right product instincts for major-match traffic: DMs and Fan Chat use optimistic local updates, Discover map loading is split into phases, the Going button locally patches state, image loading has a memory cache for Discover cards, and realtime listeners exist for the highest-value social surfaces.

The main performance risk is not one single slow function. It is accumulated fan-out: one large `@MainActor` `MapViewModel`, many broad `@Published` invalidations, repeated Supabase count/aggregation refreshes after realtime events, selected venue preview work inside a large SwiftUI view, and launch/foreground paths that combine several independent network tasks. During World Cup-style traffic, these patterns can turn acceptable single-user latency into visible jank or 1-5 second waits.

The reported Appearance-to-Light crash is most likely a SwiftUI/MapKit/material overlay rebuild crash, not an obvious invalid light-mode color or force unwrap. The global `@AppStorage` value in `FanSpotApp` drives `.preferredColorScheme(...)` on `ContentView`, which forces a full scene environment rebuild. If a Discover map, selected venue preview, prediction card, material overlays, or custom overlay window is active at the same time, SwiftUI and MapKit can be asked to tear down and rebuild a very deep tree while asynchronous `.task`, `onAppear`, realtime, image, and snapshot work are still mutating observed state.

Highest-priority recommendations:

- P0: Add targeted appearance-crash instrumentation before touching behavior.
- P0: Keep DM, Fan Chat, Going, reactions, and predictions optimistic locally; never regress to wait-for-server UI.
- P0: Add realtime latency measurements for send tap to local render, write success, remote receive, and badge update.
- P1: Coalesce and cap Fan Chat/reaction/count refreshes under high traffic.
- P1: Reduce Discover venue preview body churn and background prefetch fan-out.
- P1: Add missing or stronger indexes/RPCs for prediction aggregates, comment reactions, conversation read state, and realtime/high-frequency count paths.
- P2: Split large observable state after tests exist; do not do this as a quick fix.

## 2. Current performance strengths

- Launch has a dedicated `BootstrapLoadingCoordinator` with a maximum wait of 3.8 seconds and separates critical bootstrap from warm preload.
- Discover uses phased loading: fast venue pins first, selected-day venue events second, then enrichment. The loader preserves existing rows during refreshes and fences stale requests with `loadVenuesRequestID`.
- Discover image loading uses `DiscoverMapImageCache` with in-flight request coalescing and a bounded memory cache.
- DM sends are optimistic: `DirectChatView.sendDraft()` appends a local message immediately, then writes to Supabase in a background `Task`.
- DM thread realtime is filtered by `conversation_id` and has reconnect/fallback behavior.
- Fan Chat posting and app-level comment preview updates use optimistic/local merge behavior and realtime subscriptions.
- Going button UI updates immediately through `toggleVenueGameGoingFromUI(...)` and uses short-lived reconcile guards to avoid replica-lag flicker.
- Prediction summaries have a 45-second cache, manual refresh, and per-event realtime invalidation with a 250 ms debounce.
- Fan Chat comments and reactions have exact-count/server reconcile paths, which improves correctness after missed realtime.

## 3. Critical bottlenecks

1. Launch critical path still awaits too much work.
   `BootstrapLoadingCoordinator.performCriticalBootstrap(...)` awaits cached Discover restore, initial region/preload, auth session restore, Discover core refresh, and unread DM count before marking launch complete. Any slow Supabase/session call can stretch the splash.

2. Discover selected-day event loading is serial and can fan out.
   `fetchVenueEventRowsForDiscover(...)` performs three serial chunk loops: by `venue_id`, by legacy `owner_email`, and by legacy `venue_name`. With many visible venues, this can be multiple PostgREST round trips before phase 2 completes.

3. Venue preview work runs inside a large SwiftUI surface.
   `DiscoverScreen.venuePreviewCard(...)` computes selected events, stable item lists, prefetch keys, image prefetches, social prefetches, and renders full game cards inside the same large view that owns map overlays, date overlay, pickup previews, and search overlays.

4. Realtime often triggers aggregate fetches.
   Realtime events are useful, but several paths translate realtime into delayed REST refreshes: Fan Chat counts, comment reactions, vibes, prediction aggregates, unread badges, and fallback receiver refreshes. This is correct but can become expensive during high-traffic matches.

5. One central `MapViewModel` invalidates too broadly.
   `MapViewModel` owns Discover, account/auth, owner tools, pickup, social, predictions, comments, vibes, and many UI flags. A single `@Published` update can redraw more of the app than necessary.

## 4. Realtime reliability risks

Private DMs:

- Local sender latency should be under 100 ms because the optimistic append happens before the Supabase write.
- Remote receiver latency depends on Supabase Realtime publication/RLS and channel health. Thread-level listener is scoped by `conversation_id`, but inbox listener is unfiltered across `direct_messages` and `conversation_read_state`, relying on RLS.
- Badge updates are locally patched when possible, then corrected through `get_dm_unread_total`. This is good for correctness but still needs end-to-end badge latency logs.

Fan Chat:

- Sheet-level comments use a per-event `venue_event_comments` listener and app-level previews use `IN` filters over visible event IDs.
- App-level comment previews scale better than one listener per card, but high fan-out is still possible because each insert can trigger profile loads and exact count reconciles.
- Comment reactions currently subscribe to all `venue_event_comment_reactions` changes and filter by visible comment ID in the client. This is a scaling risk because every reaction table change that RLS permits can wake every open Fan Chat reaction listener.

Going/attendance:

- Local Going is instant.
- Other users do not appear to have a dedicated realtime listener on `venue_event_interests`; remote count freshness depends on refresh/reconcile paths unless a separate realtime path exists outside the inspected code.
- This means Going counts are currently closer to "optimistic local plus eventual consistency" than truly sub-1-second remote realtime.

Predictions:

- Per-event realtime on `venue_event_predictions` is implemented and debounced to a summary reload after 250 ms.
- Local winner/first-score/score save UX should feel fast only if the view patches local selected state immediately; crowd percentages still wait for aggregate refresh.
- Summary aggregation is client-side over all prediction rows for the event. This is fine for small events but will degrade for large matches.

Reactions/live venue activity:

- Vibes and crowd reactions are realtime-aware, but refreshes call `loadVibes(for:)` per tracked event after a 300 ms debounce.
- Under match spikes, this should be coalesced and capped so one burst does not create many concurrent aggregate reads.

## 5. Main-thread/SwiftUI risks

Top risks:

- `DiscoverScreen` is a very large view with `GeometryReader`, many `.overlay` layers, many `.onChange` handlers, selected venue/pickup previews, calendar overlay, search overlays, and map annotations.
- `VenueEventCommentsView.comments` sorts comments and `venueCommentsListItems` injects ads as computed properties. Every body invalidation can sort/rebuild the feed.
- `VenueEventPredictionModule` starts realtime in `.task(id: venueEventID)` and reloads user prediction using a token that includes changing summary fields. Aggregate updates can cause user-prediction reload churn.
- `DiscoverMapRenderSnapshotBuilder` runs detached, which is good, but it repeatedly scans events per venue and checks selected-day events multiple times during venue filtering and pin construction.
- `MapViewModel` centralizes many unrelated `@Published` values, increasing redraw scope.
- Debug logs are extensive. They are valuable during audit, but per-row Discover logs, per-card mode logs, and prediction layout logs can significantly slow DEBUG performance and make device testing look worse than release.

Crash-risk SwiftUI patterns found:

- `GeometryReader` and `PreferenceKey` remain in `VenueEventCommentsView` for near-bottom detection.
- Discover root uses `GeometryReader` plus multiple overlays around MapKit.
- Venue preview previously had crash-prone swipe/scroll tracking removed; current `gamesListSection` uses stable IDs, disables inline ad injection, and logs duplicate IDs.
- Many material overlays (`.ultraThinMaterial`, `.regularMaterial`, gradient overlays, shadows) rebuild on color-scheme changes.
- The selected venue preview is rendered while MapKit annotations and overlays remain active underneath.

## 6. Backend/Supabase query and index risks

Existing helpful backend work:

- `get_dm_unread_total()` RPC exists and replaces O(conversation count) unread fan-out in the normal path.
- Indexes exist for `direct_messages(conversation_id, created_at)`, `direct_messages(sender_id, conversation_id, created_at)`, `venue_event_comments(venue_event_id, created_at)`, `venue_event_vibes(venue_event_id)`, and `venue_event_interests(venue_event_id)`.
- `venue_event_comments` and `venue_event_comment_reactions` are added to `supabase_realtime`.
- `venue_event_comment_reactions` has indexes on `comment_id`, `user_id`, and `(comment_id, reaction_type)`.

Questionable or missing backend support:

- `venue_event_predictions` needs explicit indexes for:
  - `(venue_event_id, prediction_type)`
  - `(venue_event_id, user_id, prediction_type)` unique/upsert path if not already present
  - possibly `(venue_event_id, updated_at)` for recent participant avatars
- `conversation_read_state` should have a confirmed index or primary key on `(conversation_id, user_id)` and likely a user-facing index on `(user_id, conversation_id)`.
- `direct_conversations` should have indexes for both participant lookup paths: `(user_a_id)` and `(user_b_id)` or a better participant mapping table.
- `venue_event_interests` should confirm a unique constraint/index matching the upsert semantics, likely `(user_email, venue_event_id)` and/or an auth-user based key if the model evolves.
- `venue_event_comments` exact count queries rely on `venue_event_id` plus moderation visibility. A partial index on visible comments may help if moderation-hidden rows grow.
- `venue_event_comment_reactions` realtime is table-wide in client code. Backend publication is table-wide; client should either filter by visible comment IDs if Supabase supports `IN`, or use a server-side aggregate/count RPC.
- `venue_event_vibes` should confirm an index matching `(venue_event_id, user_email, vibe_type)` if toggles delete/insert by those columns.
- Discover legacy matching by `owner_email` and `venue_name` keeps query compatibility but adds index and query complexity. Long term, every `venue_events` row should have `venue_id`.

Recommended SQL improvements, not applied:

- Add a prediction summary RPC that aggregates counts/percentages/top scores in SQL and returns one row per event.
- Add a Fan Chat visible count RPC and reaction summary RPC so clients avoid exact count scans during bursts.
- Add or confirm indexes listed above before major-match traffic.
- Confirm realtime publication coverage for `direct_messages`, `conversation_read_state`, `venue_event_comments`, `venue_event_comment_reactions`, `venue_event_vibes`, `venue_event_predictions`, and optionally `venue_event_interests` if remote Going must be sub-1-second.
- Use `EXPLAIN ANALYZE` on hot queries with realistic event/comment/prediction volumes.

## 7. App launch analysis

Critical path in `BootstrapLoadingCoordinator.performCriticalBootstrap(...)`:

1. `renderCachedDiscoverCore()`
2. `prepareInitialDiscoverRegionAndPreload()`
3. `bootstrapAuthSessionOnly()`
4. `refreshDiscoverCoreInBackground()`
5. `refreshUnreadDirectMessageCount()` if authenticated

Deferred path in `LaunchWarmPreloadCoordinator.runStaggeredWarmPreload(...)`:

- business owner hydration
- personalization
- chat full refresh
- calendar dots and games
- pickup Discover metadata
- pokes badge

Avoidable startup work:

- Fresh Discover core refresh before splash dismissal may be too expensive if cached data is already usable.
- Unread DM count before splash dismissal is product-useful but not required for first usable map.
- `GoogleMobileAdsBootstrap.startIfNeeded()` runs in app init. It should be measured; if costly, it can be deferred, but only after ad regression testing.
- DEBUG builds force a 2-second minimum splash in `ContentView`, so launch timing must be measured in release or with that debug gate accounted for.

Main-thread risk:

- The coordinator is `@MainActor`, and many view model mutations happen on the central model during launch. The code does use detached mapping in some Discover paths, but launch still causes broad state invalidation.

Recommendation:

- Keep cached Discover render critical.
- Measure each launch step with `[LaunchPerf]` including cache hit/miss and network duration.
- If physical-device cold start exceeds 2 seconds, move unread DM refresh and fresh Discover refresh to warm preload unless product requires badge-at-first-paint.

## 8. Discover/map analysis

Map venue loading:

- `loadVenuesFromSupabase(...)` has a good phased design: phase 1 fast pins, phase 2 selected-day venue events, then enrichment.
- The selected-day event fetch is the main bottleneck: serial chunks over venue IDs, owner emails, and venue names.
- The loader suppresses snapshot rebuilds during application and flushes once, which is good.

Map annotation rendering:

- `DiscoverMapRenderSnapshotBuilder` runs off-main but repeatedly scans all `input.events` per venue. This can be optimized by pre-indexing events by date/title and venue event rows by venue ID/title.
- Clustering is custom and likely acceptable for current counts, but should be profiled with 500-2,000 venues/events.

Selected venue preview:

- Current `gamesListSection` uses `VenuePreviewStableGameItem` and stable duplicate-aware IDs. This directly addresses the previously suspected unstable `ForEach` issue.
- Inline ad injection is disabled inside the venue preview list, reducing crash risk.
- Full game cards are restored for logged-in users, so render cost is higher again.
- The preview `.task(id: visibleSocialPrefetchKey)` prefetches image and social data for visible events. This is useful but can create work on every selection/date/sport change.

UI invalidation hotspots:

- `selectedBar`, `selectedSport`, `selectedDate`, `venueEventRows`, `venueEventInterestCounts`, `fanUpdatesStore` values, prediction summaries, and image state can all update while the same preview is visible.
- Appearance changes force all color-dependent materials and overlays to rebuild.

Recommendations:

- Keep current stable IDs and avoid reintroducing swipe-dismiss `GeometryReader`/`PreferenceKey` tracking in the venue preview.
- Move venue preview social prefetch behind a small TTL by event ID.
- Measure venue preview open time from pin tap to first card render; target under 300 ms.
- Pre-index Discover snapshot inputs.
- Add a high-water guard for visible venue event count and event prefetch count.

## 9. DM realtime analysis

Send path:

- `sendDraft()` validates locally, appends an optimistic `DirectMessageRow`, updates display timeline, clears draft, then starts `completeOptimisticSend(...)`.
- This should meet the local optimistic target of under 100 ms.

Write path:

- `completeOptimisticSend(...)` writes via `DirectChatService.sendMessage(...)`, replaces/absorbs the optimistic row, requests badge recalculation, and schedules realtime fallback.
- If write succeeds but realtime echo does not arrive, fallback refresh can merge missing messages.

Receive path:

- Thread realtime uses a filtered `direct_messages` channel per conversation.
- Inbox realtime listens to unfiltered `direct_messages` and `conversation_read_state` and relies on RLS. This avoids stale conversation filters but can become expensive at scale.

Badge path:

- Incoming messages are patched locally when possible.
- `get_dm_unread_total()` is used for server recount; fallback fan-out remains only as an RPC failure path.
- Badge reliability looks good, but the actual latency must be measured.

Risks:

- Unfiltered inbox listener can wake too often as message volume grows.
- `conversation_read_state` changes trigger debounced unread RPC refreshes; high read activity could create repeated badge recomputes.
- Thread opening still combines initial history fetch, realtime setup, and read-state writes.

Recommendations:

- Keep optimistic send.
- Add end-to-end timestamps for receiver badge update.
- Track RPC fallback usage separately from normal RPC usage.
- Explore a user-scoped realtime/broadcast table or server channel if unfiltered inbox changes become noisy.

## 10. Fan Chat realtime analysis

Posting:

- Fan updates insert into `venue_event_comments`, then local and realtime paths merge into comments/previews.
- Comment send path has latency diagnostics and fallback recovery.

Subscriptions:

- App-level preview listener uses `IN` filters over visible event IDs for comments and vibes.
- Sheet listener uses `venue_event_id = eq.<id>` for a single event.
- Comment reactions listener currently watches insert/update/delete on `venue_event_comment_reactions` without a Postgres filter and filters by visible comment ID after decode.

Expected behavior:

- Comments should appear instantly to sender via optimistic/local path.
- Other users should see comments in under 1 second when realtime is healthy.
- Reaction counts can feel delayed because updates debounce and reload reaction summaries.

Scale risks:

- Exact count reconcile after every insert can become expensive.
- Profile loading on realtime insert can add network work during hot chats.
- Reaction realtime should not remain table-wide for high-traffic events.
- App-level `IN` filters need chunking limits and resubscribe stability; current chunking is good but should be tested with large event lists.

Recommendations:

- Add per-event comment write success to remote receive measurements.
- Cap exact count reconcile frequency, for example one visible count reconcile per event per 1-2 seconds during bursts.
- Add a reaction summary RPC and/or filtered realtime by visible comment IDs.
- Cache user profiles by normalized email/user ID before loading on every realtime insert.

## 11. Going/reactions/predictions analysis

Going:

- Local UI update is instant due to `applyOptimisticVenueGameGoingUI(...)`.
- There is no confirmed dedicated realtime listener for `venue_event_interests` in inspected code. Remote count update is therefore not guaranteed under 1 second.
- Failure modes include Supabase write failure rollback, replica lag flashing, stale counts after background/foreground, and duplicate count fetches.

Reactions/live activity:

- Vibes are written through `venue_event_vibes` and refreshed in batches after realtime.
- App-level crowd reaction refresh loads vibes for each tracked event after a 300 ms debounce.
- Under high traffic, this should be coalesced by event and capped.

Predictions:

- User selection can be local/instant if the view state is patched before write completion.
- Crowd aggregate refresh is not instant; realtime event causes cache invalidation and summary reload after 250 ms.
- `VenueEventPredictionService.fetchPredictionSummary(...)` fetches all prediction rows for event IDs and aggregates client-side. This will not scale for a major public match if thousands of predictions exist.

Recommendations:

- Add `venue_event_interests` realtime or a lightweight aggregate channel if remote Going count under 1 second is a hard requirement.
- Add prediction aggregate RPC/indexes.
- Keep prediction cache but shorten forced refresh path only for currently visible event.
- Do not reload user prediction on every aggregate count change unless there is a real user prediction mutation.

## 12. Appearance crash investigation

Reported issue:

- App crashed when switching Appearance to Light mode.
- After reopening, the app launched normally.

Appearance path:

- `SettingsScreen` writes `appearancePreferenceRaw` via `@AppStorage(FanGeoAppearancePreference.appStorageKey)`.
- `FanSpotApp` reads the same key and applies `.preferredColorScheme(appearancePreference.colorScheme)` to `ContentView`.
- `FanGeoAppearancePreference.light` maps to `.light`.
- Many views read `@Environment(\.colorScheme)` and recompute colors/materials.
- `PublicProfileOverlayWindowPresenter` creates a custom `UIWindow` and sets `window.overrideUserInterfaceStyle` from the current preference at presentation time.

Likely crash cause:

- Most likely: a SwiftUI/MapKit render lifecycle crash during a global color-scheme environment swap while Discover map overlays or selected venue preview are active.
- The selected venue preview is a strong suspect because it combines a map-backed screen, a scroll view, material backgrounds, shadows, image tasks, full game cards, prediction modules, Fan Chat social data, and many color-scheme-dependent computed colors.
- MapKit/SwiftUI re-render is also a strong suspect because map annotations and overlay cards are rebuilt together under `.preferredColorScheme`.
- Invalid light-mode assets/colors are less likely. Static search found no obvious app-path `UIImage(named:)!`, `Color("...")` force unwrap, `try!`, or `as!` crash pattern. The only `fatalError` hit was `required init?(coder:)` in `CompactNativeAdCard`, which is normal UIKit boilerplate and not an Appearance path.

Reproducibility hypothesis:

- More likely reproducible when a selected venue preview is open on Discover.
- More likely reproducible if full game cards and prediction module are visible.
- More likely on physical device than simulator due to material/MapKit/render timing.
- Less likely on clean launch because no active environment swap occurs; reopening normally fits a transient render lifecycle crash.

File/function suspects:

- `FanSpotApp.body`: global `.preferredColorScheme(...)` update.
- `SettingsScreen.FanGeoAppearanceSelectionView`: direct `@AppStorage` mutation on tap.
- `DiscoverScreen.discoverScreenCore`: `GeometryReader`, map, and stacked overlays.
- `DiscoverScreen.discoverBottomLeadingCard`: active selected venue/pickup preview overlay.
- `DiscoverScreen.venuePreviewCard(...)`: selected venue scroll card and bottom actions.
- `DiscoverScreen.gamesListSection(...)`: full card `ForEach`, stable now but still render-heavy.
- `VenueEventPredictionModule.body`: realtime tasks and color-dependent material card during rebuild.
- `MapVenuePreviewCard`: older preview card still uses `.ultraThinMaterial`, fixed white backgrounds, overlays, and sheet presentation.
- `PublicProfileOverlayWindowPresenter.present(...)`: custom `UIWindow` style may become stale if an overlay is already active during appearance change.

Recommended safe fix, not implemented:

1. Add diagnostic logs first.
2. Reproduce with selected venue preview closed, then open, then with prediction card visible.
3. If tied to selected preview, dismiss/defocus the selected venue before applying global appearance change, or defer the `@AppStorage` write by one runloop after Settings selection animation completes.
4. If tied to MapKit, consider applying appearance change from a neutral Settings context after clearing transient Discover overlays.
5. If tied to custom `UIWindow`, update or tear down overlay windows when appearance preference changes.
6. Avoid changing colors/assets until logs confirm an invalid asset/color path.

Recommended logs to add later:

```text
[AppearanceCrashDebug] appearanceChangedTo=
[AppearanceCrashDebug] activeTab=
[AppearanceCrashDebug] selectedVenueOpen=
[AppearanceCrashDebug] colorSchemeBefore=
[AppearanceCrashDebug] colorSchemeAfter=
```

Additional useful logs:

```text
[AppearanceCrashDebug] selectedVenueId=
[AppearanceCrashDebug] selectedPickupOpen=
[AppearanceCrashDebug] venuePreviewGameCount=
[AppearanceCrashDebug] predictionModuleVisible=
[AppearanceCrashDebug] publicProfileOverlayActive=
[AppearanceCrashDebug] mapContentMode=
[AppearanceCrashDebug] scenePhase=
```

## 13. Recommended fixes ranked

### P0 critical

- Add Appearance crash logs exactly as requested before any behavior change.
- Measure DMs, Fan Chat, Going, reactions, predictions, and badges with real two-device latency logs.
- Keep all local optimistic UI paths intact.
- Add runtime guards to prevent duplicate realtime listeners from multiplying during foreground/background and sheet transitions.
- Confirm Supabase realtime publication coverage for all critical realtime tables.
- If Going remote count under 1 second is required, add a realtime or aggregate update path for `venue_event_interests`.

### P1 high priority

- Move nonessential launch work out of the splash critical path if measured startup exceeds target.
- Pre-index Discover snapshot inputs and reduce repeated event scans.
- Coalesce Discover selected-day venue event chunk queries where safe, or migrate legacy owner/name rows to venue IDs.
- Add prediction summary RPC and supporting indexes.
- Add Fan Chat count/reaction summary RPCs.
- Filter reaction realtime by visible comment IDs or replace table-wide realtime with aggregate refresh notifications.
- Add TTL/caps for venue preview social prefetches.
- Reduce DEBUG log volume behind sampled gates for performance testing.

### P2 polish

- Split `MapViewModel` into smaller stores after regression tests exist.
- Memoize sorted comments and ad-injected list items by revision.
- Add persistent disk image cache if memory-only cache misses are visible.
- Add UI tests for Appearance switching, Discover selected venue preview, Fan Chat send/receive, DM unread badge, Going count, and predictions.
- Add release-build performance logging that can be enabled without heavy DEBUG print overhead.

## 14. Suggested test plan with two devices

Device setup:

- Device A signed in as fan A.
- Device B signed in as fan B.
- Both on same event/venue when testing Fan Chat, Going, reactions, and predictions.
- Test on physical devices first; simulator is secondary.

Launch:

- Cold launch with no session.
- Cold launch with fan session.
- Cold launch with venue owner session.
- Warm foreground after 5 minutes idle.
- Record splash visible duration and first usable Discover time.

Discover/map:

- Open Discover with cached data.
- Force cold map load by changing location/date/sport.
- Open a selected venue preview with 0, 1, 5, and 12 games.
- Switch Appearance to Light while no preview is open.
- Switch Appearance to Light while selected venue preview is open.
- Switch Appearance with prediction module visible.
- Switch Appearance while Fan Chat sheet is open.

DM:

- A opens thread with B.
- A sends text and emoji.
- Measure tap to local render on A.
- Measure tap to Supabase write success on A.
- Measure write success to message visible on B.
- Measure B unread badge update when B is outside thread.
- Measure read-state clearing when B opens thread.

Fan Chat:

- A posts update in event Fan Chat.
- B watches sheet open.
- B watches only Discover preview closed/open.
- Measure message visibility, count update, and reaction update.
- Repeat with rapid 10-message burst.

Going/reactions/predictions:

- A taps Going; verify instant local count.
- B watches count change time.
- A toggles vibe/reaction; B watches count change time.
- A submits winner, first-score, and exact-score predictions.
- B watches aggregate percentages and top score update.

Stress:

- 20 rapid comments across one event.
- 20 reactions across visible comments.
- 20 Going toggles across multiple events, if test users/data permit.
- Foreground/background during realtime subscriptions.

## 15. Suggested metrics targets

- Local optimistic UI response: under 100 ms.
- Realtime event arrival on second device: ideal under 500 ms, acceptable under 1 second.
- Unread badge update: under 1 second.
- Fan Chat message visible to other user: under 1 second.
- Going count local update: instant, under 100 ms.
- Going count remote update: under 1 second.
- Prediction local update: instant, under 100 ms.
- Prediction aggregate refresh: under 1-2 seconds.
- Discover first usable map: under 1 second cached, under 2 seconds cold.
- Venue preview open: under 300 ms.
- Appearance switch: no crash, no visible freeze over 500 ms, no stuck overlay.

## 16. Instrumentation audit

Useful existing logs:

- `[LaunchPerf]`: useful for critical and warm preload timing.
- `[DiscoverPerf]`, `[Phase1Perf]`, `[Phase2Perf]`, `[Phase3Perf]`: useful for map load phases.
- `[DMRealtimeLatencyDebug]`: strong coverage for send tap, optimistic append, insert success, realtime receive, and UI update.
- `[FanChatRealtimeDelayDebug]`: useful for subscribe and insert receive timing.
- `[RealtimeHealthDebug]`: useful for subscribe/reconnect health.
- `[BadgeSyncDebug]` and `[UnreadBadgeDebug]`: useful if consistently emitted around badge recalculation.
- `[PredictionRealtimeDebug]`: useful for subscription and aggregate refresh timing.
- `[AdDebug]`: useful for ad initialization/render issues.
- `[ImageCacheDebug]`: useful for cache hit/fetch timing.

Noisy logs:

- Per-row Discover event logs in `loadVenuesFromSupabase(...)` can be very noisy.
- Prediction layout logs on every appearance can be noisy.
- Venue preview mode logs inside every game row can be noisy.
- Emoji/Fan Chat UI logs are useful for debugging but should not be enabled during performance timing unless sampled.

Missing metrics:

- Appearance before/after color-scheme transition with active selected venue state.
- Send tap to local render for Fan Chat and Going, not only DMs.
- Supabase write success to remote realtime receive on another device.
- Realtime receive to badge UI update.
- Going write to remote count update.
- Prediction write to aggregate refresh completion.
- Venue preview pin tap to first rendered card.
- Map cached first usable time vs cold first usable time.

Recommended latency measurements:

- DM: send tap -> local render -> Supabase write success -> remote realtime receive -> remote UI render -> badge update.
- Fan Chat: post tap -> local render -> Supabase write success -> remote receive -> visible row -> count update.
- Going: tap -> local count update -> write success -> second device count update.
- Prediction: tap -> local selected state -> write success -> realtime receive -> aggregate visible.
- Reactions/vibes: tap -> local count/selection update -> write success -> remote count update.

## 17. Search/static audit notes

Requested smell searches were performed across Swift sources for:

- `GeometryReader`
- `PreferenceKey`
- `ForEach`
- `Task {`
- `await`
- `.onAppear`
- `forceRefresh`
- `loadVenuesFromSupabase`
- `startInboxRealtimeListener`
- `subscribe`
- `realtime`
- `venueEventRows`
- `count`

The largest concentration of relevant hits is in `DiscoverScreen`, `MapViewModel+VenueAndGameData`, `MapViewModel+CommentsAndVibes`, `DirectChatView`, `ChatViewModel`, and `VenueEventPredictionsView`.

Force-crash search notes:

- No obvious Appearance-path force unwrap was found.
- No obvious invalid light-mode asset lookup was found.
- `CompactNativeAdCard.required init?(coder:)` contains `fatalError("init(coder:) has not been implemented")`, which is normal for programmatic UIKit views and not suspected for Appearance unless the view is unexpectedly storyboard-decoded.

## 18. Bottom line

FanGeo is close to the right architecture for fast perceived performance because the most important actions are already optimistic. The main risk for major matches is backend and client fan-out after realtime events, plus large SwiftUI invalidations on Discover. The Appearance crash should be treated as a render-lifecycle issue until logs prove otherwise. Add the requested `[AppearanceCrashDebug]` logs, reproduce on two physical devices, and then apply the smallest fix tied to the confirmed state: selected venue open, MapKit rebuild, prediction card rebuild, or custom overlay window.
