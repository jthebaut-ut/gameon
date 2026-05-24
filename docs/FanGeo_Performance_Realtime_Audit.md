# FanGeo Performance, Latency, and Realtime Reliability Audit

Date: 2026-05-24

Scope: report only. This audit does not change product code, UI, subscription behavior, ads, Supabase/backend behavior, or database schema. Instrumentation mentioned below is recommended future work only.

## 1. Executive Summary

FanGeo already has several strong performance foundations:

- Discover renders cached venue/game data from disk during startup.
- Main tabs are lazily mounted and preserved after first use.
- Discover map snapshot work is moved into detached/cancellable builders.
- Going/interested taps apply optimistic local state before Supabase writes finish.
- DM threads and fan chat both have realtime plus fallback refresh paths.
- Avatar/image loading uses a shared in-memory cache with in-flight request coalescing.
- Ad requests are gated on visible host tab and consent readiness.
- Startup splits critical bootstrap from warm preload.

The main risk is not a single slow function. It is the combined effect of broad observable state, high fan-out Supabase reads, multiple realtime subscriptions, fallback polling, heavy SwiftUI surfaces, ads, and debug logging during the same sports moment. Under normal load these paths may feel good. Under a major match, several surfaces can still drift into 1-5 second perceived latency.

### Top 10 Likely Performance Risks

1. `MapViewModel` is a very broad `@MainActor ObservableObject`; many unrelated `@Published` mutations can invalidate large screen trees.
2. `FanUpdatesRealtimeStore` publishes dictionaries/sets that can invalidate comment sheets, venue cards, previews, counts, and reaction rows together.
3. Discover has many `onChange`, `.task`, and foreground triggers that can stack or schedule overlapping network/map work.
4. Venue details and venue cards receive many closures and large data dictionaries from shared view models, making recomposition expensive.
5. Fan chat comments sort on every `comments` computed access in `VenueEventCommentsView`.
6. Venue owner analytics realtime events debounce into full REST refreshes for interests, comments, and vibes per tracked event.
7. Going count refreshes read raw `venue_event_interests` rows and aggregate client-side for chunks of visible events.
8. DM unread fallback can become O(conversations) if the unread RPC fails or is unavailable.
9. UIKit ad bridges call `layoutIfNeeded`, produce native/banner host updates, and can appear inside scroll-heavy surfaces.
10. Debug logging volume is very high in realtime, Discover, ads, auth, and UI paths; Debug builds may misrepresent actual latency.

### Top 10 Likely Realtime Latency Risks

1. Supabase Realtime delivers row-level Postgres changes, not pre-aggregated count deltas, so client refresh/reconcile work often follows.
2. DM inbox listens broadly to `direct_messages` and `conversation_read_state`, relying on RLS rather than always using narrow per-user summaries.
3. Fan chat per-event subscriptions plus app-level subscriptions can overlap, resubscribe, or reconcile the same events.
4. Fan chat first-poll fallback waits up to 2.5 seconds; DM fallback waits 1.5 seconds.
5. Reaction realtime falls back to polling at an 8-second cadence and debounces reaction refresh.
6. Venue owner analytics realtime deliberately debounces then refetches all tracked engagement data.
7. Realtime channel joins use network/Phoenix subscribe paths that may add hundreds of milliseconds before a screen is truly live.
8. Foreground reconnects stop/restart some realtime listeners, which can create gaps during tab switching or app resume.
9. Deduplication relies on body/sender matching or server IDs; retries/out-of-order delivery can still force list rebuilds.
10. MainActor application of realtime changes can be delayed behind rendering, image decode state changes, ad callbacks, or reload tasks.

### Top 10 Highest-Impact Fixes Later

1. Replace high-traffic count queries with server-side aggregate RPCs or materialized counters.
2. Add user-scoped Realtime broadcast channels for DM inbox summaries instead of broad row-level `direct_messages`.
3. Add event-scoped broadcast payloads for fan chat count/reaction/vibe deltas.
4. Split `MapViewModel` into smaller observable stores for Discover, venue social, auth/profile, pickup, and business dashboard state.
5. Introduce per-surface request coalescers with cancellation and last-writer-wins tokens for Discover, venue detail, and comments.
6. Add p50/p95/p99 latency metrics for send-to-visible, realtime-received-to-rendered, tap-to-count, and query durations.
7. Build a single event engagement cache keyed by `venue_event_id` and fed by optimistic writes, realtime, and occasional reconciliation.
8. Move expensive list transforms out of SwiftUI `body`/computed properties and update derived arrays only when source data changes.
9. Prewarm avatar/image and venue-card data for likely next screens, with bounded caches and memory pressure handling.
10. Add database indexes for all high-cardinality filters listed in the Supabase/database section.

## 2. Realtime Audit

### DM Inbox

Files inspected:

- `ChatViewModel.swift`
- `DirectChatService.swift`
- `RecoveredSocialChatViews.swift`
- `DMRealtimeDiagnostics.swift`
- `MainTabView.swift`

Current data path:

- `FriendsTabView` calls `refreshInboxSummariesIfNeeded()` and `refreshFriendRequestListsOnly()` on appear.
- `ChatViewModel` owns `friends`, `incomingRequests`, `outgoingRequests`, `pendingBadgeCount`, `unreadDirectMessageCount`, and inbox notification state.
- Unread count prefers `DirectChatService.fetchUnreadDirectMessageCount()`, which calls RPC `get_dm_unread_total`.
- If RPC fails, it falls back to fetching conversation IDs, read states, then running per-conversation unread counts.

Realtime subscription path:

- `ChatViewModel.ensureSignedInSocialRealtimeIfNeeded()` starts inbox and friendship realtime listeners.
- Inbox channel is named `dm-inbox-<userId>`.
- It listens to `conversation_read_state` with `AnyAction`.
- It listens to `direct_messages` inserts without a client-side conversation filter, relying on RLS.
- Foreground resumes schedule a debounced realtime restart after 400 ms.

Optimistic update behavior:

- The inbox itself does not appear to have a full optimistic inbox summary mutation for every send.
- DM thread sends optimistically; inbox catches up through thread state, realtime insert, unread refresh, or full inbox summary refresh.
- For incoming DMs, the app can show an in-app notification and update unread counts.

Fallback polling behavior:

- `inboxUnreadDebounceTask` debounces unread total refreshes.
- `inboxMissingPeerReconcileTask` coalesces rare cases where an incoming peer is not in the inbox list.
- Badge recalculation coalesces explicit badge recount requests.

Dedupe behavior:

- Duplicate listener start is guarded by `inboxListenTask == nil` and `inboxChannel == nil`.
- Inconsistent channel/task state is repaired by stopping listeners.
- Inbox rows likely dedupe by conversation/peer during summary refresh, but broad realtime events can still queue redundant refreshes.

Cache behavior:

- `lastInboxLoadAt` and `minInboxRefreshInterval = 2` limit refresh frequency.
- Startup chat prefetch has TTL around 90 seconds.

Main-thread risks:

- `ChatViewModel` is `@MainActor`; realtime event handling that mutates inbox arrays, badges, or notifications contends with the UI.
- Debug logs run from hot realtime paths in Debug builds.

Race conditions:

- Foreground reconnect can stop and restart both inbox and friendships realtime while unread refreshes are also running.
- A sent message may update the thread optimistically before the inbox summary is refreshed.
- Missing-peer reconciliation can race with a manual inbox refresh.

Why updates may take >1s:

- Realtime channel subscribe/reconnect time.
- Debounced unread refresh.
- RPC duration for unread total.
- MainActor queue contention from tab switching, Discover, ads, or profile work.

Why updates may take 3-5s:

- RPC failure triggers fan-out unread fallback.
- Foreground reconnect plus network refresh plus full inbox summary refresh.
- Supabase Realtime delayed under load or websocket temporarily reconnecting.

What would make it flawless:

- User-scoped realtime/broadcast payload with `{ conversation_id, last_message, unread_total_delta }`.
- Server-side inbox summary table/RPC with one read.
- Local per-conversation cache updated optimistically and reconciled in background.
- Explicit connection health metrics and automatic silent resubscribe without clearing visible state.

### DM Thread

Files inspected:

- `DirectChatView.swift`
- `DirectChatService.swift`
- `RecoveredSocialChatViews.swift`
- `ChatViewModel.swift`

Current data path:

- `DirectChatPresenter` fetches/creates conversation, then fetches latest messages with keyset pagination.
- Initial fetch loads latest 50 messages from `direct_messages`.
- Older/newer loads use `(created_at, id)` keyset filters.
- Sending calls `DirectChatService.insertMessage()` with `.insert(...).select().single()`.

Realtime subscription path:

- `DirectChatService.directMessagesInsertChannel(conversationId:)` creates `dm-thread-<conversationId>`.
- It uses a filtered Postgres realtime stream on `direct_messages` where `conversation_id = eq.<id>`.
- `DirectChatPresenter.runRealtimeSubscription()` owns a bounded reconnect loop with delays `[0, 1s, 3s, 5s]`.
- `subscribeWithError()` is executed from a detached task to avoid coupling Phoenix join with the MainActor.

Optimistic update behavior:

- Sending creates a local optimistic message with a client-generated UUID.
- `pendingOptimisticMessages` tracks local pending rows.
- On server confirmation/realtime echo, `absorbPendingOptimistic` removes the local pending row and inserts or keeps the server row.

Fallback polling behavior:

- `RealtimeFallback.delayNs` is 1.5 seconds.
- Fallback refresh fetches newer messages and merges missing rows.
- Foreground quiet refresh runs if the channel is healthy but no insert has arrived for 12 seconds.

Dedupe behavior:

- Dedupes by server message ID.
- Echo dedupe also matches pending optimistic messages by sender/body.
- Display timeline is kept in lockstep with message mutations to avoid rebuilding from `body`.

Cache behavior:

- Messages are local to the presenter. There is no durable per-thread cache visible in the inspected code.
- Reopening a thread fetches latest messages again.

Main-thread risks:

- Presenter is `@MainActor`; messages array and timeline mutations are on the UI actor.
- Sorting/rebuilding can happen when out-of-order rows arrive or older messages prepend.
- Bubbles use gradients, shadows, avatars, timestamps, and potentially many rows.

Race conditions:

- Local optimistic row and server echo can arrive out of order.
- Realtime reconnect can overlap with foreground quiet refresh.
- `markConversationRead()` can race with unread count refresh in inbox.

Why updates may take >1s:

- Insert round-trip plus realtime delivery.
- Channel not subscribed yet when a message is sent.
- Fallback waits 1.5 seconds before fetching missing rows.

Why updates may take 3-5s:

- Realtime subscription attempt fails and reconnect backs off to 3s/5s.
- Supabase insert completes but Realtime is delayed; fallback query also waits behind network/server load.
- MainActor is busy with scrolling, avatar loading, or tab transition.

What would make it flawless:

- Preserve per-thread message cache across navigation.
- Use server-generated or client-supplied idempotency/correlation IDs for perfect dedupe.
- Broadcast message payloads from an Edge Function after insert, with Postgres Realtime as backup.
- Track send tap -> local append -> insert complete -> realtime receive -> rendered with p95/p99 dashboards.

### Fan Chat / Comments

Files inspected:

- `VenueEventCommentsView.swift`
- `MapViewModel+CommentsAndVibes.swift`
- `FanUpdatesRealtimeStore.swift`
- `VenueEventCommentsSheet.swift`
- `VenueCommentsAdPlacement.swift`
- `CompactNativeAdCard.swift`

Current data path:

- Comments live in `FanUpdatesRealtimeStore.venueEventComments[venueEventID]`.
- Initial limit is 100 comments; page limit is 50.
- `VenueEventCommentsView.comments` sorts comments by `created_at` and `id`.
- Comment previews and counts are stored separately in `venueEventCommentPreviews` and `venueEventCommentPreviewCounts`.
- Comment rows are enriched with reaction metadata from dictionaries keyed by comment ID.

