import Foundation

/// Client-side send throttling for DMs and venue-event fan updates (comments).
///
/// **Future:** Enforce limits with a Supabase **Edge Function** (validate JWT + body, apply sliding windows in Redis or Postgres)
/// or **Postgres triggers** on `direct_messages` / `venue_event_comments` so limits cannot be bypassed by modified clients.
enum RateLimitService {

    /// Generic throttle (spacing + volume windows).
    static let slowDownMessage = "Slow down — please wait a moment before posting again."

    /// Same text resent within the duplicate window.
    static let duplicateBlockedMessage = "Duplicate message blocked."
    static let fanUpdateMinimumQualityMessage = "Add a little more detail before posting."

    // MARK: - Private chat (`DirectChatService.sendMessage`)

    private static let chatMinInterval: TimeInterval = 1.5
    private static let chatWindow30: TimeInterval = 30
    private static let chatMaxPer30: Int = 5
    private static let chatWindow5m: TimeInterval = 300
    private static let chatMaxPer5m: Int = 20
    private static let chatDuplicateWindow: TimeInterval = 30

    // MARK: - Venue event comments / fan updates (`MapViewModel.addComment`)

    static let venueEventCommentMinInterval: TimeInterval = 10
    static let venueEventCommentDuplicateWindow: TimeInterval = 60
    static let venueEventCommentMinimumMeaningfulCharacters = 3
    private static let commentMinInterval: TimeInterval = venueEventCommentMinInterval
    private static let commentWindow2m: TimeInterval = 120
    private static let commentMaxPer2m: Int = 5
    private static let commentDuplicateWindow: TimeInterval = venueEventCommentDuplicateWindow

    // MARK: - Conversation reports (`ModerationService.reportConversation`)

    private static let conversationReportGlobalWindow: TimeInterval = 600
    private static let conversationReportGlobalMax = 3
    private static let conversationReportMinSpacingPerConversation: TimeInterval = 20

    // MARK: - Support requests (`SupportRequestService`)

    private static let supportRequestWindow: TimeInterval = 3600
    private static let supportRequestMaxPerWindow = 3

    private static let lock = NSLock()
    private static var chatByConversation: [UUID: ChatSendState] = [:]
    private static var commentByEvent: [UUID: CommentSendState] = [:]
    /// Per reporter: timestamps of conversation report submits (any conversation).
    private static var conversationReportGlobalTimes: [UUID: [Date]] = [:]
    /// Per conversation: last report submit attempt (spacing hammer on same thread).
    private static var conversationReportLastAttemptByConversation: [UUID: Date] = [:]
    /// Per user: successful support request sends (sliding hour).
    private static var supportRequestSuccessTimes: [UUID: [Date]] = [:]

    private struct ChatSendState {
        var lastSendAt: Date?
        var sendTimes: [Date]
        var lastFingerprint: String?
        var lastFingerprintAt: Date?
    }

    private struct CommentSendState {
        var lastSendAt: Date?
        var sendTimes: [Date]
        var lastFingerprint: String?
        var lastFingerprintAt: Date?
    }

    /// Returns a user-facing error string, or `nil` if the send may proceed.
    static func checkDirectChatSend(conversationId: UUID, body: String, now: Date = Date()) -> String? {
        let fingerprint = sendFingerprint(for: body)
        lock.lock()
        defer { lock.unlock() }

        var s = chatByConversation[conversationId] ?? ChatSendState(
            lastSendAt: nil,
            sendTimes: [],
            lastFingerprint: nil,
            lastFingerprintAt: nil
        )

        pruneChatSendTimes(&s.sendTimes, now: now)

        if let last = s.lastSendAt, now.timeIntervalSince(last) < chatMinInterval {
            return Self.slowDownMessage
        }

        let in30 = s.sendTimes.filter { now.timeIntervalSince($0) <= chatWindow30 }
        if in30.count >= chatMaxPer30 {
            return Self.slowDownMessage
        }

        if s.sendTimes.count >= chatMaxPer5m {
            return Self.slowDownMessage
        }

        if let fp = s.lastFingerprint,
           let at = s.lastFingerprintAt,
           fp == fingerprint,
           now.timeIntervalSince(at) < chatDuplicateWindow {
            return Self.duplicateBlockedMessage
        }

        return nil
    }

    /// Call only after a DM is successfully persisted.
    static func recordDirectChatSend(conversationId: UUID, body: String, now: Date = Date()) {
        let fingerprint = sendFingerprint(for: body)
        lock.lock()
        defer { lock.unlock() }

        var s = chatByConversation[conversationId] ?? ChatSendState(
            lastSendAt: nil,
            sendTimes: [],
            lastFingerprint: nil,
            lastFingerprintAt: nil
        )
        pruneChatSendTimes(&s.sendTimes, now: now)
        s.sendTimes.append(now)
        s.lastSendAt = now
        s.lastFingerprint = fingerprint
        s.lastFingerprintAt = now
        chatByConversation[conversationId] = s
    }

