# FanGeo Realtime Chain Diagnostics

Date: May 21, 2026

Scope: targeted diagnostics for why newly verified Supabase realtime publication coverage does not yet translate into live-feeling UI updates.

Constraints followed:

- No UI changes.
- No backend schema changes.
- No RLS changes.
- No existing realtime listener logic or filters changed.
- Diagnostics are DEBUG-only print logs plus this report.

## Executive findings

### Highest suspected failure points

1. `venue_event_predictions`: listener exists and is filtered correctly by `venue_event_id`, but it only starts when `VenueEventPredictionModule` is mounted. It is present in Discover game cards and venue detail cards, not as a global listener. If the watched preview/card does not render the module, no subscription starts.
2. `venue_event_interests`: publication now exists, but there is no fan-facing Going-count realtime listener for Discover/venue preview users. Going remote count is not realtime for fan users yet.
3. `venue_event_vibes`: app-level listener exists, but current event handling does not decode the changed `venue_event_id`; it refreshes all tracked event IDs. If the listener is not started, no vibe realtime will happen; if it starts, matching is broad/unknown rather than payload-verified.
4. `conversation_read_state`: listener exists, but it is unfiltered and relies on RLS. It should now receive publication events, then debounce into the unread RPC. Diagnostics will show whether it receives any read-state event at all.

## Logs added

All new logs use `[RealtimeChainDebug]`.

### Standard chain points

- `subscribeRequested table=...`
- `subscribeReady table=...`
- `subscribeFailed table=... error=...`
- `eventReceived table=... eventType=... rowId=...`
- `eventMatchedCurrentView table=... matched=...`
- `refreshQueued table=... reason=...`
- `refreshStarted table=...`
- `refreshSucceeded table=...`
- `uiStateUpdated table=... key=... oldValue=... newValue=...`

## A. Predictions: `venue_event_predictions`

### Existing listener coverage

Feature has an existing fan-facing listener.

- Starts in `MapViewModel+VenueEventPredictions.startVenueEventPredictionRealtime(for:)`.
- Subscribes to `venue_event_predictions` with `venue_event_id = eq.<eventID>`.
- Called from `VenueEventPredictionsView.task(id: venueEventID)`.
- Discover preview/game cards pass `onStartRealtime` through `VenueEventPredictionModule` in `DiscoverScreen`.
- Venue detail also passes prediction realtime start/stop closures.

### Diagnostics added

- Subscribe requested/ready/failed in `MapViewModel+VenueEventPredictions.swift`.
- Event received and matched-current-view logs in `MapViewModel+VenueEventPredictions.swift`.
- Refresh queued/started/succeeded in `MapViewModel+VenueEventPredictions.swift`.
- Summary dictionary update logs in `loadVenueEventPredictionSummaries`.
- Prediction module render/update logs in `VenueEventPredictionsView.swift` when `totalCount` or `winnerPercent` changes.

### Manual test path

User A changes a prediction while User B is watching the same event card/module.

Expected DEBUG sequence on User B:

```text
[RealtimeChainDebug] subscribeRequested table=venue_event_predictions ...
[RealtimeChainDebug] subscribeReady table=venue_event_predictions ...
[RealtimeChainDebug] eventReceived table=venue_event_predictions eventType=...
[RealtimeChainDebug] eventMatchedCurrentView table=venue_event_predictions matched=true ...
[RealtimeChainDebug] refreshQueued table=venue_event_predictions reason=realtime_event ...
[RealtimeChainDebug] refreshStarted table=venue_event_predictions ...
[RealtimeChainDebug] uiStateUpdated table=venue_event_predictions key=<event>.totalCount ...
[RealtimeChainDebug] refreshSucceeded table=venue_event_predictions ...
[RealtimeChainDebug] uiStateUpdated table=venue_event_predictions key=<event>.predictionModuleTotal ...
```

### Suspected failure if still not live

- If `subscribeRequested` does not appear: the prediction module is not mounted for the currently watched UI surface.
- If `subscribeReady` appears but `eventReceived` does not: Supabase filter/RLS/publication/runtime delivery is still not delivering rows to this client.
- If `eventReceived` appears but no `refreshQueued`: the stream loop is exiting or the task is being cancelled.
- If `refreshSucceeded` appears but no module update log: the dictionary updated, but the visible view is not observing the same `predictionEventID` or the summary value did not change.

### Next minimal fix, not implemented

If logs show no subscription while watching a venue preview, add a narrowly scoped prediction realtime starter for the selected/visible preview event IDs, reusing the existing `startVenueEventPredictionRealtime(for:)` and `stopVenueEventPredictionRealtime(for:)`.

## B. Going count: `venue_event_interests`

### Existing listener coverage

No fan-facing Going-count realtime listener exists for Discover/venue preview users.

Existing realtime listener is owner analytics only:

- `MapViewModel+VenueOwnerAnalyticsRealtime.runVenueOwnerAnalyticsRealtimeLoop(trackedEventIDs:)`
- Subscribes to `venue_event_interests`, `venue_event_comments`, and `venue_event_vibes`.
- Starts from venue owner analytics UI.

Fan-facing Discover/venue preview paths currently rely on:

- Optimistic local updates in `setVenueEventInterest(...)`.
- REST reload via `loadVisibleVenueEventInterests(...)`.
- Background/deferred reconcile paths.

Required explicit finding:

> Going remote count is not realtime for fan users yet.

### Diagnostics added

- Owner analytics `venue_event_interests` subscribe requested/ready/failed logs.
- Owner analytics event received/matched logs.
- Owner analytics refresh queued/started/succeeded logs.
- Owner analytics count dictionary update logs in `loadInterestCountsForVenueEventIDs(...)`.

### Manual test path

For fan User A/User B Discover preview Going count, no fan-facing event sequence is expected yet because there is no fan listener.

For venue owner analytics:

```text
[RealtimeChainDebug] subscribeRequested table=venue_event_interests ...
[RealtimeChainDebug] subscribeReady table=venue_event_interests ...
[RealtimeChainDebug] eventReceived table=venue_event_interests ...
[RealtimeChainDebug] refreshQueued table=venue_event_interests reason=owner_analytics_realtime ...
[RealtimeChainDebug] refreshStarted table=venue_event_interests key=ownerAnalytics
[RealtimeChainDebug] uiStateUpdated table=venue_event_interests key=<event>.ownerAnalyticsCount ...
[RealtimeChainDebug] refreshSucceeded table=venue_event_interests key=ownerAnalytics
```

### Suspected failure point

Publication coverage alone cannot make fan Going counts realtime because no fan-facing subscription is attached to `venue_event_interests`.

### Where a minimal listener should be added later

Later implementation should be near the Discover social enrichment path:

- Starter/stopper likely belongs in `MapViewModel+VenueEventSocial.swift`, next to `loadVisibleVenueEventInterests(...)`.
- Invocation should likely be from selected/visible Discover venue event IDs in `DiscoverScreen.prefetchVisibleVenueSocialData(...)`.
- It should not be owner analytics; it should update `venueEventInterestCounts` for visible event IDs only.

## C. Fan Chat vibes/reactions: `venue_event_vibes`

### Existing listener coverage

Feature has an existing app-level listener for vibes.

- `MapViewModel+CommentsAndVibes.runFanChatAppLevelRealtimeLoop(eventIDs:)`
- Subscribes to `venue_event_vibes` with chunked `venue_event_id IN (...)`.
- Listener is tied to loaded `venueEventRows`, not specifically to the currently open Fan Chat sheet.

### Diagnostics added

- Subscribe requested/ready/failed logs for `venue_event_vibes`.
- Event received log in `consumeCrowdReactionAppLevelRealtimeStream(...)`.
- Event matched log reports `matched=unknown` because the current code does not decode the changed row's `venue_event_id`; it refreshes tracked events broadly.
- Refresh queued log in `scheduleCrowdReactionVibeRealtimeRefresh(...)`.
- Refresh started/succeeded and vibe-count state update logs in `loadVibes(for:)`.

### Manual test path

User A sends a vibe/reaction while User B watches a venue/event with the same tracked event loaded.

Expected DEBUG sequence on User B:

```text
[RealtimeChainDebug] subscribeRequested table=venue_event_vibes ...
[RealtimeChainDebug] subscribeReady table=venue_event_vibes ...
[RealtimeChainDebug] eventReceived table=venue_event_vibes eventType=...
[RealtimeChainDebug] eventMatchedCurrentView table=venue_event_vibes matched=unknown reason=existingListenerRefreshesTrackedEventsWithoutDecodingPayload ...
[RealtimeChainDebug] refreshQueued table=venue_event_vibes reason=realtime_event ...
[RealtimeChainDebug] refreshStarted table=venue_event_vibes key=<event>
[RealtimeChainDebug] uiStateUpdated table=venue_event_vibes key=<event>.totalVibes ...
[RealtimeChainDebug] refreshSucceeded table=venue_event_vibes key=<event>
```

### Suspected failure if still not live

- If `subscribeRequested` does not appear: app-level Fan Chat realtime is not being started for loaded venue events.
- If `subscribeReady` appears but no `eventReceived`: Supabase delivery/filter/RLS is still not delivering.
- If `eventReceived` appears but no count update: refresh is running against event IDs that do not include the visible view's event, or the visible view reads a different key.
- If count updates but UI does not: the visible view is not observing `venueEventVibeCounts` for the same `venueEventID`.

### Next minimal fix, not implemented

Decode the `venue_event_vibes` realtime payload and refresh only the changed `venue_event_id`. This would turn `matched=unknown` into a real event ID match and avoid broad tracked-event refreshes.

## D. DM unread/read state: `conversation_read_state`

### Existing listener coverage

Feature has an existing app-level listener.

