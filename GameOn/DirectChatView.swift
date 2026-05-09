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

    @State private var showOverflowMenu = false
    @State private var overflowAnchorGlobal: CGRect = .zero
    @State private var pendingDestructive: DestructiveOverflowAction?
    @State private var scrollToBottomCoalesceTask: Task<Void, Never>?
    /// Floating tab bar in `MainTabView` is an overlay (not SwiftUI safe area); reserve space so composer clears it when keyboard is down.
    @State private var keyboardCoversBottomChrome = false

    private enum DestructiveOverflowAction {
        case clearHistory
        case removeFriend
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
        .safeAreaInset(edge: .bottom, spacing: 0) {
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
                    withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
                        showOverflowMenu.toggle()
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
        .overlay {
            if showOverflowMenu {
                chatOverflowMenuOverlay
                    .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .topTrailing)))
            }
        }
        .zIndex(showOverflowMenu ? 50 : 0)
        .animation(.spring(response: 0.38, dampingFraction: 0.86), value: showOverflowMenu)
        .confirmationDialog(
            "",
            isPresented: Binding(
                get: { pendingDestructive != nil },
                set: { if !$0 { pendingDestructive = nil } }
            ),
            titleVisibility: .hidden
        ) {
            Group {
                if pendingDestructive == .clearHistory {
                    Button("Clear Chat History", role: .destructive) {
                        Task { await runClearHistoryConfirmed() }
                    }
                    Button("Cancel", role: .cancel) {
                        pendingDestructive = nil
                    }
                } else if pendingDestructive == .removeFriend {
                    Button("Remove Friend", role: .destructive) {
                        Task { await runRemoveFriendConfirmed() }
                    }
                    Button("Cancel", role: .cancel) {
                        pendingDestructive = nil
                    }
                }
            }
        } message: {
            if pendingDestructive == .clearHistory {
                Text("This clears the conversation history for both of you.")
            } else if pendingDestructive == .removeFriend {
                Text("You will unfriend \(presenter.friend.displayName) and leave this chat.")
            }
        }
        .onChange(of: composerFocused) { _, focused in
            if focused {
                dismissOverflowMenu()
            }
        }
        #if canImport(UIKit)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in
            keyboardCoversBottomChrome = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidHideNotification)) { _ in
            keyboardCoversBottomChrome = false
        }
        #endif
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
            showOverflowMenu = false
            Task {
                await presenter.flushMarkReadNow()
                await chatViewModel.refreshInboxSummaries()
            }
        }
    }

    private func dismissOverflowMenu() {
        withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
            showOverflowMenu = false
        }
    }

    private func resignComposerFirstResponder() {
        #if canImport(UIKit)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #endif
    }

    private func runClearHistoryConfirmed() async {
        pendingDestructive = nil
        await presenter.clearChatHistory()
        await chatViewModel.refreshInboxSummaries()
    }

    private func runRemoveFriendConfirmed() async {
        pendingDestructive = nil
        do {
            try await presenter.removeFriend()
            await chatViewModel.refresh()
            dismiss()
        } catch {
            presenter.menuBanner = error.localizedDescription
        }
    }

    private var chatOverflowMenuOverlay: some View {
        GeometryReader { geo in
            let containerGlobal = geo.frame(in: .global)
            ZStack(alignment: .topLeading) {
                ZStack {
                    Rectangle().fill(.ultraThinMaterial)
                    Rectangle().fill(Color.black.opacity(0.18))
                }
                .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        dismissOverflowMenu()
                    }

                let menuWidth: CGFloat = 248
                let anchor = overflowAnchorGlobal
                let topLeftGlobal = CGPoint(x: anchor.maxX - menuWidth, y: anchor.maxY + 6)
                let x = topLeftGlobal.x - containerGlobal.minX
                let y = topLeftGlobal.y - containerGlobal.minY

                VStack(alignment: .leading, spacing: 0) {
                    overflowMenuRow(title: "Clear Chat History", systemImage: "trash", role: .destructive) {
                        dismissOverflowMenu()
                        pendingDestructive = .clearHistory
                    }
                    Divider().padding(.leading, 12)
                    overflowMenuRow(title: "Remove Friend", systemImage: "person.fill.xmark", role: .destructive) {
                        dismissOverflowMenu()
                        pendingDestructive = .removeFriend
                    }
                }
                .frame(width: menuWidth, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color(.secondarySystemGroupedBackground))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.22), radius: 22, y: 10)
                .offset(x: max(12, min(x, geo.size.width - menuWidth - 12)), y: max(geo.safeAreaInsets.top + 4, y))
                .accessibilityElement(children: .contain)
            }
        }
    }

    private func overflowMenuRow(
        title: String,
        systemImage: String,
        role: ButtonRole?,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.body.weight(.semibold))
                    .frame(width: 22, alignment: .center)
                Text(title)
                    .font(.body.weight(.medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(role == .destructive ? Color.red : Color.primary)
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
                .padding(.bottom, 4)
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

    /// Reserves space for `MainTabView`’s floating capsule tab bar (overlay, not part of SwiftUI safe area).
    private static let floatingTabBarReserve: CGFloat = 86

    /// `safeAreaInset` already respects the home indicator; avoid duplicating window safe-area padding (was causing excess bottom gap).
    private var composerOuterBottomPadding: CGFloat {
        if composerFocused || keyboardCoversBottomChrome { return 8 }
        return Self.floatingTabBarReserve
    }

    private var composer: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 0.5)
                .accessibilityHidden(true)

            VStack(spacing: 8) {
                quickReactionTray
                composerInputRow
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, composerOuterBottomPadding)
        }
        .background {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea(edges: .bottom)
        }
    }

    private var composerInputRow: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Message", text: $presenter.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.body)
                .lineLimit(1...5)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(Color(.secondarySystemGroupedBackground))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
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
                .frame(minHeight: 40, alignment: .center)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                Task { await presenter.sendDraft() }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 32))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Color.white, Color.accentColor)
            }
            .disabled(!presenter.canSend)
            .frame(width: 40, height: 40)
            .contentShape(Rectangle())
            .accessibilityLabel("Send")
        }
    }

    private var quickReactionTray: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(DirectChatQuickReactions.emojis, id: \.self) { emoji in
                    Button {
                        Task { await presenter.sendQuickReaction(emoji) }
                    } label: {
                        Text(emoji)
                            .font(.system(size: 22))
                            .frame(minWidth: 36, minHeight: 36)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Send \(emoji) reaction")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground).opacity(0.94))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.05), radius: 6, y: 2)
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
