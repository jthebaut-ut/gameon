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

        switch sport {

        case "Soccer":
            return "soccerball"

        case "NBA":
            return "basketball.fill"

        case "NFL":
            return "football.fill"

        case "NHL":
            return "hockey.puck.fill"

        case "Baseball":
            return "baseball.fill"

        case "Softball":
            return "circle.fill"

        case "Tennis":
            return "tennisball.fill"

        case "Cricket":
            return "cricket.ball.fill"

        case "UFC":
            return "figure.boxing"
            
        case "Golf":
            return "figure.golf"

        default:
            return "sportscourt.fill"
        }
    }
}
