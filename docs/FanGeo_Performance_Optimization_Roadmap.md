# FanGeo Performance Optimization Roadmap

Date: 2026-05-24

Source: `docs/FanGeo_Performance_Realtime_Audit.md`

Scope: planning/report only. This roadmap does not modify product code, refactor UI, change Supabase schema, or alter backend behavior. File paths below are the likely implementation touchpoints for future work.

## Goals And Priority Order

The execution order should protect correctness first, then reduce visible latency. FanGeo already has optimistic UI, caching, lazy tabs, and fallback refreshes; the roadmap focuses on making those paths measurable, cheaper, and eventually event-delta driven.

Priority order:

1. Realtime DM send, receive, unread, and inbox summaries feel flawless.
2. Realtime fan chat comments feel flawless.
3. Going counts update instantly on the tapping device and quickly across devices.
4. Reactions update instantly and do not rebuild the full comment surface.
5. Venue activity counts update instantly without analytics refetch storms.
6. Discover stays smooth during camera movement, tab switching, and major-match traffic.
7. Chat/comment/Discover scrolling stays smooth with ads and avatars active.
8. Startup/auth/session restore does not regress while performance work lands.

Success targets from the audit:

- Local user action visible in under 50 ms.
- Same-device server confirmation p95 under 700 ms.
- Cross-device realtime visible p95 under 1 second.
- Fallback visible p95 under 2 seconds.
- No scroll frame drops during chat/comment bursts.

## Top 5 Safest Fixes To Do First

These are the safest first implementation items because they either measure behavior, reduce repeated work, or preserve existing user-visible behavior.

1. Add Release-safe latency metrics and signposts for DM, fan chat, Going, reactions, Discover, startup, queries, and realtime channel health.
  - Why first: every later phase needs p50/p95/p99 baselines and rollback criteria.
  - Likely files: `GameOn/ChatViewModel.swift`, `GameOn/DirectChatView.swift`, `GameOn/DirectChatService.swift`, `GameOn/VenueEventCommentsView.swift`, `GameOn/MapViewModel+CommentsAndVibes.swift`, `GameOn/MapViewModel+VenueEventSocial.swift`, `GameOn/DiscoverScreen.swift`, `GameOn/MapViewModel+VenueAndGameData.swift`, `GameOn/BootstrapLoadingCoordinator.swift`, new `GameOn/PerformanceMetrics.swift`.
2. Gate and rate-limit hot DEBUG logging in realtime, Discover, ads, startup, and auth paths.
  - Why first: low behavior risk and prevents Debug builds from misleading performance conclusions.
  - Likely files: `GameOn/DMRealtimeDiagnostics.swift`, `GameOn/MapViewModel+CommentsAndVibes.swift`, `GameOn/MapViewModel+VenueAndGameData.swift`, `GameOn/MapViewModel+StartupPrefetch.swift`, `GameOn/AdaptiveBannerView.swift`, `GameOn/CompactNativeAdCard.swift`, new `GameOn/DebugLogGate.swift`.
3. Precompute sorted fan-chat comments when store data changes instead of sorting from `VenueEventCommentsView` body/computed access.
  - Why first: contained client work with high impact on fan-chat scroll smoothness.
  - Likely files: `GameOn/FanUpdatesRealtimeStore.swift`, `GameOn/MapViewModel+CommentsAndVibes.swift`, `GameOn/VenueEventCommentsView.swift`.
4. Add per-surface request coalescing and last-writer-wins tokens around Discover refresh paths.
  - Why first: reduces duplicate map/network work without changing UI or backend contracts.
  - Likely files: `GameOn/DiscoverScreen.swift`, `GameOn/MapViewModel+VenueAndGameData.swift`, `GameOn/MapViewModel+PickupPlaces.swift`, `GameOn/MapViewModel+StartupPrefetch.swift`.
