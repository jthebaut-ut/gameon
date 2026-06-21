import Combine
import MapKit
import SwiftUI

struct ProfileHomeCityAutocompleteField: View {
    @Binding var city: String
    @Binding var region: String
    @Binding var country: String
    @Binding var displayText: String

    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var isFocused: Bool
    @StateObject private var controller = ProfileHomeCitySearchController()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("Lehi, Utah", text: $displayText)
                    .textInputAutocapitalization(.words)
                    .disableAutocorrection(true)
                    .focused($isFocused)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .profileHomeCityInputStyle(colorScheme: colorScheme)
                    .onChange(of: displayText) { _, newValue in
                        controller.refresh(query: newValue, isFocused: isFocused)
                    }
                    .onChange(of: isFocused) { _, focused in
                        controller.refresh(query: displayText, isFocused: focused)
                        if !focused {
                            controller.clearSuggestions()
                        }
                    }

                if !displayText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button {
                        clearSelection()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(FGColor.secondaryText(colorScheme).opacity(0.72))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear home city")
                }
            }

            if isFocused, !controller.suggestions.isEmpty {
                VStack(spacing: 0) {
                    ForEach(controller.suggestions) { suggestion in
                        Button {
                            Task { await selectSuggestion(suggestion) }
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(suggestion.title)
                                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                                    .foregroundStyle(FGColor.primaryText(colorScheme))
                                    .lineLimit(1)
                                if !suggestion.subtitle.isEmpty {
                                    Text(suggestion.subtitle)
                                        .font(.system(size: 12, weight: .medium, design: .rounded))
                                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                                        .lineLimit(1)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                        }
                        .buttonStyle(.plain)

                        if suggestion.id != controller.suggestions.last?.id {
                            Divider()
                                .padding(.leading, 12)
                        }
                    }
                }
                .background {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(FGColor.cardBackground(colorScheme).opacity(colorScheme == .dark ? 0.92 : 0.98))
                        .overlay {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(FGColor.divider(colorScheme), lineWidth: 1)
                        }
                }
            }
        }
    }

    private func clearSelection() {
        city = ""
        region = ""
        country = ""
        displayText = ""
        controller.clearSuggestions()
    }

    private func selectSuggestion(_ suggestion: ProfileHomeCitySuggestion) async {
        let request = MKLocalSearch.Request(completion: suggestion.completion)
        let search = MKLocalSearch(request: request)
        do {
            let response = try await search.start()
            guard let item = response.mapItems.first else { return }
            let parsed = ProfileHomeCityIdentity.parse(mapItem: item)
            await MainActor.run {
                city = parsed.city
                region = parsed.region
                country = parsed.country
                displayText = parsed.display
                controller.clearSuggestions()
                isFocused = false
            }
        } catch {
            await MainActor.run {
                displayText = suggestion.displayQuery
                city = suggestion.title
                region = suggestion.subtitle
                country = ""
                controller.clearSuggestions()
                isFocused = false
            }
        }
    }
}

private struct ProfileHomeCitySuggestion: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let displayQuery: String
    let completion: MKLocalSearchCompletion

    init(completion: MKLocalSearchCompletion) {
        self.completion = completion
        title = completion.title.trimmingCharacters(in: .whitespacesAndNewlines)
        subtitle = completion.subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
        displayQuery = subtitle.isEmpty ? title : "\(title), \(subtitle)"
        id = [title, subtitle].joined(separator: "|")
    }
}

@MainActor
private final class ProfileHomeCitySearchController: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published private(set) var suggestions: [ProfileHomeCitySuggestion] = []

    private var completer: MKLocalSearchCompleter!
    private var debounceTask: Task<Void, Never>?
    private var activeQueryKey = ""

    private static let minimumQueryLength = 2
    private static let suggestionLimit = 5
    private static let debounceMilliseconds: UInt64 = 350

    override init() {
        super.init()
        let searchCompleter = MKLocalSearchCompleter()
        searchCompleter.delegate = self
        searchCompleter.resultTypes = [.address]
        completer = searchCompleter
    }

    func refresh(query: String, isFocused: Bool) {
        debounceTask?.cancel()

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = trimmed.lowercased()

        guard isFocused, key.count >= Self.minimumQueryLength else {
            activeQueryKey = ""
            suggestions = []
            return
        }

        activeQueryKey = key
        debounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.debounceMilliseconds * 1_000_000)
            guard let self, !Task.isCancelled else { return }
            guard self.activeQueryKey == key else { return }
            self.completer.queryFragment = trimmed
        }
    }

    func clearSuggestions() {
        debounceTask?.cancel()
        activeQueryKey = ""
        suggestions = []
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let rawResults = Array(completer.results.prefix(5))
        Task { @MainActor [weak self] in
            self?.suggestions = rawResults.map { ProfileHomeCitySuggestion(completion: $0) }
        }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        Task { @MainActor [weak self] in
            self?.suggestions = []
        }
    }
}

private extension View {
    func profileHomeCityInputStyle(colorScheme: ColorScheme) -> some View {
        self
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(FGColor.background(colorScheme).opacity(colorScheme == .dark ? 0.62 : 0.96))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(FGColor.divider(colorScheme), lineWidth: 1)
            }
    }
}
