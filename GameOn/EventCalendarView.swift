import SwiftUI
import UIKit

// MARK: - Shared calendar sheet layout (Discover + Calendar tab)

/// Visual chrome for ``LiquidGlassCalendarPicker`` / ``EventCalendarView``. Discover map uses FanGeo liquid glass; Calendar tab keeps semantic adaptive surfaces.
enum LiquidGlassCalendarChrome: Equatable {
    case discoverMap
    case calendarTab
}

/// Layout constants for date pickers presented while ``MainTabView`` floating tab bar may sit above tab content (`zIndex` 2). Scroll tail padding keeps the month grid and Today/Done tappable after scrolling to the end on SE through Pro Max.
enum EventCalendarSheetLayout {
    /// Matches `MainTabView.floatingTabBarStackHeight` (capsule + margins).
    static let floatingTabChromeOverlapScrollInset: CGFloat = 92
    /// Breathing room above the home indicator / sheet drag indicator when content is scrolled flush to the bottom.
    static let sheetDragAndHomeComfortInset: CGFloat = 20
    /// Small top inset so the title clears the sheet grabber on all phones.
    static let sheetTopContentInset: CGFloat = 8
    /// Corner radius for the floating calendar card (Discover overlay + Calendar tab sheet).
    static let calendarCardCornerRadius: CGFloat = 32

    /// Total bottom padding **inside** the scroll view so the last row (Today/Done) clears floating chrome + home safe area when scrolled to the end.
    static var scrollContentBottomInset: CGFloat {
        floatingTabChromeOverlapScrollInset + sheetDragAndHomeComfortInset
    }
}

// MARK: - Semantic calendar chrome (Discover overlay + Calendar tab sheet)

/// Solid adaptive surfaces only — avoids stacked `Material` + white veils that read as a washed-out sheet in Dark Mode.
private struct EventCalendarCardBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let r = EventCalendarSheetLayout.calendarCardCornerRadius
        RoundedRectangle(cornerRadius: r, style: .continuous)
            .fill(Color(.secondarySystemBackground))
            .overlay {
                RoundedRectangle(cornerRadius: r, style: .continuous)
                    .strokeBorder(Color(.separator), lineWidth: 1)
            }
            .shadow(
                color: Color.black.opacity(colorScheme == .dark ? 0.55 : 0.10),
                radius: colorScheme == .dark ? 24 : 12,
                x: 0,
                y: colorScheme == .dark ? 14 : 8
            )
    }
}

/// Single material layer + light specular wash + FG stroke (Discover overlay only).
private struct DiscoverLiquidGlassCalendarCardBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let r = EventCalendarSheetLayout.calendarCardCornerRadius
        RoundedRectangle(cornerRadius: r, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay {
                RoundedRectangle(cornerRadius: r, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(colorScheme == .dark ? 0.07 : 0.18),
                                Color.clear,
                            ],
                            startPoint: .topLeading,
                            endPoint: .center
                        )
                    )
            }
            .overlay {
                RoundedRectangle(cornerRadius: r, style: .continuous)
                    .strokeBorder(FGColor.divider(colorScheme), lineWidth: 1)
            }
            .shadow(
                color: Color.black.opacity(colorScheme == .dark ? 0.42 : 0.11),
                radius: colorScheme == .dark ? 26 : 14,
                x: 0,
                y: colorScheme == .dark ? 14 : 9
            )
    }
}

private struct EventCalendarMonthNavButton: View {
    let systemName: String
    let accessibilityLabel: String
    let chrome: LiquidGlassCalendarChrome
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.body.weight(.semibold))
                .foregroundStyle(chrome == .discoverMap ? FGColor.accentBlue : Color.accentColor)
                .frame(width: 42, height: 42)
                .background {
                    ZStack {
                        if chrome == .discoverMap {
                            Capsule(style: .continuous)
                                .fill(.ultraThinMaterial)
                            Capsule(style: .continuous)
                                .strokeBorder(FGColor.divider(colorScheme), lineWidth: 1)
                        } else {
                            Circle()
                                .fill(Color(.tertiarySystemBackground))
                            Circle()
                                .strokeBorder(Color(.separator), lineWidth: 1)
                        }
                    }
                }
        }
        .buttonStyle(CalendarChromeMonthNavButtonStyle(chrome: chrome))
        .accessibilityLabel(accessibilityLabel)
    }
}