5. Stabilize chat/comment/ad scroll work by preserving layout slots and deferring noncritical avatar/profile refresh during active scrolling.
  - Why first: targets scroll lag without changing visual design.
  - Likely files: `GameOn/VenueEventCommentsView.swift`, `GameOn/VenueCommentsAdPlacement.swift`, `GameOn/CompactNativeAdCard.swift`, `GameOn/AdaptiveBannerView.swift`, `GameOn/UserAvatarView.swift`, `GameOn/SocialAvatarRenderer.swift`, `GameOn/DiscoverMapImageCache.swift`, `GameOn/LaunchWarmPreloadCoordinator.swift`.

## Phase 0 — Measurement And Instrumentation Only

Objective: establish trustworthy baselines before optimizing. This phase should not change user-facing behavior.

### 0.1 Add A Shared Performance Metrics Helper

- Likely files touched: new `GameOn/PerformanceMetrics.swift`, `GameOn/BootstrapLoadingCoordinator.swift`, `GameOn/MainTabView.swift`.
- Expected impact: high confidence in future decisions; no direct latency improvement.
- Risk level: low.
- Validation test: confirm metrics compile in Debug and Release, have units, and can be disabled or sampled; run cold launch and verify `startup.critical_bootstrap_ms`, `startup.auth_restore_ms`, and `startup.warm_preload_ms` are emitted once per launch.
- Rollback plan: remove the helper calls or disable the helper behind a compile-time/internal flag.
- Ship before TestFlight: yes, if metrics are internal-only and do not log sensitive data.

### 0.2 Measure DM Latency End To End

- Likely files touched: `GameOn/DirectChatView.swift`, `GameOn/DirectChatService.swift`, `GameOn/ChatViewModel.swift`, `GameOn/DMRealtimeDiagnostics.swift`.
- Expected impact: exposes send-tap-to-optimistic, send-tap-to-insert, insert-to-realtime, realtime-to-rendered, fallback-used-rate, unread RPC duration, and reconnect gaps.
- Risk level: low.
- Validation test: scripted local flow opens a DM thread, sends messages both directions, backgrounds/foregrounds the app, and reports p50/p95/p99 for `dm.*` metrics.
- Rollback plan: disable metric emission with one flag; leave existing DM behavior untouched.
- Ship before TestFlight: yes.

### 0.3 Measure Fan Chat, Reactions, Going, And Venue Activity

- Likely files touched: `GameOn/VenueEventCommentsView.swift`, `GameOn/MapViewModel+CommentsAndVibes.swift`, `GameOn/FanUpdatesRealtimeStore.swift`, `GameOn/MapViewModel+VenueEventSocial.swift`, `GameOn/MapViewModel+VenueOwnerAnalyticsRealtime.swift`, `GameOn/VenueDetailView.swift`.
- Expected impact: reveals whether delays come from realtime join, fallback wait, server insert, client rendering, or MainActor contention.
- Risk level: low.
- Validation test: send a comment, tap reactions, toggle Going, open owner analytics, and verify metrics for `fan_chat.*`, `going.*`, `realtime.*`, and `main_actor.block_ms`.
- Rollback plan: disable metrics at the shared helper.
- Ship before TestFlight: yes.

### 0.4 Measure Discover Smoothness And Duplicate Requests

- Likely files touched: `GameOn/DiscoverScreen.swift`, `GameOn/MapViewModel+VenueAndGameData.swift`, `GameOn/DiscoverMapRenderSnapshot.swift`, `GameOn/MapViewModel+PickupPlaces.swift`, `GameOn/AdaptiveBannerView.swift`, `GameOn/CompactNativeAdCard.swift`.
- Expected impact: identifies overlapping `loadVenuesFromSupabase`, map snapshot rebuild time, camera-to-pins latency, ad layout churn, and dropped frames.
- Risk level: low.
- Validation test: pan/zoom the map, switch tabs, open/close venue cards, and verify `discover.load_venues_ms`, `discover.snapshot_build_ms`, `discover.map_camera_end_to_pins_updated_ms`, `query.duplicate_count`, and `scroll.frame_drop_count`.
- Rollback plan: remove measurement wrappers or disable sampling.
- Ship before TestFlight: yes.

