# FanGeo Performance, Realtime, and Scalability Audit

Date: May 23, 2026

Scope: report-only static audit of the FanGeo iOS app and Supabase query/index shape. No app code, backend code, SQL, UI, or account-deletion behavior was changed.

Verification performed: read-only source inspection with targeted searches and file reads across launch/auth, Discover/map, DMs, Fan Chat, Going/Interested, reactions/vibes, live games, image loading, logging, and migrations. No build was required for this documentation-only change.

## A. Executive Summary

FanGeo already has several correct ingredients for major-match responsiveness: cached Discover startup snapshots, phased venue loading, optimistic DM sends, optimistic Fan Chat comments, optimistic Going toggles, bounded image cache/in-flight image coalescing, keyset pagination for DMs/comments, debounced realtime reconnects, and defensive auth/session restoration.

The biggest remaining risk is fan-out under live match pressure. Many features are locally optimistic, but remote freshness often falls back to REST reconciliation, exact counts, profile hydration, or broad realtime subscriptions. At 500 venue-game watchers and 100 active Fan Chat users, those correctness paths can become the reason a user sees 3-5 second lag.

### Top 10 Performance Risks

1. `MapViewModel` is a single large `@MainActor` observable that owns Discover, auth, owner tools, comments, vibes, Going, predictions, live sports, pickup games, and social state. Hot updates can invalidate more SwiftUI than necessary.
2. DM inbox realtime listens to unfiltered `direct_messages` and `conversation_read_state`, relying on RLS. This is simple but can wake clients for every visible row allowed by RLS.
3. Fan Chat uses per-sheet realtime plus app-level tracked-event realtime plus fallback polling. Under heavy chat, duplicate safety is good, but fallback and exact-count reconciliation can stack.
4. Going count/card avatar reconciliation can query all interest rows for one event, then fetch user profiles by email. This is an N+1-style risk when many cards refresh.
5. Realtime inserts often trigger aggregate REST refreshes: unread badge recounts, comment counts, reaction counts, vibe summaries, prediction summaries, and receiver fallback refreshes.
6. Debug logging is extremely dense in realtime paths. It is compiled out in Release when guarded by `#if DEBUG`, but TestFlight/internal debug builds during game testing may distort latency.
7. Discover rendering still contains heavy map marker effects, shadows, gradients, animations, and repeated theme/identity calculations in large SwiftUI surfaces.
8. Live matches use a 60-second client cache plus a sync Edge Function cooldown. That is acceptable for a Live tab, but not enough for "instant" live venue activity unless paired with local venue-game realtime.
9. Database indexes exist for several hot paths, but some high-volume filters and aggregate shapes need stronger composite indexes or RPC-side aggregation.
10. Foreground handling can kick off auth validation, owner refresh, admin status check, DM realtime reconnect, Fan Chat realtime verification, pickup refreshes, and deferred batches around the same scene transition.

### Top 10 Fastest Wins

1. Add production-safe latency metrics counters around optimistic render, DB write ack, realtime receive, and fallback merge for DMs and Fan Chat.
2. Keep all send/tap flows optimistic; do not block UI on Supabase writes for DM, Fan Chat, Going, reactions, predictions, or vibes.
3. Replace per-event Going card full-row refreshes with a small RPC returning count, viewer state, and top avatar previews.
4. Add a server-side Fan Chat summary RPC returning comment count, latest preview rows, reaction counts, and viewer reactions in one call.
5. Add missing composite indexes for `venue_event_interests(venue_event_id, user_email)`, `venue_event_vibes(venue_event_id, vibe_type)`, and `venue_event_predictions(venue_event_id, prediction_type, choice)`.
6. Gate DEBUG hot-path logging behind a runtime flag, not only `#if DEBUG`, so performance testing can run quiet builds.
7. Precompute venue-game display models for visible cards instead of resolving themes, flags, sport metadata, and live energy repeatedly in SwiftUI body.
8. Increase image cache quality by adding byte-cost eviction and downsampling before storing `UIImage`.
9. Make foreground refreshes staggered and visibility-aware; only visible tab work should happen in the first foreground second.
10. Prefer one user-scoped broadcast or RPC delta stream for DM inbox/unread instead of unfiltered Postgres changes.

### Top 10 Critical Fixes Before TestFlight Scale

