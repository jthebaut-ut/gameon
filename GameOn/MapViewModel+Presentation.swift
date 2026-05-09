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
        if let url = URL(string: "tel://\(bar.phone)") {
            UIApplication.shared.open(url)
        }
    }

    func displayTime(for event: SportsEvent) -> String {
        "\(event.time) \(selectedTimeZone.abbreviation)"
    }

    func iconForSport(_ sport: String) -> String {
        SportFilterCatalog.resolve(sport).systemImage
    }

    /// Brand-style tint for map pins, game rows, and sport chips (see ``SportFilterCatalog``).
    func colorForSport(_ sport: String) -> Color {
        SportFilterCatalog.resolve(sport).accent
    }
}