### 0.5 Add Supabase Query Duration And Shape Logging

- Likely files touched: `GameOn/SupabaseClientManager.swift`, `GameOn/DirectChatService.swift`, `GameOn/MapViewModel+VenueAndGameData.swift`, `GameOn/MapViewModel+VenueEventSocial.swift`, `GameOn/MapViewModel+CommentsAndVibes.swift`, `GameOn/MapViewModel+PickupGames.swift`.
- Expected impact: makes slow query shapes visible before adding indexes or RPCs.
- Risk level: low/medium because wrappers around database calls can accidentally log too much.
- Validation test: verify logs include table, operation, filter shape hash, row count, screen, and duration without emails, message bodies, auth tokens, or profile text.
- Rollback plan: remove wrapper usage or keep wrapper disabled by default.
- Ship before TestFlight: yes, only with privacy-safe sampling.

## Phase 1 — No-Risk / Low-Risk Client Fixes

Objective: reduce repeated client work while preserving existing data paths, optimistic behavior, UI, and backend contracts.

### 1.1 Gate And Rate-Limit Hot Debug Logs

- Likely files touched: `GameOn/DMRealtimeDiagnostics.swift`, `GameOn/MapViewModel+CommentsAndVibes.swift`, `GameOn/MapViewModel+VenueAndGameData.swift`, `GameOn/MapViewModel+StartupPrefetch.swift`, `GameOn/MapViewModel+AuthAndProfile.swift`, `GameOn/AdaptiveBannerView.swift`, `GameOn/CompactNativeAdCard.swift`, new `GameOn/DebugLogGate.swift`.
- Expected impact: medium in Debug, low in Release; cleaner measurements and fewer hot-path string interpolations.
- Risk level: low.
- Validation test: simulated major-match flow produces bounded log lines per 60 seconds while key diagnostic tags remain available on demand.
- Rollback plan: bypass the gate for affected log tags or revert the helper.
- Ship before TestFlight: yes.

### 1.2 Precompute Ordered Fan Chat Comments

- Likely files touched: `GameOn/FanUpdatesRealtimeStore.swift`, `GameOn/MapViewModel+CommentsAndVibes.swift`, `GameOn/VenueEventCommentsView.swift`.
- Expected impact: high for fan chat scrolling and comment burst rendering; removes repeated sorting from view evaluation.
- Risk level: low.
- Validation test: before/after compare `fan_chat.realtime_received_to_rendered_ms`, comment list body counts, and dropped frames while sending 200 comments/minute in a test scenario.
- Rollback plan: keep old computed sorting path behind a temporary flag and switch back if ordering/dedupe bugs appear.
- Ship before TestFlight: yes.

### 1.3 Add Immediate Incremental Fan Chat Fallback When Realtime Health Is Unknown

- Likely files touched: `GameOn/MapViewModel+CommentsAndVibes.swift`, `GameOn/FanUpdatesRealtimeStore.swift`, `GameOn/VenueEventCommentsView.swift`.
- Expected impact: high for fan chat reliability; avoids waiting the full first-poll grace when a channel is not ready.
- Risk level: low/medium due extra reads if poorly throttled.
- Validation test: force realtime subscribe failure, send comments, and verify fallback visible p95 under 2 seconds with no duplicate rows.
- Rollback plan: restore existing 2.5 second first-poll grace and keep metrics.
- Ship before TestFlight: yes, if throttled and deduped.

### 1.4 Add Discover Refresh Coalescing And Last-Writer-Wins Tokens

