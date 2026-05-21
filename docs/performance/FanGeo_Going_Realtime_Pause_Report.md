# FanGeo Going Realtime Pause Report

Date: 2026-05-21

## Summary

Selected-venue Going realtime is paused for now. The app should stay on the known-stable paths: optimistic local Going updates, delayed visible-interest reloads, and the existing Following tab reconcile. No `DiscoverScreen` render path, row lifecycle, `GeometryReader`, overlay builder, or game-row `.task` should mutate realtime subscriptions.

## Why `[GoingRealtimeDebug]` Never Triggers

`[GoingRealtimeDebug]` is emitted only by the new fan-facing realtime listener path in `MapViewModel+VenueEventSocial.swift`, starting with `syncFanFacingVenueEventInterestsRealtimeSubscription(eventIDs:)` and then `runFanFacingVenueEventInterestsRealtimeLoop(eventIDs:)`.

The observed logs contain no:

- `[GoingRealtimeDebug] selectedVenueSyncRequested ids=`
- `[GoingRealtimeDebug] subscribeRequested eventIds=`
- `[GoingRealtimeDebug] subscribeReady eventIds=`
- `[GoingRealtimeDebug] eventReceived action= eventId=`

That means the new listener never reached subscription startup. In practice, the selected-venue approach did not have a reliable, already-proven non-render lifecycle hook that both:

- knows the exact venue preview event IDs, and
- runs after those IDs are resolved for the visible preview.

The render-path attempt proved unsafe and caused `EXC_BAD_ACCESS`. The later selected-venue attempt avoided `DiscoverScreen`, but the absence of logs shows it still did not connect to the actual venue preview data flow in a way that starts the listener.

## Where `[GoingTabSyncDebug] reconcileApplied` Comes From

`[GoingTabSyncDebug] reconcileApplied` comes from `scheduleDeferredFollowingTabGoingReconcile(venueEventID:)` in `MapViewModel+VenueEventSocial.swift`.

That function is scheduled after successful local Going writes, including the venue-preview toggle flow. It waits about 2 seconds, calls `refreshFollowingTabDataGlobally()`, then logs:

`[GoingTabSyncDebug] reconcileApplied count=... eventId=...`

This is not Supabase realtime. It is a delayed reconcile path that re-queries Supabase after the current user changes Going state. The refresh path in `MapViewModel+FollowingTab.swift` reloads the user's `venue_event_interests`, fetches related `venue_events`, computes attendee counts for those events, and republishes Following tab Going state.

Separately, venue preview counts are updated by `loadVisibleVenueEventInterests(preserveLocalOptimistic:)`, which queries `venue_event_interests` for loaded `venueEventRows` and applies `venueEventInterestCounts` / `venueEventInterestIDs`. That path logs `[GoingButtonDebug] reconcileApplied`, not `[GoingTabSyncDebug] reconcileApplied`.

## Can This Path Be Made Faster Or Reused Safely?

The `GoingTabSyncDebug` path should not be reused directly for venue preview responsiveness. It is intentionally broad: it reloads favorite venues, the user's Going memberships, event rows, aggregate counts, reminders, and pickup-related Following state. Running that as a venue-preview refresh would be heavier than needed and could add avoidable latency.

The safer reusable piece is the narrower count reconciliation concept:

- For venue preview, reconcile only the affected `venue_event_id` or the currently visible event IDs.
- Update only `venueEventInterestCounts[eventID]` and the current user's `venueEventInterestIDs` when needed.
- Trigger it only from stable non-render lifecycle events or an already-safe service callback, never from `DiscoverScreen` body/rows/tasks/overlays.

This can make venue preview updates faster than the global Following reconcile, but it still will not make User B realtime by itself. Without a safe subscription trigger or another remote event source, User B still needs either an explicit refresh, a coalesced polling/refresh trigger, or a future listener started from a proven non-render lifecycle owner.

## Current Safety Decision

For now, selected-venue Going realtime should remain paused. Keep the app stable, keep existing optimistic Going UX, and use the existing reconcile paths while a safer lifecycle owner is identified.
