import SwiftUI

struct EventCalendarView: View {
    let events: [SportsEvent]
    /// Passed from Discover/Calendar for API compatibility; dots are driven by `events` only for now.
    let bars: [BarVenue]
    let useVisibleMapRegionOnly: Bool
    @Binding var selectedDate: Date
    let onDone: () -> Void

    init(
        events: [SportsEvent],
        bars: [BarVenue] = [],
        useVisibleMapRegionOnly: Bool = false,
        selectedDate: Binding<Date>,
        onDone: @escaping () -> Void
    ) {
        self.events = events
        self.bars = bars
        self.useVisibleMapRegionOnly = useVisibleMapRegionOnly
        self._selectedDate = selectedDate
        self.onDone = onDone
    }

    @State private var displayedMonth: Date = SampleData.makeDate(year: 2026, month: 6, day: 1)
    
    private let columns = Array(repeating: GridItem(.flexible()), count: 7)
    private let calendar = Calendar.current
    
    var body: some View {
        VStack(spacing: 18) {
            
            Text("Choose a date")
                .font(.title2)
                .fontWeight(.bold)
            
            HStack {
                Button {
                    changeMonth(by: -1)
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.title2)
                        .fontWeight(.bold)
                }
                
                Spacer()
                
                Text(monthTitle(displayedMonth))
                    .font(.title3)
                    .fontWeight(.bold)
                
                Spacer()
                
                Button {
                    changeMonth(by: 1)
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.title2)
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
            
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(calendarDays, id: \.self) { date in
                    if let date {
                        Button {
                            selectedDate = date
                        } label: {
                            VStack(spacing: 5) {
                                Text("\(calendar.component(.day, from: date))")
                                    .font(.headline)
                                    .fontWeight(.semibold)
                                
                                if hasEvents(on: date) {
                                    Circle()
                                        .fill(Color.green)
                                        .frame(width: 7, height: 7)
                                } else {
                                    Circle()
                                        .fill(Color.clear)
                                        .frame(width: 7, height: 7)
                                }
                            }
                            .frame(width: 44, height: 52)
                            .foregroundStyle(isSelected(date) ? .white : .primary)
                            .background(isSelected(date) ? Color.black : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                        }
                    } else {
                        Color.clear
                            .frame(width: 44, height: 52)
                    }
                }
            }
            
            Button {
                onDone()
            } label: {
                Text("Done")
                    .fontWeight(.bold)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.black)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            }
        }
        .padding()
        .onAppear {
            displayedMonth = startOfMonth(selectedDate)
        }
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
    
    private func hasEvents(on date: Date) -> Bool {
        events.contains {
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
