import SwiftUI
import UniformTypeIdentifiers

struct PickupImportPreviewView: View {
    @ObservedObject var viewModel: MapViewModel
    var onImported: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    @State private var isFileImporterPresented = false
    @State private var selectedFileName = ""
    @State private var previewRows: [PickupImportPreparedRow] = []
    @State private var isLoadingPreview = false
    @State private var isImporting = false
    @State private var errorMessage: String?
    @State private var importResult: PickupBulkImportResult?

    private var summary: PickupImportSummary {
        PickupImportValidation.summary(for: previewRows)
    }

    private var allowedFileTypes: [UTType] {
        var types: [UTType] = [.commaSeparatedText]
        if let csv = UTType(filenameExtension: "csv") {
            types.append(csv)
        }
        if let xlsx = UTType(filenameExtension: "xlsx") {
            types.append(xlsx)
        }
        return types
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Upload the official FanGeo pickup games template.")
                        .font(FGTypography.body)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .fixedSize(horizontal: false, vertical: true)

                    Button {
                        isFileImporterPresented = true
                    } label: {
                        Label(selectedFileName.isEmpty ? "Choose CSV/XLSX file" : selectedFileName, systemImage: "doc.badge.plus")
                            .font(FGTypography.body.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(FGColor.accentBlue)
                    .disabled(isLoadingPreview || isImporting)
                }
                .padding(.vertical, 4)
            } header: {
                Text("Import Pickup Games")
            } footer: {
                Text("Manual pickup game creation is unchanged. Bulk import is optional for organizers adding many games.")
            }

            if let errorMessage, !errorMessage.isEmpty {
                Section {
                    Text(errorMessage)
                        .font(FGTypography.caption.weight(.semibold))
                        .foregroundStyle(FGColor.dangerRed)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if isLoadingPreview {
                Section {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Validating template...")
                            .font(FGTypography.body)
                    }
                    .padding(.vertical, 6)
                }
            }

            if !previewRows.isEmpty {
                Section {
                    summaryGrid
                } header: {
                    Text("Preview Summary")
                }

                importableRowsSection(title: "Valid rows", status: .valid)
                importableRowsSection(title: "Warning rows", status: .warning)
                failedRowsSection
            }

            if let importResult {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Imported \(importResult.insertedCount) pickup games", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(FGColor.accentGreen)
                            .font(FGTypography.body.weight(.semibold))
                        if importResult.failedCount > 0 {
                            Text("\(importResult.failedCount) rows failed during insert and were skipped.")
                                .font(FGTypography.caption)
                                .foregroundStyle(FGColor.secondaryText(colorScheme))
                        }
                    }
                } header: {
                    Text("Import Result")
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .fanGeoScreenBackground()
        .navigationTitle("Import Pickup Games")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") {
                    dismiss()
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(importButtonTitle) {
                    Task { await importPreparedRows() }
                }
                .disabled(summary.importableCount == 0 || isLoadingPreview || isImporting)
            }
        }
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: allowedFileTypes,
            allowsMultipleSelection: false
        ) { result in
            handleFileImporter(result)
        }
        .onAppear {
#if DEBUG
            print("[PickupBulkImport] previewScreenPresented=true")
#endif
        }
    }

    private var importButtonTitle: String {
        if isImporting { return "Importing..." }
        let count = summary.importableCount
        return count == 0 ? "Import" : "Import \(count)"
    }

    private var summaryGrid: some View {
        HStack(spacing: 10) {
            summaryPill(title: "Valid", value: summary.validCount, tint: FGColor.accentGreen)
            summaryPill(title: "Warnings", value: summary.warningCount, tint: FGColor.accentYellow)
            summaryPill(title: "Failed", value: summary.failedCount, tint: FGColor.dangerRed)
        }
        .padding(.vertical, 4)
    }

    private func summaryPill(title: String, value: Int, tint: Color) -> some View {
        VStack(spacing: 4) {
            Text("\(value)")
                .font(.title3.weight(.black))
                .foregroundStyle(tint)
            Text(title)
                .font(FGTypography.caption.weight(.semibold))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(tint.opacity(colorScheme == .dark ? 0.14 : 0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder
    private func importableRowsSection(title: String, status: PickupImportRowStatus) -> some View {
        let rows = previewRows.filter { $0.status == status }
        if !rows.isEmpty {
            Section {
                ForEach(rows) { row in
                    PickupImportPreviewRowView(row: row)
                }
            } header: {
                Text(title)
            }
        }
    }

    @ViewBuilder
    private var failedRowsSection: some View {
        let rows = previewRows.filter { $0.status == .failed }
        if !rows.isEmpty {
            Section {
                ForEach(rows) { row in
                    PickupImportPreviewRowView(row: row)
                }
            } header: {
                Text("Failed rows")
            } footer: {
                Text("Failed rows will not be imported.")
            }
        }
    }

    private func handleFileImporter(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            selectedFileName = url.lastPathComponent
            importResult = nil
            Task { await loadPreview(from: url) }
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func loadPreview(from url: URL) async {
        isLoadingPreview = true
        errorMessage = nil
        previewRows = []
        defer { isLoadingPreview = false }

        do {
            previewRows = try await PickupBulkImportService.loadPreview(from: url, viewModel: viewModel)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func importPreparedRows() async {
        isImporting = true
        errorMessage = nil
        defer { isImporting = false }

        let result = await PickupBulkImportService.importRows(previewRows, viewModel: viewModel)
        importResult = result
        if result.insertedCount > 0 {
            onImported()
        }
    }
}

private struct PickupImportPreviewRowView: View {
    let row: PickupImportPreparedRow
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Row \(row.rowNumber)")
                    .font(FGTypography.caption.weight(.black))
                    .foregroundStyle(statusTint)
                Text(row.title.isEmpty ? "Untitled pickup game" : row.title)
                    .font(FGTypography.body.weight(.semibold))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .lineLimit(2)
            }

            Text(detailLine)
                .font(FGTypography.caption)
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .fixedSize(horizontal: false, vertical: true)

            if !row.locationLine.isEmpty {
                Text(row.locationLine)
                    .font(FGTypography.caption)
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .lineLimit(2)
            }

            ForEach(row.warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(FGTypography.caption)
                    .foregroundStyle(FGColor.accentYellow)
            }

            ForEach(row.errors, id: \.self) { error in
                Label(error, systemImage: "xmark.octagon.fill")
                    .font(FGTypography.caption)
                    .foregroundStyle(FGColor.dangerRed)
            }
        }
        .padding(.vertical, 4)
    }

    private var statusTint: Color {
        switch row.status {
        case .valid:
            return FGColor.accentGreen
        case .warning:
            return FGColor.accentYellow
        case .failed:
            return FGColor.dangerRed
        }
    }

    private var detailLine: String {
        let startText = row.gameStartAt.map {
            Self.dateFormatter.string(from: $0)
        } ?? "Invalid start"
        let players = row.playersNeeded.map { "\($0) needed" } ?? "players invalid"
        return "\(row.sport) • \(row.skillLevel) • \(startText) • \(players)"
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
