import SwiftUI
import UIKit

struct EventDateStrip: View {
    let events: [SportsEvent]
    @Binding var selectedDate: Date
    let onDateSelected: () -> Void
    
    private var upcomingDates: [Date] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        
        return (0..<14).compactMap {
            calendar.date(byAdding: .day, value: $0, to: today)
        }
    }
    
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(upcomingDates, id: \.self) { date in
                    Button {
                        selectedDate = date
                        onDateSelected()
                    } label: {
                        VStack(spacing: 6) {
                            Text(dayName(date))
                                .font(.caption2)
                                .fontWeight(.bold)
                            
                            Text(dayNumber(date))
                                .font(.headline)
                                .fontWeight(.bold)
                            
                            if hasEvents(on: date) {
                                Circle()
                                    .fill(Color(UIColor.systemGreen))
                                    .frame(width: 7, height: 7)
                            } else {
                                Circle()
                                    .fill(Color.clear)
                                    .frame(width: 7, height: 7)
                            }
                        }
                        .frame(width: 62, height: 72)
                        .foregroundStyle(isSelected(date) ? Color(.systemBackground) : .primary)
                        .background(isSelected(date) ? Color.primary : Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                    }
                }
            }
        }
    }
    
    private func hasEvents(on date: Date) -> Bool {
        events.contains {
            Calendar.current.isDate($0.date, inSameDayAs: date)
        }
    }
    
    private func isSelected(_ date: Date) -> Bool {
        Calendar.current.isDate(date, inSameDayAs: selectedDate)
    }
    
    private func dayName(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated))
    }
    
    private func dayNumber(_ date: Date) -> String {
        date.formatted(.dateTime.day())
    }
}
