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
    @Published private(set) var loadError: String?
    @Published var sendError: String?
    /// Subscribe/connect failure; live inserts may be unavailable until reopening the thread.
    @Published var realtimeNotice: String?
    @Published var draft: String = ""
    @Published var menuBanner: String?

    private(set) var currentUserId: UUID?

    private let maxBodyLength = 1000

    init(friend: UserPreview) {
        self.friend = friend
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
        } catch {
            loadError = error.localizedDescription
            messages = []
        }
        isLoadingInitial = false
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

        sendError = nil
        draft = ""

        do {
            let row = try await service.sendMessage(conversationId: conversationId, senderId: me, body: trimmed)
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

        sendError = nil
        do {
            let row = try await service.sendMessage(conversationId: conversationId, senderId: me, body: trimmed)
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

    private enum ChatOverflowPhase: Equatable {
        case hidden
        case actions
        case confirmClearHistory
        case confirmRemoveFriend
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
                Text(banner)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
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

    // Tuned to match Screenshot 2 (pre-recovery target).
    private static let overflowMenuWidth: CGFloat = 244
    private static let overflowMenuHeight: CGFloat = 112
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
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .padding(.top, Self.overflowMenuTopPadding)
            .padding(.trailing, Self.overflowMenuTrailingPadding)
        }
    }

    private func chatOverflowActionsCard() -> some View {
        VStack(alignment: .leading, spacing: 0) {
            overflowMenuActionRow(title: "Clear chat history") {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.9)) {
                    chatOverflowPhase = .confirmClearHistory
                }
            }
            Rectangle()
                .fill(Color.primary.opacity(0.0))
                .frame(height: 0.0)
                .padding(.horizontal, 30)
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

            Button {
                Task { await presenter.sendDraft() }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 30))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Color.white, Color.blue)
            }
            .disabled(!presenter.canSend)
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
