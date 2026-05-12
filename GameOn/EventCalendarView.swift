import SwiftUI

// MARK: - Shared calendar sheet layout (Discover + Calendar tab)

/// Layout constants for date pickers presented while ``MainTabView`` floating tab bar may sit above tab content (`zIndex` 2). Scroll tail padding keeps the month grid and Today/Done tappable after scrolling to the end on SE through Pro Max.
enum EventCalendarSheetLayout {
    /// Matches `MainTabView.floatingTabBarStackHeight` (capsule + margins).
    static let floatingTabChromeOverlapScrollInset: CGFloat = 92
    /// Breathing room above the home indicator / sheet drag indicator when content is scrolled flush to the bottom.
    static let sheetDragAndHomeComfortInset: CGFloat = 20
    /// Small top inset so the title clears the sheet grabber on all phones.
    static let sheetTopContentInset: CGFloat = 8

    /// Total bottom padding **inside** the scroll view so the last row (Today/Done) clears floating chrome + home safe area when scrolled to the end.
    static var scrollContentBottomInset: CGFloat {
        floatingTabChromeOverlapScrollInset + sheetDragAndHomeComfortInset
    }
}

// MARK: - Liquid Glass chrome (shared Discover overlay + Calendar tab sheet)

private enum EventCalendarLiquidGlass {
    static let cardCornerRadius: CGFloat = 32

    /// One shared frosted card: map/tab colors read through; white veils capped at **0.10** (never solid `Color.white` fills).
    @ViewBuilder
    static func calendarGlassCard() -> some View {
        let r = cardCornerRadius
        ZStack {
            RoundedRectangle(cornerRadius: r, style: .continuous)
                .fill(.ultraThinMaterial)

            RoundedRectangle(cornerRadius: r, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.10),
                            Color.white.opacity(0.03)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            RoundedRectangle(cornerRadius: r, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.45, green: 0.78, blue: 0.95).opacity(0.05),
                            Color(red: 0.25, green: 0.62, blue: 0.48).opacity(0.035)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .blendMode(.plusLighter)

            RoundedRectangle(cornerRadius: r, style: .continuous)
                .stroke(Color.white.opacity(0.22), lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.18), radius: 16, x: 0, y: 10)
        .shadow(color: Color.black.opacity(0.06), radius: 4, x: 0, y: 2)
    }

    static func monthNavButton(systemName: String, accessibilityLabel: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.10),
                                Color.white.opacity(0.03)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.45, green: 0.78, blue: 0.95).opacity(0.05),
                                Color(red: 0.28, green: 0.68, blue: 0.52).opacity(0.03)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .blendMode(.plusLighter)
                Circle()
                    .stroke(Color.white.opacity(0.22), lineWidth: 1)

                Image(systemName: systemName)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.blue)
            }
            .frame(width: 42, height: 42)
            .shadow(color: Color.black.opacity(0.08), radius: 6, x: 0, y: 3)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    static func todayGlassCapsule() -> some View {
        ZStack {
            Capsule(style: .continuous)
                .fill(.ultraThinMaterial)
            Capsule(style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.10),
                            Color.white.opacity(0.03)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Capsule(style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.42, green: 0.76, blue: 0.92).opacity(0.045),
                            Color(red: 0.28, green: 0.65, blue: 0.50).opacity(0.03)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .blendMode(.plusLighter)
            Capsule(style: .continuous)
                .stroke(Color.white.opacity(0.22), lineWidth: 1)
        }
    }

    @ViewBuilder
    static func doneGlassCapsule() -> some View {
        ZStack {
            Capsule(style: .continuous)
                .fill(Color.black.opacity(0.32))

            Capsule(style: .continuous)
                .fill(.ultraThinMaterial)
                .opacity(0.38)
                .blendMode(.overlay)

            Capsule(style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.10),
                            Color.white.opacity(0.04),
                            Color.clear
                        ],
                        startPoint: .topLeading,
                        endPoint: .center
                    )
                )
                .blendMode(.plusLighter)

            Capsule(style: .continuous)
                .stroke(Color.white.opacity(0.22), lineWidth: 1)
        }
    }
}

/// Shared Liquid Glass calendar used from Discover (in-tab overlay) and Calendar tab (sheet). Day grid + dots live in ``EventCalendarView``.
struct LiquidGlassCalendarPicker: View {
    let events: [SportsEvent]
    let bars: [BarVenue]
    let useVisibleMapRegionOnly: Bool
    let eventDotDates: Set<Date>
    let dotsLoading: Bool
    let dotStatusText: String?
    @Binding var selectedDate: Date
    let onDone: () -> Void
    let onDisplayedMonthChange: ((Date) -> Void)?

