#if DEBUG
import Foundation
import Supabase

extension MapViewModel {

    private static let calendarDotRPCShadowSQLDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone.current
        return f
    }()

    private struct GameonCalendarDotRPCParams: Encodable {
        let p_date_min: String
        let p_date_max: String
        let p_sport: String
        let p_venue_ids: [UUID]?
        let p_owner_emails: [String]?
        let p_venue_names: [String]?
        let p_region_only: Bool
    }

    private struct GameonCalendarDotRPCRow: Decodable {
        let event_date: String
    }

    /// Phase 3a.2: fire-and-forget RPC shadow compare (DEBUG only); does not touch UI state.
    func scheduleCalendarDotRPCShadowCompareAfterRecompute(
        tokenKey: String,
        tokenGen: UInt64,
        clientDots: Set<Date>,
        sport: String,
        regionOnly: Bool,
        barsCount: Int,
        venueIds: [UUID],
        ownerEmails: [String],
        venueNames: [String]
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performCalendarDotRPCShadowCompareIfCurrent(
                tokenKey: tokenKey,
                tokenGen: tokenGen,
                clientDots: clientDots,
                sport: sport,
                regionOnly: regionOnly,
                barsCount: barsCount,
                venueIds: venueIds,
                ownerEmails: ownerEmails,
                venueNames: venueNames
            )
        }
    }

    private func performCalendarDotRPCShadowCompareIfCurrent(
        tokenKey: String,
        tokenGen: UInt64,
        clientDots: Set<Date>,
        sport: String,
        regionOnly: Bool,
        barsCount: Int,
        venueIds: [UUID],
        ownerEmails: [String],
        venueNames: [String]
    ) async {
        guard lastCalendarDotRecomputeKey == tokenKey, scheduleDataGeneration == tokenGen else { return }

        let bounds = calendarDotRPCShadowScheduleBounds()
        let fmt = Self.calendarDotRPCShadowSQLDateFormatter
        let dateMin = fmt.string(from: bounds.min)
        let dateMax = fmt.string(from: bounds.max)

        let params = GameonCalendarDotRPCParams(
            p_date_min: dateMin,
            p_date_max: dateMax,
            p_sport: sport,
            p_venue_ids: venueIds.isEmpty ? nil : venueIds,
            p_owner_emails: ownerEmails.isEmpty ? nil : ownerEmails,
            p_venue_names: venueNames.isEmpty ? nil : venueNames,
            p_region_only: regionOnly
        )

        let rows: [GameonCalendarDotRPCRow]
        do {
            rows = try await supabase
                .rpc("gameon_calendar_dot_dates", params: params)
                .execute()
                .value
        } catch {
            return
        }

        guard lastCalendarDotRecomputeKey == tokenKey, scheduleDataGeneration == tokenGen else { return }

        let cal = Calendar.current
        var rpcDates: Set<Date> = []
        rpcDates.reserveCapacity(rows.count)
        for row in rows {
            let raw = row.event_date.trimmingCharacters(in: .whitespacesAndNewlines)
            guard raw.count >= 10 else { continue }
            let ymd = String(raw.prefix(10))
            guard let parsed = Self.calendarDotRPCShadowSQLDateFormatter.date(from: ymd) else { continue }
            rpcDates.insert(cal.startOfDay(for: parsed))
        }

        let onlyInClient = clientDots.subtracting(rpcDates)
        let onlyInRPC = rpcDates.subtracting(clientDots)

        let sampleClient = onlyInClient.sorted()
            .prefix(5)
            .map { Self.calendarDotRPCShadowSQLDateFormatter.string(from: $0) }
            .joined(separator: ",")
        let sampleRPC = onlyInRPC.sorted()
            .prefix(5)
            .map { Self.calendarDotRPCShadowSQLDateFormatter.string(from: $0) }
            .joined(separator: ",")

        guard !onlyInClient.isEmpty || !onlyInRPC.isEmpty else { return }

        print(
            "[Phase3Perf] calendar_dot_rpc_shadow clientCount=\(clientDots.count) rpcCount=\(rpcDates.count) " +
                "onlyInClientCount=\(onlyInClient.count) onlyInRPCCount=\(onlyInRPC.count) sport=\(sport) " +
                "regionOnly=\(regionOnly) barsCount=\(barsCount) onlyInClientSample=\(sampleClient) onlyInRPCSample=\(sampleRPC)"
        )

        if !onlyInRPC.isEmpty {
            logPhase3PerfCalendarDotShadowOnlyInRPCDiagnostics(
                onlyInRPCDates: onlyInRPC,
                sport: sport,
                regionOnly: regionOnly,
                venueIds: Set(venueIds),
                ownerEmails: Set(ownerEmails),
                venueNames: Set(venueNames)
            )
        }
        if !onlyInClient.isEmpty {
            print(
                "[Phase3Perf] calendar_dot_rpc_shadow_diag onlyInClient=RPC_missing_dates " +
                    "(client has dot days RPC did not return); check date windows / RLS / timezone."
            )
        }
    }

    /// DEBUG: explain why RPC returned calendar days absent from ``calendarDotDates`` (client uses ``eventsForCalendarDots``).
    private func logPhase3PerfCalendarDotShadowOnlyInRPCDiagnostics(
        onlyInRPCDates: Set<Date>,
        sport: String,
        regionOnly: Bool,
        venueIds: Set<UUID>,
        ownerEmails: Set<String>,
        venueNames: Set<String>
    ) {
        let cal = Calendar.current
        let fmt = Self.calendarDotRPCShadowSQLDateFormatter
        let venueGameTitles = Set(bars.flatMap(\.games))
        let skipSport = sport.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || sport.trimmingCharacters(in: .whitespacesAndNewlines).localizedCaseInsensitiveCompare("All") == .orderedSame

        for day in onlyInRPCDates.sorted().prefix(8) {
            let ymd = fmt.string(from: day)
            let sameDay = events.filter { cal.isDate($0.date, inSameDayAs: day) }
            let sportDay = sameDay.filter { skipSport || $0.sport == sport }
            let official = sportDay.filter { $0.league != "Venue Event" }
            let venueSports = sportDay.filter { $0.league == "Venue Event" }
            let passesTitleGate = venueSports.filter { venueGameTitles.contains($0.title) }
            let wouldAppearInClientDots: [SportsEvent] = sportDay.filter { ev in
                if skipSport == false, ev.sport != sport { return false }
                if !regionOnly { return true }
                return ev.league == "Venue Event" && venueGameTitles.contains(ev.title)
            }

            let veRowsDay = venueEventRows.filter { row in
                guard let ed = row.event_date?.trimmingCharacters(in: .whitespacesAndNewlines), ed.count >= 10 else { return false }
                return String(ed.prefix(10)) == ymd
            }
            var veByLink = "venue_event_rows=\(veRowsDay.count)"
            if !veRowsDay.isEmpty {
                let parts = veRowsDay.prefix(6).map { row -> String in
                    let vid = row.venue_id.map(\.uuidString) ?? "nil"
                    let em = row.owner_email ?? "-"
                    let vn = row.venue_name ?? "-"
                    let ttl = row.event_title ?? "-"
                    let link: String
                    if let id = row.venue_id {
                        link = venueIds.contains(id) ? "venue_id_in_map" : "venue_id_NOT_in_map"
                    } else {
                        let emM = em != "-" && ownerEmails.contains(em)
                        let vnM = vn != "-" && venueNames.contains(vn)
                        link = "legacy_null_vid em_match=\(emM) name_match=\(vnM)"
                    }
                    return "{\(ttl) vid=\(vid) \(link)}"
                }
                veByLink += " [" + parts.joined(separator: "; ") + "]"
            }

            var classification = "unknown"
            if !official.isEmpty && regionOnly {
                classification = "expected_semantics_drift_official_games_included_by_RPC_excluded_from_client_dots_when_regionOnly"
            } else if !official.isEmpty && !regionOnly {
                classification = "investigate_official_games_on_day_client_should_include_unless_sampleData_or_timezone"
            } else if wouldAppearInClientDots.isEmpty, !venueSports.isEmpty, regionOnly {
                classification = "expected_or_data_venue_events_on_day_fail_title_gate_titlesOnBars=\(venueGameTitles.count)"
            } else if wouldAppearInClientDots.isEmpty, veRowsDay.isEmpty, official.isEmpty {
                classification = "likely_RPC_official_or_remote_venue_row_not_in_client_events_array"
            } else if !wouldAppearInClientDots.isEmpty {
                classification = "unexpected_client_dots_logic_should_include_day_recheck_timezone_or_stale_snapshot"
            }

            print(
                "[Phase3Perf] calendar_dot_rpc_shadow_diag date=\(ymd) classification=\(classification) " +
                    "sameDayEvents=\(sameDay.count) sportDay=\(sportDay.count) officialGames=\(official.count) " +
                    "venueSportsEvents=\(venueSports.count) passTitleGateVenue=\(passesTitleGate.count) " +
                    "wouldAppearInClientDots=\(wouldAppearInClientDots.count) \(veByLink)"
            )

            if !official.isEmpty {
                let titles = official.prefix(4).map { "\($0.title)(\($0.league))" }.joined(separator: ", ")
                print("[Phase3Perf] calendar_dot_rpc_shadow_diag date=\(ymd) official_sample=\(titles)")
            }
            if !venueSports.isEmpty {
                let t = venueSports.prefix(6).map { "\($0.title)|inBarGames=\(venueGameTitles.contains($0.title))" }.joined(separator: "; ")
                print("[Phase3Perf] calendar_dot_rpc_shadow_diag date=\(ymd) venue_sport_events_sample=\(t)")
            }
        }
    }
}
#endif