- `ChatViewModel.runInboxRealtimeListenerLoop()`
- Subscribes to `conversation_read_state` AnyAction with no filter.
- Same channel also listens to `direct_messages` INSERTs.
- It is intentionally started while signed in and survives tab changes.

### Diagnostics added

- Subscribe requested/ready/failed logs for `conversation_read_state`.
- Event received log in `consumeConversationReadStateRealtime(...)`.
- Event matched log reports `matched=unknown` because this is an unfiltered/RLS-scoped badge listener.
- Refresh queued log in `scheduleDebouncedUnreadDirectMessageRPCRefresh()`.
- Refresh started/succeeded logs in `refreshUnreadDirectMessageCount()`.
- Badge state update log in `setUnreadDirectMessageCountAndSyncAppIcon(...)`.

### Manual test path

User B opens a DM and marks messages read while User A has badge listener active.

Expected DEBUG sequence on User A:

```text
[RealtimeChainDebug] subscribeRequested table=conversation_read_state ...
[RealtimeChainDebug] subscribeReady table=conversation_read_state ...
[RealtimeChainDebug] eventReceived table=conversation_read_state eventType=...
[RealtimeChainDebug] eventMatchedCurrentView table=conversation_read_state matched=unknown reason=unfilteredBadgeListenerReliesOnRLS
[RealtimeChainDebug] refreshQueued table=conversation_read_state reason=debounced_unread_rpc
[RealtimeChainDebug] refreshStarted table=conversation_read_state key=unreadDirectMessageCount
[RealtimeChainDebug] refreshSucceeded table=conversation_read_state key=unreadDirectMessageCount
[RealtimeChainDebug] uiStateUpdated table=conversation_read_state key=unreadDirectMessageCount ...
```

### Suspected failure if still not live

- If `subscribeRequested` does not appear: signed-in social realtime was not started.
- If `subscribeReady` appears but no `eventReceived`: read-state publication/RLS/runtime delivery is not reaching this user.
- If event and refresh logs appear but badge stays unchanged: unread RPC returned the same value or read-state semantics do not affect the watching user's unread total.

### Next minimal fix, not implemented

If read-state events are too broad or not visible through RLS, replace the unfiltered read-state listener with a user/conversation-scoped listener or server-side broadcast that emits only unread badge deltas for the current user.

## Supabase client and lifecycle checks

### Channel names

- Predictions: `venue-event-predictions-<eventID>` is unique per event.
- Vibes/Fan Chat app level: `venue-event-comments-app-<uuid>` is unique per resubscribe.
- DM inbox/read state: `dm-inbox-<userID>` is unique per user.
- Owner analytics: `venue-owner-analytics` is singleton-like and stopped before start.

### UUID casing

- Predictions filter uses `eventID.uuidString.lowercased()`.
- Vibes app-level filter uses `UUID` values from loaded event IDs.
- DM read-state has no UUID filter.
- Owner analytics filter uses UUID values.

### Immediate teardown risk

- Predictions stop on `VenueEventPredictionModule.onDisappear`. If SwiftUI removes/recreates the module or the module is not rendered in the current preview surface, subscription will stop or never start.
- Vibes app-level listener is tied to loaded venue events, not the sheet; it can survive views but depends on `venueEventRows` scheduling.
- DM inbox listener intentionally survives tab disappearance while signed in.
- Going fan count has no fan-facing listener to start or stop.

### Preview vs detail coverage

- Predictions are not detail-only. Discover game cards render `VenueEventPredictionModule` and pass `onStartRealtime`.
- Going fan count is not realtime in preview or detail for remote users.
- Vibes listener is app-level, not only detail/sheet-level, but it does not decode specific changed event IDs.
- DM read-state listener is app-level, not detail-only.

## Features with listeners vs publication only

### Existing listeners

- `venue_event_predictions`: fan-facing, per-event, filtered.
- `venue_event_vibes`: app-level, filtered by tracked event IDs, broad refresh after event.
- `conversation_read_state`: app-level badge listener, unfiltered/RLS-scoped.
- `venue_event_interests`: owner analytics only.

### Publication but no fan-facing listener

- `venue_event_interests`: fan Going remote count.
- `pickup_games`: requester pickup activity has a listener; not part of this first diagnostic pass.

## Next recommended minimal fixes

1. Run the instrumented app on two devices and capture `[RealtimeChainDebug]` logs for the four test paths above.
2. If predictions show no `subscribeRequested`, start prediction realtime for the selected preview event IDs when the preview is visible.
3. If predictions show event and refresh success but no module update, verify the visible card's `predictionEventID` matches the updated summary dictionary key.
4. Add a fan-facing `venue_event_interests` listener for visible Discover/venue event IDs only. This is the smallest missing piece for remote Going count.
5. Decode `venue_event_vibes` event payloads so refreshes are event-specific and diagnostics can log the exact matched `venue_event_id`.
6. If `conversation_read_state` events do not arrive after publication, inspect RLS visibility for read-state rows between conversation participants before changing the iOS listener.