- Likely files touched: `GameOn/DiscoverScreen.swift`, `GameOn/MapViewModel+VenueAndGameData.swift`, `GameOn/MapViewModel+PickupPlaces.swift`, `GameOn/MapViewModel+StartupPrefetch.swift`, `GameOn/DiscoverMapRenderSnapshot.swift`.
- Expected impact: high for Discover smoothness; reduces overlapping map/network/snapshot work from camera movement, startup refresh, foreground, and tab switching.
- Risk level: low/medium.
- Validation test: rapid map pans and tab switches should show lower `query.duplicate_count`, fewer canceled-but-published snapshots, and stable pin render latency.
- Rollback plan: disable coalescing per surface and fall back to current refresh behavior.
- Ship before TestFlight: yes.

### 1.5 Defer Noncritical Avatar/Profile Refresh During Active Chat Or Comment Scrolling

- Likely files touched: `GameOn/UserAvatarView.swift`, `GameOn/SocialAvatarRenderer.swift`, `GameOn/DiscoverMapImageCache.swift`, `GameOn/LaunchWarmPreloadCoordinator.swift`, `GameOn/MapViewModel+StartupPrefetch.swift`, `GameOn/VenueEventCommentsView.swift`, `GameOn/DirectChatView.swift`.
- Expected impact: medium for scroll smoothness and startup perceived stability.
- Risk level: low.
- Validation test: scroll a hot comment sheet and DM thread during warm preload; verify fewer frame drops and no permanent missing avatars after scrolling stops.
- Rollback plan: remove the active-scroll defer gate.
- Ship before TestFlight: yes.

### 1.6 Keep Ad Layout Slots Stable During Scroll

- Likely files touched: `GameOn/AdaptiveBannerView.swift`, `GameOn/CompactNativeAdCard.swift`, `GameOn/VenueCommentsAdPlacement.swift`, `GameOn/DiscoverScreen.swift`.
- Expected impact: medium for scroll smoothness; reduces layout shifts while comments/realtime rows arrive.
- Risk level: low/medium because ad loading behavior must remain compliant.
- Validation test: compare scroll frame drops and `ad.layout_pass_count` with ads enabled while comments arrive.
- Rollback plan: restore current ad view sizing/update behavior.
- Ship before TestFlight: yes, after ad behavior verification.

### 1.7 Narrow Hot Row Invalidations Without Splitting Architecture

- Likely files touched: `GameOn/VenueEventCommentsView.swift`, `GameOn/DirectChatView.swift`, `GameOn/MapVenuePreviewCard.swift`, `GameOn/GoingAvatarStack.swift`, `GameOn/VenueDetailView.swift`.
- Expected impact: medium/high for scroll and card smoothness; isolates reaction/count/avatar row updates from whole-screen rebuilds.
- Risk level: low/medium.
- Validation test: count body evaluations for hot views before/after tapping Going, reactions, and receiving comments.
- Rollback plan: keep the old direct dictionary/closure reads behind small adapter boundaries and revert affected row wrappers.
- Ship before TestFlight: yes if scoped to one surface at a time.

## Phase 2 — Supabase Query / Index Improvements

Objective: reduce slow reads and fan-out aggregation before changing realtime architecture. Each database change should ship behind client compatibility with current code paths.

### 2.1 Add Or Verify DM Hot-Path Indexes

- Likely files touched: `supabase/migrations/<timestamp>_dm_hot_path_indexes.sql`, `supabase/diagnostics/direct_messages_realtime_checks.sql`, `GameOn/DirectChatService.swift`, `GameOn/ChatViewModel.swift`.
- Expected impact: high for DM thread open, newer/older pagination, unread refresh, and inbox fallback.
- Risk level: medium due backend/index deployment.
- Validation test: `EXPLAIN ANALYZE` for latest 50 messages, newer message fetch, unread total RPC, and conversation read-state lookup; compare p95 before/after.
- Rollback plan: drop newly added indexes only if they cause write degradation or migration issues; client remains compatible with old query paths.
- Ship before TestFlight: yes, after staging verification.

### 2.2 Add Or Verify Fan Chat Comment And Reaction Indexes

