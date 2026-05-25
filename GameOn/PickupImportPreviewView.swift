import SwiftUI
import UniformTypeIdentifiers

struct PickupBulkImportPreviewView: View {
    @ObservedObject var viewModel: MapViewModel
    var showsNavigationChrome = true
    var onImported: () -> Void
    var onDoneAfterSuccess: () -> Void = {}

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    @State private var isFileImporterPresented = false
    @State private var selectedFileName = ""
    @State private var previewRows: [PickupBulkImportPreparedRow] = []
    @State private var isLoadingPreview = false
    @State private var isImporting = false
    @State private var errorMessage: String?
    @State private var templateURL: URL?
    @State private var templateErrorMessage: String?
    @State private var importResult: PickupBulkImportResult?
    @State private var selectedRowIDs: Set<UUID> = []

    private var summary: PickupBulkImportSummary {
        PickupBulkImportValidator.summary(for: previewRows)
    }

    private var importableRows: [PickupBulkImportPreparedRow] {
        previewRows.filter { $0.status.isImportable }
    }

    private var selectedImportableRows: [PickupBulkImportPreparedRow] {
        importableRows.filter { selectedRowIDs.contains($0.id) }
    }

    private var hasSuccessfulImport: Bool {
        (importResult?.insertedCount ?? 0) > 0
    }

