import Foundation
import EventKit

extension MapViewModel {

    func requestCalendarAccess() async -> Bool {
        do {
            let granted = try await eventStore.requestAccess(to: .event)
            return granted
        } catch {
            print("Calendar permission error:", error)
            return false
        }
    }

    func addGameToCalendar(
        title: String,
        date: Date,
        location: String
    ) async {
        guard syncGoingGamesToAppleCalendar else { return }

        let granted = await requestCalendarAccess()
        guard granted else {
            calendarSyncMessage = "Apple Calendar access is off. Turn it on in Settings ▸ Privacy & Security ▸ Calendars for GameOn whenever you want events added there."
            return
        }

        let startWindow = Calendar.current.startOfDay(for: date)
        let endWindow = Calendar.current.date(byAdding: .day, value: 1, to: startWindow) ?? date

        let predicate = eventStore.predicateForEvents(
            withStart: startWindow,
            end: endWindow,
            calendars: nil
        )

        let existingEvents = eventStore.events(matching: predicate)

        let alreadyExists = existingEvents.contains { event in
            event.title == title &&
            event.location == location
        }

        if alreadyExists {
            calendarSyncMessage = "Already in Apple Calendar"
            print("Calendar event already exists:", title)
            return
        }

        let event = EKEvent(eventStore: eventStore)
        event.title = title
        event.startDate = date
        event.endDate = date.addingTimeInterval(2 * 60 * 60)
        event.location = location
        event.notes = "Added by GameON"
        event.calendar = eventStore.defaultCalendarForNewEvents

        do {
            try eventStore.save(event, span: .thisEvent)
            calendarSyncMessage = "Added to Apple Calendar"
            print("Event added to Apple Calendar:", title)
        } catch {
            calendarSyncMessage = "Could not add to Apple Calendar"
            print("Error saving event:", error)
        }
    }
}