- Likely files touched: `supabase/migrations/<timestamp>_fan_chat_hot_path_indexes.sql`, `supabase/migrations/20260731_0001_venue_event_comments_realtime_publication.sql`, `supabase/migrations/20260731_0007_venue_event_comment_likes.sql`, `supabase/migrations/20260731_0027_venue_event_comment_reactions.sql`, `GameOn/MapViewModel+CommentsAndVibes.swift`.
- Expected impact: high for comment initial load, incremental fallback, reaction reconciliation, and moderation filters.
- Risk level: medium.
- Validation test: `EXPLAIN ANALYZE` for comments by `venue_event_id, created_at, id`, reactions by `comment_id`, and hidden/moderation filters; verify write p95 under burst load.
- Rollback plan: drop problematic indexes; keep app fallback/realtime behavior unchanged.
- Ship before TestFlight: yes, after staging and write-load verification.

### 2.3 Replace Visible Going Count Raw Row Aggregation With Aggregate RPC

- Likely files touched: `supabase/migrations/<timestamp>_venue_event_interest_counts_rpc.sql`, `GameOn/MapViewModel+VenueEventSocial.swift`, `GameOn/MapViewModel+VenueAndGameData.swift`, `GameOn/FollowingScreen.swift`, `GameOn/MapVenuePreviewCard.swift`.
- Expected impact: very high for Going count freshness and Discover scalability.
- Risk level: medium due backend contract and RLS correctness.
- Validation test: compare raw client aggregation vs RPC count for the same event IDs; validate p95 query duration, row count, and count correctness under 50 concurrent Going writes/minute.
- Rollback plan: keep the current raw-row loader as fallback behind a feature flag.
- Ship before TestFlight: yes if read-only RPC is validated; otherwise defer.

### 2.4 Add Discover And Venue Event Query Indexes

- Likely files touched: `supabase/migrations/<timestamp>_discover_venue_event_indexes.sql`, `GameOn/MapViewModel+VenueAndGameData.swift`, `GameOn/MapViewModel+StartupPrefetch.swift`, `GameOn/MapViewModel+FollowingTab.swift`.
- Expected impact: high for Discover, Calendar dots, Live venue slices, and startup refresh.
- Risk level: medium.
- Validation test: `EXPLAIN ANALYZE` for venue events by `(venue_id, event_date, admin_status)`, `(event_date, sport, admin_status)`, `(scheduled_start_at, sport, admin_status)`, and `(owner_email, event_date, admin_status)`.
- Rollback plan: drop individual indexes that do not improve plans or harm writes.
- Ship before TestFlight: yes after staging.

### 2.5 Add Venue And Location Query Indexes

- Likely files touched: `supabase/migrations/<timestamp>_venue_location_indexes.sql`, `GameOn/MapViewModel+VenueAndGameData.swift`, `GameOn/MapViewModel+PickupPlaces.swift`.
- Expected impact: medium/high for map bounds, venue search, and pickup/place loading.
- Risk level: medium.
- Validation test: compare p95 for map bounds queries, venue owner/business lookup, and place-type filters; verify index use for `(admin_status, latitude, longitude)`, `(business_id, admin_status)`, and `(owner_email, admin_status)`.
- Rollback plan: drop ineffective indexes; client code remains compatible.
- Ship before TestFlight: yes if index creation is safe for database size.

### 2.6 Tighten Select Columns And Keyset Query Shapes

- Likely files touched: `GameOn/DirectChatService.swift`, `GameOn/MapViewModel+VenueAndGameData.swift`, `GameOn/MapViewModel+CommentsAndVibes.swift`, `GameOn/MapViewModel+StartupPrefetch.swift`, `GameOn/MapViewModel+PickupGames.swift`.
- Expected impact: medium; reduces payload size, decode cost, and RLS/read pressure.
- Risk level: low/medium because missing columns can break screens.
- Validation test: compile plus scripted flows for Discover, venue detail, fan chat, DM thread pagination, startup, and pickup; compare row bytes and decode duration.
- Rollback plan: restore broader `.select()` or prior column lists per failing surface.
- Ship before TestFlight: yes if covered by flow tests.

## Phase 3 — Realtime / Counter Architecture