private struct CalendarChromeMonthNavButtonStyle: ButtonStyle {
    let chrome: LiquidGlassCalendarChrome

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(chrome == .discoverMap && configuration.isPressed ? 0.94 : 1)
            .opacity(chrome == .discoverMap && configuration.isPressed ? 0.88 : 1)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

private struct EventCalendarTodayCapsuleBackground: View {
    let chrome: LiquidGlassCalendarChrome
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            if chrome == .discoverMap {
                Capsule(style: .continuous)
                    .fill(.ultraThinMaterial)
                Capsule(style: .continuous)
                    .strokeBorder(FGColor.divider(colorScheme), lineWidth: 1)
            } else {
                Capsule(style: .continuous)
                    .fill(Color(.tertiarySystemBackground))
                Capsule(style: .continuous)
                    .strokeBorder(Color(.separator), lineWidth: 1)
            }
        }
    }
}

private struct EventCalendarDoneCapsuleBackground: View {
    let chrome: LiquidGlassCalendarChrome
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            if chrome == .discoverMap {
                Capsule(style: .continuous)
                    .fill(FGColor.brandGradient)
                Capsule(style: .continuous)
                    .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.22 : 0.35), lineWidth: 1)
            } else {
                Capsule(style: .continuous)
                    .fill(Color.primary)
                Capsule(style: .continuous)
                    .strokeBorder(Color(.separator).opacity(0.35), lineWidth: 1)
            }
        }
    }
}

private struct CalendarChromeDayCellButtonStyle: ButtonStyle {
    let chrome: LiquidGlassCalendarChrome

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(chrome == .discoverMap && configuration.isPressed ? 0.96 : 1)
            .opacity(chrome == .discoverMap && configuration.isPressed ? 0.9 : 1)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

private struct CalendarChromeFooterButtonStyle: ButtonStyle {
    let chrome: LiquidGlassCalendarChrome

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(chrome == .discoverMap && configuration.isPressed ? 0.98 : 1)
            .opacity(chrome == .discoverMap && configuration.isPressed ? 0.92 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

private struct CalendarTabSheetDimmingBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Color.black.opacity(colorScheme == .dark ? 0.58 : 0.22)
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
    /// When set (Discover map picker), days before this start-of-day are non-selectable and prior months are floored.
    let minimumSelectableDay: Date?
    let chrome: LiquidGlassCalendarChrome
    /// When non-nil (Discover map), day dots use venue green vs pickup blue and never fall back to scanning ``events``.
    let calendarDotPalette: DiscoverCalendarDotPalette?
    let onDone: () -> Void
    let onDisplayedMonthChange: ((Date) -> Void)?

    init(
        events: [SportsEvent],
        bars: [BarVenue],
        useVisibleMapRegionOnly: Bool,
        eventDotDates: Set<Date>,
        dotsLoading: Bool,
        dotStatusText: String?,
        selectedDate: Binding<Date>,
        minimumSelectableDay: Date? = nil,
        chrome: LiquidGlassCalendarChrome = .calendarTab,
        calendarDotPalette: DiscoverCalendarDotPalette? = nil,
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
        self.minimumSelectableDay = minimumSelectableDay
        self.chrome = chrome
        self.calendarDotPalette = calendarDotPalette
        self.onDone = onDone
        self.onDisplayedMonthChange = onDisplayedMonthChange
    }

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
                    minimumSelectableDay: minimumSelectableDay,
                    chrome: chrome,
                    calendarDotPalette: calendarDotPalette,
                    onDone: onDone,
                    onDisplayedMonthChange: onDisplayedMonthChange
                )
                .padding(.horizontal, 22)
                .padding(.vertical, 20)
                .background {
                    switch chrome {
                    case .calendarTab:
                        EventCalendarCardBackground()
                    case .discoverMap:
                        DiscoverLiquidGlassCalendarCardBackground()
                    }
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
    /// Dimmed scrim behind the floating card (adaptive opacity; no stacked materials).
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
                    CalendarTabSheetDimmingBackdrop()
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
    /// When non-nil (Discover map), day dots use venue green vs pickup blue and never fall back to scanning ``events``.
    let calendarDotPalette: DiscoverCalendarDotPalette?
    /// When non-nil (Discover map), days before this instant (compared as start-of-day) cannot be selected and earlier months are blocked.
    let minimumSelectableDay: Date?
    let chrome: LiquidGlassCalendarChrome
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
        minimumSelectableDay: Date? = nil,
        chrome: LiquidGlassCalendarChrome = .calendarTab,
        calendarDotPalette: DiscoverCalendarDotPalette? = nil,
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
        self.minimumSelectableDay = minimumSelectableDay
        self.chrome = chrome
        self.calendarDotPalette = calendarDotPalette
        self.onDone = onDone
        self.onDisplayedMonthChange = onDisplayedMonthChange
    }