    var body: some View {
        ZStack(alignment: .top) {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            ScrollView {
                EventCalendarView(
                    events: events,
                    bars: bars,
                    useVisibleMapRegionOnly: useVisibleMapRegionOnly,
                    eventDotDates: eventDotDates,
                    dotsLoading: dotsLoading,
                    dotStatusText: dotStatusText,
                    selectedDate: $selectedDate,
                    onDone: onDone,
                    onDisplayedMonthChange: onDisplayedMonthChange
                )
                .padding(.horizontal, 22)
                .padding(.vertical, 20)
                .background {
                    EventCalendarLiquidGlass.calendarGlassCard()
                }
                .padding(.horizontal, 14)
                .padding(.top, EventCalendarSheetLayout.sheetTopContentInset)
                .padding(.bottom, EventCalendarSheetLayout.scrollContentBottomInset)
            }
            .scrollIndicators(.visible)
            .scrollBounceBehavior(.basedOnSize)
            .scrollContentBackground(.hidden)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
    }
}

/// Backdrop for ``LiquidGlassCalendarPicker`` when presented as a **sheet** (Calendar tab).
enum LiquidGlassCalendarSheetBackdrop {
    /// Full transparency — use with Discover overlay (no system sheet).
    case transparent
    /// Light frosted scrim behind the floating card (not solid white).
    case frostedDim
}

extension View {
    /// Detents + drag indicator + presentation background for sheet-hosted ``LiquidGlassCalendarPicker``.
    @ViewBuilder
    func liquidGlassCalendarSheetPresentation(
        selection: Binding<PresentationDetent>,
        backdrop: LiquidGlassCalendarSheetBackdrop
    ) -> some View {
        switch backdrop {
        case .transparent:
            self.presentationDetents([.medium, .large], selection: selection)
                .presentationDragIndicator(.visible)
                .presentationContentInteraction(.scrolls)
                .presentationCornerRadius(40)
                .presentationBackground(.clear)
        case .frostedDim:
            self.presentationDetents([.medium, .large], selection: selection)
                .presentationDragIndicator(.visible)
                .presentationContentInteraction(.scrolls)
                .presentationCornerRadius(40)
                .presentationBackground {
                    ZStack {
                        Rectangle()
                            .fill(.ultraThinMaterial)
                        Rectangle()
                            .fill(Color.black.opacity(0.08))
                    }
                }
        }
    }

    /// Legacy name for ``liquidGlassCalendarSheetPresentation(selection:backdrop:)``.
    @ViewBuilder
    func eventCalendarPickerSheetPresentation(selection: Binding<PresentationDetent>, discoverMapBackdrop: Bool = false) -> some View {
        liquidGlassCalendarSheetPresentation(
            selection: selection,
            backdrop: discoverMapBackdrop ? .transparent : .frostedDim
        )
    }
}

struct EventCalendarView: View {
    let events: [SportsEvent]
    /// Passed from Discover/Calendar for API compatibility; dots are driven by `events` only for now.
    let bars: [BarVenue]
    let useVisibleMapRegionOnly: Bool
    /// Precomputed start-of-day keys for green dots (O(1) per cell). When empty, falls back to scanning `events`.
    let eventDotDates: Set<Date>
    /// Subtle loading hint for region-backed dots only (does not block interaction).
    let dotsLoading: Bool
    let dotStatusText: String?
    @Binding var selectedDate: Date
    let onDone: () -> Void
    let onDisplayedMonthChange: ((Date) -> Void)?

    init(
        events: [SportsEvent],
        bars: [BarVenue] = [],
        useVisibleMapRegionOnly: Bool = false,
        eventDotDates: Set<Date> = [],
        dotsLoading: Bool = false,
        dotStatusText: String? = nil,
        selectedDate: Binding<Date>,
        onDone: @escaping () -> Void,
        onDisplayedMonthChange: ((Date) -> Void)? = nil
    ) {
        self.events = events
        self.bars = bars
        self.useVisibleMapRegionOnly = useVisibleMapRegionOnly
        self.eventDotDates = eventDotDates
        self.dotsLoading = dotsLoading
        self.dotStatusText = dotStatusText
        self._selectedDate = selectedDate
        self.onDone = onDone
        self.onDisplayedMonthChange = onDisplayedMonthChange
    }

    @State private var displayedMonth: Date = SampleData.makeDate(year: 2026, month: 6, day: 1)

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)
    private let calendar = Calendar.current

    private var calendarToday: Date {
        calendar.startOfDay(for: Date())
    }

    /// True when the grid is already showing the current month and today is the selected day.
    private var isAlreadyTodaySelection: Bool {
        calendar.isDate(selectedDate, inSameDayAs: calendarToday)
            && calendar.isDate(displayedMonth, equalTo: calendarToday, toGranularity: .month)
    }