Objective: move hot social state from row-driven invalidation plus REST refetch toward event-scoped counters and delta delivery.

### 3.1 Build A Local Event Engagement Cache

- Likely files touched: new `GameOn/EventEngagementStore.swift`, `GameOn/FanUpdatesRealtimeStore.swift`, `GameOn/MapViewModel+VenueEventSocial.swift`, `GameOn/MapViewModel+CommentsAndVibes.swift`, `GameOn/VenueDetailView.swift`, `GameOn/MapVenuePreviewCard.swift`, `GameOn/GoingAvatarStack.swift`.
- Expected impact: high; gives Going, comments, vibes, reactions, and venue activity one local source of truth fed by optimistic actions, realtime, and periodic reconciliation.
- Risk level: medium.
- Validation test: same event opened in Discover, venue detail, fan chat, Live, and owner dashboard should show consistent counts after optimistic tap, realtime echo, and background reconcile.
- Rollback plan: leave existing dictionaries as the source of truth and make the new store read-only until validated; remove store wiring per surface if stale counts appear.
- Ship before TestFlight: maybe; only if introduced incrementally behind a feature flag.

### 3.2 Add User-Scoped DM Inbox Summary Delivery

- Likely files touched: `GameOn/ChatViewModel.swift`, `GameOn/DirectChatService.swift`, `GameOn/DMRealtimeDiagnostics.swift`, `supabase/migrations/<timestamp>_dm_inbox_summary_rpc_or_table.sql`, optional `supabase/functions/dm-inbox-summary/index.ts`.
- Expected impact: very high for DM inbox and unread reliability; removes broad inbox reaction to row-level `direct_messages`.
- Risk level: high if backend semantics change; medium if implemented as additive read model.
- Validation test: two-device DM test with sends, reads, background/foreground, blocked users, deleted messages, and unread badge changes; p95 cross-device inbox update under 1 second.
- Rollback plan: retain current `direct_messages` and `conversation_read_state` listeners as fallback and disable summary delivery with a remote/internal flag.
- Ship before TestFlight: no unless Phase 0/1 metrics prove it and staging soak passes.

### 3.3 Add Event-Scoped Fan Chat / Reaction / Vibe Delta Stream

- Likely files touched: `GameOn/MapViewModel+CommentsAndVibes.swift`, `GameOn/FanUpdatesRealtimeStore.swift`, `GameOn/VenueEventCommentsView.swift`, `GameOn/VenueEventCommentsSheet.swift`, `supabase/migrations/<timestamp>_venue_event_activity_stream.sql`, optional `supabase/functions/venue-event-activity/index.ts`.
- Expected impact: very high for fan chat, reactions, venue activity, and major-match load.
- Risk level: high.
- Validation test: 500-reader scenario with 200 comments/minute and 500 reactions/minute; verify comment visible p95 under 1 second, fallback visible p95 under 2 seconds, duplicate event rate near zero.
- Rollback plan: keep existing Postgres realtime channels and REST fallback; disable the new event stream per event or globally.
- Ship before TestFlight: no for first implementation; stage behind internal flag.

### 3.4 Add Server-Maintained Going And Reaction Counters

- Likely files touched: `supabase/migrations/<timestamp>_venue_event_engagement_counters.sql`, `GameOn/MapViewModel+VenueEventSocial.swift`, `GameOn/MapViewModel+CommentsAndVibes.swift`, `GameOn/FanUpdatesRealtimeStore.swift`, `GameOn/VenueDetailView.swift`, `GameOn/MapVenuePreviewCard.swift`.
- Expected impact: very high; eliminates repeated raw row aggregation and enables cheap cross-device count updates.
- Risk level: high because counter consistency must be proven under writes/deletes/RLS.
- Validation test: consistency checker compares counters to raw `venue_event_interests`, comment likes/reactions, comments, and vibes under burst writes and deletes.
- Rollback plan: keep raw-table aggregate/RPC reads as fallback; run counters read-only until accuracy is proven.
- Ship before TestFlight: no unless additive/read-only first.