    @Environment(\.colorScheme) private var colorScheme

    @State private var displayedMonth: Date = SampleData.makeDate(year: 2026, month: 6, day: 1)

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)
    private let calendar = Calendar.current

    private var eventDotFillColor: Color {
        switch calendarDotPalette {
        case .some(.pickupGames):
            return FGColor.accentBlue
        case .some(.venueGames), .none:
            return Color(UIColor.systemGreen)
        }
    }

    private var calendarToday: Date {
        calendar.startOfDay(for: Date())
    }

    private var selectionFloorStart: Date {
        if let minimumSelectableDay {
            return calendar.startOfDay(for: minimumSelectableDay)
        }
        return Date.distantPast
    }

    private func isBeforeSelectableMinimum(_ date: Date) -> Bool {
        guard minimumSelectableDay != nil else { return false }
        return calendar.startOfDay(for: date) < selectionFloorStart
    }

    private var canGoToPreviousMonth: Bool {
        guard minimumSelectableDay != nil else { return true }
        guard let prevMonth = calendar.date(byAdding: .month, value: -1, to: displayedMonth) else { return false }
        return startOfMonth(prevMonth) >= startOfMonth(selectionFloorStart)
    }

    /// True when the grid is already showing the current month and today is the selected day.
    private var isAlreadyTodaySelection: Bool {
        calendar.isDate(selectedDate, inSameDayAs: calendarToday)
            && calendar.isDate(displayedMonth, equalTo: calendarToday, toGranularity: .month)
    }

