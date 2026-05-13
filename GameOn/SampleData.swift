import Foundation
import CoreLocation

struct SampleData {

    static let includeSampleData = false

    static func makeDate(year: Int, month: Int, day: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day)) ?? Date()
    }
    
    static let sports = [
        "All",
        "Soccer",
        "NBA",
        "NFL",
        "Baseball",
        "NHL",
        "Tennis",
        "Golf",
        "Volleyball",
        "Ping Pong",
        "UFC",
        "Formula 1",
        "Cricket",
        "Rugby",
        "Softball",
        "Cycling"
    ]
    
    static let events: [SportsEvent] = [
        SportsEvent(title: "France vs Argentina", sport: "Soccer", league: "International Friendly", date: makeDate(year: 2026, month: 6, day: 25), time: "7:30 PM", country: "USA"),
        SportsEvent(title: "Real Madrid vs Barcelona", sport: "Soccer", league: "La Liga", date: makeDate(year: 2026, month: 6, day: 25), time: "1:00 PM", country: "USA"),
        SportsEvent(title: "Arsenal vs Chelsea", sport: "Soccer", league: "Premier League", date: makeDate(year: 2026, month: 6, day: 25), time: "3:30 PM", country: "USA"),
        SportsEvent(title: "Dodgers vs Giants", sport: "Baseball", league: "MLB", date: makeDate(year: 2026, month: 6, day: 25), time: "6:10 PM", country: "USA"),
        SportsEvent(title: "USA Softball vs Canada", sport: "Softball", league: "International Softball", date: makeDate(year: 2026, month: 6, day: 25), time: "5:00 PM", country: "USA"),
        SportsEvent(title: "Wimbledon Quarterfinal", sport: "Tennis", league: "Wimbledon", date: makeDate(year: 2026, month: 6, day: 25), time: "9:00 AM", country: "USA"),
        SportsEvent(title: "India vs Australia", sport: "Cricket", league: "T20 International", date: makeDate(year: 2026, month: 6, day: 25), time: "10:30 AM", country: "USA"),
        
        SportsEvent(title: "Utah Jazz vs Lakers", sport: "NBA", league: "NBA", date: makeDate(year: 2026, month: 6, day: 26), time: "7:00 PM", country: "USA"),
        SportsEvent(title: "Yankees vs Red Sox", sport: "Baseball", league: "MLB", date: makeDate(year: 2026, month: 6, day: 26), time: "5:05 PM", country: "USA"),
        SportsEvent(title: "Sinner vs Alcaraz", sport: "Tennis", league: "ATP Tour", date: makeDate(year: 2026, month: 6, day: 26), time: "12:00 PM", country: "USA"),
        SportsEvent(title: "England vs South Africa", sport: "Cricket", league: "ODI", date: makeDate(year: 2026, month: 6, day: 26), time: "11:00 AM", country: "USA"),
        
        SportsEvent(title: "Chiefs vs Broncos", sport: "NFL", league: "NFL", date: makeDate(year: 2026, month: 6, day: 27), time: "6:20 PM", country: "USA"),
        SportsEvent(title: "UFC Fight Night", sport: "UFC", league: "UFC", date: makeDate(year: 2026, month: 6, day: 27), time: "8:00 PM", country: "USA"),
        SportsEvent(title: "Mets vs Braves", sport: "Baseball", league: "MLB", date: makeDate(year: 2026, month: 6, day: 27), time: "7:15 PM", country: "USA"),
        SportsEvent(title: "Pakistan vs New Zealand", sport: "Cricket", league: "T20 International", date: makeDate(year: 2026, month: 6, day: 27), time: "10:00 AM", country: "USA"),
        
        SportsEvent(title: "Champions League Final", sport: "Soccer", league: "Champions League", date: makeDate(year: 2026, month: 6, day: 28), time: "2:00 PM", country: "USA"),
        SportsEvent(title: "Cubs vs Cardinals", sport: "Baseball", league: "MLB", date: makeDate(year: 2026, month: 6, day: 28), time: "6:40 PM", country: "USA"),
        SportsEvent(title: "Djokovic vs Medvedev", sport: "Tennis", league: "ATP Tour", date: makeDate(year: 2026, month: 6, day: 28), time: "11:30 AM", country: "USA"),
        SportsEvent(title: "RCB vs MI", sport: "Cricket", league: "IPL", date: makeDate(year: 2026, month: 6, day: 28), time: "8:00 AM", country: "USA")
    ]
    
    static let bars: [BarVenue] = [
        BarVenue(
            name: "Legends Sports Pub",
            address: "677 S 200 W, Salt Lake City, UT",
            phone: "8015551111",
            primarySport: "Soccer",
            distance: "21 mi",
            rating: 4.6,
            tags: ["Sound On", "Big Screens", "Soccer Crowd"],
            games: ["France vs Argentina", "Real Madrid vs Barcelona", "Arsenal vs Chelsea"],
            coordinate: CLLocationCoordinate2D(latitude: 40.7555, longitude: -111.8977),
            goingCounts: ["France vs Argentina": 3400, "Real Madrid vs Barcelona": 850, "Arsenal vs Chelsea": 420]
        ),
        BarVenue(
            name: "Flanker Kitchen + Sporting Club",
            address: "6 N Rio Grande St, Salt Lake City, UT",
            phone: "8015552222",
            primarySport: "NFL",
            distance: "22 mi",
            rating: 4.7,
            tags: ["Premium Venue", "Large Screens", "Game Night"],
            games: ["Chiefs vs Broncos", "Champions League Final", "Dodgers vs Giants"],
            coordinate: CLLocationCoordinate2D(latitude: 40.7682, longitude: -111.9045),
            goingCounts: ["Chiefs vs Broncos": 1200, "Champions League Final": 740, "Dodgers vs Giants": 250]
        ),
        BarVenue(
            name: "Bout Time Pub & Grub",
            address: "5502 W 13400 S, Herriman, UT",
            phone: "8015553333",
            primarySport: "NBA",
            distance: "12 mi",
            rating: 4.3,
            tags: ["Casual", "Food Specials", "Sports Bar"],
            games: ["Utah Jazz vs Lakers", "UFC Fight Night", "Yankees vs Red Sox"],
            coordinate: CLLocationCoordinate2D(latitude: 40.5065, longitude: -112.0173),
            goingCounts: ["Utah Jazz vs Lakers": 560, "UFC Fight Night": 900, "Yankees vs Red Sox": 190]
        ),
        BarVenue(
            name: "The Break Sports Grill",
            address: "11274 Kestrel Rise Rd, South Jordan, UT",
            phone: "8015554444",
            primarySport: "UFC",
            distance: "15 mi",
            rating: 4.5,
            tags: ["Fight Night", "Late Night", "Good Crowd"],
            games: ["UFC Fight Night", "Mets vs Braves"],
            coordinate: CLLocationCoordinate2D(latitude: 40.5488, longitude: -111.9515),
            goingCounts: ["UFC Fight Night": 1300, "Mets vs Braves": 220]
        ),
        BarVenue(
            name: "Center Court Lounge",
            address: "200 S Main St, Salt Lake City, UT",
            phone: "8015557777",
            primarySport: "Tennis",
            distance: "22 mi",
            rating: 4.5,
            tags: ["Tennis Matches", "Quiet Viewing", "Brunch"],
            games: ["Wimbledon Quarterfinal", "Sinner vs Alcaraz", "Djokovic vs Medvedev"],
            coordinate: CLLocationCoordinate2D(latitude: 40.7645, longitude: -111.8910),
            goingCounts: ["Wimbledon Quarterfinal": 310, "Sinner vs Alcaraz": 480, "Djokovic vs Medvedev": 520]
        ),
        BarVenue(
            name: "The Wicket House",
            address: "4700 S 900 E, Salt Lake City, UT",
            phone: "8015558888",
            primarySport: "Cricket",
            distance: "20 mi",
            rating: 4.6,
            tags: ["Cricket Crowd", "International Sports", "Early Matches"],
            games: ["India vs Australia", "England vs South Africa", "Pakistan vs New Zealand", "RCB vs MI"],
            coordinate: CLLocationCoordinate2D(latitude: 40.6688, longitude: -111.8659),
            goingCounts: ["India vs Australia": 760, "England vs South Africa": 400, "Pakistan vs New Zealand": 680, "RCB vs MI": 890]
        )
    ]
    static let venueEvents: [VenueEvent] = [
        VenueEvent(
            venueName: "Legends Sports Pub",
            eventTitle: "France vs Argentina",
            confirmedShowing: true,
            soundOn: true,
            special: "$8 nachos during the game",
            goingCount: 3400
        ),
        VenueEvent(
            venueName: "Legends Sports Pub",
            eventTitle: "Real Madrid vs Barcelona",
            confirmedShowing: true,
            soundOn: true,
            special: "Soccer crowd expected",
            goingCount: 850
        ),
        VenueEvent(
            venueName: "The Break Sports Grill",
            eventTitle: "UFC Fight Night",
            confirmedShowing: true,
            soundOn: true,
            special: "Fight night special",
            goingCount: 1300
        ),
        VenueEvent(
            venueName: "The Break Sports Grill",
            eventTitle: "Mets vs Braves",
            confirmedShowing: true,
            soundOn: false,
            special: nil,
            goingCount: 220
        ),
        VenueEvent(
            venueName: "Bout Time Pub & Grub",
            eventTitle: "Utah Jazz vs Lakers",
            confirmedShowing: true,
            soundOn: true,
            special: "Jazz game drink specials",
            goingCount: 560
        ),
        VenueEvent(
            venueName: "The Wicket House",
            eventTitle: "India vs Australia",
            confirmedShowing: true,
            soundOn: true,
            special: "Cricket watch party",
            goingCount: 760
        )
    ]
    
    static let venueExperiences: [VenueExperience] = [
        VenueExperience(
            venueName: "Legends Sports Pub",
            atmosphere: "High-energy soccer crowd",
            crowdLevel: "Packed for big matches",
            teamFanbases: ["Real Madrid", "Arsenal", "France"],
            hasAudio: true,
            drinkSpecials: "$8 nachos • $5 draft beers",
            availableSeating: "Limited seating during big games",
            coverCharge: "No cover",
            reservationsAvailable: true,
            waitlistAvailable: true,
            socialCoordination: "Great for supporter groups and match meetups",
            liveOccupancy: "Busy"
        ),
        VenueExperience(
            venueName: "The Break Sports Grill",
            atmosphere: "Loud fight-night energy",
            crowdLevel: "Very busy for UFC",
            teamFanbases: ["UFC", "MMA", "Local sports fans"],
            hasAudio: true,
            drinkSpecials: "Fight-night drink specials",
            availableSeating: "Walk-in seating varies",
            coverCharge: "$10 for major fights",
            reservationsAvailable: false,
            waitlistAvailable: true,
            socialCoordination: "Good for groups watching main events",
            liveOccupancy: "Moderate"
        )
    ]
    
    
}