Realtime subscription path:

- Per-event comment realtime tasks/channels are tracked by `venueEventCommentsRealtimeTasks` and `venueEventCommentsRealtimeChannels`.
- App-level fan chat realtime tracks up to 160 event IDs and chunks filters by 80.
- There are per-comment reaction realtime channels/tasks as well.
- Subscription readiness is tracked via `venueEventCommentsRealtimeReadyIDs` and reaction-ready sets.

Optimistic update behavior:

- `appendPendingVenueEventComment` immediately inserts a pending local comment and updates preview count.
- Insert success and realtime/fallback later confirm the server row.
- Matching pending comments use event ID, normalized email, and text.

Fallback polling behavior:

- Fan chat recovery delays are `[750ms, 2s, 5s]`.
- First polling grace is 2.5 seconds.
- Fallback poll interval is 2.5 seconds when unhealthy and 8 seconds when healthy.
- Reaction fallback polling is 8 seconds.

Dedupe behavior:

- Server IDs are tracked in `venueEventCommentRealtimeReceivedServerIDs`.
- Pending comments are matched by email/text when server row arrives.
- Previews dedupe by `serverCommentID`.

Cache behavior:

- Comment prefetch TTL is 30 seconds.
- Vibe prefetch TTL is 20 seconds.
- Reaction refresh minimum interval is 20 seconds.
- Preview limit is 2 comments.

Main-thread risks:

- `FanUpdatesRealtimeStore` is `@MainActor`.
- `VenueEventCommentsView.comments` sorts on access, which can run repeatedly during body recomposition.
- Native ads are injected into comments list after `showNativeAdsInFeed`, changing item identity/layout while comments are updating.
- Comment rows use avatars, gradients, shadows, preference keys for bottom tracking, and scroll-to-bottom logic.

Race conditions:

- Per-event sheet realtime and app-level realtime may both observe/update the same event.
- Fallback polling can merge rows already applied by realtime.
- Reaction refreshes can overwrite optimistic reaction state if server reads lag.
- Ad insertion can affect scroll target timing when new comments arrive.

Why updates may take >1s:

- Realtime setup not ready when sheet opens.
- First polling grace/fallback waits.
- Reaction debounce and refresh minimum intervals.
- MainActor sort/dedupe/update under active scrolling.

Why updates may take 3-5s:

- Realtime subscribe fails or channel is not in publication.
- App-level resubscribe plus fallback recovery sequence.
- Server reads for comments/reactions delayed under high write load.

What would make it flawless:

- Event-scoped engagement stream with comments, count deltas, reaction deltas, and vibe deltas in one channel.
- Precomputed ordered comments array stored in the view model/store, not sorted from view computed properties.
- Separate stores for comment body, reaction counts, preview counts, and sheet-local state.
- Replace fallback polling with a bounded `latest_created_at` incremental fetch that runs immediately when channel health is unknown.

### Going / Interested Count

Files inspected:

- `MapViewModel+VenueEventSocial.swift`
- `MapViewModel+VenueAndGameData.swift`
- `FollowingScreen.swift`
- `MapVenuePreviewCard.swift`
- `GoingAvatarStack.swift`

Current data path:

- Going is stored in `venue_event_interests`.
- Local state includes `venueEventInterestIDs`, `venueEventInterestCounts`, `followingTabUserVenueEventInterestIDs`, `followingTabGoingInterestCounts`, `goingProfilesByVenueEventID`, and pending target dictionaries.
- Visible event interest counts are loaded by querying raw interest rows for chunks of visible event IDs and aggregating client-side.

Realtime subscription path:

- No dedicated user-visible realtime count stream was confirmed for Discover Going counts.
- Venue owner analytics has realtime on `venue_event_interests`, but it debounces into REST refresh.
- Going counts rely heavily on optimistic local writes plus scheduled refresh/reconcile.

Optimistic update behavior:

- `toggleVenueGameGoingFromUI` applies local state immediately.
- It records rollback snapshots and write-in-flight IDs.
- It updates following tab snapshots and going avatars optimistically.

Fallback polling behavior:

- Deferred following reconcile runs after 2 seconds.
- Visible event interests reloads are scheduled after writes.
- `refreshVenueGameCardGoingState` and `loadGoingUserProfiles` reconcile specific event state.

Dedupe behavior:

- Write-in-flight set prevents repeated taps for the same event.
- Pending target state prevents read-replica flashback.
- Recently confirmed going/not-going TTL is 15 seconds.

Cache behavior:

- Going profile prefetch TTL is 45 seconds.
- Event card store caches some card state separately.

Main-thread risks:

- Count dictionaries are `@Published` on the broad `MapViewModel`.
- Updating one count can invalidate many cards if they observe the whole model.
- Loading avatars after a Going tap can trigger additional image/cache work.

Why updates may take >1s:

- Server confirmation and post-write profile reload.
- Reconcile waits and network reads.
- Client-side aggregation of raw rows.

Why updates may take 3-5s:

- High write load on `venue_event_interests`.
- Missing composite indexes on event/user/email filters.
- Read-after-write lag or RLS overhead.

What would make it flawless:

- `venue_event_interest_counts` materialized/counter table or RPC.
- Realtime/broadcast count delta stream by `venue_event_id`.
- Local count cache that receives optimistic deltas and reconciles in the background.

### Reactions / Likes

Files inspected:

- `MapViewModel+CommentsAndVibes.swift`
- `FanUpdatesRealtimeStore.swift`
- `VenueEventCommentsView.swift`

Current data path:

- Comment reactions/likes are stored in per-comment dictionaries:
  - `venueEventCommentLikeCountsByID`
  - `venueEventCommentDownReactionCountsByID`
  - `venueEventCommentIDsLikedByCurrentUser`
  - `venueEventCommentViewerReactionsByID`
- Rows are rendered with reaction metadata merged into comment rows.

