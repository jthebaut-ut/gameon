import CoreLocation
import Foundation

struct PickupBulkImportResult {
    let insertedRows: [PickupGameRow]
    let failedRows: [(rowNumber: Int, message: String)]

    var insertedCount: Int { insertedRows.count }
    var failedCount: Int { failedRows.count }
}

enum PickupBulkImportService {
    @MainActor
    static func loadPreview(from url: URL, viewModel: MapViewModel) async throws -> [PickupBulkImportPreparedRow] {
#if DEBUG
        print("[PickupBulkImport] loadPreviewStarted file=\(url.lastPathComponent)")
#endif
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess { url.stopAccessingSecurityScopedResource() }
        }
        let rawRows = try PickupBulkImportParser.parseFile(at: url)
        let rows = await PickupBulkImportValidator.validate(rawRows: rawRows, viewModel: viewModel)
#if DEBUG
        let summary = PickupBulkImportValidator.summary(for: rows)
        print("[PickupBulkImport] previewReady total=\(summary.totalCount) importable=\(summary.importableCount)")
#endif
        return rows
    }

    @MainActor
    static func importRows(_ rows: [PickupBulkImportPreparedRow], viewModel: MapViewModel) async -> PickupBulkImportResult {
        let candidates = rows.filter { $0.status.isImportable }
#if DEBUG
        print("[PickupBulkInsert] started rows=\(candidates.count)")
#endif
        var inserted: [PickupGameRow] = []
        var failed: [(rowNumber: Int, message: String)] = []

        for row in candidates {
            guard let start = row.gameStartAt,
                  let coordinate = row.coordinate,
                  let playersNeeded = row.playersNeeded else {
                failed.append((row.rowNumber, "Row was not fully validated."))
                continue
            }
            let end = row.endTime ?? PickupGameModels.defaultPickupEndTime(forStart: start)

            do {
#if DEBUG
                print("[PickupBulkInsert] row=\(row.rowNumber) title=\(row.title)")
#endif
                let insertedRow = try await viewModel.insertPickupGame(
                    title: row.title,
                    sport: row.sport,
                    description: row.description,
                    skillLevel: row.skillLevel,
                    gameStartAt: start,
                    endTime: end,
                    address: row.address.isEmpty ? nil : row.address,
                    city: row.city.isEmpty ? nil : row.city,
                    state: row.state.isEmpty ? nil : row.state,
                    latitude: coordinate.latitude,
                    longitude: coordinate.longitude,
                    playersNeeded: playersNeeded,
                    playEnvironment: PickupPlayEnvironment.either.rawValue,
                    participantPreference: PickupParticipantPreference.everyone.rawValue,
                    isFree: true,
                    entryFeeAmount: nil,
                    maxPlayers: row.maxPlayers,
                    gameFormat: row.gameType
                )
                inserted.append(insertedRow)
#if DEBUG
                print("[PickupBulkInsert] row=\(row.rowNumber) success=true id=\(insertedRow.id.uuidString.lowercased())")
#endif
            } catch {
#if DEBUG
                print("[PickupBulkInsert] row=\(row.rowNumber) success=false error=\(error.localizedDescription)")
#endif
                failed.append((row.rowNumber, error.localizedDescription))
            }
        }

        if !inserted.isEmpty {
            await viewModel.loadMyPickupGamesForSettings()
            await viewModel.refreshPickupGamesForDiscoverMap(force: true, preservePickupCalendarDotDatesCache: true)
        }

#if DEBUG
        print("[PickupBulkInsert] finished inserted=\(inserted.count) failed=\(failed.count)")
#endif
        return PickupBulkImportResult(insertedRows: inserted, failedRows: failed)
    }
}
