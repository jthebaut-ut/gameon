import Foundation
import Supabase

// Venue-event social layer: vibe votes, threaded comments, reports, and moderation helpers for venue owners.

/// Task cancellation during overlapping loads is expected; do not log as ERROR.
private func logVenueEventSocialLoadError(_ prefix: String, loadCancelledTag: String, error: Error) {
    if error is CancellationError {
#if DEBUG
        print("[LoadCancelled] \(loadCancelledTag)")
#endif
        return
    }
    print(prefix, error)
}

private enum VenueEventCommentsPagination {
    static let initialLimit = 100
    static let pageLimit = 50
    static let selectColumns = "id,venue_event_id,user_email,comment,created_at,is_moderation_hidden"
}

private enum CurrentUserCommentReportFlags {
    static let inQueryChunk = 80
}

private enum VenueEventCommentsQuery {
    static func isoTimestamp(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    static func keysetOlderThanOrFilter(createdAt: Date, commentId: UUID) -> String {
        let iso = isoTimestamp(createdAt)
        let uid = commentId.uuidString.lowercased()
        return "created_at.lt.\(iso),and(created_at.eq.\(iso),id.lt.\(uid))"
    }
}

extension MapViewModel {

    /// Whether the signed-in fan has a `comment_reports` row for this comment (local cache, hydrated from Supabase on comment load).
    func hasCurrentUserReportedComment(commentID: UUID?) -> Bool {
        guard let commentID else { return false }
        return commentIDsReportedByCurrentUser.contains(commentID)
    }

    /// Marks a comment as reported in memory so the flag UI updates immediately (also used when the insert hits the unique constraint).
    func markCommentReportedLocally(commentID: UUID) {
        commentIDsReportedByCurrentUser.insert(commentID)
    }

    func markCommentUnreportedLocally(commentID: UUID) {
        commentIDsReportedByCurrentUser.remove(commentID)
    }

    private func fetchModerationReportCountForComment(commentId: UUID) async -> Int? {
        struct Row: Decodable { let moderation_report_count: Int? }
        do {
            let rows: [Row] = try await supabase
                .from("venue_event_comments")
                .select("moderation_report_count")
                .eq("id", value: commentId.uuidString)
                .limit(1)
                .execute()
                .value
            return rows.first?.moderation_report_count
        } catch {
            return nil
        }
    }

    /// Loads `comment_reports` rows for the current auth email and visible comment ids so flags render as already reported after relaunch.
    func loadCurrentUserCommentReportFlags(for venueEventID: UUID) async {
        let ids = await MainActor.run {
            venueEventComments[venueEventID]?.compactMap(\.id) ?? []
        }
        guard !ids.isEmpty else { return }

        let session: Session
        do {
            session = try await supabase.auth.session
        } catch {
            return
        }

        let reporterEmail = session.user.email?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !reporterEmail.isEmpty else { return }

        var merged: Set<UUID> = []
        var start = 0
        while start < ids.count {
            let end = min(start + CurrentUserCommentReportFlags.inQueryChunk, ids.count)
            let chunk = Array(ids[start..<end])
            start = end

            do {
                let rows: [CommentReportRow] = try await supabase
                    .from("comment_reports")
                    .select("comment_id")
                    .eq("venue_event_id", value: venueEventID)
                    .eq("reporter_email", value: reporterEmail)
                    .in("comment_id", values: chunk)
                    .execute()
                    .value

                for row in rows {
                    if let cid = row.comment_id {
                        merged.insert(cid)
                    }
                }
            } catch {
                logVenueEventSocialLoadError(
                    "ERROR LOADING COMMENT REPORT FLAGS:",
                    loadCancelledTag: "comment_report_flags",
                    error: error
                )
            }
        }

        await MainActor.run {
            for cid in merged where commentIDsReportedByCurrentUser.insert(cid).inserted {}
        }
    }

