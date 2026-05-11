import Combine
import Supabase
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Timeline (day grouping + formatting)

private enum DirectChatTimelineEntry: Identifiable, Hashable {
    case daySeparator(dayStart: TimeInterval, label: String)
    case message(DirectMessageRow)

    var id: String {
        switch self {
        case .daySeparator(let dayStart, _):
            return "day-\(dayStart)"
        case .message(let m):
            return m.id.uuidString
        }
    }
}

private enum DirectChatTimeGrouping {
    private static let isoWithFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parseDate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        if let d = isoWithFractional.date(from: raw) { return d }
        return isoPlain.date(from: raw)
    }

    static func dayLabel(for date: Date, calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        let df = DateFormatter()
        df.locale = .autoupdatingCurrent
        df.setLocalizedDateFormatFromTemplate("MMM d yyyy")
        return df.string(from: date)
    }

    /// e.g. 11:05 PM in US locale
    static func shortTime(from date: Date) -> String {
        let df = DateFormatter()
        df.locale = .autoupdatingCurrent
        df.timeStyle = .short
        df.dateStyle = .none
        return df.string(from: date)
    }

    static func shortTimeString(forCreatedAt raw: String?) -> String? {
        guard let date = parseDate(raw) else { return nil }
        return shortTime(from: date)
    }

    static func buildTimeline(from rows: [DirectMessageRow]) -> [DirectChatTimelineEntry] {
        let cal = Calendar.current
        var out: [DirectChatTimelineEntry] = []
        var lastDayStart: TimeInterval?

        for row in rows {
            guard let date = parseDate(row.created_at) else {
                out.append(.message(row))
                continue
            }
            let start = cal.startOfDay(for: date)
            let key = start.timeIntervalSince1970
            if lastDayStart == nil || key != lastDayStart {
                out.append(.daySeparator(dayStart: key, label: dayLabel(for: start)))
                lastDayStart = key
            }
            out.append(.message(row))
        }
        return out
    }
}

// MARK: - Toolbar overflow anchor (global frame for iMessage-style menu placement)

private struct ChatOverflowAnchorKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

@MainActor
private final class DirectChatPresenter: ObservableObject {

    let friend: UserPreview
    private let service = DirectChatService()

    @Published private(set) var messages: [DirectMessageRow] = []
    @Published private(set) var conversationId: UUID?
    @Published private(set) var isLoadingInitial = true
    /// More history may exist before the oldest loaded row (keyset pagination).
    @Published private(set) var hasOlderMessages = false
    @Published private(set) var isLoadingOlderMessages = false
    @Published private(set) var loadError: String?
    @Published var sendError: String?
    /// Subscribe/connect failure; live inserts may be unavailable until reopening the thread.
    @Published var realtimeNotice: String?
    @Published var draft: String = ""
    @Published var menuBanner: String?

    private(set) var currentUserId: UUID?

    private let maxBodyLength = 1000

    /// Set from the view layer so sends can respect bidirectional blocks + refresh social state.
    weak var chatViewModel: ChatViewModel?

    init(friend: UserPreview) {
        self.friend = friend
    }

    func bindChatViewModel(_ vm: ChatViewModel) {
        chatViewModel = vm
    }

    private func isMessagingBlocked() -> Bool {
        guard let chatViewModel else { return false }
        return chatViewModel.isEitherDirectionBlocked(with: friend.id)
    }

    private func validateDMText(_ trimmed: String) -> String? {
        if ModerationService.containsProfanity(trimmed) {
            return ModerationService.profanityRejectionUserMessage()
        }
        return nil
    }

    func onAppear() async {
        sendError = nil
        realtimeNotice = nil
        loadError = nil
        do {
            let me = try await service.currentUserId()
            currentUserId = me

            if conversationId == nil {
                let cid = try await service.startDirectConversation(friendUserId: friend.id)
                conversationId = cid
            }

            guard let conversationId else { return }

            let rows = try await service.fetchLatestMessages(conversationId: conversationId, limit: 50)
            messages = rows
            hasOlderMessages = rows.count >= 50
        } catch {
            loadError = error.localizedDescription
            messages = []
            hasOlderMessages = false
        }
        isLoadingInitial = false
    }