Realtime subscription path:

- Reaction realtime channels are tracked per event/comment set.
- Reaction updates debounce at 250 ms.
- Reaction ready grace is 2 seconds.

Optimistic update behavior:

- The store tracks write-in-flight IDs for comment likes.
- The UI appears to update local reaction metadata before or around server write, then reconcile.

Fallback polling behavior:

- Reaction fallback poll interval is 8 seconds.
- Reaction refresh minimum interval is 20 seconds in fan chat first-polling config.

Dedupe behavior:

- Reaction rows are keyed by comment ID and current viewer reaction.
- Dedupe depends on server state overwriting local dictionaries.

Cache behavior:

- Reaction metadata remains in shared store dictionaries.
- Cache freshness is coarse and event/comment scoped.

Main-thread risks:

- Reaction taps mutate shared dictionaries, invalidating rows and possibly whole comment views.
- Poll refresh for many comments can update many dictionary entries together.

Why updates may take >1s:

- Debounce plus network write/read.
- Realtime not ready within 2 seconds.

Why updates may take 3-5s:

- Fallback polling interval.
- Many concurrent comment reaction writes on a hot event.

What would make it flawless:

- Reaction delta broadcast with `{ comment_id, up_count, down_count, viewer_reaction }`.
- Row-local observable state or memoized row view models to avoid rebuilding the full comment list.

### Venue Activity / Social Counts

Files inspected:

- `VenueDetailView.swift`
- `MapViewModel+CommentsAndVibes.swift`
- `MapViewModel+VenueOwnerAnalyticsRealtime.swift`
- `BusinessVenueDashboardOverviewView.swift`
- `VenueOwnerDashboardView.swift`

Current data path:

- Venue details receive closures for comment count, vibe counts, selected vibes, open fan chat, toggle vibe, and prefetch social data.
- Owner dashboard analytics loads interest counts for event IDs, then loads comments and vibes per event.
- Live venue activity counts are derived from multiple dictionaries and store state.

Realtime subscription path:

- Venue owner analytics subscribes to `venue_event_interests`, `venue_event_comments`, and `venue_event_vibes` for tracked event IDs.
- On any event, it debounces 380 ms and calls existing REST loaders.

Optimistic update behavior:

- Vibes and comments have local optimistic paths.
- Owner analytics appears refresh-based, not delta-based.

Fallback polling behavior:

- Owner analytics effectively uses realtime-as-invalidator plus REST refetch.
- Fan chat and vibe prefetch TTLs provide stale-while-refresh behavior.

Dedupe behavior:

- Tracked event IDs are de-duplicated before subscription.
- Refresh debounces collapse bursts but can still refetch many events repeatedly.

Cache behavior:

- Vibe/comment prefetch TTLs are short.
- Dashboard rows recalculate from shared store.

Main-thread risks:

- Owner analytics refresh loops call `loadComments` and `loadVibes` for each tracked event.
- Each refresh can mutate multiple shared dictionaries and dashboard arrays.

Why updates may take >1s:

- 380 ms debounce plus 3 sets of REST reads.
- Per-event loops for comments/vibes.

Why updates may take 3-5s:

- Many tracked events during a busy venue dashboard.
- Supabase row-level reads under concurrent writes.

What would make it flawless:

- Single server aggregate endpoint for owner analytics.
- Realtime payloads with count deltas rather than invalidation-only events.
- Dashboard-local store that applies deltas and periodically reconciles.

## 3. Data Loading Audit

### Discover

Initial network/data calls:

- Startup coordinator calls `renderCachedDiscoverCore()`, `prepareInitialDiscoverRegionAndPreload()`, `bootstrapAuthSessionOnly()`, and `refreshDiscoverCoreInBackground()`.
- `refreshDiscoverCoreInBackground()` calls `loadVenuesFromSupabase()` then schedules full enrichment.
- Discover screen `.task` and `.onAppear` also call business session checks and weather refresh.
- Map camera end schedules `loadVenuesFromSupabase()` or pickup place refresh after 250 ms.
- Mode changes can call pickup games/places refresh and calendar dot loads.

Duplicated calls:

- Business session restoration is checked from startup, Discover `.task`, Discover `.onAppear`, and later warm preloads.
- `loadVenuesFromSupabase()` is called by startup refresh, map movement, following navigation, venue status changes, venue saves, account deletion, and fallback paths.
- Calendar dot loaders are triggered by mode changes, month changes, calendar opens, startup warm preload, and Calendar tab.

Heavy joins/filters:

- Venue selects include many columns plus embedded `businesses!venues_business_id_fkey(owner_email,admin_status)`.
- Venue event loading filters by date, sport, venue IDs, owner emails, and venue names.
- Calendar dots use RPC `gameon_calendar_dot_dates`, with REST fallback/cache logic.

Slow Supabase filters suspected:

- Bounding box latitude/longitude filters on `venues`.
- `venue_events` by selected date/sport/admin status.
- `venue_events` by `venue_id in (...)`, `owner_email in (...)`, and venue names.
- `ilike` search fallback for null-coordinate venues.

Stale cache risks:

- Disk snapshot can show very fast but stale venue/event state until phase 1/2 refresh.
- Calendar dot cache TTL is 120 seconds; empty guest caches are specially bypassed in some flows.
- Viewport cache TTL is 90 seconds.

Reload triggers:

- Selected date, sport, search text, map display mode, pickup submode, map camera end, foreground, following map navigation, and auth gate changes.

Offscreen work:

- Main tabs are preserved offscreen after mounting.
- Discover stays mounted and can continue state reactions while other tabs are visible.
- Ad views defer based on visible tab, but Discover state can still schedule work.

Expected bottlenecks:

- First uncached `loadVenuesFromSupabase()`.
- Map camera end reloads in dense regions.
- Calendar dot RPC/fallback on calendar open.
- Snapshot rebuild for many venues/events if it is triggered repeatedly.

### Venue Detail

Initial network/data calls:

- Venue detail receives most data from already-loaded Discover state.
- It can call prediction summary loaders, fan chat prefetch, vibe loaders, and venue rating/profile loaders.
- Hero/menu images load via cached image paths when URLs exist.

Duplicated calls:

- Social prefetch can be triggered from venue cards, venue detail, Live, and comments.
- Prediction summaries can be loaded on detail open and refreshed from predictions sheet/realtime.

Heavy joins/filters:

- No single giant join in the view itself; heaviness comes from upstream `BarVenue`, `VenueEventRow`, prediction summary, comment/vibe/interest calls.

Stale cache risks:

- Venue detail can show stale Discover snapshot details while phase 2 enrichment catches up.
- Social counts can be stale until prefetch/realtime/fallback applies.

Reload triggers:

- Opening detail, selected event change, prediction sheet, fan chat open, vibe tap, claim state changes.

Expected bottlenecks:

- Large SwiftUI body with hero images, feature grids, scheduled games, prediction controls, comments/vibes, and claim/business sections.
- Image decode/network if cache misses.

### Calendar

Initial network/data calls:

- Calendar tab loads calendar dot caches and calls `loadGamesFromSupabase()` on selection and date changes.
- It refreshes pickup sources via `refreshCalendarTabPickupSources()`.
- Date picker month change calls `loadCalendarTabCalendarDotsAroundMonth`.

Duplicated calls:

- Discover and Calendar both use venue game calendar dot caches.
- `loadGamesFromSupabase()` is coalesced, which is good, but many callers still enqueue work.

Heavy filters:

- Venue events by date/sport/status.
- Pickup game sources by date/range/location.

Offscreen work:

- Calendar is lazily mounted and preserved; guards such as `isCalendarTabSelected` prevent some offscreen refresh.

Expected bottlenecks:

- Opening date picker before dots are warm.
- Switching between game filters and region modes.

### Live

Initial network/data calls:

- Live screen consumes live sports data, venue activity, fan chat/vibes, and ad placements.
- It can toggle vibe and prefetch event social data.

Duplicated calls:

- Vibe/comment prefetch can overlap with Discover venue cards and venue detail.
- Live sports refresh may be independent of Discover event refresh.

Expected bottlenecks:

- Many rows/cards with live score updates, venue activity, avatars, and ads.
- Shared `MapViewModel` changes can invalidate Live even when unrelated state updates.

### Chat

Initial network/data calls:

- Chat tab calls inbox summaries, friend request lists, moderation block sets, unread counts, and realtime ensure.
- Direct thread opens fetch conversation plus latest messages.

Duplicated calls:

- Startup warm preload fetches chat badges and inbox summaries.
- Chat tab on appear fetches inbox summaries again if TTL allows.
- Foreground badge refresh can overlap with realtime unread refresh.

Heavy filters:

- `direct_conversations` by `user_a_id OR user_b_id`.
- `direct_messages` by conversation and created/id ordering.
- `conversation_read_state` by user/conversation.

Expected bottlenecks:

- Unread RPC fallback fan-out.
- Initial thread fetch on slow connection.
- Avatar cache misses in rows.

### Profile

Initial network/data calls:

- Startup warm preload calls profile creation/check, profile load, favorite venues, favorite teams, following today plans, identity preferences, home crowd, single-session enforcement, pending pickup request count.
- Profile/Settings can also trigger pickup request badge loads and suggested fans.

Duplicated calls:

- Auth/admin checks run in bootstrap, startup prefetch, foreground validation, and profile load.
- Avatar/user profile data is cached in UserDefaults but still refreshed.

Expected bottlenecks:

- Business restore paths and profile restoration if Supabase session is transiently missing.
- Many profile-related calls serialized in warm preload.

### Settings / Business Dashboard

Initial network/data calls:

- Business settings refresh owned businesses/venues, claims, pending/rejected rows, dashboard games, analytics, comments, vibes, interest counts.
- Venue owner dashboard refreshes manage games, analytics histories, social counts, and Business Pro membership state.

Duplicated calls:

- `loadVenuesFromSupabase(forceRefresh: true)` is called after business saves, deletes, claims, and approvals.
- Owner dashboard and Settings inline dashboard can load overlapping games/comments/vibes.

Expected bottlenecks:

- Owner analytics realtime invalidates into full per-event REST refresh.
- Business dashboard can do multiple per-event social loads in task groups.

## 4. SwiftUI / Rendering Audit

Broad `@Published` invalidation risks:

- `MapViewModel` contains auth, Discover, venue owner, comments/vibes, going counts, profile, calendar, pickup, admin, ads-adjacent state, and many UI booleans.
- Screens observe the whole `MapViewModel`, so a small state change can invalidate large surfaces.
- `ChatViewModel` is narrower, but still combines inbox, friend requests, badges, blocked users, direct chat visibility, and search.
- `FanUpdatesRealtimeStore` helps separate social state, but its dictionaries are still broad and high-churn.

Views observing full models unnecessarily:

- `DiscoverScreen`, `VenueDetailView` call sites, `CalendarScreen`, `SettingsScreen`, `LiveScreen`, and `VenueOwnerDashboardView` all observe `MapViewModel`.
- Many child rows are passed closures plus full state-derived values instead of small row-specific view models.

Body recomposition hotspots:

- `DiscoverScreen` has many overlays, `onChange` handlers, map annotations, bottom cards, date picker, and ad layers.
- `VenueEventCommentsView.comments` sorts comments on access.
- `VenueDetailView` is a large composed view with many optional sections.
- `SettingsScreen` has large `List` sections and multiple sheets tied to the same broad model.
- `MainTabView` overlays preserved tab roots and floating tab bar.

Expensive card rendering:

- Venue cards and preview cards use gradients, shadows, materials, images, avatars, counts, and social controls.
- DM bubbles use gradients and shadows.
- Comment cards include avatars, reactions, report controls, and dynamic scroll behavior.
- Business dashboard cards combine photos, metrics, rows, and glass surfaces.

Gradients/shadows/materials inside scroll views:

- Frequent use of `FGAdaptiveSurface`, `.ultraThinMaterial`, gradients, `.softCardShadow()`, rounded overlays, and stroked borders can stress scrolling, especially with long lists.
- Shadows on avatar rows and message bubbles can be expensive when many are visible.

AsyncImage/image decoding risks:

- The app uses a custom `DiscoverMapImageCache`, which is good.
- Cache max entries is 72, likely too small for major event usage across Discover, avatars, comments, and chat.
- `URLSession.shared.data(from:)` plus detached decode avoids some main-thread work, but memory pressure and eviction can cause refetch/flicker.

Map annotation rendering risks:

- Discover map snapshot builder is detached/cancellable, a strong pattern.
- However, map annotation SwiftUI views still render per pin/cluster and can be invalidated by broad state changes.
- Camera end reloads can trigger network fetch and snapshot rebuild close together.

Ad UIKit bridge layout risks:

- `AdaptiveBannerView` calls `container.layoutIfNeeded()` on resize and can force load on size changes.
- Native ad host updates happen through `UIViewRepresentable` inside scroll surfaces.
- Ad callbacks mutate SwiftUI state (`adLoaded`, `adFailed`) and can shift layout/opacity during scrolling.
- Ads are gated on visible tab and consent, which is good, but their loading still competes for network and main-thread layout.

## 5. Supabase / Database Audit

This section recommends likely indexes only. Do not run migrations from this report.

### Likely Needed Indexes

`venue_events`:

- `(venue_id, event_date, admin_status)`
- `(event_date, sport, admin_status)`
- `(scheduled_start_at, sport, admin_status)`
- `(owner_email, event_date, admin_status)`
- `(external_source, external_game_id)` if imports look up by external ID
- Optional partial index where `admin_status = 'active'`

`venue_event_comments`:

- `(venue_event_id, created_at, id)`
- `(venue_event_id, is_moderation_hidden, created_at, id)`
- `(user_email, created_at)` for user/report moderation screens

`venue_event_interests`:

- Unique or primary key on `(venue_event_id, user_email)`
- `(venue_event_id)`
- `(user_email, venue_event_id)`
- Optional `(venue_event_id, created_at)` if recent activity is queried

`venue_event_comment_likes` / reaction table:

- Unique or primary key on `(comment_id, user_email)` or `(comment_id, user_id)`
- `(comment_id)`
- `(user_email, comment_id)` or `(user_id, comment_id)`

`direct_messages`:

- `(conversation_id, created_at DESC, id DESC)` for latest/older pages
- `(conversation_id, created_at ASC, id ASC)` for newer pages
- Partial index where `deleted_at IS NULL`
- `(sender_id, created_at)` if moderation/reporting queries scan sender history

`conversation_read_state`:

- Unique `(conversation_id, user_id)`
- `(user_id, conversation_id)`

`direct_conversations`:

- `(user_a_id)`
- `(user_b_id)`
- Functional or generated participant key for pair lookup if used frequently

`pickup_games`:

- `(start_time, sport, status)`
- `(location_id, start_time)`
- `(creator_user_id, start_time)`
- Spatial/geographic index if querying by coordinates/bounds

`pickup_places`:

- `(latitude, longitude)` or spatial index
- GIN on `sport_tags` if array contains/filtering is server-side
- `(place_type)`

`venues`:

- `(admin_status, latitude, longitude)`
- Spatial/geographic index for map bounds
- `(business_id, admin_status)`
- `(owner_email, admin_status)`
- Trigram index for `venue_name ILIKE` fallback searches

`live_matches`:

- `(start_time, sport, status)`
- `(status, start_time)`
- `(external_id)` if imported/matched by provider ID

### Query Performance Risks

- Raw row aggregation on client for interest counts does not scale as well as `count(*) group by venue_event_id`.
- Realtime invalidation followed by REST refetch multiplies database reads during write bursts.
- RLS policies can add significant planning/execution cost on high-cardinality realtime tables.
- OR filters on conversations and venue event keyset pagination need matching indexes to avoid scans.
- Bounds queries on latitude/longitude need composite or spatial indexing.

## 6. Startup / Session Audit

Auth restore timing risks:

- Critical bootstrap calls `bootstrapAuthSessionOnly()` before Discover core refresh and chat badge load finish.
- Supabase session resolution may refresh expired sessions.
- Business restore has multiple preservation/pending paths; these protect correctness but can extend time to fully authenticated UI.

Business restore risks:

- Business restore now avoids destructive logout on transient missing session, but pending state can leave business-only surfaces in an in-between state.
- Multiple surfaces call `ensureBusinessOwnerSessionFlagsIfPossible`, including Discover, warm preload, and dashboard/settings.
- If business hydration runs after splash timeout, Settings may render before all owner venue data is available.

Prefetch sequencing:

- Critical bootstrap:
  1. Render cached Discover core.
  2. Prepare initial region/preload.
  3. Restore auth session.
  4. Refresh Discover core in background.
  5. Load chat unread badge if authenticated.
- Warm preload:
  1. Business owner hydration after 220 ms.
  2. Lightweight user prefetch after 180 ms.
  3. Chat badges/inbox/friend requests after 220 ms.
  4. Pokes badge after 160 ms.

Splash timeout effects:

- `BootstrapLoadingCoordinator` has a maximum wait of 3.8 seconds.
- If bootstrap exceeds that, the app opens while auth restore continues.
- This is better for perceived speed, but can produce temporary UI uncertainty if auth/business state is not ready.

Profile/avatar warm preload effectiveness:

- Profile/avatar URLs are detected in `prefetchLightweightUserDataForStartup`, but actual image prewarming is limited.
- Avatar cache is shared and useful, but only 72 entries and memory-only.

What could make startup feel instant:

- Treat cached Discover render as the true first paint and defer all nonessential auth/profile/social work.
- Render profile/settings from durable local auth snapshot while Supabase session refresh completes.
- Add a local "last known account mode + display identity" cache separate from destructive auth state.
- Prewarm the current user's avatar thumbnail immediately after session restore.
- Move chat unread badge to a server-side single RPC that is guaranteed indexed and cheap.