    /// Returns a user-facing error string, or `nil` if the post may proceed.
    static func checkVenueEventCommentSend(venueEventId: UUID, body: String, now: Date = Date()) -> String? {
        guard fanUpdateHasMinimumContentQuality(body) else {
            return fanUpdateMinimumQualityMessage
        }
        let fingerprint = sendFingerprint(for: body)
        lock.lock()
        defer { lock.unlock() }

        var s = commentByEvent[venueEventId] ?? CommentSendState(
            lastSendAt: nil,
            sendTimes: [],
            lastFingerprint: nil,
            lastFingerprintAt: nil
        )

        pruneCommentSendTimes(&s.sendTimes, now: now)

        if let last = s.lastSendAt, now.timeIntervalSince(last) < commentMinInterval {
            return Self.slowDownMessage
        }

        if s.sendTimes.count >= commentMaxPer2m {
            return Self.slowDownMessage
        }

        if let fp = s.lastFingerprint,
           let at = s.lastFingerprintAt,
           fp == fingerprint,
           now.timeIntervalSince(at) < commentDuplicateWindow {
            return Self.duplicateBlockedMessage
        }

        return nil
    }

    /// Returns a user-facing error string, or `nil` if a conversation report submit may proceed.
    static func checkConversationReportSubmit(reporterId: UUID, conversationId: UUID, now: Date = Date()) -> String? {
        lock.lock()
        defer { lock.unlock() }

        var global = conversationReportGlobalTimes[reporterId] ?? []
        global.removeAll { now.timeIntervalSince($0) > conversationReportGlobalWindow }
        if global.count >= conversationReportGlobalMax {
            return "Too many reports in a short time. Please try again in a few minutes."
        }

        if let last = conversationReportLastAttemptByConversation[conversationId],
           now.timeIntervalSince(last) < conversationReportMinSpacingPerConversation {
            return "Please wait a moment before reporting this conversation again."
        }

        return nil
    }

    /// Record a conversation report attempt after it reached the server (success or duplicate unique violation).
    static func recordConversationReportSubmit(reporterId: UUID, conversationId: UUID, now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }

        var global = conversationReportGlobalTimes[reporterId] ?? []
        global.removeAll { now.timeIntervalSince($0) > conversationReportGlobalWindow }
        global.append(now)
        conversationReportGlobalTimes[reporterId] = global

        conversationReportLastAttemptByConversation[conversationId] = now
    }

    /// Returns a user-facing error string, or `nil` if another support request may be sent this hour.
    static func checkSupportRequestSubmit(userId: UUID, now: Date = Date()) -> String? {
        lock.lock()
        defer { lock.unlock() }

        var times = supportRequestSuccessTimes[userId] ?? []
        times.removeAll { now.timeIntervalSince($0) > supportRequestWindow }
        if times.count >= supportRequestMaxPerWindow {
            return "You’ve reached the limit for support messages. Please try again in about an hour."
        }
        return nil
    }

    /// Call only after a support email is successfully sent.
    static func recordSupportRequestSubmit(userId: UUID, now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }

        var times = supportRequestSuccessTimes[userId] ?? []
        times.removeAll { now.timeIntervalSince($0) > supportRequestWindow }
        times.append(now)
        supportRequestSuccessTimes[userId] = times
    }

    /// Call only after a comment row is successfully inserted.
    static func recordVenueEventCommentSend(venueEventId: UUID, body: String, now: Date = Date()) {
        let fingerprint = sendFingerprint(for: body)
        lock.lock()
        defer { lock.unlock() }

        var s = commentByEvent[venueEventId] ?? CommentSendState(
            lastSendAt: nil,
            sendTimes: [],
            lastFingerprint: nil,
            lastFingerprintAt: nil
        )
        pruneCommentSendTimes(&s.sendTimes, now: now)
        s.sendTimes.append(now)
        s.lastSendAt = now
        s.lastFingerprint = fingerprint
        s.lastFingerprintAt = now
        commentByEvent[venueEventId] = s
    }

    // MARK: - Helpers

    static func fanUpdateHasMinimumContentQuality(_ body: String) -> Bool {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let meaningfulCharacters = trimmed.filter { !$0.isWhitespace && !$0.isNewline }
        guard meaningfulCharacters.count >= venueEventCommentMinimumMeaningfulCharacters else { return false }

        let normalized = ModerationService.normalizeModerationText(String(meaningfulCharacters))
        if !normalized.isEmpty {
            let alphanumericScalars = normalized.unicodeScalars.filter {
                CharacterSet.alphanumerics.contains($0)
            }
            let uniqueAlphanumericScalars = Set(alphanumericScalars)
            if alphanumericScalars.count <= 2 { return false }
            if uniqueAlphanumericScalars.count == 1 { return false }
            return true
        }

        return Set(meaningfulCharacters).count > 1
    }

    private static func sendFingerprint(for body: String) -> String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = ModerationService.normalizeModerationText(trimmed)
        if normalized.isEmpty {
            return trimmed.lowercased()
        }
        return normalized
    }

    private static func pruneChatSendTimes(_ times: inout [Date], now: Date) {
        times.removeAll { now.timeIntervalSince($0) > chatWindow5m }
    }

    private static func pruneCommentSendTimes(_ times: inout [Date], now: Date) {
        times.removeAll { now.timeIntervalSince($0) > commentWindow2m }
    }
}