    private static func isCommentReportUniqueViolation(_ error: Error) -> Bool {
        if let pe = error as? PostgrestError, pe.code == "23505" {
            return true
        }
        let blob = "\(error.localizedDescription) \(String(describing: error))".lowercased()
        if blob.contains("23505") || blob.contains("duplicate key") || blob.contains("unique constraint") {
            return true
        }
        if let pe = error as? PostgrestError {
            let detail = "\(pe.message) \(pe.detail ?? "") \(pe.hint ?? "")".lowercased()
            if detail.contains("duplicate") || detail.contains("unique") || detail.contains("23505") {
                return true
            }
        }
        return false
    }

    // Fetches aggregate vibe tallies and the current user’s selections for one event.
    func loadVibes(for venueEventID: UUID) async {
        do {
            let rows: [VenueEventVibeRow] = try await supabase
                .from("venue_event_vibes")
                .select("venue_event_id,user_email,vibe_type")
                .eq("venue_event_id", value: venueEventID.uuidString)
                .execute()
                .value

            var counts: [String: Int] = [:]
            var myVibes: Set<String> = []

            let email = await strictNormalizedSessionEmailForSocialTables()
                ?? OwnerBusinessEmail.normalized(!currentUserEmail.isEmpty ? currentUserEmail : venueOwnerEmail)

            for row in rows {
                guard let vibe = row.vibe_type else { continue }

                counts[vibe, default: 0] += 1

                if OwnerBusinessEmail.normalized(row.user_email ?? "") == email {
                    myVibes.insert(vibe)
                }
            }

            await MainActor.run {
                venueEventVibeCounts[venueEventID] = counts
                myVenueEventVibes[venueEventID] = myVibes
            }

            print("LOADED VIBES:", counts)

        } catch {
            logVenueEventSocialLoadError("ERROR LOADING VIBES:", loadCancelledTag: "vibes", error: error)
        }
    }

    // Inserts or deletes a single vibe row for the signed-in user or venue owner.
    func toggleVibe(for venueEventID: UUID, vibeType: String) async {
        let email = await strictNormalizedSessionEmailForSocialTables()
            ?? OwnerBusinessEmail.normalized(!currentUserEmail.isEmpty ? currentUserEmail : venueOwnerEmail)

        guard OwnerBusinessEmail.isValidStrict(email) else {
            print("LOGIN REQUIRED TO VOTE VIBE")
            return
        }

        let alreadySelected = myVenueEventVibes[venueEventID]?.contains(vibeType) ?? false

        do {
            if alreadySelected {
                try await supabase
                    .from("venue_event_vibes")
                    .delete()
                    .eq("venue_event_id", value: venueEventID.uuidString)
                    .eq("user_email", value: email)
                    .eq("vibe_type", value: vibeType)
                    .execute()
            } else {
                let insert = VenueEventVibeInsert(
                    venue_event_id: venueEventID,
                    user_email: email,
                    vibe_type: vibeType
                )

                try await supabase
                    .from("venue_event_vibes")
                    .insert(insert)
                    .execute()
            }

            await loadVibes(for: venueEventID)

        } catch {
            print("ERROR TOGGLING VIBE:", error)
        }
    }

    /// Loads the first page of fan updates (newest first server-side, stored unsorted; views sort for display).
    func loadComments(for venueEventID: UUID) async {
        _ = await loadCommentsFirstPage(for: venueEventID)
    }

    /// Keyset-paginated first page. Returns `true` if older rows may exist (page was full).
    func loadCommentsFirstPage(for venueEventID: UUID) async -> Bool {
        #if DEBUG
        let t0 = CFAbsoluteTimeGetCurrent()
        #endif
        do {
            let rowsRaw: [VenueEventCommentRow] = try await supabase
                .from("venue_event_comments")
                .select(VenueEventCommentsPagination.selectColumns)
                .eq("venue_event_id", value: venueEventID)
                .order("created_at", ascending: false)
                .order("id", ascending: false)
                .limit(VenueEventCommentsPagination.initialLimit)
                .execute()
                .value

            let rows = rowsRaw.filter { !$0.isHiddenFromThread }

            await MainActor.run {
                venueEventComments[venueEventID] = rows
            }

            await loadCurrentUserCommentReportFlags(for: venueEventID)

            let hasMore = rowsRaw.count >= VenueEventCommentsPagination.initialLimit
            #if DEBUG
            let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            print("[VenueCommentsPagination] initial: \(String(format: "%.1f", ms))ms rows=\(rows.count) limit=\(VenueEventCommentsPagination.initialLimit) hasMore=\(hasMore)")
            #endif
            return hasMore
        } catch {
            logVenueEventSocialLoadError("ERROR LOADING COMMENTS:", loadCancelledTag: "comments", error: error)
            await MainActor.run {
                venueEventComments[venueEventID] = []
            }
            return false
        }
    }