1. Add `EXPLAIN ANALYZE` verification for all SQL recommendations below in staging.
2. Create consolidated server RPCs for venue-game social state: Going count/viewer state/avatar preview, Fan Chat summary, reaction summary, and prediction summary.
3. Replace unfiltered DM inbox listener with a user-scoped realtime/broadcast strategy or a small channel filter that does not rely on large conversation lists.
4. Reduce Fan Chat fallback polling. It should be recovery-only, visibly bounded, and disabled once realtime is proven healthy.
5. Add stress-test scripts for 100 Fan Chat inserts, 100 Going toggles, 50 reaction/vibe writes, and concurrent DM sends.
6. Split hot UI display state from broad `MapViewModel` publisher invalidations without changing behavior.
7. Convert major Discover card calculations into cached display models keyed by venue event ID plus social version.
8. Add server-side aggregate indexes and RPCs before relying on realtime aggregate refresh during live matches.
9. Add memory-pressure and cache eviction policy to image loading.
10. Build a release-like performance test configuration with DEBUG logs quiet but diagnostics counters enabled.

## B. Latency Targets

- DM send local display: less than 300 ms, target less than 100 ms.
- DM remote receive to visible thread display: less than 750 ms p95, less than 1.5 s p99.
- DM unread badge update: less than 500 ms p95 after realtime receive.
- Fan Chat send local display: less than 300 ms, target less than 100 ms.
- Fan Chat remote receive to visible sheet display: less than 750 ms p95, less than 1.5 s p99.
- Fan Chat comment count update: less than 500 ms p95 after local send/realtime insert.
- Going count local update: less than 150 ms.
- Going remote propagation to other visible users: less than 1 s p95.
- Reaction/vibe local update: less than 150 ms.
- Reaction/vibe remote count propagation: less than 1 s p95.
- Venue card open: less than 500 ms to usable content.
- Discover first pins: less than 1 s from cold app usable state; cached pins should appear in less than 300 ms after root view render.
- Venue detail usable: less than 1 s, with images allowed to stream in after layout is stable.
- Live tab refresh visible cached data: less than 300 ms; fresh network sync should not block cached content.

## C. Current Architecture Findings

### 1. App Launch and Auth Restore

Files inspected:

- `GameOn/MapViewModel+AuthAndProfile.swift`
- `GameOn/MapViewModel+StartupPrefetch.swift`
- `GameOn/MainTabView.swift`
- `GameOn/MapViewModel+SingleSession.swift`
- `GameOn/SupabaseClientManager.swift`

Current behavior:

- `bootstrapAuthSessionOnly()` transitions through `loadingSession`, resolves Supabase session, checks deleted/disabled account state with `checkCurrentUserAdminStatus()`, restores account mode, and starts fan single-session realtime for fan users.
- `prefetchLightweightUserDataForStartup()` then does session validation, deleted-user check, `ensureUserProfileExists()`, `loadUserProfile()`, favorite venues, favorite teams, following today plans, fan identity preferences, home crowd, single-session enforcement, and pickup join request count.
- `MainTabView.handleAppBecameActive()` validates session, owner session data, single-session, admin status, DM realtime, Fan Chat realtime, pickup refreshes, and deferred foreground work.

Likely bottleneck:

- Launch and foreground still include multiple sequential auth/profile/social calls. Some are defensive and correct, but not all are critical to first paint.
- `checkCurrentUserAdminStatus()` is necessary for deleted/disabled blocking, but it should be the only blocking profile/admin query before the app becomes usable.
- Startup personalization currently awaits many useful but non-critical warm loads.

Risk level: High for cold start and foreground churn during games.

Proposed fixes:

- Keep auth restore and deleted/disabled check on the critical path.
- Move favorite teams, home crowd, following today plans, pickup count, and non-visible tab work into a priority queue after first usable frame.
- Add latency buckets: `auth_restore_ms`, `admin_status_check_ms`, `profile_load_ms`, `startup_prefetch_ms`, `foreground_batch_ms`.
- On foreground, run only visible-tab work immediately; delay owner refresh, pickup refresh, pokes refresh, and Fan Chat verification unless their surface is visible.

### 2. Tab Switching Performance

Files inspected:

- `GameOn/MainTabView.swift`
- `GameOn/ChatViewModel.swift`
- `GameOn/DirectChatView.swift`
- `GameOn/LiveScreen.swift`
- `GameOn/VenueOwnerDashboardView.swift`

Current behavior:

- Chat realtime intentionally remains active across tabs.
- `scheduleDeferredChatSocialRealtimeStartupIfNeeded()` delays social realtime startup after bootstrap.
- `setChatTabRealtimeEnabled(false)` is a no-op, preserving inbox/friend realtime outside Chat.
- Foreground logic performs visible-tab and deferred work.