    private var isImportButtonDisabled: Bool {
        hasSuccessfulImport || selectedImportableRows.isEmpty || isLoadingPreview || isImporting
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
                    Text("Upload multiple pickup games at once using the FanGeo template.")
                        .font(FGTypography.body)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .fixedSize(horizontal: false, vertical: true)

                    if let templateURL {
                        ShareLink(item: templateURL) {
                            Label("Download Template", systemImage: "arrow.down.doc")
                                .font(FGTypography.body.weight(.semibold))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    } else {
                        Button {
                            prepareTemplateFile()
                        } label: {
                            Label("Download Template", systemImage: "arrow.down.doc")
                                .font(FGTypography.body.weight(.semibold))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }

                    Button {
                        isFileImporterPresented = true
                    } label: {
                        Label(selectedFileName.isEmpty ? "Upload CSV/XLSX" : selectedFileName, systemImage: "doc.badge.plus")
                            .font(FGTypography.body.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(FGColor.accentBlue)
                    .disabled(isLoadingPreview || isImporting || hasSuccessfulImport)
                    if let templateErrorMessage, !templateErrorMessage.isEmpty {
                        Text(templateErrorMessage)
                            .font(FGTypography.caption)
                            .foregroundStyle(FGColor.dangerRed)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("Import CSV/XLSX")
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

                Section {
                    HStack(spacing: 12) {
                        Button("Select All") {
                            selectAllImportableRows()
                        }
                        .disabled(importableRows.isEmpty || isImporting || hasSuccessfulImport)

                        Button("Deselect All") {
                            selectedRowIDs.removeAll()
                        }
                        .disabled(selectedRowIDs.isEmpty || isImporting || hasSuccessfulImport)
                    }
                    .font(FGTypography.caption.weight(.semibold))
                    .buttonStyle(.borderless)

                    Text("\(selectedImportableRows.count) selected for import")
                        .font(FGTypography.body.weight(.semibold))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                }

                importableRowsSection(title: "Ready rows", status: .valid)
                importableRowsSection(title: "Warning rows", status: .warning)
                errorRowsSection
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

            if !showsNavigationChrome {
                Section {
                    completionActionButtons
                        .font(FGTypography.body.weight(.semibold))
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .fanGeoScreenBackground()
        .navigationTitle(showsNavigationChrome ? "Import CSV/XLSX" : "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showsNavigationChrome {
                if !hasSuccessfulImport {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") {
                            dismiss()
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if hasSuccessfulImport {
                        Button("Done") {
                            doneTappedAfterSuccess()
                        }
                    } else {
                        Button(importButtonTitle) {
                            Task { await importPreparedRows() }
                        }
                        .disabled(isImportButtonDisabled)
                    }
                }
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
            prepareTemplateFile()
#if DEBUG
            print("[PickupBulkImport] previewScreenPresented=true")
#endif
        }
    }

    private var importButtonTitle: String {
        if isImporting { return "Importing..." }
        return "Import Games"
    }

    @ViewBuilder
    private var completionActionButtons: some View {
        if hasSuccessfulImport {
            Button("Done") {
                doneTappedAfterSuccess()
            }
            .frame(maxWidth: .infinity)

            Button("Import another file") {
                resetForAnotherFile()
            }
            .font(FGTypography.caption.weight(.semibold))
            .frame(maxWidth: .infinity)
            .buttonStyle(.borderless)
        } else {
            Button(importButtonTitle) {
                Task { await importPreparedRows() }
            }
            .frame(maxWidth: .infinity)
            .disabled(isImportButtonDisabled)
        }
    }

    private func selectAllImportableRows() {
        guard !hasSuccessfulImport else { return }
        selectedRowIDs = Set(importableRows.map(\.id))
    }

    private var summaryGrid: some View {
        HStack(spacing: 10) {
            summaryPill(title: "Ready", value: summary.validCount, tint: FGColor.accentGreen)
            summaryPill(title: "Warning", value: summary.warningCount, tint: FGColor.accentYellow)
            summaryPill(title: "Error", value: summary.failedCount, tint: FGColor.dangerRed)
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
    private func importableRowsSection(title: String, status: PickupBulkImportRowStatus) -> some View {
        let rows = previewRows.filter { $0.status == status }
        if !rows.isEmpty {
            Section {
                ForEach(rows) { row in
                    PickupBulkImportPreviewRowView(
                        row: row,
                        isSelected: selectedRowIDs.contains(row.id),
                        isSelectionEnabled: row.status.isImportable && !isImporting && !hasSuccessfulImport,
                        onToggleSelection: { toggleSelection(for: row) }
                    )
                }
            } header: {
                Text(title)
            }
        }
    }

    @ViewBuilder
    private var errorRowsSection: some View {
        let rows = previewRows.filter { $0.status == .failed }
        if !rows.isEmpty {
            Section {
                ForEach(rows) { row in
                    PickupBulkImportPreviewRowView(
                        row: row,
                        isSelected: false,
                        isSelectionEnabled: false,
                        onToggleSelection: {}
                    )
                }
            } header: {
                Text("Error rows")
            } footer: {
                Text("Error rows will not be imported.")
            }
        }
    }

    private func handleFileImporter(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            selectedFileName = url.lastPathComponent
            importResult = nil
            selectedRowIDs.removeAll()
            Task { await loadPreview(from: url) }
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }

    private func prepareTemplateFile() {
        do {
            templateURL = try PickupBulkImportParser.bundledTemplateFileURL()
            templateErrorMessage = nil
        } catch {
            templateErrorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func loadPreview(from url: URL) async {
        isLoadingPreview = true
        errorMessage = nil
        previewRows = []
        selectedRowIDs.removeAll()
        defer { isLoadingPreview = false }

        do {
            let rows = try await PickupBulkImportService.loadPreview(from: url, viewModel: viewModel)
            previewRows = rows
            selectedRowIDs = Set(rows.filter { $0.status.isImportable }.map(\.id))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func toggleSelection(for row: PickupBulkImportPreparedRow) {
        guard row.status.isImportable, !isImporting, !hasSuccessfulImport else { return }
        if selectedRowIDs.contains(row.id) {
            selectedRowIDs.remove(row.id)
        } else {
            selectedRowIDs.insert(row.id)
        }
    }

    private func resetForAnotherFile() {
        selectedFileName = ""
        previewRows = []
        selectedRowIDs.removeAll()
        importResult = nil
        errorMessage = nil
        templateErrorMessage = nil
    }

    private func doneTappedAfterSuccess() {
#if DEBUG
        print("[PickupBulkImport] doneTappedAfterSuccess")
#endif
        onDoneAfterSuccess()
        dismiss()
    }

    @MainActor
    private func importPreparedRows() async {
        guard !hasSuccessfulImport else { return }
        let rowsToImport = selectedImportableRows
        guard !rowsToImport.isEmpty else { return }
#if DEBUG
        let selectedRows = rowsToImport.map { String($0.rowNumber) }.joined(separator: ",")
        print("[PickupBulkImport] selectedRowsForImport=\(selectedRows)")
#endif
        isImporting = true
        errorMessage = nil
        defer { isImporting = false }

        let result = await PickupBulkImportService.importRows(rowsToImport, viewModel: viewModel)
        importResult = result
        if result.insertedCount > 0 {
            onImported()
        }
    }
}

private struct PickupBulkImportPreviewRowView: View {
    let row: PickupBulkImportPreparedRow
    let isSelected: Bool
    let isSelectionEnabled: Bool
    var onToggleSelection: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                onToggleSelection()
            } label: {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(isSelectionEnabled ? FGColor.accentBlue : FGColor.secondaryText(colorScheme).opacity(0.55))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .disabled(!isSelectionEnabled)
            .accessibilityLabel(isSelected ? "Deselect row \(row.rowNumber)" : "Select row \(row.rowNumber)")

            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(row.title.isEmpty ? "Untitled pickup game" : row.title)
                        .font(FGTypography.body.weight(.semibold))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .lineLimit(2)

                    Spacer(minLength: 8)

                    GameFormatBadgeView(format: row.gameType, colorScheme: colorScheme)

                    Text(row.status.displayTitle)
                        .font(FGTypography.caption.weight(.black))
                        .foregroundStyle(statusTint)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(statusTint.opacity(colorScheme == .dark ? 0.18 : 0.12), in: Capsule())
                }

                Text(detailLine)
                    .font(FGTypography.caption)
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)

                if !row.locationLine.isEmpty {
                    Text(cityStateLine)
                        .font(FGTypography.caption)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .lineLimit(2)
                }

                if let metadataLine {
                    Text(metadataLine)
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
        return "\(row.sport) • \(startText)"
    }

    private var cityStateLine: String {
        [row.city, row.state].filter { !$0.isEmpty }.joined(separator: ", ")
    }

    private var metadataLine: String? {
        let values = [row.leagueName, row.homeTeam, row.awayTeam, row.season, row.division]
            .compactMap { value -> String? in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
        guard !values.isEmpty else { return nil }
        return values.joined(separator: " • ")
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
