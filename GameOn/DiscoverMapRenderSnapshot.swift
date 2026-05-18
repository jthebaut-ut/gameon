import CoreLocation
import Foundation

struct DiscoverMapRenderSnapshotKey: Equatable {
    let selectedDay: String
    let selectedSport: String
    let mapDisplayMode: DiscoverMapDisplayMode
    let searchText: String
    let visibleLatitudeDeltaBucket: String
    let venueCount: Int
    let eventRowCount: Int
}

struct DiscoverVenuePinRenderItem: Identifiable {
    let id: UUID
    let bar: BarVenue
    let selectedDayGames: [SportsEvent]
    let venueEventIDsByGameTitle: [String: UUID]
    let goingTotalsByGameTitle: [String: Int]
    let liveNowByGameTitle: [String: Bool]
    let goingTotal: Int
    let pinEnergyScore: Int
    let hasLiveNow: Bool
}

struct DiscoverVenueClusterRenderItem: Identifiable {
    let id: String
    let bars: [BarVenue]
    let coordinate: CLLocationCoordinate2D
    let venueIDs: [UUID]
    let count: Int
    let maxEnergyScore: Int
    let dominantSport: String?
    let hasLiveNow: Bool
}

struct DiscoverMapRenderSnapshot {
    let key: DiscoverMapRenderSnapshotKey
    let builtAt: Date
    let venuePinsByID: [UUID: DiscoverVenuePinRenderItem]
    let venueClustersByID: [String: DiscoverVenueClusterRenderItem]

    static let empty = DiscoverMapRenderSnapshot(
        key: DiscoverMapRenderSnapshotKey(
            selectedDay: "",
            selectedSport: "All",
            mapDisplayMode: .allSpots,
            searchText: "",
            visibleLatitudeDeltaBucket: "",
            venueCount: 0,
            eventRowCount: 0
        ),
        builtAt: .distantPast,
        venuePinsByID: [:],
        venueClustersByID: [:]
    )
}

extension MapViewModel {
    func rebuildDiscoverMapRenderSnapshot(reason: String) {
        let buildStart = Date()
        let visibleBars = mapVisibleBars
        let clusters = clusteredBars()
        let key = discoverMapRenderSnapshotKey(venueCount: visibleBars.count)

        var pinItems: [UUID: DiscoverVenuePinRenderItem] = [:]
        pinItems.reserveCapacity(visibleBars.count)

        for bar in visibleBars {
            let gamesToday = selectedDayEventsForMap(bar)
            var eventIDsByTitle: [String: UUID] = [:]
            var goingByTitle: [String: Int] = [:]
            var liveNowByTitle: [String: Bool] = [:]
            var goingTotal = 0
            var hasLiveNow = false

            for game in gamesToday {
                if let eventID = cachedVenueEventID(for: bar, gameTitle: game.title) {
                    eventIDsByTitle[game.title] = eventID
                    let going = interestCountForVenueEvent(eventID)
                    goingByTitle[game.title] = going
                    goingTotal += going
                } else {
                    goingByTitle[game.title] = 0
                }

                let gameIsLive = hasLiveVenueEventNow(for: bar, events: [game])
                liveNowByTitle[game.title] = gameIsLive
                hasLiveNow = hasLiveNow || gameIsLive
            }

            pinItems[bar.id] = DiscoverVenuePinRenderItem(
                id: bar.id,
                bar: bar,
                selectedDayGames: gamesToday,
                venueEventIDsByGameTitle: eventIDsByTitle,
                goingTotalsByGameTitle: goingByTitle,
                liveNowByGameTitle: liveNowByTitle,
                goingTotal: goingTotal,
                pinEnergyScore: goingTotal,
                hasLiveNow: hasLiveNow
            )
        }

        var clusterItems: [String: DiscoverVenueClusterRenderItem] = [:]
        clusterItems.reserveCapacity(clusters.count)

        for cluster in clusters {
            var maxEnergyScore = 0
            var dominantSport: String?
            var clusterHasLiveNow = false

            for bar in cluster.bars {
                guard let pin = pinItems[bar.id] else { continue }
                clusterHasLiveNow = clusterHasLiveNow || pin.hasLiveNow
                for game in pin.selectedDayGames {
                    let gameScore = pin.goingTotalsByGameTitle[game.title] ?? 0
                    if gameScore > maxEnergyScore {
                        maxEnergyScore = gameScore
                        dominantSport = game.sport
                    }
                }
            }

            clusterItems[cluster.id] = DiscoverVenueClusterRenderItem(
                id: cluster.id,
                bars: cluster.bars,
                coordinate: cluster.coordinate,
                venueIDs: cluster.bars.map(\.id),
                count: cluster.count,
                maxEnergyScore: maxEnergyScore,
                dominantSport: dominantSport,
                hasLiveNow: clusterHasLiveNow
            )
        }

        applyDiscoverMapRenderSnapshot(
            DiscoverMapRenderSnapshot(
                key: key,
                builtAt: Date(),
                venuePinsByID: pinItems,
                venueClustersByID: clusterItems
            )
        )

        #if DEBUG
        let buildMs = Int(Date().timeIntervalSince(buildStart) * 1000)
        print("[DiscoverMapSnapshotDebug] rebuild reason=\(reason)")
        print("[DiscoverMapSnapshotDebug] venueCount=\(pinItems.count)")
        print("[DiscoverMapSnapshotDebug] clusterCount=\(clusterItems.count)")
        print("[DiscoverMapSnapshotDebug] buildMs=\(buildMs)")
        #endif
    }

    private func discoverMapRenderSnapshotKey(venueCount: Int) -> DiscoverMapRenderSnapshotKey {
        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "yyyy-MM-dd"
        dayFormatter.timeZone = TimeZone.current

        return DiscoverMapRenderSnapshotKey(
            selectedDay: dayFormatter.string(from: selectedDate),
            selectedSport: selectedSport,
            mapDisplayMode: mapDisplayMode,
            searchText: debouncedDiscoverSearchText,
            visibleLatitudeDeltaBucket: String(format: "%.5f", visibleLatitudeDelta),
            venueCount: venueCount,
            eventRowCount: venueEventRows.count
        )
    }
}