Likely bottleneck:

- Preserving realtime is good for instant DMs, but tab switches can still trigger hidden work through broad `MapViewModel` updates.
- The Live tab recomputes filtered/sorted match lists in view properties.
- Chat and DirectChat are better isolated, but unread badge recalculation can still trigger RPC recounts.

Risk level: Medium.

Proposed fixes:

- Keep DM inbox realtime always-on for signed-in users, but avoid full inbox summary refreshes unless local patch fails.
- Add per-tab performance logging around first frame after tab selection.
- Cache Live tab filtered sections by `(liveMatchesVersion, filter, day)` rather than sorting/filtering in multiple computed properties.
- Use display-model version counters instead of publishing large arrays for surfaces that are not visible.

### 3. Discover and Map Performance

Files inspected:

- `GameOn/DiscoverScreen.swift`
- `GameOn/MapViewModel+VenueAndGameData.swift`
- `GameOn/DiscoverVenueLoadAssembler.swift`
- `GameOn/MapViewModel+VenueGameCardStore.swift`
- `GameOn/ThemeGradientBuilder.swift`
- `GameOn/VenueDetailView.swift`
- `GameOn/DiscoverMapImageCache.swift`
- `GameOn/ImageDisplayURL.swift`

Current behavior:

- Discover has disk snapshot restore via `DiscoverCoreDiskSnapshot`.
- Fresh load is phased: `refreshDiscoverCoreInBackground()` calls `loadVenuesFromSupabase()`, then schedules full enrichment.
- Venue rows use explicit column lists for fast pins and thumbnails.
- Viewport cache exists with a 90-second TTL and 6 entries.
- Venue detail has been simplified away from a large repeated hero image, which helps sheet open latency.
- `VenueMatchupCardView` still uses gradients, radial overlays, blur, shadows, and flag orbs.

Likely bottleneck:

- `DiscoverScreen` is very large and performs many calculations in SwiftUI body/subview functions.
- Map markers use animation, blur, shadows, glows, and debug `onAppear` logs.
- `VenueGameCardState` pulls live energy, going profiles, comment counts, vibe counts, prediction summaries, and avatar stacks per card.
- `refreshVenueGameCardGoingState()` reads all `venue_event_interests` rows for an event and then fetches profiles by email.

Risk level: High for Discover map/card scroll and selected venue sheet during major games.

Proposed fixes:

- Introduce immutable `VenueGameDisplayModel` and `VenuePinDisplayModel` caches keyed by event ID, selected day, and social version.
- Keep premium gradients for primary feed cards, but pre-resolve themes and flags once per event.
- Reduce map marker animation count: only selected/high-activity pins should pulse.
- Keep venue detail game rows lightweight; avoid reintroducing full premium cards inside the detail sheet.
- Replace per-event Going row/profile refresh with one RPC returning `{count, viewerGoing, avatarPreviews}`.

### 4. Realtime DM Performance

Files inspected:

- `GameOn/DirectChatView.swift`
- `GameOn/DirectChatService.swift`
- `GameOn/ChatViewModel.swift`
- `GameOn/DMRealtimeDiagnostics.swift`
- `GameOn/RealtimeDiagnosticLogging.swift`
- `supabase/migrations/20260512_0001_keyset_pagination_indexes.sql`
- `supabase/migrations/20260622_0001_direct_messages_realtime_publication.sql`
- `supabase/migrations/20260623_0001_direct_messages_rls_participants.sql`
- `supabase/migrations/20260511_0001_scalability_dm_unread_rpc_and_indexes.sql`

Current behavior:

- `DirectChatView` has optimistic local messages through `pendingOptimisticMessages`.
- `DirectChatService.sendMessage()` inserts into `direct_messages` and returns `.select().single()`.
- Thread realtime is scoped by `conversation_id`.
- Duplicate suppression absorbs pending local messages when the server row arrives.
- `ChatViewModel` maintains an inbox listener for `direct_messages` inserts and `conversation_read_state`.
- Active visible thread gating prevents counting unread for the currently open thread.
- Badge updates are locally patched, then debounced to a server unread RPC.

Likely bottleneck:

- Inbox realtime is unfiltered for `direct_messages` and `conversation_read_state`, relying on RLS. At scale, this can create unnecessary wakeups and RLS evaluation overhead.
- Sending requests full row return with `.select()`; acceptable for one message, but should use minimal columns if possible.
- `requestBadgeRecalculation(... includeInboxSummaries: true)` after sender insert may cause extra RPC/inbox work when local optimistic state is already known.

Risk level: High for many concurrent DMs.