    private static let debugBlockedDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone.current
        return f
    }()

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
                EventCalendarMonthNavButton(
                    systemName: "chevron.left",
                    accessibilityLabel: "Previous month",
                    chrome: chrome
                ) {
                    changeMonth(by: -1)
                }
                .opacity(canGoToPreviousMonth ? 1 : 0.38)
                .disabled(!canGoToPreviousMonth)

                Spacer(minLength: 8)

                Text(monthTitle(displayedMonth))
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.85)
                    .lineLimit(1)

                Spacer(minLength: 8)

                EventCalendarMonthNavButton(
                    systemName: "chevron.right",
                    accessibilityLabel: "Next month",
                    chrome: chrome
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
                        let beforeMin = isBeforeSelectableMinimum(date)
                        let isTodayCell = calendar.isDate(date, inSameDayAs: calendarToday)
                        Button {
                            if beforeMin {
                                #if DEBUG
                                print("[DiscoverCalendar] past date blocked date=\(Self.debugBlockedDateFormatter.string(from: date))")
                                #endif
                                return
                            }
                            selectedDate = date
                        } label: {
                            VStack(spacing: 4) {
                                Text("\(calendar.component(.day, from: date))")
                                    .font(.headline.weight(.semibold))

                                if hasEventDot(on: date) {
                                    Circle()
                                        .fill(eventDotFillColor)
                                        .frame(width: 7, height: 7)
                                } else if dotsLoading && (useVisibleMapRegionOnly || calendarDotPalette != nil) {
                                    Circle()
                                        .strokeBorder(eventDotFillColor.opacity(0.55), lineWidth: 1.2)
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
                            .foregroundStyle(dayCellForeground(beforeMin: beforeMin, date: date))
                            .background {
                                dayCellBackground(beforeMin: beforeMin, date: date)
                            }
                            .overlay {
                                if chrome == .discoverMap, isTodayCell, !isSelected(date), !beforeMin {
                                    Capsule(style: .continuous)
                                        .strokeBorder(FGColor.accentBlue.opacity(colorScheme == .dark ? 0.5 : 0.42), lineWidth: 1.5)
                                }
                            }
                            .opacity(beforeMin ? 0.48 : 1)
                        }
                        .buttonStyle(CalendarChromeDayCellButtonStyle(chrome: chrome))
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
                .buttonStyle(CalendarChromeFooterButtonStyle(chrome: chrome))
                .background {
                    EventCalendarTodayCapsuleBackground(chrome: chrome)
                }
                .foregroundStyle(.primary)
                .disabled(isAlreadyTodaySelection)
                .opacity(isAlreadyTodaySelection ? 0.42 : 1)
                .accessibilityLabel("Jump to today")

                Button {
                    if let minDay = minimumSelectableDay {
                        let sod = calendar.startOfDay(for: selectedDate)
                        let minSod = calendar.startOfDay(for: minDay)
                        if sod < minSod {
                            selectedDate = minSod
                            #if DEBUG
                            print("[DiscoverCalendar] selected date clamped to today")
                            #endif
                        }
                    }
                    onDone()
                } label: {
                    Text("Done")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(chrome == .discoverMap ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color(.systemBackground)))
                        .frame(maxWidth: .infinity, minHeight: 46)
                }
                .buttonStyle(CalendarChromeFooterButtonStyle(chrome: chrome))
                .background {
                    EventCalendarDoneCapsuleBackground(chrome: chrome)
                }
                .accessibilityLabel("Done")
            }
            .padding(.top, 6)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
        .background(Color.clear)
        .onAppear {
            let monthFromSelection = startOfMonth(selectedDate)
            if minimumSelectableDay != nil {
                displayedMonth = max(monthFromSelection, startOfMonth(selectionFloorStart))
            } else {
                displayedMonth = monthFromSelection
            }
            onDisplayedMonthChange?(displayedMonth)
        }
        .onChange(of: displayedMonth) { _, month in
            onDisplayedMonthChange?(month)
        }
        .onChange(of: selectedDate) { _, newDate in
            guard minimumSelectableDay != nil else { return }
            let minMonth = startOfMonth(selectionFloorStart)
            if startOfMonth(newDate) < minMonth {
                displayedMonth = minMonth
            }
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
        if calendarDotPalette != nil {
            return eventDotDates.contains(sod)
        }
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

    private func dayCellForeground(beforeMin: Bool, date: Date) -> AnyShapeStyle {
        if beforeMin { return AnyShapeStyle(.secondary) }
        if isSelected(date) {
            if chrome == .discoverMap {
                return AnyShapeStyle(Color.white)
            }
            return AnyShapeStyle(Color(.systemBackground))
        }
        return AnyShapeStyle(.primary)
    }

    @ViewBuilder
    private func dayCellBackground(beforeMin: Bool, date: Date) -> some View {
        if isSelected(date), !beforeMin {
            if chrome == .discoverMap {
                ZStack {
                    Capsule(style: .continuous)
                        .fill(FGColor.brandGradient)
                    Capsule(style: .continuous)
                        .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.2 : 0.32), lineWidth: 1)
                }
                .shadow(color: FGColor.accentBlue.opacity(0.28), radius: 10, y: 3)
            } else {
                Capsule(style: .continuous)
                    .fill(Color.primary)
            }
        }
    }

    private func monthTitle(_ date: Date) -> String {
        date.formatted(.dateTime.month(.wide).year())
    }

    private func startOfMonth(_ date: Date) -> Date {
        calendar.date(from: calendar.dateComponents([.year, .month], from: date)) ?? date
    }

    private func changeMonth(by value: Int) {
        guard value != 0 else { return }
        if value < 0, !canGoToPreviousMonth { return }
        let next = calendar.date(byAdding: .month, value: value, to: displayedMonth) ?? displayedMonth
        if minimumSelectableDay != nil {
            let minMonthStart = startOfMonth(selectionFloorStart)
            let nextMonthStart = startOfMonth(next)
            displayedMonth = max(nextMonthStart, minMonthStart)
        } else {
            displayedMonth = next
        }
    }
}
