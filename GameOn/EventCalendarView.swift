import SwiftUI

// MARK: - Shared calendar sheet layout (Discover + Calendar tab)

/// Layout constants for date pickers presented while ``MainTabView`` floating tab bar may sit above tab content (`zIndex` 2). Scroll tail padding keeps the month grid and Today/Done tappable after scrolling to the end on SE through Pro Max.
enum EventCalendarSheetLayout {
    /// Matches `MainTabView.floatingTabBarStackHeight` (capsule + margins).
    static let floatingTabChromeOverlapScrollInset: CGFloat = 92
    /// Breathing room above the home indicator / sheet drag indicator when content is scrolled flush to the bottom.
    static let sheetDragAndHomeComfortInset: CGFloat = 20
    /// Small top inset so the title clears the sheet grabber on all phones.
    static let sheetTopContentInset: CGFloat = 6

    /// Total bottom padding **inside** the scroll view so the last row (Today/Done) clears floating chrome + home safe area when scrolled to the end.
    static var scrollContentBottomInset: CGFloat {
        floatingTabChromeOverlapScrollInset + sheetDragAndHomeComfortInset
    }
}

/// Single standard calendar body for every `.sheet` date picker: scrollable on short detents / small phones, consistent background, shared bottom inset for floating tab + home indicator.
struct EventCalendarPickerSheet: View {
    let events: [SportsEvent]
    let bars: [BarVenue]
    let useVisibleMapRegionOnly: Bool
    let eventDotDates: Set<Date>
    let dotsLoading: Bool
    @Binding var selectedDate: Date
    let onDone: () -> Void

    var body: some View {
        ScrollView {
            EventCalendarView(
                events: events,
                bars: bars,
                useVisibleMapRegionOnly: useVisibleMapRegionOnly,
                eventDotDates: eventDotDates,
                dotsLoading: dotsLoading,
                selectedDate: $selectedDate,
                onDone: onDone
            )
            .frame(maxWidth: .infinity)
            .padding(.top, EventCalendarSheetLayout.sheetTopContentInset)
            .padding(.bottom, EventCalendarSheetLayout.scrollContentBottomInset)
        }
        .scrollIndicators(.visible)
        .scrollBounceBehavior(.basedOnSize)
        .background(Color(.systemBackground).ignoresSafeArea())
    }
}

extension View {
    /// Standard Apple-style sheet chrome for ``EventCalendarPickerSheet``: medium + large detents, visible grabber, scroll-friendly interaction with the sheet resize gesture.
    func eventCalendarPickerSheetPresentation(selection: Binding<PresentationDetent>) -> some View {
        presentationDetents([.medium, .large], selection: selection)
            .presentationDragIndicator(.visible)
            .presentationContentInteraction(.scrolls)
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
    @Binding var selectedDate: Date
    let onDone: () -> Void

    init(
        events: [SportsEvent],
        bars: [BarVenue] = [],
        useVisibleMapRegionOnly: Bool = false,
        eventDotDates: Set<Date> = [],
        dotsLoading: Bool = false,
        selectedDate: Binding<Date>,
        onDone: @escaping () -> Void
    ) {
        self.events = events
        self.bars = bars
        self.useVisibleMapRegionOnly = useVisibleMapRegionOnly
        self.eventDotDates = eventDotDates
        self.dotsLoading = dotsLoading
        self._selectedDate = selectedDate
        self.onDone = onDone
    }

    @State private var displayedMonth: Date = SampleData.makeDate(year: 2026, month: 6, day: 1)

    private let columns = Array(repeating: GridItem(.flexible()), count: 7)
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
        VStack(spacing: 11) {
            
            Text("Choose a date")
                .font(.title3)
                .fontWeight(.bold)
            
            HStack {
                Button {
                    changeMonth(by: -1)
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.title3)
                        .fontWeight(.bold)
                }
                
                Spacer()
                
                Text(monthTitle(displayedMonth))
                    .font(.headline)
                    .fontWeight(.bold)
                
                Spacer()
                
                Button {
                    changeMonth(by: 1)
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.title3)
                        .fontWeight(.bold)
                }
            }
            
            HStack {
                ForEach(["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"], id: \.self) { day in
                    Text(day)
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            
            LazyVGrid(columns: columns, spacing: 8) {
                // Index-based IDs: `id: \.self` on `[Date?]` is invalid because every `nil` is the same identity.
                ForEach(0..<calendarDays.count, id: \.self) { index in
                    if let date = calendarDays[index] {
                        Button {
                            selectedDate = date
                        } label: {
                            VStack(spacing: 4) {
                                Text("\(calendar.component(.day, from: date))")
                                    .font(.headline)
                                    .fontWeight(.semibold)
                                
                                if hasEventDot(on: date) {
                                    Circle()
                                        .fill(Color.green)
                                        .frame(width: 7, height: 7)
                                } else if dotsLoading && useVisibleMapRegionOnly {
                                    Circle()
                                        .strokeBorder(Color.green.opacity(0.35), lineWidth: 1.2)
                                        .frame(width: 7, height: 7)
                                } else {
                                    Circle()
                                        .fill(Color.clear)
                                        .frame(width: 7, height: 7)
                                }
                            }
                            .frame(width: 44, height: 48)
                            .foregroundStyle(isSelected(date) ? .white : .primary)
                            .background(isSelected(date) ? Color.black : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                        }
                    } else {
                        Color.clear
                            .frame(width: 44, height: 48)
                    }
                }
            }
            
            HStack(spacing: 10) {
                Button {
                    jumpToTodayAndApply()
                } label: {
                    Text("Today")
                        .font(.subheadline.weight(.semibold))
                        .frame(minWidth: 92, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(isAlreadyTodaySelection)
                .opacity(isAlreadyTodaySelection ? 0.42 : 1)

                Button {
                    onDone()
                } label: {
                    Text("Done")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .tint(.black)
                .controlSize(.large)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .onAppear {
            displayedMonth = startOfMonth(selectedDate)
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