    /// Older fan updates before `(beforeCreatedAt, beforeId)` in `(created_at DESC, id DESC)` order. Returns whether more may exist.
    func loadOlderVenueComments(for venueEventID: UUID, beforeCreatedAt: Date, beforeId: UUID) async -> Bool {
        #if DEBUG
        let t0 = CFAbsoluteTimeGetCurrent()
        #endif
        do {
            let rowsRaw: [VenueEventCommentRow] = try await supabase
                .from("venue_event_comments")
                .select(VenueEventCommentsPagination.selectColumns)
                .eq("venue_event_id", value: venueEventID)
                .or(VenueEventCommentsQuery.keysetOlderThanOrFilter(createdAt: beforeCreatedAt, commentId: beforeId))
                .order("created_at", ascending: false)
                .order("id", ascending: false)
                .limit(VenueEventCommentsPagination.pageLimit)
                .execute()
                .value

            let rows = rowsRaw.filter { !$0.isHiddenFromThread }

            await MainActor.run {
                var list = venueEventComments[venueEventID] ?? []
                var existing = Set(list.compactMap(\.id))
                for row in rows {
                    guard let rid = row.id, !existing.contains(rid) else { continue }
                    list.append(row)
                    existing.insert(rid)
                }
                venueEventComments[venueEventID] = list
            }

            await loadCurrentUserCommentReportFlags(for: venueEventID)

            let hasMore = rowsRaw.count >= VenueEventCommentsPagination.pageLimit
            #if DEBUG
            let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            print("[VenueCommentsPagination] older page: \(String(format: "%.1f", ms))ms rows=\(rowsRaw.count) hasMore=\(hasMore)")
            #endif
            return hasMore
        } catch {
            logVenueEventSocialLoadError("ERROR LOADING OLDER COMMENTS:", loadCancelledTag: "comments", error: error)
            return true
        }
    }

    /// Inserts a comment as the active authenticated session email. Returns `nil` on success, or a user-facing error string.
    func addComment(to venueEventID: UUID, text: String) async -> String? {
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleanText.isEmpty else { return nil }
        guard let commenterEmail = await strictNormalizedSessionEmailForSocialTables() else {
            print("LOGIN REQUIRED TO COMMENT")
            return "Sign in to post an update."
        }

        if ModerationService.containsProfanity(cleanText) {
            return ModerationService.profanityRejectionUserMessage()
        }

        if let limit = RateLimitService.checkVenueEventCommentSend(venueEventId: venueEventID, body: cleanText) {
            return limit
        }

        do {
            let newComment = VenueEventCommentInsert(
                venue_event_id: venueEventID,
                user_email: commenterEmail,
                comment: cleanText
            )

            let row: VenueEventCommentRow = try await supabase
                .from("venue_event_comments")
                .insert(newComment)
                .select(VenueEventCommentsPagination.selectColumns)
                .single()
                .execute()
                .value

            RateLimitService.recordVenueEventCommentSend(venueEventId: venueEventID, body: cleanText)

            await MainActor.run {
                guard !row.isHiddenFromThread else { return }
                var list = venueEventComments[venueEventID] ?? []
                if let nid = row.id {
                    if !list.contains(where: { $0.id == nid }) {
                        list.append(row)
                    }
                } else {
                    list.append(row)
                }
                venueEventComments[venueEventID] = list
            }

            print("COMMENT ADDED")

        } catch {
            print("ERROR ADDING COMMENT:", error)
            await loadComments(for: venueEventID)
            return "Couldn’t post that update. Check your connection and try again."
        }
        return nil
    }

