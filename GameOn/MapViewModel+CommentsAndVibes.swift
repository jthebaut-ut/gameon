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
    static let selectColumns = "id,venue_event_id,user_email,comment,created_at"
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

            let email = !currentUserEmail.isEmpty ? currentUserEmail : venueOwnerEmail

            for row in rows {
                guard let vibe = row.vibe_type else { continue }

                counts[vibe, default: 0] += 1

                if row.user_email == email {
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
        let email = !currentUserEmail.isEmpty ? currentUserEmail : venueOwnerEmail

        guard !email.isEmpty else {
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
            let rows: [VenueEventCommentRow] = try await supabase
                .from("venue_event_comments")
                .select(VenueEventCommentsPagination.selectColumns)
                .eq("venue_event_id", value: venueEventID)
                .order("created_at", ascending: false)
                .order("id", ascending: false)
                .limit(VenueEventCommentsPagination.initialLimit)
                .execute()
                .value

            await MainActor.run {
                venueEventComments[venueEventID] = rows
            }

            let hasMore = rows.count >= VenueEventCommentsPagination.initialLimit
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
            let rows: [VenueEventCommentRow] = try await supabase
                .from("venue_event_comments")
                .select(VenueEventCommentsPagination.selectColumns)
                .eq("venue_event_id", value: venueEventID)
                .or(VenueEventCommentsQuery.keysetOlderThanOrFilter(createdAt: beforeCreatedAt, commentId: beforeId))
                .order("created_at", ascending: false)
                .order("id", ascending: false)
                .limit(VenueEventCommentsPagination.pageLimit)
                .execute()
                .value

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

            let hasMore = rows.count >= VenueEventCommentsPagination.pageLimit
            #if DEBUG
            let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            print("[VenueCommentsPagination] older page: \(String(format: "%.1f", ms))ms rows=\(rows.count) hasMore=\(hasMore)")
            #endif
            return hasMore
        } catch {
            logVenueEventSocialLoadError("ERROR LOADING OLDER COMMENTS:", loadCancelledTag: "comments", error: error)
            return true
        }
    }

    // Inserts a comment as `currentUserEmail`; refreshes the thread on success or error.
    func addComment(to venueEventID: UUID, text: String) async {
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleanText.isEmpty else { return }
        guard !currentUserEmail.isEmpty else {
            print("LOGIN REQUIRED TO COMMENT")
            return
        }

        do {
            let newComment = VenueEventCommentInsert(
                venue_event_id: venueEventID,
                user_email: currentUserEmail,
                comment: cleanText
            )

            let row: VenueEventCommentRow = try await supabase
                .from("venue_event_comments")
                .insert(newComment)
                .select(VenueEventCommentsPagination.selectColumns)
                .single()
                .execute()
                .value

            await MainActor.run {
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
        }
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

    // Venue-owner dashboard: loads `comment_reports` for events owned by `venueOwnerEmail` and builds display rows.
    func loadReportedCommentsForMyVenue() async {
        guard !venueOwnerEmail.isEmpty else { return }

        do {
            let myVenueEvents: [VenueEventRow] = try await supabase
                .from("venue_events")
                .select()
                .eq("owner_email", value: venueOwnerEmail)
                .execute()
                .value

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

    func reportComment(_ comment: VenueEventCommentRow, reason: String = "reported") async {
        guard let commentID = comment.id,
              let venueEventID = comment.venue_event_id else {
            print("NO VALID COMMENT OR EVENT ID")
            return
        }

        do {
            let session = try await supabase.auth.session
            let reporterEmail = session.user.email ?? ""

            guard !reporterEmail.isEmpty else {
                print("NO AUTH SESSION EMAIL")
                return
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

        } catch {
            print("ERROR REPORTING COMMENT:", error)
        }
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
