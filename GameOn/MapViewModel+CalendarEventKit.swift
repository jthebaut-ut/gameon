import Foundation
import EventKit

nonisolated enum FanGeoCalendarEventStore {
    static let eventIdentifierMapKey = "gameon.appleCalendar.eventIdentifiers.v1"
}

struct FanGeoAppleCalendarMutationResult {
    var attempted = false
    var created = false
    var updated = false
    var deleted = false
    var permissionNeeded = false
    var skippedReason: String?
    var error: String?

    var succeeded: Bool {
        created || updated || deleted || (attempted && error == nil && permissionNeeded == false && skippedReason == nil)
    }
}

struct FanGeoAppleCalendarSyncSummary {
    var attempted = 0
    var created = 0
    var updated = 0
    var deleted = 0
    var permissionNeeded = false
    var firstError: String?

    mutating func merge(_ result: FanGeoAppleCalendarMutationResult) {
        if result.attempted { attempted += 1 }
        if result.created { created += 1 }
        if result.updated { updated += 1 }
        if result.deleted { deleted += 1 }
        if result.permissionNeeded { permissionNeeded = true }
        if firstError == nil {
            firstError = result.error
        }
    }

    var userMessage: String {
        if permissionNeeded {
            return "Calendar permission needed"
        }
        if let firstError, !firstError.isEmpty {
            return "Sync failed: \(firstError)"
        }
        return "Calendar synced"
    }
}

extension MapViewModel {

    func requestCalendarAccess() async -> Bool {
        let statusBefore = calendarSyncAuthorizationStatusDescription()
        print("[CalendarSyncDebug] eventStoreAuthStatus=\(statusBefore)")
        switch EKEventStore.authorizationStatus(for: .event) {
        case .authorized, .fullAccess:
            return true
        case .denied, .restricted:
            return false
        case .writeOnly, .notDetermined:
            break
        @unknown default:
            break
        }

        do {
            let granted = try await eventStore.requestFullAccessToEvents()
            print("[CalendarSyncDebug] eventStoreAuthStatus=\(calendarSyncAuthorizationStatusDescription())")
            return granted && calendarSyncHasFullCalendarAccess()
        } catch {
            print("Calendar permission error:", error)
            print("[CalendarSyncDebug] error=\(error.localizedDescription)")
            return false
        }
    }

    private func calendarSyncHasFullCalendarAccess() -> Bool {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .authorized, .fullAccess:
            return true
        default:
            return false
        }
    }

    private func calendarSyncWritableCalendarForNewEvents() -> EKCalendar? {
        if let defaultCalendar = eventStore.defaultCalendarForNewEvents,
           defaultCalendar.allowsContentModifications {
            return defaultCalendar
        }

        return eventStore.calendars(for: .event).first(where: { calendar in
            calendar.allowsContentModifications
        })
    }

    private func calendarSyncLogCalendar(_ calendar: EKCalendar) {
        print("[CalendarSyncDebug] calendarIdentifier=\(calendar.calendarIdentifier)")
        print("[CalendarSyncDebug] calendarTitle=\(calendar.title)")
        print("[CalendarSyncDebug] calendarSource=\(calendar.source.title)")
        print("[CalendarSyncDebug] calendarAllowsContentModifications=\(calendar.allowsContentModifications)")
    }

#if DEBUG
    private func calendarSyncDebugLogEventKitContext(_ context: String) {
        // MapViewModel calendar mutations are @MainActor-isolated; avoid Thread.isMainThread in async paths.
        print("[CalendarSyncDebug] context=\(context) eventKitOnMainActor=true")
    }