    /// Prepends older pages (keyset on `created_at` + `id`); keeps realtime/new sends unchanged.
    func loadOlderMessages() async {
        guard !isLoadingOlderMessages, hasOlderMessages else { return }
        guard let oldest = messages.first,
              let oldestDate = DirectChatTimeGrouping.parseDate(oldest.created_at),
              let cid = conversationId else {
            hasOlderMessages = false
            return
        }

        isLoadingOlderMessages = true
        defer { isLoadingOlderMessages = false }

        do {
            let page = try await service.fetchOlderMessages(
                conversationId: cid,
                beforeCreatedAt: oldestDate,
                beforeMessageId: oldest.id,
                limit: 50
            )
            if page.isEmpty {
                hasOlderMessages = false
                return
            }
            let existing = Set(messages.map(\.id))
            let mergedPrefix = page.filter { !existing.contains($0.id) }
            if mergedPrefix.isEmpty {
                hasOlderMessages = false
                return
            }
            messages = mergedPrefix + messages
            if page.count < 50 {
                hasOlderMessages = false
            }
        } catch {
            // Non-fatal: user can retry “Load older”.
        }
    }

    /// Upserts read cursor with `Date()` so `last_read_at` is never behind DB `created_at` microsecond precision.
    func flushMarkReadNow() async {
        guard loadError == nil, let cid = conversationId, let me = currentUserId else { return }
        try? await service.markConversationRead(
            conversationId: cid,
            userId: me,
            lastReadAt: Date()
        )
    }

    /// Listens for peer inserts until the view task is cancelled; removes the Realtime channel when exiting.
    func runRealtimeSubscription(chatViewModel: ChatViewModel) async {
        guard loadError == nil, let cid = conversationId, let me = currentUserId else { return }

        let (channel, stream) = service.directMessagesInsertChannel(conversationId: cid)
        let decoder = JSONDecoder()

        do {
            try await channel.subscribeWithError()
            realtimeNotice = nil
            for await insertion in stream {
                try Task.checkCancellation()
                let row: DirectMessageRow
                do {
                    row = try insertion.decodeRecord(as: DirectMessageRow.self, decoder: decoder)
                } catch {
                    continue
                }
                if row.deleted_at != nil { continue }
                if row.is_deleted == true { continue }
                guard !messages.contains(where: { $0.id == row.id }) else { continue }
                messages.append(row)
                if row.sender_id != me {
                    await flushMarkReadNow()
                    await chatViewModel.refreshInboxSummaries()
                }
            }
        } catch is CancellationError {
        } catch {
            realtimeNotice = error.localizedDescription
        }

        await service.removeRealtimeChannel(channel)
    }

    func sendDraft() async {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard trimmed.count <= maxBodyLength else { return }
        guard let conversationId, let me = currentUserId else { return }

        if isMessagingBlocked() {
            sendError = "You can’t message this user."
            return
        }
        if let blocked = validateDMText(trimmed) {
            sendError = blocked
            return
        }

        if let limited = RateLimitService.checkDirectChatSend(conversationId: conversationId, body: trimmed) {
            sendError = limited
            return
        }

        sendError = nil
        draft = ""

        do {
            let row = try await service.sendMessage(conversationId: conversationId, senderId: me, body: trimmed)
            RateLimitService.recordDirectChatSend(conversationId: conversationId, body: trimmed)
            messages.append(row)
        } catch {
            draft = trimmed
            sendError = error.localizedDescription
        }
    }

    /// Sends a single emoji (or short reaction) without using the draft field; same server path as `sendDraft`.
    func sendQuickReaction(_ raw: String) async {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxBodyLength else { return }
        guard let conversationId, let me = currentUserId else { return }

        if isMessagingBlocked() {
            sendError = "You can’t message this user."
            return
        }
        if let blocked = validateDMText(trimmed) {
            sendError = blocked
            return
        }

        if let limited = RateLimitService.checkDirectChatSend(conversationId: conversationId, body: trimmed) {
            sendError = limited
            return
        }

        sendError = nil
        do {
            let row = try await service.sendMessage(conversationId: conversationId, senderId: me, body: trimmed)
            RateLimitService.recordDirectChatSend(conversationId: conversationId, body: trimmed)
            messages.append(row)
        } catch {
            sendError = error.localizedDescription
        }
    }

    func trimDraftIfNeeded() {
        if draft.count > maxBodyLength {
            draft = String(draft.prefix(maxBodyLength))
        }
    }