    func deleteComment(_ comment: VenueEventCommentRow) async {
        guard let id = comment.id else { return }

        do {
            try await supabase
                .from("venue_event_comments")
                .delete()
                .eq("id", value: id.uuidString)
                .execute()

            if let venueEventID = comment.venue_event_id {
                await MainActor.run {
                    venueEventComments[venueEventID]?.removeAll { $0.id == id }
                }
            }

            print("COMMENT DELETED")

        } catch {
            print("ERROR DELETING COMMENT:", error)
            if let venueEventID = comment.venue_event_id {
                await loadComments(for: venueEventID)
            }
        }
    }

    // Venue-owner dashboard: loads `comment_reports` for events scoped to the selected venue (`venue_id`) when set, otherwise legacy `owner_email`.
    func loadReportedCommentsForMyVenue() async {
        do {
            let myVenueEvents: [VenueEventRow]
            if let vid = ownerVenueDatabaseId {
#if DEBUG
                print("[BusinessPhaseB3] using venue_id path screen=loadReportedCommentsForMyVenue")
#endif
                myVenueEvents = try await supabase
                    .from("venue_events")
                    .select()
                    .eq("venue_id", value: vid.uuidString.lowercased())
                    .eq("admin_status", value: "active")
                    .execute()
                    .value
            } else {
                let ownerEmail = OwnerBusinessEmail.normalized(venueOwnerEmail)
                guard OwnerBusinessEmail.isValidStrict(ownerEmail) else { return }
#if DEBUG
                print("[BusinessPhaseB3] using owner_email fallback screen=loadReportedCommentsForMyVenue")
#endif
                myVenueEvents = try await supabase
                    .from("venue_events")
                    .select()
                    .eq("owner_email", value: ownerEmail)
                    .eq("admin_status", value: "active")
                    .execute()
                    .value
            }

            let myVenueEventIDs = myVenueEvents.compactMap { $0.id }

            guard !myVenueEventIDs.isEmpty else {
                await MainActor.run {
                    reportedComments = []
                    reportedCommentDisplays = []
                }
                return
            }

            let reports: [CommentReportRow] = try await supabase
                .from("comment_reports")
                .select()
                .in("venue_event_id", values: myVenueEventIDs)
                .order("created_at", ascending: false)
                .execute()
                .value

            await buildReportedCommentDisplays(from: reports)

            print("LOADED MY VENUE REPORTS:", reports.count)

        } catch {
            print("ERROR LOADING MY VENUE REPORTS:", error)
        }
    }

    func buildReportedCommentDisplays(from reports: [CommentReportRow]) async {
        do {
            let commentIDs = reports.compactMap { $0.comment_id }

            let comments: [VenueEventCommentRow] = commentIDs.isEmpty ? [] : try await supabase
                .from("venue_event_comments")
                .select()
                .in("id", values: commentIDs)
                .execute()
                .value

            let commentsByID: [UUID: VenueEventCommentRow] = Dictionary(
                uniqueKeysWithValues: comments.compactMap { comment in
                    guard let id = comment.id else { return nil }
                    return (id, comment)
                }
            )

            let venueEventIDs = comments.compactMap { $0.venue_event_id }

            let venueEvents: [VenueEventRow] = venueEventIDs.isEmpty ? [] : try await supabase
                .from("venue_events")
                .select()
                .in("id", values: venueEventIDs)
                .eq("admin_status", value: "active")
                .execute()
                .value

            let venueEventsByID: [UUID: VenueEventRow] = Dictionary(
                uniqueKeysWithValues: venueEvents.compactMap { event in
                    guard let id = event.id else { return nil }
                    return (id, event)
                }
            )

            let emails = Array(Set(
                comments.compactMap { $0.user_email } +
                reports.compactMap { $0.reporter_email }
            ))

            let profiles: [UserProfileRow] = emails.isEmpty ? [] : try await supabase
                .from("user_profiles")
                .select()
                .in("email", values: emails)
                .eq("admin_status", value: "active")
                .execute()
                .value

            let profilesByEmail: [String: UserProfileRow] = Dictionary(
                uniqueKeysWithValues: profiles.compactMap { profile in
                    guard let email = profile.email else { return nil }
                    return (email, profile)
                }
            )

            let displays = reports.map { report -> ReportedCommentDisplay in
                let comment = report.comment_id.flatMap { commentsByID[$0] }
                let venueEvent = comment?.venue_event_id.flatMap { venueEventsByID[$0] }

                return ReportedCommentDisplay(
                    reportID: report.id,
                    commentID: report.comment_id,
                    commentText: comment?.comment ?? "Comment not found",
                    reporterEmail: report.reporter_email ?? "Unknown",
                    reporterName: {
                        guard let email = report.reporter_email else { return "Unknown" }
                        return profilesByEmail[email]?.display_name ?? email
                    }(),
                    reportedAt: report.created_at ?? "",
                    commenterName: {
                        guard let email = comment?.user_email else { return "Unknown user" }
                        return profilesByEmail[email]?.display_name ?? email
                    }(),
                    commenterAvatarURL: {
                        guard let email = comment?.user_email else { return "" }
                        return profilesByEmail[email]?.avatar_url ?? ""
                    }(),
                    venueName: venueEvent?.venue_name ?? "Unknown venue",
                    eventTitle: venueEvent?.event_title ?? "Unknown game"
                )
            }

            await MainActor.run {
                self.reportedComments = reports
                self.reportedCommentDisplays = displays
            }

        } catch {
            print("ERROR BUILDING REPORT DISPLAYS:", error)
        }
    }