Proposed fixes:

- Keep thread listener filtered by `conversation_id`.
- Replace unfiltered inbox realtime with one of:
  - a server-side user-scoped broadcast channel;
  - a small `conversation_id IN (...)` filter when conversation count is under threshold and a fallback polling/recount for large inboxes;
  - an Edge Function that emits unread summary deltas.
- Use minimal returning columns for DM insert instead of `.select()`.
- Keep local inbox patch and badge changes first; server recount should remain debounced and recovery-only.
- Add metrics for `send_tap_to_optimistic_ms`, `send_tap_to_insert_ack_ms`, `insert_ack_to_sender_echo_ms`, `remote_insert_to_receiver_ui_ms`, and `badge_patch_ms`.

### 5. Realtime Fan Chat Performance

Files inspected:

- `GameOn/MapViewModel+CommentsAndVibes.swift`
- `GameOn/VenueEventCommentsView.swift`
- `supabase/migrations/20260731_0001_venue_event_comments_realtime_publication.sql`
- `supabase/migrations/20260512_0001_keyset_pagination_indexes.sql`
- `supabase/migrations/20260515_0001_moderation_venue_reports_comment_hide.sql`
- `supabase/migrations/20260731_0027_venue_event_comment_reactions.sql`
- `supabase/migrations/20260731_0029_venue_event_comment_reactions_realtime.sql`

Current behavior:

- Comment send appends a pending local comment immediately.
- Insert writes to `venue_event_comments` and returns minimal `VenueEventCommentsPagination.selectColumns`.
- Duplicate suppression matches server IDs and pending local rows.
- Sheet-level realtime subscribes to one `venue_event_id`.
- App-level preview realtime tracks loaded venue events with chunking and debounced resubscribe.
- If realtime is unhealthy, receiver refresh burst polls after 2.5 seconds and repeats every 2.5 seconds for up to 3 ticks.
- Comment pagination uses keyset query shapes and indexes.

Likely bottleneck:

- A healthy realtime path is fast, but the fallback path is too slow for the user's "3-5 seconds unacceptable" requirement. The first fallback tick starts after a 2.5-second grace period.
- Exact count reconciliation can add another request after merging fallback rows.
- Comment insert loads user profile for the sender email after insert; for active chat, profile hydration should be cached/batched.
- DEBUG logs are very dense in comment send, merge, fallback, count, and reaction paths.

Risk level: High.

Proposed fixes:

- Keep optimistic send, but reduce receiver fallback detection target to less than 1 second once sheet subscription is expected healthy.
- Treat exact count as background correction, never blocking visible comment count.
- Batch `loadUserProfilesForEmails` for new comment authors on a short debounce.
- Use a single Fan Chat summary RPC for sheet open: latest comments, count, reaction counts, viewer reactions, and author previews.
- Add a visible realtime health indicator only for diagnostics builds; avoid user-facing feature changes.

### 6. Going and Interested Performance

Files inspected:

- `GameOn/MapViewModel+VenueEventSocial.swift`
- `GameOn/MapViewModel+VenueGameCardStore.swift`
- `GameOn/MapViewModel+FollowingTab.swift`
- `supabase/migrations/20260731_0002_social_hot_path_indexes.sql`
- `supabase/migrations/20260731_0014_venue_event_interests_fan_rls.sql`
- `supabase/migrations/20260630_0002_venue_event_interests_interest_status.sql`

Current behavior:

- `toggleVenueGameGoingFromUI()` applies local state before the Supabase write.
- Rollback snapshots preserve previous state on failure.
- `applyLocalVenueEventInterestState()` updates count and local going state.
- `refreshVenueGameCardGoingState()` can load all interest rows for one event and then fetch user profiles for those emails.

Likely bottleneck:

- Local feel is good, but remote propagation and avatar stack refresh are not guaranteed sub-second for other users.
- Full row reads for all attendees do not scale to 500+ users on one event.

Risk level: High for major games.

Proposed fixes:

- Add an aggregate RPC per event: count, viewer going, top N avatar preview profiles, updated_at.
- Add realtime on `venue_event_interests` only for visible/selected venue event IDs, and use inserts/deletes to update counts locally.
- Keep server aggregate refresh as correction after debounced bursts.
- Store `user_id` on interests if possible long-term; email-based joins are slower and harder to index safely.

### 7. Reactions and Vibes Performance

Files inspected:

- `GameOn/MapViewModel+CommentsAndVibes.swift`
- `GameOn/VenueEventVibeMeterView.swift`
- `supabase/migrations/20260731_0002_social_hot_path_indexes.sql`
- `supabase/migrations/20260731_0027_venue_event_comment_reactions.sql`
- `supabase/migrations/20260731_0029_venue_event_comment_reactions_realtime.sql`
- `supabase/migrations/20260731_0030_realtime_publication_verification_missing_tables.sql`

Current behavior:

- Vibes have a unique index on `(venue_event_id, user_email, vibe_type)`.
- Comment reactions have indexes on comment ID, user ID, and `(comment_id, reaction_type)`.
- Fan Chat reaction realtime has debounce and fallback polling.
- Vibe/comment reaction counts are eventually reconciled.

Likely bottleneck:

- Reaction/vibe count updates are often aggregate refreshes, not pure delta application.
- If reaction realtime is broad or client-filtered, open sheets can wake for unrelated reaction rows.

Risk level: Medium to High.

Proposed fixes:

- Keep local reaction toggle under 150 ms.
- Apply realtime deltas locally when the row's event/comment is visible.
- Batch count reconciliation across comment IDs/event IDs after a burst.
- Add event-level vibe count RPC for visible cards.

### 8. Live Venue Activity

Files inspected:

- `GameOn/MapViewModel+LiveSports.swift`
- `GameOn/LiveSportsService.swift`
- `GameOn/LiveScreen.swift`
- `GameOn/MapViewModel+LiveEnergy.swift`
- `GameOn/FanGeoLiveEnergy.swift`
- `supabase/migrations/20260730_0001_live_matches.sql`

Current behavior:

- `LiveSportsService` uses a 60-second cache and a 55-second cache sync cooldown.
- It triggers `sync-live-matches` Edge Function before fetching `live_matches`.
- Live tab auto-refresh runs while Live tab is active.
- `live_matches` has status/start-time indexes and read-only RLS.

Likely bottleneck:

- Live match freshness depends on Edge Function sync and cache TTL, not realtime.
- Live venue activity badges and crowd scores depend on app-side derived social state and refresh cadence.

Risk level: Medium for scores, High for venue activity if users expect instant crowd movement.

Proposed fixes:

- Keep cached live match data visible immediately.
- Decouple external sports scores from venue social activity. Venue activity should update via local optimistic + realtime deltas.
- Add per-event `activity_score` display model locally and update from Going/Fan Chat/vibe deltas.
- Use live match fetch for score freshness only; do not wait on it to render live venue activity.

### 9. Supabase and Database Query Performance

Files inspected:

- `supabase/migrations/*.sql`
- `GameOn/MapViewModel+VenueAndGameData.swift`
- `GameOn/MapViewModel+VenueEventSocial.swift`
- `GameOn/MapViewModel+CommentsAndVibes.swift`
- `GameOn/DirectChatService.swift`
- `GameOn/ChatViewModel.swift`
- `GameOn/VenueEventPredictionService.swift`
- `GameOn/RecoveredSocialModels.swift`
- `GameOn/PublicUserProfileService.swift`

Current behavior:

- Several important indexes already exist:
  - `venue_event_comments(venue_event_id, created_at DESC, id DESC)`
  - `direct_messages(conversation_id, created_at DESC, id DESC)`
  - `venue_events(venue_id, event_date)` active partial
  - `venue_events(event_date, sport)` active partial
  - `favorite_venues(user_email, venue_id)`
  - `venue_event_interests(user_email, venue_event_id)` unique
  - `venue_event_vibes(venue_event_id, user_email, vibe_type)` unique
  - `conversation_read_state(conversation_id, user_id)` unique
  - `live_matches(match_status, start_time)`
- Some moderation/admin owner tools use `.select()` wildcard and large admin-oriented payloads.
- Discover uses explicit venue select columns in hot paths.

Likely bottleneck:

- Some hot query directions are not covered by existing indexes. For example, Going count by `venue_event_id` has a unique index leading with `user_email`, not `venue_event_id`.
- Aggregate counts are often computed client-side after fetching rows.
- RLS policies with `EXISTS` subqueries can be fine with indexes, but should be tested with real row counts.

Risk level: High.

Proposed fixes:

- Add composite indexes listed below after staging `EXPLAIN ANALYZE`.
- Move high-volume counts and summaries into RPCs that return compact payloads.
- Prefer `user_id` over email on future social tables where possible.
- Use explicit columns instead of `.select()` in owner moderation/admin surfaces that may grow.

### 10. Image and Network Performance

Files inspected:

- `GameOn/DiscoverMapImageCache.swift`
- `GameOn/ImageDisplayURL.swift`
- `GameOn/UserAvatarView.swift`
- `GameOn/SocialAvatarRenderer.swift`
- `GameOn/VenueDetailView.swift`
- `GameOn/DiscoverScreen.swift`

Current behavior:

- List surfaces prefer thumbnail URLs via `ImageDisplayURL.forList`.
- Detail surfaces prefer full URLs via `ImageDisplayURL.forDetail`.
- Discover image cache coalesces in-flight fetches and stores up to 72 images.
- Prefetch caps to 8 URLs.

Likely bottleneck:

- Cache eviction is entry-count based, not byte-cost based.
- Images are decoded from raw data without explicit downsampling to display size.
- Detail surfaces prefer full images, which is reasonable for detail, but venue detail must stay usable before image completion.

Risk level: Medium.

Proposed fixes:

- Use byte-cost `NSCache` or actor-backed LRU with memory warning purge.
- Downsample large JPEG/PNG data before creating `UIImage`.
- Keep card/list surfaces thumbnail-only.
- Add image timing counters and cache hit ratio metrics.

### 11. SwiftUI Performance

Files inspected:

- `GameOn/DiscoverScreen.swift`
- `GameOn/VenueDetailView.swift`
- `GameOn/ThemeGradientBuilder.swift`
- `GameOn/MainTabView.swift`
- `GameOn/LiveScreen.swift`
- `GameOn/MapVenuePreviewCard.swift`

Current behavior:

- Discover has snapshot rendering helpers, but the view remains very large.
- `VenueMatchupCardView` uses multiple gradients, radial gradients, blur, shadows, and on-appear logs.
- Venue detail games are now lightweight, which is good.
- Map markers include repeating pulse animations and blur/glow.

Likely bottleneck:

- Repeated body recomputation can redo theme/flag/sport/live-energy calculations.
- Large `@Published` arrays/dictionaries on `MapViewModel` can invalidate offscreen surfaces.
- Geometry/map overlays and retained sheets can keep tasks alive.

Risk level: High for Discover/map.

Proposed fixes:

- Cache display models for visible cards and pins.
- Use `EquatableView` or stable value models for repeated cards.
- Reduce always-on marker animations.
- Keep expensive gradients out of list/detail repeated rows.
- Split hot state by surface after behavior tests exist.

### 12. Logging Performance

Files inspected:

- `GameOn/RealtimeDiagnosticLogging.swift`
- `GameOn/DirectChatView.swift`
- `GameOn/ChatViewModel.swift`
- `GameOn/MapViewModel+CommentsAndVibes.swift`
- `GameOn/MapViewModel+VenueEventSocial.swift`
- `GameOn/DiscoverScreen.swift`
- `GameOn/LiveSportsService.swift`

Current behavior:

- `DebugLogGate.debug` is compiled out in Release.
- `DebugLogGate.noisy` is runtime-disabled in DEBUG unless `noisyRealtimeInvestigationLogs` is true.
- Many hot paths still use plain `print` inside `#if DEBUG`.

Likely bottleneck:

- Debug/TestFlight-like performance sessions can be distorted by thousands of string interpolations and terminal writes during chat/reaction/Going bursts.

Risk level: Medium in production Release, High during diagnostic builds and simulator tests.

Proposed fixes:

- Route all hot realtime/perf logs through `DebugLogGate` with runtime flags.
- Add rate-limited counters for high-frequency events.
- Keep `[AuthForceLogoutDebug]` always visible because it is rare and diagnostic-critical; do not do that for chat/comment loops.

### 13. Major-Match Stress Scenario

Scenario:

- 500 users watching one venue game.
- 100 users in Fan Chat.
- 100 users tap Going/Interested.
- 50 users react/vibe quickly.
- DMs active at the same time.
- Live games refresh every 5 minutes.
- App foreground/background cycling.

Expected current behavior:

- Sender-side DM, Fan Chat, Going, and reactions feel fast locally because optimistic updates exist.
- Other users may see 1-5 second gaps when realtime is delayed, fallback polling waits for grace periods, aggregate refreshes are queued, or profile/count fetches are contended.
- The busiest event can trigger many comment inserts, reaction rows, count refreshes, profile hydrations, avatar updates, and UI invalidations inside the same `MapViewModel`.
- Foreground cycling can reconnect DM/Fan Chat and run session/admin/owner/social refreshes while live chat is active.

Stress risk level: High.

Required before scale:

- Load test Supabase writes and realtime fanout with realistic RLS.
- Measure remote receive p95/p99, not only local optimistic latency.
- Verify every fallback path has a cap and does not multiply with users.
- Add aggregate RPCs and indexes so count correction is cheap.