## 7. Major Match Stress Scenario

Scenario:

- 500 users viewing the same venue event.
- Many Going taps.
- Many reactions.
- Fan chat active.
- Venue activity counts updating.
- Ads loading.
- Users switching tabs.

What likely breaks first:

1. Engagement count freshness.
   - `venue_event_interests` writes spike.
   - Clients optimistically update their own state, but cross-device counts depend on refetch/reconcile.
   - Raw row reads/aggregation become expensive.

2. Fan chat reaction freshness.
   - Comments may arrive through realtime or fallback.
   - Reactions have debounce, ready grace, and 8-second fallback polling, so counts can lag under bursty use.

3. Venue owner analytics.
   - Realtime invalidates into REST refetch for all tracked event IDs.
   - Each event can load interests, comments, and vibes.
   - This is likely to lag and consume Supabase quota under burst writes.

4. MainActor UI responsiveness.
   - Comment list updates, map cards, avatar image state changes, ads, and broad `MapViewModel` publishes can contend.
   - Scrolling and tab switching can hitch if many states publish together.

5. Realtime channel stability.
   - Hundreds of clients subscribed to the same hot rows/tables can produce delayed Realtime delivery.
   - Client fallback polling then increases REST load, amplifying pressure.

6. Ad impact.
   - Ad SDK network and layout callbacks compete with image and Supabase traffic.
   - Native ads in comments can shift list layout while realtime comments arrive.

Why:

- High write fan-out creates both realtime events and follow-up REST reads.
- Client aggregation makes every device do repeated work.
- Shared observable state turns many small server events into broad UI invalidations.
- Fallback polling starts when realtime is unhealthy, exactly when the backend is already stressed.

What would make this scenario reliable:

- Server-maintained event engagement counters.
- Broadcast deltas for comments/reactions/vibes/going counts.
- One event activity stream per `venue_event_id`.
- Local optimistic state with sequence-numbered server reconciliation.
- Explicit backpressure: degrade reaction/analytics updates before chat message delivery.

## 8. Prioritized Roadmap

### No-Risk Fixes Later

1. Document performance budgets per surface.
   - Impact: medium.
   - Files: docs only.
   - Risk: none.
   - Validation: review budget coverage against major-match scenario.

2. Add release-only build comparison checklist.
   - Impact: medium.
   - Files: docs/CI.
   - Risk: none.
   - Validation: compare Debug vs Release latency before performance conclusions.

3. Audit and gate debug logging volume.
   - Impact: medium in Debug, low in Release.
   - Files: many `print` hot paths, `DebugLogGate`, `AdDebugDiagnostics`.
   - Risk: low if logs remain available behind flags.
   - Validation: count log lines per 60 seconds during simulated match.

4. Add a metrics naming guide.
   - Impact: medium.
   - Files: docs.
   - Risk: none.
   - Validation: every metric in section 9 has owner and unit.

### Low-Risk Fixes Later

1. Precompute sorted comments when store updates.
   - Impact: high for fan chat scrolling.
   - Files: `MapViewModel+CommentsAndVibes.swift`, `FanUpdatesRealtimeStore.swift`, `VenueEventCommentsView.swift`.
   - Risk: low.
   - Validation: measure comment list body time and frame drops before/after.

2. Increase and segment image cache.
   - Impact: medium.
   - Files: `DiscoverMapImageCache.swift`, `UserAvatarView.swift`, `SocialAvatarRenderer.swift`.
   - Risk: low/medium due memory.
   - Validation: cache hit rate, memory warnings, avatar load p95.

3. Add request coalescing IDs to more Discover refresh paths.
   - Impact: high.
   - Files: `DiscoverScreen.swift`, `MapViewModel+VenueAndGameData.swift`, `MapViewModel+PickupPlaces.swift`.
   - Risk: low/medium.
   - Validation: duplicate request count and map reload p95.

4. Defer noncritical avatar/profile refresh during active chat/comment scrolling.
   - Impact: medium.
   - Files: `LaunchWarmPreloadCoordinator.swift`, profile/avatar loaders.
   - Risk: low.
   - Validation: scroll FPS during warm preload.

5. Keep ad layout slots stable.
   - Impact: medium.
   - Files: `AdaptiveBannerView.swift`, `CompactNativeAdCard.swift`, ad placement files.
   - Risk: low.
   - Validation: layout pass count and scroll hitch rate with ads enabled.

### Medium-Risk Fixes Later

1. Add aggregate RPCs for visible event interest counts.
   - Impact: very high.
   - Files: `MapViewModel+VenueEventSocial.swift`, Supabase SQL.
   - Risk: medium due backend contract.
   - Validation: query p95, count freshness, RLS correctness.

2. Split `FanUpdatesRealtimeStore` into comment, reaction, vibe, and preview stores.
   - Impact: high.
   - Files: `FanUpdatesRealtimeStore.swift`, `MapViewModel+CommentsAndVibes.swift`, `VenueEventCommentsView.swift`, venue cards.
   - Risk: medium.
   - Validation: SwiftUI invalidation counts and realtime latency.

3. Add event activity cache.
   - Impact: high.
   - Files: social/view model/store files.
   - Risk: medium.
   - Validation: cache hit rate and stale count incidents.

4. Convert owner analytics realtime from invalidation refetch to incremental deltas.
   - Impact: high for business dashboards.
   - Files: `MapViewModel+VenueOwnerAnalyticsRealtime.swift`, dashboard loaders, backend.
   - Risk: medium.
   - Validation: analytics update p95 with 50 tracked events.

5. Add durable DM thread cache.
   - Impact: medium/high.
   - Files: `DirectChatView.swift`, `DirectChatService.swift`, local cache layer.
   - Risk: medium.
   - Validation: thread open p95 and stale-message reconciliation.

### High-Risk Architecture Changes Later