    func loadReportedComments() async {
        do {
            let reports: [CommentReportRow] = try await supabase
                .from("comment_reports")
                .select()
                .order("created_at", ascending: false)
                .execute()
                .value

            await buildReportedCommentDisplays(from: reports)

            print("LOADED COMMENT REPORTS:", reports.count)

        } catch {
            print("ERROR LOADING COMMENT REPORTS:", error)
        }
    }

    /// Returns `true` when the comment should show as reported (insert succeeded or duplicate unique constraint).
    @discardableResult
    func reportComment(_ comment: VenueEventCommentRow, reason: String = "reported") async -> Bool {
        guard let commentID = comment.id,
              let venueEventID = comment.venue_event_id else {
            print("NO VALID COMMENT OR EVENT ID")
            return false
        }

        do {
            let session = try await supabase.auth.session
            let reporterEmail = session.user.email ?? ""

            guard !reporterEmail.isEmpty else {
                print("NO AUTH SESSION EMAIL")
                return false
            }

            print("REPORTER EMAIL FROM SESSION:", reporterEmail)

            let report = CommentReportInsert(
                comment_id: commentID,
                venue_event_id: venueEventID,
                reporter_email: reporterEmail,
                reason: reason
            )

            try await supabase
                .from("comment_reports")
                .insert(report)
                .execute()

            print("COMMENT REPORTED")

            markCommentReportedLocally(commentID: commentID)

#if DEBUG
            print("[CommentReport] report added comment=\(commentID.uuidString)")
#endif
            let activeAfterInsert = await fetchModerationReportCountForComment(commentId: commentID) ?? 0
#if DEBUG
            print("[CommentReport] active count=\(activeAfterInsert)")
            print(
                "[CommentReport] auto-hide threshold reached=\(activeAfterInsert >= ModerationService.hiddenAfterReportsThreshold)"
            )
#endif

            await applyCommentModerationAutoHide(commentId: commentID, venueEventID: venueEventID)

            return true

        } catch {
            if Self.isCommentReportUniqueViolation(error) {
                markCommentReportedLocally(commentID: commentID)
#if DEBUG
                let activeDup = await fetchModerationReportCountForComment(commentId: commentID) ?? 0
                print("[CommentReport] active count=\(activeDup)")
                print(
                    "[CommentReport] auto-hide threshold reached=\(activeDup >= ModerationService.hiddenAfterReportsThreshold)"
                )
#endif
                return true
            }
            print("ERROR REPORTING COMMENT:", error)
            return false
        }
    }