    var body: some View {
        VStack(spacing: 14) {
            VStack(spacing: 6) {
                Text("Choose a date")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.primary)

                if let dotStatusText, !dotStatusText.isEmpty {
                    HStack(spacing: 6) {
                        if dotsLoading {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(dotStatusText)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            HStack(spacing: 10) {
                EventCalendarLiquidGlass.monthNavButton(
                    systemName: "chevron.left",
                    accessibilityLabel: "Previous month"
                ) {
                    changeMonth(by: -1)
                }

                Spacer(minLength: 8)

                Text(monthTitle(displayedMonth))
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.85)
                    .lineLimit(1)

                Spacer(minLength: 8)

                EventCalendarLiquidGlass.monthNavButton(
                    systemName: "chevron.right",
                    accessibilityLabel: "Next month"
                ) {
                    changeMonth(by: 1)
                }
            }

            HStack(spacing: 0) {
                ForEach(["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"], id: \.self) { day in
                    Text(day)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }

            LazyVGrid(columns: columns, spacing: 6) {
                // Index-based IDs: `id: \.self` on `[Date?]` is invalid because every `nil` is the same identity.
                ForEach(0..<calendarDays.count, id: \.self) { index in
                    if let date = calendarDays[index] {
                        Button {
                            selectedDate = date
                        } label: {
                            VStack(spacing: 4) {
                                Text("\(calendar.component(.day, from: date))")
                                    .font(.headline.weight(.semibold))

                                if hasEventDot(on: date) {
                                    Circle()
                                        .fill(Color.green)
                                        .frame(width: 7, height: 7)
                                } else if dotsLoading && useVisibleMapRegionOnly {
                                    Circle()
                                        .strokeBorder(Color.green.opacity(0.45), lineWidth: 1.2)
                                        .frame(width: 7, height: 7)
                                } else {
                                    Circle()
                                        .fill(Color.clear)
                                        .frame(width: 7, height: 7)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                            .padding(.horizontal, 2)
                            .padding(.vertical, 2)
                            .foregroundStyle(isSelected(date) ? Color.white : Color.primary)
                            .background {
                                if isSelected(date) {
                                    Capsule()
                                        .fill(Color.black)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    } else {
                        Color.clear
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                    }
                }
            }

            HStack(alignment: .center, spacing: 12) {
                Button {
                    jumpToTodayAndApply()
                } label: {
                    Text("Today")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 20)
                        .frame(minHeight: 46)
                }
                .buttonStyle(.plain)
                .background {
                    EventCalendarLiquidGlass.todayGlassCapsule()
                }
                .foregroundStyle(.primary)
                .shadow(color: Color.black.opacity(0.10), radius: 10, x: 0, y: 5)
                .disabled(isAlreadyTodaySelection)
                .opacity(isAlreadyTodaySelection ? 0.42 : 1)
                .accessibilityLabel("Jump to today")

                Button {
                    onDone()
                } label: {
                    Text("Done")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 46)
                }
                .buttonStyle(.plain)
                .background {
                    EventCalendarLiquidGlass.doneGlassCapsule()
                }
                .shadow(color: Color.black.opacity(0.28), radius: 14, x: 0, y: 8)
                .accessibilityLabel("Done")
            }
            .padding(.top, 6)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
        .background(Color.clear)
        .onAppear {
            displayedMonth = startOfMonth(selectedDate)
            onDisplayedMonthChange?(displayedMonth)
        }
        .onChange(of: displayedMonth) { _, month in
            onDisplayedMonthChange?(month)
        }
    }

    private func jumpToTodayAndApply() {
        let today = calendarToday
        withAnimation(.spring(response: 0.38, dampingFraction: 0.88)) {
            displayedMonth = startOfMonth(today)
            selectedDate = today
        }
        onDone()
    }

    private var calendarDays: [Date?] {
        guard let range = calendar.range(of: .day, in: .month, for: displayedMonth),
              let firstDay = calendar.date(from: calendar.dateComponents([.year, .month], from: displayedMonth)) else {
            return []
        }

        let firstWeekday = calendar.component(.weekday, from: firstDay)
        let leadingEmptyDays = firstWeekday - 1

        var days: [Date?] = Array(repeating: nil, count: leadingEmptyDays)

        for day in range {
            if let date = calendar.date(byAdding: .day, value: day - 1, to: firstDay) {
                days.append(date)
            }
        }

        return days
    }

    private func hasEventDot(on date: Date) -> Bool {
        let sod = calendar.startOfDay(for: date)
        if useVisibleMapRegionOnly {
            return eventDotDates.contains(sod)
        }
        if !eventDotDates.isEmpty {
            return eventDotDates.contains(sod)
        }
        return events.contains {
            calendar.isDate($0.date, inSameDayAs: date)
        }
    }

    private func isSelected(_ date: Date) -> Bool {
        calendar.isDate(date, inSameDayAs: selectedDate)
    }

    private func monthTitle(_ date: Date) -> String {
        date.formatted(.dateTime.month(.wide).year())
    }

    private func startOfMonth(_ date: Date) -> Date {
        calendar.date(from: calendar.dateComponents([.year, .month], from: date)) ?? date
    }

    private func changeMonth(by value: Int) {
        displayedMonth = calendar.date(byAdding: .month, value: value, to: displayedMonth) ?? displayedMonth
    }
}