    var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && draft.trimmingCharacters(in: .whitespacesAndNewlines).count <= maxBodyLength
    }

    var lastMessageId: UUID? {
        messages.last?.id
    }

    /// Clears visible history locally and requests server-side clear when the `clear_direct_conversation` RPC is deployed.
    func clearChatHistory() async {
        menuBanner = nil
        guard let conversationId else {
            menuBanner = "Conversation isn’t ready yet."
            return
        }
        do {
            struct Params: Encodable {
                let p_conversation_id: UUID
            }
            try await supabase
                .rpc("clear_direct_conversation", params: Params(p_conversation_id: conversationId))
                .execute()
            messages = []
            hasOlderMessages = false
        } catch {
            menuBanner = "Couldn’t clear chat on the server. Nothing was removed.\n\(error.localizedDescription)"
        }
    }

    /// Ends friendship + DM thread when `remove_friend_and_clear_conversation` (or `remove_friend`) exists on Supabase.
    func removeFriend() async throws {
        menuBanner = nil
        struct ParamsFriend: Encodable {
            let p_friend_user_id: UUID
        }
        let params = ParamsFriend(p_friend_user_id: friend.id)
        do {
            try await supabase
                .rpc("remove_friend_and_clear_conversation", params: params)
                .execute()
        } catch {
            try await supabase
                .rpc("remove_friend", params: params)
                .execute()
        }
    }
}

private enum DirectChatQuickReactions {
    static let emojis: [String] = ["👍", "😂", "🔥", "⚽️", "🏀", "🏈", "👀", "🙌", "❤️"]
}

struct DirectChatView: View {

    @EnvironmentObject private var chatViewModel: ChatViewModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var presenter: DirectChatPresenter
    @FocusState private var composerFocused: Bool

    @State private var overflowAnchorGlobal: CGRect = .zero
    @State private var scrollToBottomCoalesceTask: Task<Void, Never>?
    /// Custom overlay only (no `confirmationDialog` / `Menu` / `contextMenu`).
    @State private var chatOverflowPhase: ChatOverflowPhase = .hidden
    /// Quick emoji strip above composer; off by default, toggled by smiley (does not use the system emoji keyboard).
    @State private var showEmojiQuickTray = false
    @State private var reportSheet: DirectChatReportSheetKind?
    /// `nil` until the reporter picks a category (required before submit).
    @State private var reportCategory: ModerationReportCategory?
    @State private var reportDetails: String = ""
    @State private var isSubmittingReport = false
    @State private var reportSheetError: String?

    private static let reportSubmittedBannerText = "Report submitted. GameOn administration will review it."
    private static let duplicateConversationReportBannerText =
        "You already reported this conversation. GameOn administration will review it."

    private static func isPositiveReportBanner(_ text: String) -> Bool {
        text == reportSubmittedBannerText || text == duplicateConversationReportBannerText
    }

    private enum ChatOverflowPhase: Equatable {
        case hidden
        case actions
        case confirmClearHistory
        case confirmRemoveFriend
        case confirmBlockUser
    }

    private enum DirectChatReportSheetKind: Identifiable, Equatable {
        case user
        case conversation
        case message(DirectMessageRow)

        var id: String {
            switch self {
            case .user: return "report-user"
            case .conversation: return "report-conversation"
            case .message(let m): return "report-message-\(m.id.uuidString)"
            }
        }

        static func == (lhs: DirectChatReportSheetKind, rhs: DirectChatReportSheetKind) -> Bool {
            switch (lhs, rhs) {
            case (.user, .user): return true
            case (.conversation, .conversation): return true
            case (.message(let a), .message(let b)): return a.id == b.id
            default: return false
            }
        }
    }

    private var messagingBlocked: Bool {
        chatViewModel.isEitherDirectionBlocked(with: presenter.friend.id)
    }