    /// Deletes the signed-in fan's `comment_reports` row only (unflag). DB trigger recomputes ``moderation_report_count``.
    @discardableResult
    func unreportComment(_ comment: VenueEventCommentRow) async -> Bool {
        guard let commentID = comment.id else {
            return false
        }

        do {
            let session = try await supabase.auth.session
            let reporterEmail = session.user.email?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            guard !reporterEmail.isEmpty else {
                return false
            }

            try await supabase
                .from("comment_reports")
                .delete()
                .eq("comment_id", value: commentID.uuidString)
                .eq("reporter_email", value: reporterEmail)
                .execute()

            markCommentUnreportedLocally(commentID: commentID)

#if DEBUG
            print("[CommentReport] report removed comment=\(commentID.uuidString)")
#endif
            let activeAfterDelete = await fetchModerationReportCountForComment(commentId: commentID) ?? 0
#if DEBUG
            print("[CommentReport] active count=\(activeAfterDelete)")
            print(
                "[CommentReport] auto-hide threshold reached=\(activeAfterDelete >= ModerationService.hiddenAfterReportsThreshold)"
            )
#endif

            return true
        } catch {
#if DEBUG
            print("[CommentReport] unreport failed:", error)
#endif
            return false
        }
    }

    /// After a new report row, DB trigger bumps ``moderation_report_count`` and may set ``is_moderation_hidden``. Refresh local thread and queue one-shot admin email via Edge Function.
    private func applyCommentModerationAutoHide(commentId: UUID, venueEventID: UUID) async {
        do {
            struct Row: Decodable {
                let id: UUID?
                let is_moderation_hidden: Bool?
                let moderation_report_count: Int?
            }
            let rows: [Row] = try await supabase
                .from("venue_event_comments")
                .select("id,is_moderation_hidden,moderation_report_count")
                .eq("id", value: commentId.uuidString)
                .limit(1)
                .execute()
                .value

            guard let row = rows.first,
                  row.is_moderation_hidden == true,
                  let count = row.moderation_report_count,
                  count >= ModerationService.hiddenAfterReportsThreshold
            else { return }

            await MainActor.run {
                venueEventComments[venueEventID]?.removeAll { $0.id == commentId }
            }

            ModerationService().notifyCommentModerationAlertBestEffort(commentId: commentId)
        } catch {
#if DEBUG
            print("[Moderation] applyCommentModerationAutoHide:", error)
#endif
        }
    }

    /// Report a venue listing (abuse, misinformation, etc.). Requires signed-in fan session.
    func reportVenue(venueId: UUID, category: ModerationReportCategory, details: String?) async throws {
        try await ModerationService().reportVenue(venueId: venueId, category: category, details: details)
    }

    func deleteReportedComment(_ report: ReportedCommentDisplay) async {
        guard let commentID = report.commentID else {
            print("NO COMMENT ID TO DELETE")
            return
        }

        do {
            try await supabase
                .from("venue_event_comments")
                .delete()
                .eq("id", value: commentID.uuidString)
                .execute()

            try await supabase
                .from("comment_reports")
                .delete()
                .eq("comment_id", value: commentID.uuidString)
                .execute()

            await MainActor.run {
                reportedComments.removeAll { $0.comment_id == commentID }
                reportedCommentDisplays.removeAll { $0.commentID == commentID }
            }

            print("REPORTED COMMENT AND REPORTS DELETED")

        } catch {
            print("ERROR DELETING REPORTED COMMENT:", error)
        }
    }

    func dismissCommentReport(_ report: ReportedCommentDisplay) async {
        guard let commentID = report.commentID else {
            print("NO COMMENT ID TO DISMISS REPORT")
            return
        }

        do {
            try await supabase
                .from("comment_reports")
                .delete()
                .eq("comment_id", value: commentID.uuidString)
                .execute()

            await MainActor.run {
                reportedComments.removeAll { $0.comment_id == commentID }
                reportedCommentDisplays.removeAll { $0.commentID == commentID }
            }

            print("COMMENT REPORT DISMISSED")

        } catch {
            print("ERROR DISMISSING COMMENT REPORT:", error)
        }
    }
}
