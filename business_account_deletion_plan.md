# Business Account Deletion Plan

## Scope And Goal

Add a self-service business account deletion flow that removes the business account/profile and cleans up all venues managed by that business using the existing venue removal architecture:

- `origin_type = community`: release/unclaim the venue and return it to the community marketplace.
- `origin_type = business`: hard-delete the business-created venue row and its linked venue ecosystem.

This plan is implementation guidance only. It does not change code or SQL yet.

## Current Architecture To Reuse

The existing single-venue flow is the foundation:

- `public.release_or_delete_business_venue(p_venue_id uuid)` performs transactional database cleanup for one venue.
- `public.delete_business_venue_cascade(p_venue_id uuid)` is a compatibility wrapper.
- The RPC determines behavior from `venues.origin_type`.
- The RPC returns exact `deleted_storage_paths`.
- The app deletes those paths from Supabase Storage using `storage.from("venue-photos").remove(paths:)` as best-effort cleanup.
- The app optimistically removes local venue/event/chat/prediction state, stops realtime listeners, refreshes owned venues, and refreshes Discover after success.

Business account deletion should preserve this model, but run it for every venue owned or claimed by the business before deleting the business row/profile.

## Recommended High-Level Flow

1. User opens Settings -> Business Account -> Delete Business Account.
2. App loads a deletion preview from the server:
   - business display name
   - number of business-created venues that will be hard-deleted
   - number of community venues that will be released
   - number of venue events/games that will be removed
   - number of storage paths expected for cleanup
3. User confirms with strong destructive wording and re-authentication if available.
4. App calls one server-side business deletion endpoint.
5. Server validates ownership and locks the target business row.
6. Server finds all managed venues:
   - `venues.business_id = p_business_id`
   - approved `venue_claims.business_id = p_business_id`
   - legacy approved claims for the same owner email when no business id exists
7. Server releases/deletes each venue according to `origin_type`.
8. Server deletes or anonymizes remaining business-linked profile rows.
9. Server deletes the `public.businesses` row only after venue cleanup succeeds.
10. Server returns deleted storage paths and cleanup counts.
11. Storage cleanup runs after the database transaction succeeds.
12. App clears business caches, dismisses business UI, and shows an account-deleted empty/signed-out state.

## 1. Business-Created Venues Deletion

For `origin_type = business`, the account deletion flow should hard-delete each venue just like the current venue-level path:

- Delete child venue event/social rows first.
- Delete business history/stat rows tied to the venue.
- Delete reports and favorite links tied to the venue.
- Clear user profile references such as `home_crowd_venue_id`.
- Unlink claim rows by setting `venue_id = NULL` and `business_id = NULL`.
- Delete the `public.venues` row.
- Collect storage paths from:
  - `cover_photo_url`
  - `menu_photo_url`
  - `cover_photo_thumbnail_url`
  - `menu_photo_thumbnail_url`

Business-created venues should disappear from Discover/map, business dashboard, saved/favorites, and venue detail screens.

## 2. Claimed Community Venues Release

For `origin_type = community`, the account deletion flow must not delete the public venue identity row.

Release behavior should mirror the existing venue release path:

- Keep the `public.venues` row.
- Preserve safe public identity fields:
  - name
  - address/location
  - coordinates
  - `venue_identity_key`
  - `origin_type = community`
  - `admin_status = active`
- Remove business linkage:
  - `business_id = NULL`
  - `owner_user_id = NULL`
  - `owner_email = NULL`
- Clear business-added details:
  - phone
  - website
  - description
  - features
  - screen count and amenity booleans back to `NULL`
  - supporter country
  - venue photos and thumbnails
- Update approved claim rows to released:
  - `approval_status = 'released'`
  - `venue_id = NULL`
  - `business_id = NULL`

Released community venues should remain visible on Discover as unclaimed/community venues and become claimable again.

## 3. Games, Chats, Vibes, Going, Predictions Cleanup

The business account deletion flow should delete every venue event owned by the business’s managed venues.

Cleanup targets should include:

- `venue_events`
- `venue_event_comments`
- `venue_event_comment_likes`
- `venue_event_comment_reactions`
- `comment_reports` tied to deleted events/comments
- `venue_event_vibes`
- `venue_event_interests` / going rows
- `venue_event_predictions`
- `business_game_history`
- any venue/event analytics/stat rows present in the schema

This should happen for both business-created venues and released community venues because business-created games/chats/social activity are tied to the business listing and should not remain after account deletion.

Realtime cleanup is client-side after success:

- Stop venue owner analytics realtime.
- Stop venue event comments listeners.
- Stop venue event comment reaction refresh.
- Stop venue event prediction realtime.
- Clear local event ids, interest ids, going counts, avatar profiles, prediction summaries, and selected event state.

## 4. Storage And Photo Cleanup

Database functions must not directly delete from `storage.objects`.

Storage cleanup should use only exact paths returned by the server:

- Do not delete folders.
- Do not delete wildcard paths.
- Do not delete by owner email prefix.
- Do not delete all files under a business folder.
- Do not infer paths on the client.

The server should collect exact paths from venue photo columns before clearing/deleting venue rows and return a deduplicated array:

- `deleted_storage_paths`
- optional `storage_paths_returned`
- optional per-venue path counts for audit/debug

Storage deletion should be best-effort and non-transactional:

- Database deletion/release succeeds or fails atomically.
- Storage cleanup failure must not resurrect the business account or venue rows.
- Failed storage cleanup should be logged with enough path metadata to retry safely.

## 5. Business Row And Profile Deletion

After all managed venues have been released or hard-deleted successfully, delete business-level records.

Primary target:

- `public.businesses` row for the selected business.

Related cleanup:

- Pending venue claims for that business should be cancelled/deleted or marked with a terminal status such as `business_deleted`.
- Approved claim rows should already be released/unlinked by venue cleanup.
- Archived/disabled business rows for the same owner should be handled deliberately:
  - If deleting one selected business, only delete that business.
  - If deleting the entire business-owner account, delete all businesses owned by the authenticated owner.
- Clear local business owner caches:
  - `ownedBusinesses`
  - `archivedOwnedBusinesses`
  - `ownedBusinessVenues`
  - `legacyOwnerVenuesForEmailFallback`
  - pending/rejected claim state
  - selected owner venue id

Auth account deletion is a separate decision:

- If “delete business profile” means only the business organization, keep the Supabase auth user and return them to non-business/no-business state.
- If “delete business login account” means deleting the Supabase auth user, do that only after database cleanup succeeds, using an Edge Function with service-role privileges.

## 6. Audit Logging

Add a dedicated minimal audit table for business account deletion, or extend the existing audit model with a separate parent audit row.

Recommended audit shape:

- `id`
- `action = 'businessAccountDelete'`
- `business_id`
- `deleted_by`
- `deleted_by_email`
- `business_snapshot`
- `venue_ids`
- `released_venue_ids`
- `hard_deleted_venue_ids`
- `deleted_event_ids`
- `deleted_storage_paths`
- `deleted_counts`
- `started_at`
- `deleted_at`

Keep snapshots minimal and privacy-safe.

Allowed snapshot fields:

- business id
- display name
- owner user id
- owner email
- admin status
- deletion timestamp
- counts

Do not store:

- venue phone numbers
- venue websites
- venue descriptions
- photo URLs
- addresses
- comments
- chat content
- fan social content
- prediction content

Keep the existing per-venue audit rows for venue-level traceability and add the business parent audit row to tie the full account deletion together.

## 7. Transaction Safety

Database cleanup should be all-or-nothing.

Recommended database invariant:

- If any venue release/delete fails, do not delete the business row.
- If any community venue release verification fails, roll back the whole business deletion.
- If any business-created venue hard delete fails, roll back the whole business deletion.
- If business row deletion fails, roll back all venue cleanup.

Use row locks:

- Lock the target `businesses` row with `FOR UPDATE`.
- Lock all target venue rows with `FOR UPDATE`.
- Resolve target venue ids before mutation.
- Resolve event/comment ids before deletion.
- Resolve storage paths before clearing/deleting venue rows.