    init(friend: UserPreview) {
        _presenter = StateObject(wrappedValue: DirectChatPresenter(friend: friend))
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if presenter.isLoadingInitial {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let err = presenter.loadError {
                    ContentUnavailableView(
                        "Couldn’t load chat",
                        systemImage: "wifi.exclamationmark",
                        description: Text(err)
                    )
                    .frame(maxHeight: .infinity)
                } else {
                    messagesScroll
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentTransition(.interpolate)
            .animation(.easeInOut(duration: 0.22), value: presenter.isLoadingInitial)
            .animation(.easeInOut(duration: 0.22), value: presenter.loadError)

            if let sendErr = presenter.sendError, !sendErr.isEmpty {
                Text(sendErr)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if let notice = presenter.realtimeNotice, !notice.isEmpty {
                Text(notice)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 4)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if let banner = presenter.menuBanner, !banner.isEmpty {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: Self.isPositiveReportBanner(banner) ? "checkmark.circle.fill" : "info.circle.fill")
                        .font(.body)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(Self.isPositiveReportBanner(banner) ? Color.green : Color.secondary)
                    Text(banner)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                        )
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 6) {
            composer
        }
        .background(Color(.systemGroupedBackground))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 8) {
                    ProfileAvatarView(preview: presenter.friend, size: 32)
                    Text(presenter.friend.displayName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                }
                .accessibilityElement(children: .combine)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    resignComposerFirstResponder()
                    composerFocused = false
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.88)) {
                        if chatOverflowPhase == .hidden {
                            chatOverflowPhase = .actions
                        } else {
                            chatOverflowPhase = .hidden
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.primary)
                        .accessibilityLabel("Chat options")
                }
                .buttonStyle(.plain)
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: ChatOverflowAnchorKey.self,
                            value: geo.frame(in: .global)
                        )
                    }
                )
            }
        }
        .onPreferenceChange(ChatOverflowAnchorKey.self) { rect in
            overflowAnchorGlobal = rect
        }
        .overlay(alignment: .topTrailing) {
            if chatOverflowPhase != .hidden {
                chatOverflowChromeOverlay
                    .transition(.scale(scale: 0.96, anchor: .topTrailing).combined(with: .opacity))
                    .zIndex(10)
            }
        }
        .zIndex(chatOverflowPhase != .hidden ? 50 : 0)
        .animation(.spring(response: 0.42, dampingFraction: 0.88), value: chatOverflowPhase)
        .onChange(of: composerFocused) { _, focused in
            if focused {
                dismissChatOverflow()
            }
        }
        .task {
            presenter.bindChatViewModel(chatViewModel)
            await presenter.onAppear()

            if presenter.loadError == nil {
                await withTaskGroup(of: Void.self) { group in
                    group.addTask {
                        await presenter.runRealtimeSubscription(chatViewModel: chatViewModel)
                    }
                    group.addTask {
                        do {
                            try await Task.sleep(nanoseconds: 350_000_000)
                            await presenter.flushMarkReadNow()
                        } catch is CancellationError {
                            // Leaving the thread cancels this task; `onDisappear` still flushes read state.
                        } catch {}
                        await chatViewModel.refreshInboxSummaries()
                    }
                }
            } else {
                await chatViewModel.refreshInboxSummariesIfNeeded()
            }
        }
        .onAppear {
            chatViewModel.hidesFloatingTabBarForDirectChat = true
        }
        .onDisappear {
            chatViewModel.hidesFloatingTabBarForDirectChat = false
            chatOverflowPhase = .hidden
            Task {
                await presenter.flushMarkReadNow()
                await chatViewModel.refreshInboxSummaries()
            }
        }
        .sheet(item: $reportSheet) { kind in
            directChatReportSheet(kind: kind)
        }
        .onChange(of: reportSheet) { _, newValue in
            if newValue != nil {
                reportCategory = nil
                reportDetails = ""
                reportSheetError = nil
                isSubmittingReport = false
            } else {
                reportSheetError = nil
                isSubmittingReport = false
            }
        }
        .onChange(of: reportCategory) { _, _ in
            if reportSheet != nil {
                reportSheetError = nil
            }
        }
    }

    private func dismissChatOverflow() {
        withAnimation(.spring(response: 0.42, dampingFraction: 0.88)) {
            chatOverflowPhase = .hidden
        }
    }

    private func resignComposerFirstResponder() {
        #if canImport(UIKit)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #endif
    }

    private func runClearHistoryConfirmed() async {
        await presenter.clearChatHistory()
        await chatViewModel.refreshInboxSummaries()
    }

    private func runRemoveFriendConfirmed() async {
        do {
            try await presenter.removeFriend()
            await chatViewModel.refresh()
            dismiss()
        } catch {
            presenter.menuBanner = error.localizedDescription
        }
    }

    private func runBlockUserConfirmed() async {
        let moderation = ModerationService()
        do {
            try await moderation.block(userId: presenter.friend.id)
            // TODO: Optional server RPC to end friendship + archive DM when product policy requires it.
            await chatViewModel.refreshBlockedUsers()
            await chatViewModel.refreshInboxSummaries()
            await chatViewModel.refresh()
            await MainActor.run {
                dismissChatOverflow()
                dismiss()
            }
        } catch {
            await MainActor.run {
                presenter.menuBanner = error.localizedDescription
            }
        }
    }

    @ViewBuilder
    private func directChatReportSheet(kind: DirectChatReportSheetKind) -> some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Category", selection: $reportCategory) {
                        Text("Select category").tag(Optional<ModerationReportCategory>.none)
                        ForEach(ModerationReportCategory.allCases) { c in
                            Text(c.displayTitle).tag(Optional(c))
                        }
                    }
                    .disabled(isSubmittingReport)
                } footer: {
                    if reportCategory == nil {
                        Text("Choose a category to submit this report.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    TextField("Details (optional)", text: $reportDetails, axis: .vertical)
                        .lineLimit(3...6)
                        .disabled(isSubmittingReport)
                } footer: {
                    if case .conversation = kind {
                        Text(
                            "Optional. Up to \(ModerationService.conversationReportDetailsMaxCharacters) characters for conversation reports."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                .onChange(of: reportDetails) { _, newValue in
                    if newValue.count > ModerationService.conversationReportDetailsMaxCharacters {
                        reportDetails = String(newValue.prefix(ModerationService.conversationReportDetailsMaxCharacters))
                    }
                }

                if isSubmittingReport {
                    Section {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Submitting…")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                if let reportSheetError, !reportSheetError.isEmpty {
                    Section {
                        Text(reportSheetError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }
            }
            .navigationTitle(reportNavigationTitle(for: kind))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        reportSheet = nil
                    }
                    .disabled(isSubmittingReport)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSubmittingReport {
                        ProgressView()
                            .padding(.trailing, 4)
                    } else {
                        Button("Submit") {
                            Task { await submitDirectChatReport(kind: kind) }
                        }
                        .disabled(reportCategory == nil)
                    }
                }
            }
            .interactiveDismissDisabled(isSubmittingReport)
        }
    }

    private func reportNavigationTitle(for kind: DirectChatReportSheetKind) -> String {
        switch kind {
        case .user: return "Report User"
        case .conversation: return "Report Conversation"
        case .message: return "Report Message"
        }
    }

    /// Last messages for admin email only (not stored on `conversation_reports`).
    private func buildConversationRecentContextForModerationEmail() -> String? {
        guard let me = chatViewModel.currentUserAuthId else { return nil }
        let maxMessages = 10
        let tail = Array(presenter.messages.suffix(maxMessages))
        guard !tail.isEmpty else { return nil }
        var lines: [String] = []
        for m in tail {
            let label: String
            if m.sender_id == presenter.friend.id {
                label = "\(presenter.friend.displayName) (\(presenter.friend.id.uuidString))"
            } else if m.sender_id == me {
                label = "Reporter (\(me.uuidString))"
            } else {
                label = "User \(m.sender_id.uuidString)"
            }
            let ts = m.created_at ?? "—"
            let singleLine = m.body
                .replacingOccurrences(of: "\r\n", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
            lines.append("[\(ts)] \(label): \(singleLine)")
        }
        return lines.joined(separator: "\n")
    }

    private func submitDirectChatReport(kind: DirectChatReportSheetKind) async {
        guard let category = reportCategory else {
            await MainActor.run {
                reportSheetError = "Please choose a category."
            }
            return
        }

        let moderation = ModerationService()
        let trimmedDetails = reportDetails.trimmingCharacters(in: .whitespacesAndNewlines)
        let detailsOpt = trimmedDetails.isEmpty ? nil : trimmedDetails
        let contextLabel: String = {
            switch kind {
            case .user: return "report_user"
            case .conversation: return "report_conversation"
            case .message: return "report_message"
            }
        }()

        await MainActor.run {
            isSubmittingReport = true
            reportSheetError = nil
        }

        do {
            switch kind {
            case .user:
                try await moderation.reportUser(reportedUserId: presenter.friend.id, category: category, details: detailsOpt)
            case .conversation:
                guard let cid = presenter.conversationId else {
                    await MainActor.run {
                        isSubmittingReport = false
                        reportSheetError = "Conversation isn’t ready yet. Try again in a moment."
                    }
                    return
                }
                guard let reporterId = chatViewModel.currentUserAuthId else {
                    await MainActor.run {
                        isSubmittingReport = false
                        reportSheetError = "Sign in to submit a report."
                    }
                    return
                }
                if let cooldownMessage = RateLimitService.checkConversationReportSubmit(
                    reporterId: reporterId,
                    conversationId: cid
                ) {
                    await MainActor.run {
                        isSubmittingReport = false
                        reportSheetError = cooldownMessage
                    }
                    return
                }

                let recentContext = buildConversationRecentContextForModerationEmail()
#if DEBUG
                let ctxCount = presenter.messages.suffix(10).count
                print("[DMReport] recent context count=\(ctxCount)")
#endif

                try await moderation.reportConversation(
                    conversationId: cid,
                    otherUserId: presenter.friend.id,
                    category: category,
                    details: detailsOpt,
                    recentContextForModerationEmail: recentContext
                )
                RateLimitService.recordConversationReportSubmit(reporterId: reporterId, conversationId: cid)
            case .message(let row):
                try await moderation.reportMessage(
                    messageId: row.id,
                    reportedUserId: row.sender_id,
                    messageTextSnapshot: row.body,
                    category: category,
                    details: detailsOpt,
                    conversationId: presenter.conversationId
                )
            }
            await MainActor.run {
                isSubmittingReport = false
                reportSheet = nil
                presenter.menuBanner = Self.reportSubmittedBannerText
            }
        } catch let convErr as ModerationConversationReportError {
            switch convErr {
            case .duplicateOpenReport:
                if let reporterId = chatViewModel.currentUserAuthId, let cid = presenter.conversationId {
                    RateLimitService.recordConversationReportSubmit(reporterId: reporterId, conversationId: cid)
                }
#if DEBUG
                print(
                    "[DMReport] duplicate conversation report ignored conversation=\(presenter.conversationId?.uuidString ?? "nil")"
                )
#endif
                await MainActor.run {
                    isSubmittingReport = false
                    reportSheet = nil
                    presenter.menuBanner = Self.duplicateConversationReportBannerText
                }
            case .detailsTooLong, .detailsProhibitedContent:
                await MainActor.run {
                    isSubmittingReport = false
                    reportSheetError = convErr.errorDescription ?? "Invalid report details."
                }
            }
        } catch {
            ModerationService.logReportSubmitFailure(error, context: contextLabel)
            let message = ModerationService.userFacingReportSubmitError(error)
            await MainActor.run {
                isSubmittingReport = false
                reportSheetError = message
            }
        }
    }

    // Tuned to match Screenshot 2 (pre-recovery target).
    private static let overflowMenuWidth: CGFloat = 244
    /// Five primary rows (block / report / clear / remove) at ~56pt each.
    private static let overflowMenuHeight: CGFloat = 292
    private static let overflowMenuCornerRadius: CGFloat = 30
    private static let overflowMenuTopPadding: CGFloat = 54
    private static let overflowMenuTrailingPadding: CGFloat = 16
    private static let overflowMenuTextHorizontalPadding: CGFloat = 16
    private static let overflowMenuRowHeight: CGFloat = 56
    private static let overflowMenuFontSize: CGFloat = 20

    /// Adds specular highlights + subtle color refraction to create a "liquid glass" look.
    private func liquidGlassBackground(cornerRadius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return shape
            .fill(.ultraThinMaterial)
            .overlay(
                // Specular highlight (top-left)
                shape.fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.55),
                            Color.white.opacity(0.16),
                            Color.clear,
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .blendMode(.screen)
                .opacity(0.45)
            )
            .overlay(
                // Subtle refraction tints (like Screenshot 2's soft color bloom)
                shape.fill(
                    RadialGradient(
                        colors: [
                            Color(red: 1.0, green: 0.75, blue: 0.82).opacity(0.22),
                            Color.clear,
                        ],
                        center: .topLeading,
                        startRadius: 10,
                        endRadius: 160
                    )
                )
                .blendMode(.screen)
            )
            .overlay(
                shape.fill(
                    RadialGradient(
                        colors: [
                            Color(red: 0.62, green: 0.86, blue: 1.0).opacity(0.18),
                            Color.clear,
                        ],
                        center: .topTrailing,
                        startRadius: 12,
                        endRadius: 180
                    )
                )
                .blendMode(.screen)
            )
            .overlay(
                // Glass edge + slight inner contrast
                shape.strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.35),
                            Color.white.opacity(0.12),
                            Color.black.opacity(0.06),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
            )
    }

    /// Fixed top-trailing placement (no centering, no full-width card). Light dim only; chat stays visible.
    private var chatOverflowChromeOverlay: some View {
        ZStack(alignment: .topTrailing) {
            Rectangle()
                .fill(Color.clear)
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture {
                dismissChatOverflow()
            }

            Group {
                switch chatOverflowPhase {
                case .hidden:
                    EmptyView()
                case .actions:
                    chatOverflowActionsCard()
                case .confirmClearHistory:
                    chatOverflowConfirmCard(
                        title: "Clear chat history?",
                        message: "This clears the conversation history for both of you.",
                        confirmTitle: "Clear chat history",
                        onConfirm: {
                            Task {
                                await runClearHistoryConfirmed()
                                await MainActor.run { dismissChatOverflow() }
                            }
                        }
                    )
                case .confirmRemoveFriend:
                    chatOverflowConfirmCard(
                        title: "Remove friend?",
                        message: "You will unfriend \(presenter.friend.displayName) and leave this chat.",
                        confirmTitle: "Remove friend",
                        onConfirm: {
                            Task {
                                await runRemoveFriendConfirmed()
                                await MainActor.run { dismissChatOverflow() }
                            }
                        }
                    )
                case .confirmBlockUser:
                    chatOverflowConfirmCard(
                        title: "Block \(presenter.friend.displayName)?",
                        message: "They won’t be able to message you or send friend requests. You won’t see each other in chat lists while the block is active.",
                        confirmTitle: "Block",
                        onConfirm: {
                            Task {
                                await runBlockUserConfirmed()
                            }
                        }
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .padding(.top, Self.overflowMenuTopPadding)
            .padding(.trailing, Self.overflowMenuTrailingPadding)
        }
    }

    private func chatOverflowActionsCard() -> some View {
        VStack(alignment: .leading, spacing: 0) {
            overflowMenuActionRow(title: "Block user") {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.9)) {
                    chatOverflowPhase = .confirmBlockUser
                }
            }
            overflowMenuActionRow(title: "Report user") {
                dismissChatOverflow()
                reportSheet = .user
            }
            overflowMenuActionRow(title: "Report conversation") {
                dismissChatOverflow()
                reportSheet = .conversation
            }
            overflowMenuActionRow(title: "Clear chat history") {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.9)) {
                    chatOverflowPhase = .confirmClearHistory
                }
            }
            overflowMenuActionRow(title: "Remove friend") {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.9)) {
                    chatOverflowPhase = .confirmRemoveFriend
                }
            }
        }
        .padding(.vertical, 0)
        .frame(width: Self.overflowMenuWidth, height: Self.overflowMenuHeight, alignment: .top)
        .background {
            liquidGlassBackground(cornerRadius: Self.overflowMenuCornerRadius)
        }
        .shadow(color: Color.black.opacity(0.06), radius: 12, x: 0, y: 8)
        .accessibilityElement(children: .contain)
    }

    private func chatOverflowConfirmCard(
        title: String,
        message: String,
        confirmTitle: String,
        onConfirm: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(.primary)
            Text(message)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                Button("Cancel") {
                    dismissChatOverflow()
                }
                .buttonStyle(.plain)
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(.secondary)

                Spacer(minLength: 0)

                Button(confirmTitle, action: onConfirm)
                    .buttonStyle(.plain)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Color.red)
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(width: Self.overflowMenuWidth, alignment: .leading)
        .background {
            liquidGlassBackground(cornerRadius: Self.overflowMenuCornerRadius)
        }
        .shadow(color: Color.black.opacity(0.06), radius: 12, x: 0, y: 8)
    }

    private func overflowMenuActionRow(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: Self.overflowMenuFontSize, weight: .regular))
                .foregroundStyle(Color.red.opacity(0.9))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, alignment: .center)
                .frame(height: Self.overflowMenuRowHeight)
                .padding(.horizontal, Self.overflowMenuTextHorizontalPadding)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var messagesScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    if presenter.messages.isEmpty {
                        Text("No messages yet.\nSay hi!")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                            .padding(.bottom, 6)
                    } else {
                        if presenter.hasOlderMessages || presenter.isLoadingOlderMessages {
                            HStack(spacing: 10) {
                                if presenter.isLoadingOlderMessages {
                                    ProgressView()
                                        .scaleEffect(0.85)
                                }
                                if presenter.hasOlderMessages {
                                    Button {
                                        Task { await presenter.loadOlderMessages() }
                                    } label: {
                                        Text("Load older messages")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(presenter.isLoadingOlderMessages)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.bottom, 4)
                        }
                        let entries = DirectChatTimeGrouping.buildTimeline(from: presenter.messages)
                        ForEach(entries) { entry in
                            switch entry {
                            case .daySeparator(_, let label):
                                daySeparatorPill(label)
                                    .padding(.vertical, 8)
                            case .message(let row):
                                messageRow(for: row)
                            }
                        }
                        Color.clear
                            .frame(height: 2)
                            .accessibilityHidden(true)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 20)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .onAppear {
                scrollChatToBottomAfterLayout(proxy: proxy, nanoseconds: 100_000_000)
            }
            .onChange(of: presenter.lastMessageId) { oldId, newId in
                guard newId != nil, newId != oldId else { return }
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 16_000_000)
                    scrollChatToBottom(proxy: proxy)
                }
            }
            .onChange(of: presenter.isLoadingInitial) { _, loading in
                guard !loading else { return }
                scrollChatToBottomAfterLayout(proxy: proxy, nanoseconds: 140_000_000)
            }
            .directChatOnKeyboardDidShow {
                scrollChatToBottomAfterLayout(proxy: proxy, nanoseconds: 90_000_000)
            }
            .onChange(of: composerFocused) { _, focused in
                if focused {
                    scrollChatToBottomAfterLayout(proxy: proxy, nanoseconds: 100_000_000)
                }
            }
        }
    }

    private func daySeparatorPill(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(Color(.systemGray5).opacity(0.55))
            )
            .frame(maxWidth: .infinity)
    }

    private func messageRow(for row: DirectMessageRow) -> some View {
        let isMine = row.sender_id == presenter.currentUserId
        let time = DirectChatTimeGrouping.shortTimeString(forCreatedAt: row.created_at)
        return DirectMessageBubbleView(
            text: row.body,
            isFromCurrentUser: isMine,
            showFriendAvatar: !isMine,
            friendPreview: presenter.friend,
            timestamp: time
        )
        .contextMenu {
            if !isMine {
                Button("Report message") {
                    reportSheet = .message(row)
                }
            }
        }
        .id(row.id)
    }

    private func scrollChatToBottom(proxy: ScrollViewProxy, animated: Bool = true) {
        guard let id = presenter.lastMessageId else { return }
        if animated {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.88)) {
                proxy.scrollTo(id, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(id, anchor: .bottom)
        }
    }

    /// Coalesces open / keyboard / focus-driven scroll requests so overlapping layout passes produce one smooth scroll.
    private func scrollChatToBottomAfterLayout(proxy: ScrollViewProxy, nanoseconds: UInt64 = 120_000_000) {
        guard presenter.lastMessageId != nil else { return }
        scrollToBottomCoalesceTask?.cancel()
        scrollToBottomCoalesceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            scrollChatToBottom(proxy: proxy)
        }
    }

    /// Bottom input: optional slim emoji strip above composer; moves with keyboard via `safeAreaInset`.
    private var composer: some View {
        VStack(spacing: showEmojiQuickTray ? 4 : 0) {
            if messagingBlocked {
                Text("You can’t send messages in this conversation.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 2)
                    .padding(.bottom, 2)
            }
            if showEmojiQuickTray {
                quickReactionTray
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            composerInputRow
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .animation(.spring(response: 0.34, dampingFraction: 0.92), value: showEmojiQuickTray)
        .background {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea(edges: .bottom)
        }
    }

    private var composerInputRow: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Button {
                showEmojiQuickTray.toggle()
            } label: {
                Image(systemName: "face.smiling")
                    .font(.system(size: 22, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(showEmojiQuickTray ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .frame(width: 40, height: 40)
            .accessibilityLabel("Toggle emoji reactions")
            .disabled(messagingBlocked)

            TextField("Message", text: $presenter.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.body)
                .lineLimit(1...5)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color(.secondarySystemGroupedBackground))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(
                            composerFocused
                                ? Color.accentColor.opacity(0.38)
                                : Color.primary.opacity(0.07),
                            lineWidth: composerFocused ? 1.5 : 1
                        )
                        .animation(.easeInOut(duration: 0.2), value: composerFocused)
                )
                .focused($composerFocused)
                .onChange(of: presenter.draft) { _, _ in
                    presenter.trimDraftIfNeeded()
                }
                .frame(minHeight: 38, alignment: .center)
                .frame(maxWidth: .infinity, alignment: .leading)
                .disabled(messagingBlocked)

            Button {
                Task { await presenter.sendDraft() }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 30))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Color.white, Color.blue)
            }
            .disabled(!presenter.canSend || messagingBlocked)
            .frame(width: 40, height: 40)
            .contentShape(Rectangle())
            .accessibilityLabel("Send")
        }
    }

    /// Slim horizontal strip (~40–46 pt tall); no per-emoji cards; tray hidden unless `showEmojiQuickTray`.
    private var quickReactionTray: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 9) {
                ForEach(DirectChatQuickReactions.emojis, id: \.self) { emoji in
                    Button {
                        Task { await presenter.sendQuickReaction(emoji) }
                    } label: {
                        Text(emoji)
                            .font(.system(size: 23))
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(messagingBlocked)
                    .accessibilityLabel("Send \(emoji) reaction")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
        .frame(height: 42)
        .scrollBounceBehavior(.basedOnSize)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(.systemGray6).opacity(0.28))
        }
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
        )
    }
}

#if canImport(UIKit)
private extension View {
    /// Fires after the keyboard animation has finished (`didShow`), avoiding `willChangeFrame` thrash.
    func directChatOnKeyboardDidShow(_ action: @escaping () -> Void) -> some View {
        onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in
            action()
        }
    }
}
#else
private extension View {
    func directChatOnKeyboardDidShow(_ action: @escaping () -> Void) -> some View {
        self
    }
}
#endif