#endif

    private func calendarSyncAuthorizationStatusDescription() -> String {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .authorized:
            return "authorized"
        case .fullAccess:
            return "fullAccess"
        case .writeOnly:
            return "writeOnly"
        case .denied:
            return "denied"
        case .restricted:
            return "restricted"
        case .notDetermined:
            return "notDetermined"
        @unknown default:
            return "unknown"
        }
    }

    private func logProGameCalendarSync(
        action: String,
        gameId: String,
        calendarAuthorized: Bool? = nil,
        eventCreated: Bool? = nil,
        eventUpdated: Bool? = nil,
        eventDeleted: Bool? = nil,
        skippedReason: String? = nil,
        fingerprint: String? = nil,
        forceBypassFreshness: Bool
    ) {
        print("[CalendarSyncDebug] type=proGame")
        print("[CalendarSyncDebug] action=\(action)")
        print("[CalendarSyncDebug] gameId=\(gameId)")
        if let calendarAuthorized {
            print("[CalendarSyncDebug] calendarAuthorized=\(calendarAuthorized)")
        }
        if let eventCreated {
            print("[CalendarSyncDebug] eventCreated=\(eventCreated)")
        }
        if let eventUpdated {
            print("[CalendarSyncDebug] eventUpdated=\(eventUpdated)")
        }
        if let eventDeleted {
            print("[CalendarSyncDebug] eventDeleted=\(eventDeleted)")
        }
        if let skippedReason {
            print("[CalendarSyncDebug] skippedReason=\(skippedReason)")
        }
        if let fingerprint {
            print("[CalendarSyncDebug] fingerprint=\(fingerprint)")
        }
        print("[CalendarSyncDebug] forceBypassFreshness=\(forceBypassFreshness)")
    }

    @discardableResult
    func addGameToCalendar(
        title: String,
        date: Date,
        location: String,
        fanGeoIdentifier: String? = nil,
        forceBypassSyncSetting: Bool = false
    ) async -> FanGeoAppleCalendarMutationResult {
        var result = FanGeoAppleCalendarMutationResult()
        let isProGame = calendarSyncEventKind(fanGeoIdentifier: fanGeoIdentifier) == .pro
        let proGameId = fanGeoIdentifier?.replacingOccurrences(of: "pro|", with: "") ?? ""
        guard notificationSettingsStore.isAppleCalendarSyncEnabled(forFanGeoIdentifier: fanGeoIdentifier)
            || forceBypassSyncSetting else {
            if isProGame {
                logProGameCalendarSync(
                    action: "save",
                    gameId: proGameId,
                    skippedReason: "syncDisabled",
                    forceBypassFreshness: true
                )
            }
            result.skippedReason = "Calendar sync is off"
            return result
        }
        let displayTitle = calendarSyncDisplayTitle(
            title: title,
            location: location,
            fanGeoIdentifier: fanGeoIdentifier
        )
        guard date.timeIntervalSince1970.isFinite else {
            let message = "Invalid game start date"
            print("[CalendarSyncDebug] error=\(message)")
            result.error = message
            return result
        }

        let granted = await requestCalendarAccess()
        guard granted else {
            if isProGame {
                logProGameCalendarSync(
                    action: "save",
                    gameId: proGameId,
                    calendarAuthorized: false,
                    skippedReason: calendarSyncAuthorizationStatusDescription(),
                    forceBypassFreshness: true
                )
            }
            calendarSyncMessage = "Apple Calendar access is off. Turn it on in Settings ▸ Privacy & Security ▸ Calendars for FanGeo whenever you want events added there."
            result.permissionNeeded = true
            return result
        }

        guard let calendar = calendarSyncWritableCalendarForNewEvents() else {
            let message = "No writable Apple Calendar"
            print("[CalendarSyncDebug] calendarIdentifier=nil")
            print("[CalendarSyncDebug] error=\(message)")
            calendarSyncMessage = "Could not find a writable Apple Calendar"
            result.error = message
            return result
        }
        calendarSyncLogCalendar(calendar)

        if isProGame {
            logProGameCalendarSync(
                action: "save",
                gameId: proGameId,
                calendarAuthorized: true,
                fingerprint: calendarSyncProGameFingerprint(
                    gameId: proGameId,
                    title: title,
                    date: date,
                    location: location,
                    state: "saved"
                ),
                forceBypassFreshness: true
            )
        }

        result.attempted = true
        print("[CalendarSyncDebug] eventSaveAttempt=true")
        print("[CalendarSyncDebug] eventStoreAuthStatus=\(calendarSyncAuthorizationStatusDescription())")
#if DEBUG
        calendarSyncDebugLogEventKitContext("save")
#endif

        if let existingEvent = calendarSyncExistingEvent(
            title: title,
            date: date,
            location: location,
            fanGeoIdentifier: fanGeoIdentifier
        ) {
            existingEvent.title = displayTitle
            existingEvent.startDate = date
            existingEvent.endDate = date.addingTimeInterval(2 * 60 * 60)
            existingEvent.location = calendarSyncCleanLocation(location)
            existingEvent.notes = calendarSyncNotes(
                title: title,
                date: date,
                location: location,
                fanGeoIdentifier: fanGeoIdentifier
            )
            existingEvent.calendar = calendar
            calendarSyncCleanRestrictedFields(existingEvent)
            calendarSyncApplyAlarmPreference(to: existingEvent, fanGeoIdentifier: fanGeoIdentifier)
            do {
                try eventStore.save(existingEvent, span: .thisEvent)
                calendarSyncStoreEventIdentifier(existingEvent.eventIdentifier, fanGeoIdentifier: fanGeoIdentifier)
                calendarSyncMessage = "Updated in Apple Calendar"
                result.updated = true
                print("[CalendarSyncDebug] eventIdentifier=\(existingEvent.eventIdentifier ?? "nil")")
                print("[CalendarSyncDebug] eventSaved=true")
                if isProGame {
                    logProGameCalendarSync(
                        action: "save",
                        gameId: proGameId,
                        eventUpdated: true,
                        forceBypassFreshness: true
                    )
                }
                print("Event updated in Apple Calendar:", displayTitle)
            } catch {
                calendarSyncMessage = "Could not update Apple Calendar"
                result.error = error.localizedDescription
                print("[CalendarSyncDebug] eventSaved=false")
                print("[CalendarSyncDebug] error=\(error.localizedDescription)")
                if isProGame {
                    logProGameCalendarSync(
                        action: "save",
                        gameId: proGameId,
                        eventUpdated: false,
                        skippedReason: error.localizedDescription,
                        forceBypassFreshness: true
                    )
                }
                print("Error updating event:", error)
            }
            return result
        }

        let event = EKEvent(eventStore: eventStore)
        event.title = displayTitle
        event.startDate = date
        event.endDate = date.addingTimeInterval(2 * 60 * 60)
        event.location = calendarSyncCleanLocation(location)
        event.notes = calendarSyncNotes(
            title: title,
            date: date,
            location: location,
            fanGeoIdentifier: fanGeoIdentifier
        )
        calendarSyncCleanRestrictedFields(event)
        calendarSyncApplyAlarmPreference(to: event, fanGeoIdentifier: fanGeoIdentifier)
        event.calendar = calendar

        do {
            try eventStore.save(event, span: .thisEvent)
            calendarSyncStoreEventIdentifier(event.eventIdentifier, fanGeoIdentifier: fanGeoIdentifier)
            calendarSyncMessage = "Added to Apple Calendar"
            result.created = true
            print("[CalendarSyncDebug] eventIdentifier=\(event.eventIdentifier ?? "nil")")
            print("[CalendarSyncDebug] eventSaved=true")
            if isProGame {
                logProGameCalendarSync(
                    action: "save",
                    gameId: proGameId,
                    eventCreated: true,
                    forceBypassFreshness: true
                )
            }
            print("Event added to Apple Calendar:", displayTitle)
        } catch {
            calendarSyncMessage = "Could not add to Apple Calendar"
            result.error = error.localizedDescription
            print("[CalendarSyncDebug] eventSaved=false")
            print("[CalendarSyncDebug] error=\(error.localizedDescription)")
            if isProGame {
                logProGameCalendarSync(
                    action: "save",
                    gameId: proGameId,
                    eventCreated: false,
                    skippedReason: error.localizedDescription,
                    forceBypassFreshness: true
                )
            }
            print("Error saving event:", error)
        }
        return result
    }

    @discardableResult
    func removeGameFromAppleCalendar(
        fanGeoIdentifier: String,
        forceBypassSyncSetting: Bool = false
    ) async -> FanGeoAppleCalendarMutationResult {
        var result = FanGeoAppleCalendarMutationResult()
        let isProGame = calendarSyncEventKind(fanGeoIdentifier: fanGeoIdentifier) == .pro
        let proGameId = fanGeoIdentifier.replacingOccurrences(of: "pro|", with: "")
        guard !fanGeoIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return result }
        let granted = await requestCalendarAccess()
        guard granted else {
            if isProGame {
                logProGameCalendarSync(
                    action: "remove",
                    gameId: proGameId,
                    calendarAuthorized: false,
                    skippedReason: calendarSyncAuthorizationStatusDescription(),
                    forceBypassFreshness: true
                )
            }
            result.permissionNeeded = true
            return result
        }
        if isProGame {
            logProGameCalendarSync(
                action: "remove",
                gameId: proGameId,
                calendarAuthorized: true,
                fingerprint: "gameId:\(proGameId)|state:removed",
                forceBypassFreshness: true
            )
        }
        guard let event = calendarSyncEventForRemoval(fanGeoIdentifier: fanGeoIdentifier) else {
            result.skippedReason = "Event not found"
            if isProGame {
                logProGameCalendarSync(
                    action: "remove",
                    gameId: proGameId,
                    eventDeleted: false,
                    skippedReason: "eventNotFound",
                    forceBypassFreshness: true
                )
            }
            return result
        }

        result.attempted = true
#if DEBUG
        calendarSyncDebugLogEventKitContext("remove")