Verification checks:

- Community venues remain in `public.venues`.
- Community venues have no business linkage.
- Community venue approved claims are no longer approved.
- Business-created venues no longer exist.
- No target `venue_events` remain.
- The target business row no longer exists.

Storage cleanup remains outside the database transaction.

## 8. App UI Confirmation Wording

Use a two-stage confirmation.

### First Screen

Title:

`Delete business account?`

Message:

`This will permanently delete your business account and remove all business-managed content from FanGeo. Business-created venues will be deleted. Claimed community venues will be returned to the FanGeo community marketplace so another business can claim them. This action cannot be undone.`

Summary rows:

- `Business-created venues to delete: N`
- `Community venues to release: N`
- `Games and fan activity to remove: N`
- `Photos to remove: N`

Primary destructive button:

`Continue`

Secondary button:

`Cancel`

### Final Confirmation

Require typing the business display name, or require a clear destructive confirmation.

Title:

`Permanently delete business account?`

Message:

`This deletes the business profile, business-created venues, games, chats, vibes, going data, predictions, and business photos. Community venues you claimed will stay on the map but your ownership and business details will be removed.`

Buttons:

- `Cancel`
- `Delete Business Account`

Progress state:

`Deleting business account...`

Success toast:

`Business account deleted.`

Failure copy:

`We could not delete this business account. No changes were saved. Please try again.`

Storage-only warning if needed:

`The business account was deleted, but some photos could not be removed. FanGeo will retry cleanup.`

## 9. Empty State After Deletion

After success:

- Dismiss business dashboard and venue details sheets.
- Clear selected business and selected venue ids.
- Clear stale venue editor fields and photo URLs.
- Clear managed games.
- Refresh Discover/map.
- Refresh Settings business state.
- If the Supabase auth user remains signed in, show a no-business state:
  - Title: `No business account`
  - Message: `Create a business account to add or manage venues.`
  - Button: `Create Business Account`
- If the auth user is deleted or signed out, return to logged-out/auth screen.

No stale managed venues should appear from:

- `ownerVenueDatabaseId`
- `ownedBusinessVenues`
- `legacyOwnerVenuesForEmailFallback`
- cached Discover rows
- selected venue preview
- Going tab rows tied to deleted events

## 10. Supabase RPC Vs Edge Function Recommendation

Recommended approach: Edge Function orchestration + transactional SQL RPC.

Use a SQL RPC for database mutation because:

- It can run all database cleanup in one transaction.
- It can use `SECURITY DEFINER` with strict ownership validation.
- It can lock rows and verify invariants.
- It can return structured counts and exact storage paths.
- It matches the existing venue release/delete architecture.

Use an Edge Function as the public deletion endpoint because:

- Storage cleanup requires Storage API, not direct SQL against `storage.objects`.
- Auth user deletion, if required, needs service-role admin privileges.
- The Edge Function can call the database RPC, then remove exact storage paths.
- It can record storage cleanup failure separately without rolling back committed database cleanup.
- It can return a single app-friendly response.

Suggested structure:

- `public.delete_business_account_cascade(p_business_id uuid)`:
  - validates current user owns the business
  - releases/deletes all venues transactionally
  - deletes/unlinks claims and business rows transactionally
  - inserts audit rows
  - returns exact storage paths and counts
- `supabase/functions/delete-business-account`:
  - validates user session
  - calls the RPC
  - deletes exact storage paths from `venue-photos`
  - optionally deletes the auth user after successful database cleanup
  - returns final status to app

If auth account deletion is not included, the app may call the RPC directly and keep current client-side best-effort storage cleanup. For a full business account deletion feature, Edge Function orchestration is safer.

## 11. Risks And Rollback Strategy

### Risks

- Misclassifying community venues as business-created could delete public venue rows that should be retained.
- Deleting storage by prefix could remove another business’s photos.
- Deleting the business row before venue cleanup could orphan venues or claims.
- Auth user deletion before database cleanup could block ownership validation and recovery.
- Long-running deletion could time out for businesses with many venues/events.
- Existing `ON DELETE SET NULL` foreign keys may hide missing explicit cleanup if business row deletion happens too early.
- Storage cleanup failure can leave orphaned files.
- Client interruption after RPC success but before storage cleanup can leave orphaned files if using client-only cleanup.