### 3.5 Convert Venue Owner Analytics Realtime From Refetch To Delta Application

- Likely files touched: `GameOn/MapViewModel+VenueOwnerAnalyticsRealtime.swift`, `GameOn/VenueOwnerDashboardView.swift`, `GameOn/BusinessVenueDashboardOverviewView.swift`, `GameOn/FanUpdatesRealtimeStore.swift`, `supabase/migrations/<timestamp>_business_event_analytics_counts.sql`.
- Expected impact: high for venue activity instant updates and lower Supabase load during major matches.
- Risk level: medium/high.
- Validation test: owner dashboard open with 50 tracked events while fans tap Going, comments, reactions, and vibes; verify analytics p95 and query count reduction.
- Rollback plan: restore realtime-as-invalidator REST refresh path.
- Ship before TestFlight: no unless feature-flagged and limited to dashboard metrics.

### 3.6 Build A Formal Realtime Session Manager

- Likely files touched: new `GameOn/RealtimeSessionManager.swift`, `GameOn/ChatViewModel.swift`, `GameOn/DirectChatService.swift`, `GameOn/MapViewModel+CommentsAndVibes.swift`, `GameOn/MapViewModel+VenueOwnerAnalyticsRealtime.swift`, `GameOn/MapViewModel+PickupGames.swift`.
- Expected impact: high; standardizes subscribe health, reconnect backoff, foreground/background behavior, and fallback timing.
- Risk level: high because it centralizes many currently separate flows.
- Validation test: chaos network tests, foreground/background tests, tab switching, and duplicate channel detection across DM, fan chat, reactions, owner analytics, and pickup flows.
- Rollback plan: migrate one surface at a time and keep existing surface-specific subscription code behind adapters until parity is proven.
- Ship before TestFlight: no for broad manager; maybe for one surface behind a flag.

## Phase 4 — Major-Match Load Strategy

Objective: make FanGeo reliable when hundreds of fans hit the same event at once and ads, chat, reactions, Going, venue detail, and owner dashboards are active.

### 4.1 Create A Synthetic Major-Match Test Harness

- Likely files touched: new `tools/major_match_load_test/README.md`, new `tools/major_match_load_test/<script>`, `docs/FanGeo_Performance_Optimization_Roadmap.md`, optional `supabase/diagnostics/major_match_queries.sql`.
- Expected impact: very high confidence; validates fixes before users experience game-day load.
- Risk level: low if pointed only at staging/test data.
- Validation test: 500 readers, 50 Going writes/minute, 200 comments/minute, 500 reactions/minute, owner dashboard open, tab switches, and ad-enabled client sessions.
- Rollback plan: stop using the harness; no production code dependency.
- Ship before TestFlight: yes, as tooling only.

### 4.2 Define Load Budgets And Degradation Rules

- Likely files touched: `docs/FanGeo_Performance_Budgets.md`, `docs/FanGeo_Performance_Optimization_Roadmap.md`, future config file if degradation is implemented.
- Expected impact: high operational clarity; prevents lower-priority surfaces from starving chat/message delivery.
- Risk level: low for docs, medium when implemented.
- Validation test: review budgets against p50/p95/p99 metrics and major-match harness.
- Rollback plan: revise docs or disable any future degradation rules.
- Ship before TestFlight: yes for docs.

### 4.3 Prioritize Delivery Under Load

- Likely files touched: `GameOn/RealtimeSessionManager.swift`, `GameOn/MapViewModel+CommentsAndVibes.swift`, `GameOn/MapViewModel+VenueEventSocial.swift`, `GameOn/MapViewModel+VenueOwnerAnalyticsRealtime.swift`, `GameOn/AdaptiveBannerView.swift`, `GameOn/CompactNativeAdCard.swift`.
- Expected impact: very high during major matches; chat messages and DM delivery stay ahead of analytics, ads, and noncritical refresh.
- Risk level: high.
- Validation test: major-match harness should show DM/fan chat p95 under 1 second while analytics can degrade gracefully.
- Rollback plan: disable prioritization and return to current equal-priority refresh behavior.
- Ship before TestFlight: no until metrics and architecture are stable.

