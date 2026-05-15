import Foundation
import MapKit
import SwiftUI

extension MapViewModel {
    var mapPinDisplayMode: MapPinDisplayMode {
        if visibleLatitudeDelta > 0.35 {
            return .simple
        } else if visibleLatitudeDelta > 0.08 {
            return .compact
        } else {
            return .detailed
        }
    }

    var loggedInLabel: String {
        if isAdminLoggedIn {
            return "Admin"
        }

        if isVenueOwnerLoggedIn {
            return "Venue"
        }

        if isLoggedIn {
            return "User"
        }

        return ""
    }

    var formattedSelectedDate: String {
        selectedDate.formatted(date: .abbreviated, time: .omitted)
    }

    var formattedCalendarTabSelectedDate: String {
        calendarTabSelectedDate.formatted(date: .abbreviated, time: .omitted)
    }

    /// Calendar tab day dots (today onward only), respecting ``calendarTabGameFilter``.
    func calendarTabEventDotDatesForPicker() -> Set<Date> {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let merged: Set<Date>
        switch calendarTabGameFilter {
        case .all:
            merged = venueGameCalendarDotDates.union(pickupGameCalendarDotDates)
        case .venue:
            merged = venueGameCalendarDotDates
        case .pickup:
            merged = pickupGameCalendarDotDates
        }
        return Set(merged.filter { cal.startOfDay(for: $0) >= today })
    }

    func calendarTabCalendarDotPaletteForFilter() -> DiscoverCalendarDotPalette? {
        switch calendarTabGameFilter {
        case .all:
            return nil
        case .venue:
            return .venueGames
        case .pickup:
            return .pickupGames
        }
    }

    var calendarTabCalendarDotsLoading: Bool {
        switch calendarTabGameFilter {
        case .all:
            return isLoadingVenueCalendarDots || isLoadingPickupCalendarDots
        case .venue:
            return isLoadingVenueCalendarDots
        case .pickup:
            return isLoadingPickupCalendarDots
        }
    }

    func goingCount(for bar: BarVenue) -> Int {
        guard let selectedEvent else { return 0 }
        return bar.goingCounts[selectedEvent.title] ?? 0
    }

    func openDirections(to bar: BarVenue) {
        let mapItem = MKMapItem(placemark: MKPlacemark(coordinate: bar.coordinate))
        mapItem.name = bar.name
        mapItem.openInMaps()
    }

    func callVenue(_ bar: BarVenue) {
        let digits = BusinessPhoneFields.telDigits(fromStored: bar.phone)
        guard !digits.isEmpty, let url = URL(string: "tel://\(digits)") else { return }
        UIApplication.shared.open(url)
    }

    func displayTime(for event: SportsEvent) -> String {
        "\(event.time) \(selectedTimeZone.abbreviation)"
    }

    func iconForSport(_ sport: String) -> String {
        SportFilterCatalog.resolve(sport).systemImage
    }

    /// Emoji from ``SportFilterCatalog`` for pickup pins and compact labels (empty when the catalog uses SF Symbol only).
    func emojiForSport(_ sport: String) -> String {
        SportFilterCatalog.resolve(sport).emoji.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Brand-style tint for map pins, game rows, and sport chips (see ``SportFilterCatalog``).
    func colorForSport(_ sport: String) -> Color {
        SportFilterCatalog.resolve(sport).accent
    }
}