### Rollback Strategy

Database rollback:

- Keep all database cleanup inside one RPC transaction.
- Raise exceptions if verification fails.
- Do not delete the business row until all venues have completed release/delete verification.

Storage rollback:

- Storage deletes are not transactional.
- Delete storage only after the database RPC commits.
- Log exact failed paths for retry.
- Never delete storage before the database cleanup succeeds.

Auth rollback:

- Do not delete the auth user until after database cleanup and storage cleanup attempt.
- If auth deletion fails after business deletion succeeds, sign the user out or show a non-business account state.
- If auth deletion is required by product policy, add an admin retry path.

Operational rollback:

- Keep minimal audit records.
- For early rollout, consider feature flagging business account deletion.
- Add diagnostics logs for:
  - target business id
  - venues found
  - release count
  - hard-delete count
  - event count
  - storage path count
  - transaction success/failure

## 12. Test Checklist

### Business-Created Venue

- Create a business-created venue.
- Add photos.
- Add games.
- Add comments, likes/reactions, vibes, going rows, and predictions.
- Delete the business account.
- Verify the business-created venue row is gone.
- Verify venue games are gone.
- Verify fan chat/comments/vibes/going/predictions are gone.
- Verify favorite/saved venue links are gone.
- Verify venue photos are removed from `venue-photos`.
- Verify Discover/map no longer shows the venue.

### Claimed Community Venue

- Claim a community venue.
- Add business phone/website/description/features/photos.
- Add games and fan activity.
- Delete the business account.
- Verify the venue row still exists.
- Verify the venue remains visible on Discover/map.
- Verify `business_id`, `owner_user_id`, and `owner_email` are null.
- Verify business details/photos/features are cleared.
- Verify amenity booleans are `NULL`.
- Verify approved claim is now released/unlinked.
- Verify venue can be claimed again.
- Verify business-created games/social data are gone.

### Mixed Business

- Use one business account with:
  - multiple business-created venues
  - multiple claimed community venues
  - pending claims
  - rejected claims
- Delete the account.
- Verify every venue follows the correct `origin_type` path.
- Verify no managed venues remain in business dashboard.
- Verify no stale selected venue/profile data appears.

### Storage Safety

- Confirm only exact returned paths are passed to Storage API.
- Confirm no folder/prefix/wildcard deletion happens.
- Confirm paths from another venue/business are not removed.
- Simulate Storage API failure and verify database deletion still succeeds.
- Verify failed storage paths are logged for retry.

### Transaction Safety

- Force a release verification failure and verify all database changes roll back.
- Force a hard-delete failure and verify all database changes roll back.
- Force business row deletion failure and verify all venue cleanup rolls back.
- Confirm no partial business account deletion appears in UI.

### UI State

- Confirm destructive copy clearly distinguishes:
  - business-created venues will be deleted
  - community venues will be released
- Confirm final confirmation requires deliberate action.
- Confirm progress state disables duplicate taps.
- Confirm success clears business caches.
- Confirm Settings routes to no-business/create-business state.
- Confirm Venue Details and Manage Games do not open stale data.
- Confirm Discover refreshes after deletion.

### Auth Variants

- If deleting only business profile:
  - user remains signed in
  - business mode is disabled
  - fan account behavior remains intact if allowed
- If deleting business auth account:
  - database cleanup succeeds first
  - storage cleanup is attempted
  - auth user is deleted last
  - app signs out cleanly

## Implementation Phases

1. Add read-only deletion preview RPC.
2. Add transactional business deletion RPC.
3. Add Edge Function wrapper for RPC + Storage API cleanup.
4. Add app UI confirmation flow.
5. Add local cache clearing and empty-state routing.
6. Add diagnostics and audit verification.
7. Run staged tests on disposable businesses.
8. Enable for production behind a feature flag.