### 4.4 Add Server-Side Backpressure For Hot Event Counters

- Likely files touched: `supabase/functions/venue-event-activity/index.ts`, `supabase/migrations/<timestamp>_venue_event_activity_backpressure.sql`, `GameOn/FanUpdatesRealtimeStore.swift`, `GameOn/MapViewModel+VenueEventSocial.swift`.
- Expected impact: high; protects Supabase and clients from bursty counter/refetch amplification.
- Risk level: high.
- Validation test: 500-reader harness with counter burst load; verify message delivery remains healthy even if reaction/analytics updates are coalesced.
- Rollback plan: disable coalescing/backpressure and revert to direct row realtime plus REST fallback.
- Ship before TestFlight: no.

### 4.5 Split Broad Observable Stores After Hot Paths Are Proven

- Likely files touched: new `GameOn/DiscoverStore.swift`, new `GameOn/AuthProfileStore.swift`, new `GameOn/VenueSocialStore.swift`, new `GameOn/BusinessDashboardStore.swift`, `GameOn/MapViewModel.swift`, `GameOn/DiscoverScreen.swift`, `GameOn/VenueDetailView.swift`, `GameOn/CalendarScreen.swift`, `GameOn/SettingsScreen.swift`, `GameOn/LiveScreen.swift`, `GameOn/VenueOwnerDashboardView.swift`.
- Expected impact: very high for smoothness and maintainability; reduces unrelated `@Published` invalidations.
- Risk level: high.
- Validation test: compile/UI regression for all tabs, body evaluation counts before/after, startup/auth restore regression suite, Discover/Chat/Settings flows.
- Rollback plan: extract one store at a time, keep `MapViewModel` adapters during migration, and revert per-store if regressions appear.
- Ship before TestFlight: no unless limited to one low-risk store.

## Release Strategy

Recommended sequencing:

1. Ship Phase 0 measurement first.
2. Ship Phase 1 in small PRs, one surface at a time.
3. Ship Phase 2 indexes/RPCs only after query baselines prove the target bottleneck.
4. Build Phase 3 architecture behind flags and validate with Phase 4 harness before enabling broadly.
5. Do not start broad `MapViewModel` splitting until DM, fan chat, Going, reactions, and Discover have stable metrics and rollback paths.

Suggested pre-TestFlight candidates:

- Phase 0 metrics and privacy-safe query duration logging.
- Debug log gating.
- Precomputed comment ordering.
- Discover request coalescing.
- Active-scroll deferral for avatar/profile refresh.
- Safe index additions after staging verification.
- Read-only aggregate RPCs with client fallback.

Suggested post-TestFlight or flag-only candidates:

- DM inbox summary architecture.
- Event-scoped activity streams.
- Server-maintained counters as source of truth.
- Formal realtime session manager across all surfaces.
- Major-match backpressure.
- Broad feature-store split.

## Validation Checklist For Every Implementation PR

Each performance PR should include:

- Baseline metric before change.
- Same metric after change.
- Debug and Release build results.
- Scripted flow coverage:
  - Cold launch.
  - Discover open and map movement.
  - Venue detail open.
  - Fan chat open, comment send, reaction tap.
  - Going toggle.
  - DM thread open and send.
  - Tab switching.
  - Business dashboard/venue activity open when relevant.
- No startup/auth/session restore regression.
- No duplicate visible comments/messages/count flashback.
- Rollback flag or small revert plan.

## Final Recommendation

Start with measurement, log gating, fan-chat sort removal, Discover coalescing, and scroll-safe image/ad behavior. Those are the lowest-risk ways to improve the exact surfaces users feel first while building the evidence needed for Supabase indexes, aggregate RPCs, and eventually event-scoped realtime counters.