#endif
        if let calendar = event.calendar {
            calendarSyncLogCalendar(calendar)
        }
        do {
            try eventStore.remove(event, span: .thisEvent)
            calendarSyncRemoveStoredEventIdentifier(fanGeoIdentifier: fanGeoIdentifier)
            calendarSyncMessage = "Removed from Apple Calendar"
            result.deleted = true
            print("[CalendarSyncDebug] eventIdentifier=\(event.eventIdentifier ?? "nil")")
            print("[CalendarSyncDebug] eventDeleted=true")
            if isProGame {
                logProGameCalendarSync(
                    action: "remove",
                    gameId: proGameId,
                    eventDeleted: true,
                    forceBypassFreshness: true
                )
            }
            print("Event removed from Apple Calendar:", fanGeoIdentifier)
        } catch {
            calendarSyncMessage = "Could not remove Apple Calendar event"
            result.error = error.localizedDescription
            print("[CalendarSyncDebug] eventDeleted=false")
            print("[CalendarSyncDebug] error=\(error.localizedDescription)")
            if isProGame {
                logProGameCalendarSync(
                    action: "remove",
                    gameId: proGameId,
                    eventDeleted: false,
                    skippedReason: error.localizedDescription,
                    forceBypassFreshness: true
                )
            }
            print("Error removing event:", error)
        }
        return result
    }

    func syncVenueGameToAppleCalendarIfNeeded(venueEventID: UUID) async {
        guard notificationSettingsStore.syncGoingGamesToAppleCalendar,
              notificationSettingsStore.syncVenueGamesToAppleCalendar else { return }
        let identifier = "venue|\(venueEventID.uuidString.lowercased())"

        if let item = followingTabGoingItems.first(where: { $0.id == venueEventID }),
           let start = calendarSyncVenueStartDate(for: item.venueEvent) {
            let title = item.venueEvent.event_title?.trimmingCharacters(in: .whitespacesAndNewlines)
            await addGameToCalendar(
                title: title?.isEmpty == false ? title! : "Venue Game",
                date: start,
                location: item.bar.name,
                fanGeoIdentifier: identifier
            )
            return
        }

        guard let row = venueEventRows.first(where: { $0.id == venueEventID }),
              let start = calendarSyncVenueStartDate(for: row) else {
            return
        }

        let title = row.event_title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let location = row.venue_name?.trimmingCharacters(in: .whitespacesAndNewlines)
        await addGameToCalendar(
            title: title?.isEmpty == false ? title! : "Venue Game",
            date: start,
            location: location?.isEmpty == false ? location! : "Venue",
            fanGeoIdentifier: identifier
        )
    }

    @discardableResult
    func syncSavedProGameToAppleCalendar(
        _ game: SavedProGame,
        action: String,
        forceBypassFreshness: Bool,
        forceBypassSyncSetting: Bool = false
    ) async -> FanGeoAppleCalendarMutationResult {
        let identifier = calendarSyncProGameIdentifier(for: game)
        let title = calendarSyncProGameTitle(for: game)
        let fingerprint = calendarSyncProGameFingerprint(
            gameId: game.stableKey,
            title: title,
            date: game.startTime,
            location: game.league,
            state: "saved"
        )
        logProGameCalendarSync(
            action: action,
            gameId: game.stableKey,
            fingerprint: fingerprint,
            forceBypassFreshness: forceBypassFreshness
        )
        return await addGameToCalendar(
            title: title,
            date: game.startTime,
            location: game.league,
            fanGeoIdentifier: identifier,
            forceBypassSyncSetting: forceBypassSyncSetting
        )
    }

    @discardableResult
    func removeSavedProGameFromAppleCalendar(
        identifier: String,
        action: String,
        forceBypassFreshness: Bool,
        forceBypassSyncSetting: Bool = false
    ) async -> FanGeoAppleCalendarMutationResult {
        let fanGeoIdentifier = "pro|\(identifier)"
        logProGameCalendarSync(
            action: action,
            gameId: identifier,
            fingerprint: "gameId:\(identifier)|state:removed",
            forceBypassFreshness: forceBypassFreshness
        )
        return await removeGameFromAppleCalendar(
            fanGeoIdentifier: fanGeoIdentifier,
            forceBypassSyncSetting: forceBypassSyncSetting
        )
    }

    func skipProGamesCalendarReconcileAtStartup(reason: String) {
        print("[CalendarSyncDebug] skippedAtStartup=true")
        print("[CalendarSyncDebug] reason=\(reason)")
    }

    private static let proGamesCalendarSyncFingerprintDefaultsKey = "gameon.appleCalendar.proGamesSyncFingerprint.v1"
    private static let proGamesCalendarLastSyncAtDefaultsKey = "gameon.appleCalendar.lastSuccessfulSyncAt.v1"
    private static let proGamesCalendarSyncFreshnessInterval: TimeInterval = 6 * 60 * 60

    func proGamesCalendarContentFingerprint() -> String {
        savedProGames
            .map { game in
                calendarSyncProGameFingerprint(
                    gameId: game.stableKey,
                    title: calendarSyncProGameTitle(for: game),
                    date: game.startTime,
                    location: game.league,
                    state: "saved"
                )
            }
            .sorted()
            .joined(separator: "|")
    }

    private func shouldSkipFullProGamesCalendarReconcile(forceBypassFreshness: Bool) -> String? {
        guard !forceBypassFreshness else { return nil }
        guard notificationSettingsStore.syncGoingGamesToAppleCalendar else { return "syncDisabled" }
        guard notificationSettingsStore.syncSavedProGamesToAppleCalendar else { return "proCategoryDisabled" }
        let fingerprint = proGamesCalendarContentFingerprint()
        let storedFingerprint = UserDefaults.standard.string(forKey: Self.proGamesCalendarSyncFingerprintDefaultsKey)
        let lastSyncRaw = UserDefaults.standard.double(forKey: Self.proGamesCalendarLastSyncAtDefaultsKey)
        guard lastSyncRaw > 0,
              let storedFingerprint,
              storedFingerprint == fingerprint else {
            return nil
        }
        let age = Date().timeIntervalSince(Date(timeIntervalSince1970: lastSyncRaw))
        guard age < Self.proGamesCalendarSyncFreshnessInterval else { return nil }
        return "freshFingerprintUnchanged"
    }

    private func recordProGamesCalendarFullSyncCompleted() {
        UserDefaults.standard.set(
            proGamesCalendarContentFingerprint(),
            forKey: Self.proGamesCalendarSyncFingerprintDefaultsKey
        )
        UserDefaults.standard.set(
            Date().timeIntervalSince1970,
            forKey: Self.proGamesCalendarLastSyncAtDefaultsKey
        )
    }

    func scheduleDeferredProGamesAppleCalendarReconcileAfterAppReady(
        reason: String = "appReady",
        replaceExisting: Bool = false
    ) {
        guard notificationSettingsStore.syncGoingGamesToAppleCalendar,
              notificationSettingsStore.syncSavedProGamesToAppleCalendar else {
            print("[CalendarSyncDebug] reason=syncDisabled")
            return
        }
        if deferredProGamesCalendarReconcileTask != nil, !replaceExisting {
            print("[CalendarSyncDebug] reason=deferredAlreadyScheduled")
            return
        }
        deferredProGamesCalendarReconcileTask?.cancel()
        let delaySeconds = Double.random(in: 30...60)
        print("[CalendarSyncDebug] deferredAfterAppReady=true")
        print("[CalendarSyncDebug] reason=\(reason)")
        print("[CalendarSyncDebug] delaySeconds=\(String(format: "%.1f", delaySeconds))")
        deferredProGamesCalendarReconcileTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self.deferredProGamesCalendarReconcileTask = nil
            await self.reconcileSavedProGamesAppleCalendar(
                reason: "deferredAfterAppReady:\(reason)",
                forceBypassFreshness: false
            )
        }
    }

    func reconcileSavedProGamesAppleCalendar(reason: String, forceBypassFreshness: Bool) async {
        _ = await reconcileSavedProGamesAppleCalendarDetailed(
            reason: reason,
            forceBypassFreshness: forceBypassFreshness,
            forceBypassSyncSetting: false
        )
    }

    func appleCalendarAccessEnabledForSettings() -> Bool {
        calendarSyncHasFullCalendarAccess()
    }

    func appleCalendarAuthorizationStatusForSettings() -> String {
        calendarSyncAuthorizationStatusDescription()
    }

    func syncAppleCalendarFromSettings() async -> String {
        print("[CalendarSyncDebug] settingsSyncButtonTapped=true")
        print("[CalendarSyncDebug] eventStoreAuthStatus=\(calendarSyncAuthorizationStatusDescription())")
        print("[CalendarSyncDebug] proGameCount=\(savedProGames.count)")
        guard notificationSettingsStore.syncGoingGamesToAppleCalendar else {
            let message = "Calendar sync is off"
            calendarSyncMessage = message
            print("[CalendarSyncDebug] syncResult=\(message)")
            return message
        }
        guard await requestCalendarAccess() else {
            let message = "Calendar permission needed"
            calendarSyncMessage = message
            print("[CalendarSyncDebug] syncResult=\(message)")
            return message
        }

        if notificationSettingsStore.syncVenueGamesToAppleCalendar
            || notificationSettingsStore.syncPickupGamesToAppleCalendar {
            await syncFanGeoAttendingEventsToAppleCalendar(
                reason: "settingsManualSync",
                forceBypassFreshness: true
            )
        }
        var proSummary = FanGeoAppleCalendarSyncSummary()
        if notificationSettingsStore.syncSavedProGamesToAppleCalendar {
            proSummary = await reconcileSavedProGamesAppleCalendarDetailed(
                reason: "settingsManualSync",
                forceBypassFreshness: true,
                forceBypassSyncSetting: false
            )
        }
        let message = proSummary.permissionNeeded || proSummary.firstError != nil
            ? proSummary.userMessage
            : "Calendar synced"
        calendarSyncMessage = message
        print("[CalendarSyncDebug] syncResult=\(message)")
        return message
    }

    func removeAllFanGeoAppleCalendarEvents() async -> String {
        guard await requestCalendarAccess() else {
            return "Calendar permission needed"
        }

        var removedCount = 0
        var seenEventIdentifiers = Set<String>()

        for fanGeoIdentifier in calendarSyncStoredEventIdentifiers().keys {
            guard let event = calendarSyncEventForRemoval(fanGeoIdentifier: fanGeoIdentifier),
                  let eventIdentifier = event.eventIdentifier,
                  seenEventIdentifiers.insert(eventIdentifier).inserted else {
                calendarSyncRemoveStoredEventIdentifier(fanGeoIdentifier: fanGeoIdentifier)
                continue
            }
            do {
                try eventStore.remove(event, span: .thisEvent)
                calendarSyncRemoveStoredEventIdentifier(fanGeoIdentifier: fanGeoIdentifier)
                removedCount += 1
            } catch {
                print("[CalendarSyncDebug] bulkRemoveFailed identifier=\(fanGeoIdentifier) error=\(error.localizedDescription)")
            }
        }

        let predicate = eventStore.predicateForEvents(
            withStart: Calendar.current.date(byAdding: .year, value: -1, to: Date()) ?? .distantPast,
            end: Calendar.current.date(byAdding: .year, value: 2, to: Date()) ?? .distantFuture,
            calendars: nil
        )
        for event in eventStore.events(matching: predicate) {
            guard calendarSyncEventLooksLikeFanGeoCreated(event),
                  let eventIdentifier = event.eventIdentifier,
                  seenEventIdentifiers.insert(eventIdentifier).inserted else {
                continue
            }
            do {
                try eventStore.remove(event, span: .thisEvent)
                removedCount += 1
            } catch {
                print("[CalendarSyncDebug] bulkRemoveScanFailed error=\(error.localizedDescription)")
            }
        }

        UserDefaults.standard.removeObject(forKey: FanGeoCalendarEventStore.eventIdentifierMapKey)
        let message = removedCount > 0 ? "Removed FanGeo calendar events" : "No FanGeo calendar events found"
        calendarSyncMessage = message
        print("[CalendarSyncDebug] bulkRemoveFinished count=\(removedCount)")
        return message
    }

    private func reconcileSavedProGamesAppleCalendarDetailed(
        reason: String,
        forceBypassFreshness: Bool,
        forceBypassSyncSetting: Bool
    ) async -> FanGeoAppleCalendarSyncSummary {
        var summary = FanGeoAppleCalendarSyncSummary()
        guard notificationSettingsStore.syncGoingGamesToAppleCalendar || forceBypassSyncSetting else {
            logProGameCalendarSync(
                action: "reconcile",
                gameId: "all",
                skippedReason: "syncDisabled",
                forceBypassFreshness: forceBypassFreshness
            )
            print("[CalendarSyncDebug] reason=syncDisabled")
            summary.firstError = "Calendar sync is off"
            return summary
        }
        guard notificationSettingsStore.syncSavedProGamesToAppleCalendar || forceBypassSyncSetting else {
            logProGameCalendarSync(
                action: "reconcile",
                gameId: "all",
                skippedReason: "proCategoryDisabled",
                forceBypassFreshness: forceBypassFreshness
            )
            print("[CalendarSyncDebug] reason=proCategoryDisabled")
            return summary
        }

        if let skipReason = shouldSkipFullProGamesCalendarReconcile(forceBypassFreshness: forceBypassFreshness) {
            logProGameCalendarSync(
                action: "reconcile",
                gameId: "all",
                skippedReason: skipReason,
                fingerprint: proGamesCalendarContentFingerprint(),
                forceBypassFreshness: forceBypassFreshness
            )
            print("[CalendarSyncDebug] reason=\(skipReason)")
            return summary
        }

        guard await requestCalendarAccess() else {
            summary.permissionNeeded = true
            print("[CalendarSyncDebug] syncResult=\(summary.userMessage)")
            return summary
        }

        let activeIdentifiers = calendarSyncActiveProGameIdentifiers()
        logProGameCalendarSync(
            action: "reconcile",
            gameId: "all",
            fingerprint: appleCalendarProGamesFingerprint(reason: reason),
            forceBypassFreshness: forceBypassFreshness
        )

        for game in savedProGames {
            let result = await syncSavedProGameToAppleCalendar(
                game,
                action: "reconcile",
                forceBypassFreshness: forceBypassFreshness,
                forceBypassSyncSetting: forceBypassSyncSetting
            )
            summary.merge(result)
        }

        for identifier in calendarSyncKnownProCalendarIdentifiers()
            where identifier.hasPrefix("pro|") && !activeIdentifiers.contains(identifier) {
            let result = await removeGameFromAppleCalendar(
                fanGeoIdentifier: identifier,
                forceBypassSyncSetting: forceBypassSyncSetting
            )
            summary.merge(result)
        }
        recordProGamesCalendarFullSyncCompleted()
        print("[CalendarSyncDebug] syncResult=\(summary.userMessage)")
        return summary
    }

    func syncFavoriteTeamProGamesToAppleCalendar(
        _ games: [FavoriteTeamProGame],
        reason: String,
        forceBypassFreshness: Bool
    ) async {
        guard notificationSettingsStore.syncGoingGamesToAppleCalendar,
              notificationSettingsStore.syncSavedProGamesToAppleCalendar else {
            logProGameCalendarSync(
                action: "reconcile",
                gameId: "favoriteTeam",
                skippedReason: "syncDisabled",
                forceBypassFreshness: forceBypassFreshness
            )
            return
        }

        var seen = Set<String>()
        let scope = reason.hasPrefix("business") ? "business" : "fan"
        for item in games {
            guard !calendarSyncFavoriteTeamProGameIsCleared(item.game, scope: scope) else {
                logProGameCalendarSync(
                    action: "reconcile",
                    gameId: item.game.stableKey,
                    skippedReason: "completedFavoriteTeamCleared",
                    forceBypassFreshness: forceBypassFreshness
                )
                continue
            }
            let identifier = calendarSyncProGameIdentifier(for: item.game)
            guard seen.insert(identifier).inserted else { continue }
            await syncSavedProGameToAppleCalendar(
                item.game,
                action: "reconcile",
                forceBypassFreshness: forceBypassFreshness
            )
        }
        logProGameCalendarSync(
            action: "reconcile",
            gameId: "favoriteTeam",
            fingerprint: "reason:\(reason)|count:\(seen.count)|ids:\(seen.sorted().joined(separator: ","))",
            forceBypassFreshness: forceBypassFreshness
        )
    }

    func syncPickupGamesToAppleCalendarIfNeeded(reason: String, forceBypassFreshness: Bool = false) async {
        guard notificationSettingsStore.syncGoingGamesToAppleCalendar,
              notificationSettingsStore.syncPickupGamesToAppleCalendar else { return }
        let key = appleCalendarPickupSyncFingerprint(reason: reason)
        if let existing = appleCalendarPickupSyncTask {
#if DEBUG
            print("[TabPerfDebug] refreshCoalesced=true source=appleCalendarPickupSync reason=\(reason)")
#endif
            await existing.value
            return
        }
        if !forceBypassFreshness,
           lastAppleCalendarPickupSyncKey == key,
           let lastAppleCalendarPickupSyncAt {
            let age = Date().timeIntervalSince(lastAppleCalendarPickupSyncAt)
            if age < 60 {
#if DEBUG
                print("[TabPerfDebug] cacheAge=\(String(format: "%.1f", age)) source=appleCalendarPickupSync")
                print("[TabPerfDebug] refreshSkippedReason=fresh source=appleCalendarPickupSync reason=\(reason)")
#endif
                return
            }
        }
        let startedAt = Date()
#if DEBUG
        print("[TabPerfDebug] refreshStarted=appleCalendarPickupSync reason=\(reason)")
#endif
        let task = Task<Void, Never> { @MainActor [weak self] in
            await self?.syncPickupGamesToAppleCalendarNow(reason: reason)
        }
        appleCalendarPickupSyncTask = task
        await task.value
        appleCalendarPickupSyncTask = nil
        lastAppleCalendarPickupSyncAt = Date()
        lastAppleCalendarPickupSyncKey = key
#if DEBUG
        let ms = Int(Date().timeIntervalSince(startedAt) * 1000)
        print("[TabPerfDebug] refreshDurationMs=\(ms) source=appleCalendarPickupSync reason=\(reason)")
#endif
    }

    private func syncPickupGamesToAppleCalendarNow(reason: String) async {
#if DEBUG
        print("[CalendarSyncDebug] pickupSyncStarted reason=\(reason)")
#endif
        var seen = Set<String>()
        for game in myPickupGamesForSettings {
            await syncPickupGameToAppleCalendarIfNeeded(game, seen: &seen, source: "hosted")
        }
        for card in myPickupGameJoinRequestCards where card.pill == .approved {
            if let row = resolvedPickupGameRow(for: card.pickupGameId) {
                await syncPickupGameToAppleCalendarIfNeeded(row, seen: &seen, source: "joined")
            } else if let start = PickupGameModels.parseSupabaseTimestamptz(card.game_start_at) {
                let key = "pickup|\(card.pickupGameId.uuidString.lowercased())"
                guard seen.insert(key).inserted else { continue }
                await addGameToCalendar(
                    title: card.title,
                    date: start,
                    location: card.locationLine,
                    fanGeoIdentifier: key
                )
            }
        }
#if DEBUG
        print("[CalendarSyncDebug] pickupSyncFinished reason=\(reason) count=\(seen.count)")
#endif
    }

    func syncFanGeoAttendingEventsToAppleCalendar(reason: String, forceBypassFreshness: Bool = false) async {
        guard notificationSettingsStore.syncGoingGamesToAppleCalendar else { return }
        let key = appleCalendarGlobalSyncFingerprint(reason: reason)
        if let existing = appleCalendarGlobalSyncTask {
#if DEBUG
            print("[TabPerfDebug] refreshCoalesced=true source=appleCalendarGlobalSync reason=\(reason)")
#endif
            await existing.value
            return
        }
        if !forceBypassFreshness,
           lastAppleCalendarGlobalSyncKey == key,
           let lastAppleCalendarGlobalSyncAt {
            let age = Date().timeIntervalSince(lastAppleCalendarGlobalSyncAt)
            if age < 60 {
#if DEBUG
                print("[TabPerfDebug] cacheAge=\(String(format: "%.1f", age)) source=appleCalendarGlobalSync")
                print("[TabPerfDebug] refreshSkippedReason=fresh source=appleCalendarGlobalSync reason=\(reason)")
#endif
                logProGameCalendarSync(
                    action: "reconcile",
                    gameId: "all",
                    skippedReason: "fresh",
                    fingerprint: key,
                    forceBypassFreshness: forceBypassFreshness
                )
                return
            }
        }
        let startedAt = Date()
#if DEBUG
        print("[TabPerfDebug] refreshStarted=appleCalendarGlobalSync reason=\(reason)")
#endif
        let task = Task<Void, Never> { @MainActor [weak self] in
            await self?.syncFanGeoAttendingEventsToAppleCalendarNow(
                reason: reason,
                forceBypassFreshness: forceBypassFreshness
            )
        }
        appleCalendarGlobalSyncTask = task
        await task.value
        appleCalendarGlobalSyncTask = nil
        lastAppleCalendarGlobalSyncAt = Date()
        lastAppleCalendarGlobalSyncKey = key
#if DEBUG
        let ms = Int(Date().timeIntervalSince(startedAt) * 1000)
        print("[TabPerfDebug] refreshDurationMs=\(ms) source=appleCalendarGlobalSync reason=\(reason)")
#endif
    }

    private func syncFanGeoAttendingEventsToAppleCalendarNow(reason: String, forceBypassFreshness: Bool) async {
#if DEBUG
        print("[CalendarSyncDebug] globalSyncStarted reason=\(reason)")
#endif
        var seen = Set<String>()

        for item in followingTabGoingItems where item.isServerGoing {
            guard notificationSettingsStore.syncVenueGamesToAppleCalendar else { continue }
            guard let start = calendarSyncVenueStartDate(for: item.venueEvent) else { continue }
            let title = item.venueEvent.event_title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = "venue|\(item.id.uuidString.lowercased())"
            guard seen.insert(key).inserted else { continue }
            await addGameToCalendar(
                title: title?.isEmpty == false ? title! : "Venue Game",
                date: start,
                location: item.bar.name,
                fanGeoIdentifier: key
            )
        }

        if notificationSettingsStore.syncPickupGamesToAppleCalendar {
            await syncPickupGamesToAppleCalendarIfNeeded(reason: reason, forceBypassFreshness: forceBypassFreshness)
        }

        if notificationSettingsStore.syncSavedProGamesToAppleCalendar {
            for game in savedProGames {
                let key = "pro|\(game.stableKey)"
                guard seen.insert(key).inserted else { continue }
                await syncSavedProGameToAppleCalendar(
                    game,
                    action: "reconcile",
                    forceBypassFreshness: forceBypassFreshness
                )
            }
        }
#if DEBUG
        print("[CalendarSyncDebug] globalSyncFinished reason=\(reason) count=\(seen.count)")
#endif
    }

    private func appleCalendarPickupSyncFingerprint(reason: String) -> String {
        let hosted = myPickupGamesForSettings
            .map { row in
                [
                    row.id.uuidString.lowercased(),
                    row.game_start_at,
                    row.end_time ?? "",
                    row.updated_at ?? "",
                    row.status,
                    row.title,
                    row.address ?? "",
                    row.city ?? "",
                    row.state ?? ""
                ].joined(separator: "~")
            }
            .sorted()
            .joined(separator: "|")
        let joined = myPickupGameJoinRequestCards
            .map { card in
                [
                    card.pickupGameId.uuidString.lowercased(),
                    card.game_start_at,
                    card.pill.rawValue,
                    card.title,
                    card.locationLine
                ].joined(separator: "~")
            }
            .sorted()
            .joined(separator: "|")
        return "reason:\(reason)|hosted:\(hosted)|joined:\(joined)"
    }

    private func appleCalendarGlobalSyncFingerprint(reason: String) -> String {
        let venue = followingTabGoingItems
            .filter(\.isServerGoing)
            .map { item in
                [
                    item.id.uuidString.lowercased(),
                    item.venueEvent.scheduled_start_at ?? "",
                    item.venueEvent.event_date ?? "",
                    item.venueEvent.event_time ?? "",
                    item.venueEvent.event_title ?? "",
                    item.bar.name
                ].joined(separator: "~")
            }
            .sorted()
            .joined(separator: "|")
        let proGames = appleCalendarProGamesFingerprint(reason: reason)
        return "\(appleCalendarPickupSyncFingerprint(reason: reason))|venue:\(venue)|pro:\(proGames)"
    }

    private func appleCalendarProGamesFingerprint(reason: String) -> String {
        let savedState = savedProGames
            .map { game in
                calendarSyncProGameFingerprint(
                    gameId: game.stableKey,
                    title: calendarSyncProGameTitle(for: game),
                    date: game.startTime,
                    location: game.league,
                    state: "saved"
                )
            }
            .sorted()
            .joined(separator: "|")
        let fanFavoriteState = favoriteTeamProGames
            .filter { !calendarSyncFavoriteTeamProGameIsCleared($0.game, scope: "fan") }
            .map { item in
                calendarSyncProGameFingerprint(
                    gameId: item.game.stableKey,
                    title: calendarSyncProGameTitle(for: item.game),
                    date: item.game.startTime,
                    location: item.game.league,
                    state: "favoriteTeam"
                )
            }
        let businessFavoriteState = businessFavoriteTeamProGames
            .filter { !calendarSyncFavoriteTeamProGameIsCleared($0.game, scope: "business") }
            .map { item in
                calendarSyncProGameFingerprint(
                    gameId: item.game.stableKey,
                    title: calendarSyncProGameTitle(for: item.game),
                    date: item.game.startTime,
                    location: item.game.league,
                    state: "businessFavoriteTeam"
                )
            }
        let favoriteState = (fanFavoriteState + businessFavoriteState)
            .sorted()
            .joined(separator: "|")
        let storedProState = calendarSyncStoredEventIdentifiers().keys
            .filter { $0.hasPrefix("pro|") }
            .sorted()
            .joined(separator: "|")
        return "reason:\(reason)|saved:\(savedState)|favorite:\(favoriteState)|stored:\(storedProState)"
    }

    private func calendarSyncActiveProGameIdentifiers() -> Set<String> {
        var identifiers = Set(savedProGames.map { calendarSyncProGameIdentifier(for: $0) })
        for item in favoriteTeamProGames where !calendarSyncFavoriteTeamProGameIsCleared(item.game, scope: "fan") {
            identifiers.insert(calendarSyncProGameIdentifier(for: item.game))
        }
        for item in businessFavoriteTeamProGames where !calendarSyncFavoriteTeamProGameIsCleared(item.game, scope: "business") {
            identifiers.insert(calendarSyncProGameIdentifier(for: item.game))
        }
        return identifiers
    }

    private func calendarSyncKnownProCalendarIdentifiers() -> Set<String> {
        var identifiers = Set(calendarSyncStoredEventIdentifiers().keys.filter { $0.hasPrefix("pro|") })
        let predicate = eventStore.predicateForEvents(
            withStart: Calendar.current.date(byAdding: .year, value: -1, to: Date()) ?? .distantPast,
            end: Calendar.current.date(byAdding: .year, value: 2, to: Date()) ?? .distantFuture,
            calendars: nil
        )
        for event in eventStore.events(matching: predicate) {
            if let identifier = calendarSyncFanGeoIdentifier(from: event),
               identifier.hasPrefix("pro|") {
                identifiers.insert(identifier)
            }
        }
        return identifiers
    }

    private func calendarSyncFavoriteTeamProGameIsCleared(_ game: SavedProGame, scope: String) -> Bool {
        guard game.isFinal else { return false }
        let raw = UserDefaults.standard.string(forKey: "gameon.going.completedFavoriteTeamProGamesCleared.v1") ?? ""
        let token = calendarSyncCompletedFavoriteTeamProGameClearToken(for: game, scope: scope)
        return raw
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .contains(token)
    }

    private func calendarSyncCompletedFavoriteTeamProGameClearToken(for game: SavedProGame, scope: String) -> String {
        let userScope = currentUserAuthId?.uuidString.lowercased() ?? "guest"
        return "\(userScope)|\(scope)|\(game.stableKey)"
    }

    private func calendarSyncProGameIdentifier(for game: SavedProGame) -> String {
        "pro|\(game.stableKey)"
    }

    private func calendarSyncProGameTitle(for game: SavedProGame) -> String {
        ProGameNotificationFormatting.matchupTitle(
            awayTeam: game.awayTeam,
            homeTeam: game.homeTeam,
            source: "AppleCalendar"
        )
    }

    private func calendarSyncProGameFingerprint(
        gameId: String,
        title: String,
        date: Date,
        location: String,
        state: String
    ) -> String {
        [
            "gameId:\(gameId)",
            "start:\(Int(date.timeIntervalSince1970))",
            "title:\(title)",
            "location:\(location)",
            "state:\(state)"
        ].joined(separator: "|")
    }

    private func syncPickupGameToAppleCalendarIfNeeded(
        _ game: PickupGameRow,
        seen: inout Set<String>,
        source: String
    ) async {
        guard let start = PickupGameModels.parseSupabaseTimestamptz(game.game_start_at) else { return }
        let key = "pickup|\(game.id.uuidString.lowercased())"
        guard seen.insert(key).inserted else { return }
        await addGameToCalendar(
            title: game.title,
            date: start,
            location: pickupGameCalendarAddressLine(game),
            fanGeoIdentifier: key
        )
#if DEBUG
        print("[CalendarSyncDebug] pickupSynced source=\(source) id=\(game.id.uuidString.lowercased())")
#endif
    }

    private func calendarSyncExistingEvent(
        title: String,
        date: Date,
        location: String,
        fanGeoIdentifier: String?
    ) -> EKEvent? {
        let displayTitle = calendarSyncDisplayTitle(
            title: title,
            location: location,
            fanGeoIdentifier: fanGeoIdentifier
        )
        if let fanGeoIdentifier,
           !fanGeoIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let eventIdentifier = calendarSyncStoredEventIdentifier(fanGeoIdentifier: fanGeoIdentifier),
               let event = eventStore.event(withIdentifier: eventIdentifier) {
                return event
            }

            let predicate = eventStore.predicateForEvents(
                withStart: Calendar.current.date(byAdding: .year, value: -1, to: date) ?? date,
                end: Calendar.current.date(byAdding: .year, value: 2, to: date) ?? date,
                calendars: nil
            )
            if let event = eventStore.events(matching: predicate).first(where: {
                calendarSyncEvent($0, hasFanGeoIdentifier: fanGeoIdentifier)
            }) {
                return event
            }
        }

        let startWindow = Calendar.current.startOfDay(for: date)
        let endWindow = Calendar.current.date(byAdding: .day, value: 1, to: startWindow) ?? date
        let predicate = eventStore.predicateForEvents(
            withStart: startWindow,
            end: endWindow,
            calendars: nil
        )

        return eventStore.events(matching: predicate).first {
            calendarSyncEvent(
                $0,
                matchesTitle: title,
                displayTitle: displayTitle,
                location: location,
                fanGeoIdentifier: fanGeoIdentifier
            )
        }
    }

    private func calendarSyncEvent(_ event: EKEvent, hasFanGeoIdentifier identifier: String) -> Bool {
        event.notes?.contains(calendarSyncIdentifierLine(fanGeoIdentifier: identifier)) == true
    }

    private func calendarSyncFanGeoIdentifier(from event: EKEvent) -> String? {
        guard let notes = event.notes else { return nil }
        for line in notes.components(separatedBy: .newlines) {
            let prefix = "FanGeo ID:"
            guard line.localizedCaseInsensitiveContains(prefix) else { continue }
            let value = line.replacingOccurrences(of: prefix, with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private func calendarSyncEventLooksLikeFanGeoCreated(_ event: EKEvent) -> Bool {
        if let notes = event.notes,
           notes.localizedCaseInsensitiveContains("Added by FanGeo") {
            return true
        }
        if let title = event.title?.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty {
            if calendarSyncTitle(title, hasCaseInsensitivePrefix: "FanGeo:") { return true }
            if calendarSyncTitle(title, hasCaseInsensitivePrefix: "FanGeo Pickup:") { return true }
            if title.localizedCaseInsensitiveContains("FanGeo •") { return true }
        }
        return calendarSyncFanGeoIdentifier(from: event) != nil
    }

    private func calendarSyncEvent(
        _ event: EKEvent,
        matchesTitle title: String,
        displayTitle: String,
        location: String,
        fanGeoIdentifier: String? = nil
    ) -> Bool {
        let eventTitle = calendarSyncComparableTitle(event.title ?? "")
        var expectedTitles = [
            title,
            displayTitle,
            "FanGeo: \(title)",
            "FanGeo: \(displayTitle)",
            "FanGeo Pickup: \(title)",
            "FanGeo Pickup: \(displayTitle)"
        ]
        if fanGeoIdentifier?.lowercased().hasPrefix("pro|") == true {
            let cleanTitle = calendarSyncTitleRemovingFanGeoPrefix(title)
            let icon = calendarSyncSportIcon(title: cleanTitle, competition: location)
            expectedTitles.append("\(icon) FanGeo • \(cleanTitle)")
            expectedTitles.append("FanGeo • \(cleanTitle)")
        }
        let normalizedExpected = expectedTitles
            .map(calendarSyncComparableTitle)
            .filter { !$0.isEmpty }
        guard normalizedExpected.contains(eventTitle) else { return false }
        guard let expectedLocation = calendarSyncCleanLocation(location) else { return true }
        let eventLocation = event.location?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return eventLocation.isEmpty || eventLocation == expectedLocation
    }

    private func calendarSyncEventForRemoval(fanGeoIdentifier: String) -> EKEvent? {
        if let eventIdentifier = calendarSyncStoredEventIdentifier(fanGeoIdentifier: fanGeoIdentifier),
           let event = eventStore.event(withIdentifier: eventIdentifier) {
            return event
        }

        let predicate = eventStore.predicateForEvents(
            withStart: Calendar.current.date(byAdding: .year, value: -1, to: Date()) ?? .distantPast,
            end: Calendar.current.date(byAdding: .year, value: 2, to: Date()) ?? .distantFuture,
            calendars: nil
        )
        return eventStore.events(matching: predicate).first(where: {
            calendarSyncEvent($0, hasFanGeoIdentifier: fanGeoIdentifier)
        })
    }

    private func calendarSyncDisplayTitle(
        title: String,
        location: String,
        fanGeoIdentifier: String?
    ) -> String {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseTitle = cleanTitle.isEmpty ? "Game" : cleanTitle
        if calendarSyncEventKind(fanGeoIdentifier: fanGeoIdentifier) == .pro {
            return calendarSyncProGameDisplayTitle(title: baseTitle, competition: location)
        }
        let flaggedTitle = ProGameNotificationFormatting.formatTextContainingTeamNames(
            baseTitle,
            source: "AppleCalendar"
        )
        guard !calendarSyncTitle(flaggedTitle, hasCaseInsensitivePrefix: "FanGeo:"),
              !calendarSyncTitle(flaggedTitle, hasCaseInsensitivePrefix: "FanGeo Pickup:")
        else {
            return flaggedTitle
        }

        switch calendarSyncEventKind(fanGeoIdentifier: fanGeoIdentifier) {
        case .pickup:
            return "FanGeo Pickup: \(flaggedTitle)"
        case .venue:
            let venueName = calendarSyncCleanLocation(location) ?? ""
            if venueName.isEmpty || venueName.localizedCaseInsensitiveCompare("Venue") == .orderedSame {
                return "FanGeo: \(flaggedTitle)"
            }
            return "FanGeo: \(flaggedTitle) @ \(venueName)"
        case .pro:
            return calendarSyncProGameDisplayTitle(title: flaggedTitle, competition: location)
        case .general:
            return "FanGeo: \(flaggedTitle)"
        }
    }

    private func calendarSyncNotes(
        title: String,
        date: Date,
        location: String,
        fanGeoIdentifier: String?
    ) -> String {
        var lines = ["Added by FanGeo"]
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanLocation = calendarSyncCleanLocation(location) ?? ""

        switch calendarSyncEventKind(fanGeoIdentifier: fanGeoIdentifier) {
        case .pro:
            return calendarSyncProGameNotes(
                title: cleanTitle,
                date: date,
                competition: cleanLocation
            )
        case .venue:
            if !cleanTitle.isEmpty {
                let teamsLine = ProGameNotificationFormatting.formatTextContainingTeamNames(
                    cleanTitle,
                    source: "AppleCalendar"
                )
                lines.append("Teams: \(teamsLine)")
            }
            if !cleanLocation.isEmpty {
                lines.append("Venue: \(cleanLocation)")
            }
        case .pickup:
            if !cleanTitle.isEmpty {
                lines.append("Pickup Game: \(cleanTitle)")
            }
            if !cleanLocation.isEmpty {
                lines.append("Location: \(cleanLocation)")
            }
        case .general:
            if !cleanTitle.isEmpty {
                lines.append("Event: \(cleanTitle)")
            }
            if !cleanLocation.isEmpty {
                lines.append("Location: \(cleanLocation)")
            }
        }

        lines.append("Start: \(calendarSyncNotesDateFormatter.string(from: date))")
        if let fanGeoIdentifier = fanGeoIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
           !fanGeoIdentifier.isEmpty {
            lines.append(calendarSyncIdentifierLine(fanGeoIdentifier: fanGeoIdentifier))
        }
        return lines.joined(separator: "\n")
    }

    private func calendarSyncProGameNotes(title: String, date: Date, competition: String) -> String {
        var lines = ["Added by FanGeo", ""]
        let cleanCompetition = competition.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanTitle = calendarSyncTitleRemovingFanGeoPrefix(title)
        if !cleanCompetition.isEmpty {
            lines.append("🏆 \(cleanCompetition)")
        }
        if !cleanTitle.isEmpty {
            lines.append(cleanTitle)
        }
        lines.append("")
        lines.append("📅 \(calendarSyncNotesDateFormatter.string(from: date))")
        return lines.joined(separator: "\n")
    }

    private func calendarSyncIdentifierLine(fanGeoIdentifier: String) -> String {
        "FanGeo ID: \(fanGeoIdentifier)"
    }

    private func calendarSyncCleanRestrictedFields(_ event: EKEvent) {
        event.url = nil
        event.structuredLocation = nil
    }

    private func calendarSyncProGameDisplayTitle(title: String, competition: String) -> String {
        let cleanTitle = calendarSyncTitleRemovingFanGeoPrefix(title)
        let icon = calendarSyncSportIcon(title: cleanTitle, competition: competition)
        let displayTitle: String
        if icon.isEmpty {
            displayTitle = "FanGeo: \(cleanTitle)"
        } else {
            displayTitle = "FanGeo: \(icon) · \(cleanTitle)"
        }
#if DEBUG
        if let teams = calendarSyncParseMatchupTeams(from: title) {
            CountryFlagHelper.logCalendarMatchupFlagDebug(
                awayTeam: teams.away,
                homeTeam: teams.home,
                finalTitle: displayTitle,
                source: "AppleCalendar"
            )
        }
#endif
        return displayTitle
    }

    private func calendarSyncParseMatchupTeams(from title: String) -> (away: String, home: String)? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        for separator in [" vs ", " v ", " @ ", " at "] {
            guard let range = trimmed.range(of: separator, options: .caseInsensitive) else { continue }
            let away = ProGameTeamScoreIdentity.cleanTeamName(String(trimmed[..<range.lowerBound]))
            let home = ProGameTeamScoreIdentity.cleanTeamName(String(trimmed[range.upperBound...]))
            guard !away.isEmpty, !home.isEmpty else { continue }
            return (away, home)
        }
        return nil
    }

    private func calendarSyncTitleRemovingFanGeoPrefix(_ raw: String) -> String {
        var title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for marker in ["FanGeo Pickup:", "FanGeo:", "FanGeo •", "FanGeo -"] {
            guard let range = title.range(of: marker, options: [.caseInsensitive]) else { continue }
            let prefix = title[..<range.lowerBound]
            let prefixHasAlphanumeric = prefix.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
            guard !prefixHasAlphanumeric else { continue }
            title = String(title[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }
        if calendarSyncTitleContainsMatchupSeparator(title) {
            return title.isEmpty ? "Game" : title
        }
        calendarSyncStripLeadingDecorativePrefix(from: &title)
        return title.isEmpty ? "Game" : title
    }

    private func calendarSyncTitleContainsMatchupSeparator(_ title: String) -> Bool {
        [" vs ", " v ", " @ ", " at "].contains { separator in
            title.range(of: separator, options: .caseInsensitive) != nil
        }
    }

    private func calendarSyncStripLeadingDecorativePrefix(from title: inout String) {
        while let first = title.unicodeScalars.first,
              calendarSyncScalarIsDecorativeLeadingPrefix(first) {
            title = String(title.unicodeScalars.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
            if title.hasPrefix("•") || title.hasPrefix("-") || title.hasPrefix("·") {
                title = String(title.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }

    private func calendarSyncScalarIsDecorativeLeadingPrefix(_ scalar: UnicodeScalar) -> Bool {
        if scalar.properties.isEmojiPresentation {
            return true
        }
        guard scalar.properties.generalCategory == .otherSymbol else {
            return false
        }
        // Regional indicator symbols (country flags) must not be stripped from matchup titles.
        return !(0x1F1E6...0x1F1FF).contains(scalar.value)
    }

    private func calendarSyncComparableTitle(_ raw: String) -> String {
        calendarSyncTitleRemovingFanGeoPrefix(raw)
            .unicodeScalars
            .filter { scalar in
                scalar.properties.isEmojiPresentation == false
                    && scalar.properties.generalCategory != .otherSymbol
                    && scalar.properties.generalCategory != .nonspacingMark
            }
            .map(String.init)
            .joined()
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func calendarSyncSportIcon(title: String, competition: String) -> String {
        let text = LiveMatchFilters.normalizedSearchText("\(title) \(competition)")
        if text.contains("american football") || text.contains("nfl") { return "🏈" }
        if text.contains("basketball") || text.contains("nba") { return "🏀" }
        if text.contains("hockey") || text.contains("nhl") { return "🏒" }
        if text.contains("baseball") || text.contains("mlb") { return "⚾" }
        if text.contains("tennis") { return "🎾" }
        if text.contains("golf") { return "⛳" }
        if text.contains("mma") || text.contains("combat") || text.contains("boxing") || text.contains("ufc") { return "🥊" }
        if text.contains("racing") || text.contains("motorsport") || text.contains("motor sport") || text.contains("f1") || text.contains("formula 1") || text.contains("formula one") { return "🏎️" }
        if text.contains("soccer")
            || text.contains("football")
            || text.contains("fifa")
            || text.contains("uefa")
            || text.contains("world cup")
            || text.contains("friendly")
            || text.contains("nations league") {
            return "⚽"
        }
        return "🏟️"
    }

    private func calendarSyncCleanLocation(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard !trimmed.localizedCaseInsensitiveContains("thesportsdb") else { return nil }
        guard !trimmed.localizedCaseInsensitiveContains("fangeo id") else { return nil }
        guard !calendarSyncLooksLikePhoneOrProviderIdentifier(trimmed) else { return nil }
        return trimmed
    }

    private func calendarSyncLooksLikePhoneOrProviderIdentifier(_ raw: String) -> Bool {
        let digits = raw.filter(\.isNumber)
        guard !digits.isEmpty else { return false }
        let allowed = CharacterSet(charactersIn: "0123456789-+() .")
        let containsOnlyPhoneCharacters = raw.unicodeScalars.allSatisfy { allowed.contains($0) }
        return containsOnlyPhoneCharacters && digits.count >= 4 && digits.count <= 15
    }

    private func calendarSyncStoredEventIdentifier(fanGeoIdentifier: String) -> String? {
        calendarSyncStoredEventIdentifiers()[fanGeoIdentifier]
    }

    private func calendarSyncStoreEventIdentifier(_ eventIdentifier: String?, fanGeoIdentifier: String?) {
        guard let eventIdentifier,
              let fanGeoIdentifier = fanGeoIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
              !fanGeoIdentifier.isEmpty else { return }
        var identifiers = calendarSyncStoredEventIdentifiers()
        identifiers[fanGeoIdentifier] = eventIdentifier
        UserDefaults.standard.set(identifiers, forKey: FanGeoCalendarEventStore.eventIdentifierMapKey)
        print("[CalendarSyncDebug] eventIdentifier=\(eventIdentifier)")
        print("[CalendarSyncDebug] eventIdentifierPersisted=true")
    }

    private func calendarSyncRemoveStoredEventIdentifier(fanGeoIdentifier: String) {
        var identifiers = calendarSyncStoredEventIdentifiers()
        identifiers.removeValue(forKey: fanGeoIdentifier)
        UserDefaults.standard.set(identifiers, forKey: FanGeoCalendarEventStore.eventIdentifierMapKey)
    }

    private func calendarSyncStoredEventIdentifiers() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: FanGeoCalendarEventStore.eventIdentifierMapKey) as? [String: String] ?? [:]
    }

    private func calendarSyncApplyAlarmPreference(to event: EKEvent, fanGeoIdentifier: String?) {
        guard let timing = calendarSyncAlertTiming(fanGeoIdentifier: fanGeoIdentifier) else { return }
        for alarm in event.alarms ?? [] {
            event.removeAlarm(alarm)
        }
        guard let offset = timing.relativeOffset else { return }
        event.addAlarm(EKAlarm(relativeOffset: offset))
    }

    private func calendarSyncAlertTiming(fanGeoIdentifier: String?) -> FanGeoCalendarAlertTiming? {
        switch calendarSyncEventKind(fanGeoIdentifier: fanGeoIdentifier) {
        case .venue:
            return notificationSettingsStore.venueCalendarAlertTiming
        case .pickup:
            return notificationSettingsStore.pickupCalendarAlertTiming
        case .pro:
            return notificationSettingsStore.proCalendarAlertTiming
        case .general:
            return nil
        }
    }

    private enum CalendarSyncEventKind {
        case venue
        case pickup
        case pro
        case general
    }

    private func calendarSyncEventKind(fanGeoIdentifier: String?) -> CalendarSyncEventKind {
        let normalized = fanGeoIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        if normalized.hasPrefix("venue|") { return .venue }
        if normalized.hasPrefix("pickup|") { return .pickup }
        if normalized.hasPrefix("pro|") { return .pro }
        return .general
    }

    private func calendarSyncTitle(_ title: String, hasCaseInsensitivePrefix prefix: String) -> Bool {
        title.range(
            of: prefix,
            options: [.caseInsensitive, .anchored],
            range: title.startIndex..<title.endIndex,
            locale: .current
        ) != nil
    }

    private var calendarSyncNotesDateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.timeZone = .current
        return formatter
    }

    private func calendarSyncVenueStartDate(for row: VenueEventRow) -> Date? {
        if let scheduledStart = calendarSyncParseISODate(row.scheduled_start_at) {
            return scheduledStart
        }

        guard let dateString = row.event_date?.trimmingCharacters(in: .whitespacesAndNewlines),
              !dateString.isEmpty else {
            return nil
        }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        dateFormatter.timeZone = TimeZone.current
        guard let day = dateFormatter.date(from: dateString) else { return nil }

        guard let timeString = row.event_time?.trimmingCharacters(in: .whitespacesAndNewlines),
              !timeString.isEmpty,
              !timeString.localizedCaseInsensitiveContains("TBD") else {
            return day
        }

        for format in ["h:mm a", "hh:mm a", "H:mm", "HH:mm"] {
            let timeFormatter = DateFormatter()
            timeFormatter.locale = Locale(identifier: "en_US_POSIX")
            timeFormatter.dateFormat = format
            timeFormatter.timeZone = TimeZone.current
            if let time = timeFormatter.date(from: timeString.uppercased()) {
                var dayComponents = Calendar.current.dateComponents([.year, .month, .day], from: day)
                let timeComponents = Calendar.current.dateComponents([.hour, .minute, .second], from: time)
                dayComponents.hour = timeComponents.hour
                dayComponents.minute = timeComponents.minute
                dayComponents.second = timeComponents.second ?? 0
                return Calendar.current.date(from: dayComponents)
            }
        }

        return day
    }

    private func calendarSyncParseISODate(_ raw: String?) -> Date? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }

        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: raw) {
            return date
        }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }
}
