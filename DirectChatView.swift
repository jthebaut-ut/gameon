import Combine
import Supabase
import SwiftUI

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
}

struct DirectChatView: View {

    @EnvironmentObject private var chatViewModel: ChatViewModel
    @StateObject private var presenter: DirectChatPresenter
    @FocusState private var composerFocused: Bool

    init(friend: UserPreview) {
        _presenter = StateObject(wrappedValue: DirectChatPresenter(friend: friend))
    }

    var body: some View {
        VStack(spacing: 0) {
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

            if let sendErr = presenter.sendError, !sendErr.isEmpty {
                Text(sendErr)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
            }

            if let notice = presenter.realtimeNotice, !notice.isEmpty {
                Text(notice)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)
            }

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
            Task {
                await presenter.flushMarkReadNow()
                await chatViewModel.refreshInboxSummaries()
            }
        }
    }

    private var messagesScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    if presenter.messages.isEmpty {
                        Text("No messages yet.\nSay hi!")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    } else {
                        let entries = DirectChatTimeGrouping.buildTimeline(from: presenter.messages)
                        ForEach(entries) { entry in
                            switch entry {
                            case .daySeparator(_, let label):
                                daySeparatorPill(label)
                                    .padding(.vertical, 6)
                            case .message(let row):
                                messageRow(for: row)
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .onChange(of: presenter.lastMessageId) { _, newId in
                guard let newId else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(newId, anchor: .bottom)
                }
            }
            .onChange(of: presenter.isLoadingInitial) { _, loading in
                if !loading, let id = presenter.lastMessageId {
                    DispatchQueue.main.async {
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo(id, anchor: .bottom)
                        }
                    }
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
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Message", text: $presenter.draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...5)
                .focused($composerFocused)
                .onChange(of: presenter.draft) { _, _ in
                    presenter.trimDraftIfNeeded()
                }

            Button {
                Task { await presenter.sendDraft() }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 32))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Color.white, Color.accentColor)
            }
            .disabled(!presenter.canSend)
            .accessibilityLabel("Send")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }
}