## D. Database Index Recommendations

Do not apply these directly in production. Run each through staging `EXPLAIN ANALYZE` with realistic row counts and RLS enabled.

```sql
-- Going count and visible-event lookup by event id.
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_venue_event_interests_event_user_email
ON public.venue_event_interests (venue_event_id, user_email);

-- If interest_status is used for active/going filtering, prefer a partial index.
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_venue_event_interests_event_active
ON public.venue_event_interests (venue_event_id, user_email)
WHERE coalesce(interest_status, 'going') = 'going';

-- Vibe aggregation by event and type.
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_venue_event_vibes_event_type
ON public.venue_event_vibes (venue_event_id, vibe_type);

-- Viewer-specific vibe lookup for an event.
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_venue_event_vibes_user_event
ON public.venue_event_vibes (user_email, venue_event_id);

-- Prediction summary aggregation by event/type/choice.
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_venue_event_predictions_event_type_choice
ON public.venue_event_predictions (venue_event_id, prediction_type, choice);

-- Prediction viewer lookup.
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_venue_event_predictions_user_event_type
ON public.venue_event_predictions (user_id, venue_event_id, prediction_type);

-- Fan Chat visible latest comments, partial on visible rows.
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_venue_event_comments_visible_event_created_id
ON public.venue_event_comments (venue_event_id, created_at DESC, id DESC)
WHERE coalesce(is_moderation_hidden, false) = false;

-- Comment author/profile hydration helper if email remains the join key.
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_venue_event_comments_event_user_email_created
ON public.venue_event_comments (venue_event_id, user_email, created_at DESC);

-- DM inbox/latest message per conversation if not already covered by existing desc index.
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_direct_messages_conversation_created_desc
ON public.direct_messages (conversation_id, created_at DESC)
WHERE deleted_at IS NULL AND coalesce(is_deleted, false) = false;

-- DM RLS participant checks.
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_direct_conversations_user_a
ON public.direct_conversations (user_a_id, id);

CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_direct_conversations_user_b
ON public.direct_conversations (user_b_id, id);

-- Friendship lookup directions.
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_friendships_requester_status_addressee
ON public.friendships (requester_id, status, addressee_id);

CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_friendships_addressee_status_requester
ON public.friendships (addressee_id, status, requester_id);

-- Discover bounds for active venues. Consider btree first; PostGIS would be better long-term.
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_venues_active_lat_lon
ON public.venues (latitude, longitude)
WHERE coalesce(lower(trim(admin_status)), 'active') = 'active'
  AND latitude IS NOT NULL
  AND longitude IS NOT NULL;

-- Owner tools active venue lookup.
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_venues_owner_email_active
ON public.venues (owner_email, id)
WHERE coalesce(lower(trim(admin_status)), 'active') = 'active';

-- Live matches common client filter.
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_live_matches_live_window
ON public.live_matches (match_status, start_time, updated_at DESC);

-- User profile email lookup if still used for social identity batching.
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_user_profiles_email_active
ON public.user_profiles (lower(trim(coalesce(email, ''))), id)
WHERE coalesce(lower(trim(admin_status)), 'active') = 'active'
  AND coalesce(is_deleted, false) = false;
```

RPC recommendations:

- `get_venue_event_social_summary(p_event_ids uuid[], p_viewer_email text)` returning Going counts, viewer Going, top avatars, comment counts, vibe counts, and prediction summary versions.
- `get_fan_chat_sheet_bootstrap(p_venue_event_id uuid, p_viewer_id uuid)` returning latest comments, exact visible count, author previews, reaction counts, and viewer reactions.
- `get_dm_inbox_delta(p_since timestamptz)` or a broadcast equivalent returning compact unread/conversation deltas.

## E. Realtime Architecture Recommendations

- Keep sender-side optimistic UI as the first update for DMs, Fan Chat, Going, reactions, vibes, and predictions.
- Treat Supabase writes as confirmation, not as the source of first visible UI.
- Treat realtime as peer propagation and confirmation, not as sender UI dependency.
- Treat REST aggregate refreshes as correction, never as first paint.
- Use user-scoped DM inbox realtime/broadcast instead of unfiltered `direct_messages` changes.
- Use event-scoped realtime for visible/selected venue events only.
- Coalesce realtime bursts into one aggregate refresh per event every 250-500 ms.
- Keep reconnect storms controlled with foreground debounce, but ensure visible DM/Fan Chat reconnect happens before non-visible work.
- Add durable sequence/version fields for summaries if count deltas can be missed.
- Record p50/p95/p99 for local optimistic, insert ack, realtime receive, fallback merge, and visible UI apply.