1. Replace row-level Realtime for hot event engagement with Edge Function broadcasts.
   - Impact: very high.
   - Files: Supabase backend, social stores, realtime subscription helpers.
   - Risk: high.
   - Validation: load test with 500 clients and p99 update latency.

2. Split `MapViewModel` into feature stores.
   - Impact: very high.
   - Files: many screens and extensions.
   - Risk: high.
   - Validation: compile-time ownership tests, UI regression, recomposition metrics.

3. Server-maintained counters/materialized views for event engagement.
   - Impact: very high.
   - Files: Supabase schema/RPC, clients.
   - Risk: high.
   - Validation: consistency checks against raw tables under write bursts.

4. Build a formal realtime session manager.
   - Impact: high.
   - Files: `ChatViewModel.swift`, `MapViewModel+CommentsAndVibes.swift`, owner analytics, pickup realtime.
   - Risk: high.
   - Validation: reconnect tests, foreground/background tests, chaos network tests.

## 9. Metrics to Capture

Recommended future metrics/signposts:

- `startup.critical_bootstrap_ms`: p50/p95/p99 from app launch to main tabs visible.
- `startup.cached_discover_render_ms`: disk snapshot decode/publish time.
- `startup.auth_restore_ms`: Supabase session restore start-to-complete.
- `startup.business_restore_ms`: business restore start-to-dashboard-ready.
- `startup.warm_preload_ms`: total and per warm task.
- `discover.load_venues_ms`: p50/p95/p99 for `loadVenuesFromSupabase`.
- `discover.map_camera_end_to_pins_updated_ms`: camera end to rendered pins.
- `discover.snapshot_build_ms`: detached snapshot build duration and cancellation count.
- `discover.calendar_dots_ms`: calendar open/month change to dots rendered.
- `venue_detail.open_to_first_content_ms`: tap venue to first visible content.
- `venue_detail.open_to_social_counts_ms`: tap venue to comments/vibes/going visible.
- `fan_chat.send_tap_to_optimistic_ms`: should be under 50 ms.
- `fan_chat.send_tap_to_insert_ms`: p50/p95/p99.
- `fan_chat.insert_to_realtime_received_ms`: p50/p95/p99.
- `fan_chat.realtime_received_to_rendered_ms`: p50/p95/p99.
- `fan_chat.fallback_used_rate`: percentage of comments requiring fallback.
- `fan_chat.duplicate_event_rate`: realtime rows ignored as duplicates.
- `fan_chat.reaction_tap_to_rendered_ms`: p50/p95/p99.
- `dm.thread_open_ms`: thread open to latest messages visible.
- `dm.send_tap_to_optimistic_ms`: should be under 50 ms.
- `dm.send_tap_to_insert_ms`: p50/p95/p99.
- `dm.insert_to_realtime_received_ms`: p50/p95/p99.
- `dm.realtime_received_to_rendered_ms`: p50/p95/p99.
- `dm.fallback_used_rate`: percentage of messages requiring fallback.
- `dm.inbox_unread_refresh_ms`: unread RPC/fallback duration.
- `going.tap_to_local_count_ms`: should be under 50 ms.
- `going.tap_to_server_confirm_ms`: p50/p95/p99.
- `going.server_confirm_to_cross_device_count_ms`: p50/p95/p99.
- `query.duration_ms`: table, operation, filter shape, row count, screen.
- `query.duplicate_count`: same table/filter called repeatedly within 5 seconds.
- `main_actor.block_ms`: blocks over 50/100/250 ms.
- `swiftui.body_count`: body evaluations for hot views per interaction.
- `scroll.frame_drop_count`: dropped frames by screen.
- `cache.avatar_hit_rate`: hits/misses/in-flight joins.
- `cache.discover_snapshot_age_sec`: age at render.
- `ad.request_to_loaded_ms`: per placement and format.
- `ad.layout_pass_count`: UIKit bridge layout/update count per screen minute.
- `realtime.subscribe_ms`: subscribe requested to ready per channel.
- `realtime.disconnect_count`: per session.
- `realtime.reconnect_gap_ms`: disconnect to healthy.

Recommended future tools:

- `os_signpost` for hot paths in Release/TestFlight builds.
- Supabase query duration logging with table/filter hash, row count, and screen.
- A lightweight in-app performance HUD only for internal builds.
- Synthetic major-match test harness that fires Going, comments, reactions, tab switches, and ad loading concurrently.

## 10. Validation Plan for Future Optimization

Before changing architecture:

1. Measure Debug and Release separately.
2. Capture baseline p50/p95/p99 for all metrics in section 9.
3. Run a scripted local scenario:
   - Cold launch.
   - Open Discover.
   - Open venue detail.
   - Open fan chat.
   - Send comment.
   - Toggle reaction.
   - Toggle Going.
   - Switch to Chat.
   - Send DM.
   - Switch tabs repeatedly.
4. Run a backend load scenario:
   - 500 clients/readers.
   - 50 concurrent Going writes/minute.
   - 200 comments/minute.
   - 500 reactions/minute.
   - Owner dashboard open.
5. Compare:
   - Server insert latency.
   - Realtime receive latency.
   - Client render latency.
   - REST fallback rate.
   - dropped frames.

## Final Assessment

FanGeo is close to feeling instant for single-user and moderate-traffic flows because it already uses optimistic UI, caches, lazy tabs, coalescing, and fallback refreshes. The biggest gap for major sports moments is that high-traffic social state is still mostly row-driven and client-aggregated. The app can show the local user's own action instantly, but cross-device truth often depends on Supabase Realtime plus REST reconciliation.

For a 3-5 second delay to disappear under load, the next phase should prioritize event-scoped aggregate/delta delivery, smaller observable stores, and hard latency metrics. The goal should be:

- Local user action visible in under 50 ms.
- Same-device server confirmation p95 under 700 ms.
- Cross-device realtime visible p95 under 1 second.
- Fallback visible p95 under 2 seconds.
- No scroll frame drops during chat/comment bursts.