## F. SwiftUI and UI Recommendations

- Build stable display models for Discover pins, venue-game cards, live activity badges, and venue detail rows.
- Reduce repeated `TeamTheme`, `CountryTheme`, flag, sport icon, and gradient validation resolution inside SwiftUI `body`.
- Keep Venue Detail game rows lightweight and avoid premium card effects in long lists.
- Limit pulsing map annotations to selected/high-activity items.
- Keep full-size images out of cards; cards should use thumbnails only.
- Downsample images before decoding to `UIImage`.
- Use byte-cost image cache eviction and clear on memory pressure.
- Split hot state into smaller observable stores when tests exist:
  - Auth/session store.
  - Discover map/card store.
  - DM inbox store.
  - Fan Chat event store.
  - Venue owner store.
  - Live sports store.
- Avoid publishing full dictionaries/arrays for hidden tabs when a version counter or scoped store can update only the visible surface.

## G. Prioritized Implementation Plan

### Phase 1: No-Risk Quick Wins

- Add production-safe latency counters around optimistic UI, DB ack, realtime receive, fallback merge, and UI apply.
- Gate hot DEBUG logs behind runtime flags and rate limit burst logs.
- Cache display models for venue-game cards and map pins.
- Stagger foreground work so only visible-tab work runs immediately.
- Keep existing functionality and all optimistic paths.

### Phase 2: Realtime Hardening

- Replace DM inbox unfiltered listener with user-scoped deltas.
- Add event-scoped realtime delta handling for Going/Interested on visible venue games.
- Reduce Fan Chat fallback first-check time and make exact count background-only.
- Batch comment author/profile hydration.
- Add reconnect health metrics for DM thread, DM inbox, Fan Chat sheet, app-level Fan Chat, vibes, predictions, and Going.

### Phase 3: Database and Index Improvements

- Run staging `EXPLAIN ANALYZE` for all recommended indexes.
- Add compact aggregate RPCs for social summaries.
- Replace full-row client count fetches with RPC aggregates.
- Review RLS policies with realistic row counts and indexes.
- Add generated/denormalized counters only if RPC aggregation is still too slow.

### Phase 4: Stress Testing and Observability

- Create scripted stress tests for 100 chat users, 100 Going toggles, 50 reaction bursts, and concurrent DMs.
- Capture p95/p99 per path.
- Test foreground/background cycling during a hot event.
- Test with DEBUG logs off and Release-like optimization.
- Add dashboards or structured logs for realtime health, Supabase latency, fallback use rate, and UI apply time.

## H. Specific Cursor Follow-Up Commands

Phase 1 command:

```text
Audit-only findings are in docs/performance/FanGeo_Performance_Realtime_Audit.md. Implement Phase 1 no-risk quick wins only: add production-safe latency counters, gate/rate-limit hot DEBUG logs, cache Discover venue-game/pin display models, and stagger foreground work. Do not change backend, UI design, or feature behavior. Run xcodebuild.
```

Phase 2 command:

```text
Using docs/performance/FanGeo_Performance_Realtime_Audit.md, implement Phase 2 realtime hardening. Keep all optimistic UI paths. Improve DM inbox realtime scoping, visible-event Going realtime deltas, Fan Chat fallback timing, author/profile batching, and reconnect health metrics. Do not redesign UI. Run xcodebuild.
```

Phase 3 command:

```text
Using docs/performance/FanGeo_Performance_Realtime_Audit.md, prepare database/index and RPC migrations only. Include SQL for social summary RPCs and indexes, but do not apply anything locally. Make migrations idempotent and include comments explaining the query shapes. Do not change iOS UI. Run static validation where available.
```

Phase 4 command:

```text
Create a FanGeo realtime stress-test and observability plan from docs/performance/FanGeo_Performance_Realtime_Audit.md. Include scripts or documented manual test steps for 100 Fan Chat users, 100 Going toggles, 50 reactions/vibes, concurrent DMs, live refresh, and foreground/background cycling. Audit/report first before implementing test tooling.
```

## Final Notes

The app is close to the right responsiveness model because local optimistic updates already exist in the most important surfaces. The next scale jump is not a visual redesign. It is reducing aggregate/refetch fan-out, tightening realtime scopes, moving count/profile work to compact server summaries, and preventing broad SwiftUI invalidations from turning a successful realtime event into a slow visible update.
