import Compression
import Foundation

struct PickupImportRawRow: Identifiable, Equatable {
    let id = UUID()
    let rowNumber: Int
    let values: [String: String]

    func value(_ column: String) -> String {
        values[column, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum PickupImportParseError: LocalizedError {
    case emptyFile
    case unsupportedFileType
    case missingHeader([String])
    case invalidTextEncoding
    case invalidXLSX(String)

    var errorDescription: String? {
        switch self {
        case .emptyFile:
            return "The selected file is empty."
        case .unsupportedFileType:
            return "Choose a .csv or .xlsx file."
        case .missingHeader(let missing):
            return "The template is missing required columns: \(missing.joined(separator: ", "))."
        case .invalidTextEncoding:
            return "Could not read this CSV file as UTF-8 text."
        case .invalidXLSX(let message):
            return "Could not read this XLSX file. \(message)"
        }
    }
}

enum PickupCSVParser {
    static let requiredHeaders = [
        "title",
        "sport",
        "description",
        "skill_level",
        "game_start_at",
        "address",
        "city",
        "state",
        "players_needed",
        "max_players",
        "end_time"
    ]

    static func parseFile(at url: URL) throws -> [PickupImportRawRow] {
        let ext = url.pathExtension.lowercased()
#if DEBUG
        print("[PickupBulkImport] parseStarted ext=\(ext)")
#endif
        switch ext {
        case "csv":
            return try parseCSV(data: Data(contentsOf: url))
        case "xlsx":
            return try parseXLSX(data: Data(contentsOf: url))
        default:
            throw PickupImportParseError.unsupportedFileType
        }
    }

    static func parseCSV(data: Data) throws -> [PickupImportRawRow] {
        guard !data.isEmpty else { throw PickupImportParseError.emptyFile }
        guard let text = String(data: data, encoding: .utf8) else {
            throw PickupImportParseError.invalidTextEncoding
        }
        let rows = csvRows(from: text)
        return try rawRows(fromTable: rows)
    }

    static func parseXLSX(data: Data) throws -> [PickupImportRawRow] {
        guard !data.isEmpty else { throw PickupImportParseError.emptyFile }
        let archive = try MinimalXLSXArchive(data: data)
        let stringsXML = archive.stringEntry(named: "xl/sharedStrings.xml") ?? ""
        let sharedStrings = XLSXSheetParser.sharedStrings(from: stringsXML)
        let sheetName = archive.firstWorksheetName()
        guard let sheetXML = archive.stringEntry(named: sheetName) else {
            throw PickupImportParseError.invalidXLSX("The first worksheet was not found.")
        }
        return try rawRows(fromTable: XLSXSheetParser.table(from: sheetXML, sharedStrings: sharedStrings))
    }

    private static func rawRows(fromTable rows: [[String]]) throws -> [PickupImportRawRow] {
        guard let headerRow = rows.first else { throw PickupImportParseError.emptyFile }
        let headers = headerRow.map { normalizeHeader($0) }
        let missing = requiredHeaders.filter { !headers.contains($0) }
        guard missing.isEmpty else { throw PickupImportParseError.missingHeader(missing) }

        var output: [PickupImportRawRow] = []
        for (offset, row) in rows.dropFirst().enumerated() {
            let hasAnyValue = row.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            guard hasAnyValue else { continue }
            var values: [String: String] = [:]
            for (index, header) in headers.enumerated() where !header.isEmpty {
                values[header] = index < row.count ? row[index] : ""
            }
            output.append(PickupImportRawRow(rowNumber: offset + 2, values: values))
        }

#if DEBUG
        print("[PickupBulkImport] parsedRows=\(output.count)")
#endif
        return output
    }

    private static func normalizeHeader(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
    }

    private static func csvRows(from text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var insideQuotes = false
        var iterator = text.makeIterator()

        while let ch = iterator.next() {
            if ch == "\"" {
                if insideQuotes, let next = iterator.next() {
                    if next == "\"" {
                        field.append("\"")
                    } else {
                        insideQuotes = false
                        if next == "," {
                            row.append(field)
                            field = ""
                        } else if next == "\n" {
                            row.append(field)
                            rows.append(row)
                            row = []
                            field = ""
                        } else if next == "\r" {
                            continue
                        } else {
                            field.append(next)
                        }
                    }
                } else {
                    insideQuotes.toggle()
                }
            } else if ch == ",", !insideQuotes {
                row.append(field)
                field = ""
            } else if ch == "\n", !insideQuotes {
                row.append(field)
                rows.append(row)
                row = []
                field = ""
            } else if ch == "\r", !insideQuotes {
                continue
            } else {
                field.append(ch)
            }
        }

        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }
}

private enum XLSXSheetParser {
    static func sharedStrings(from xml: String) -> [String] {
        guard !xml.isEmpty else { return [] }
        return matches(pattern: #"<si[\s\S]*?</si>"#, in: xml).map { item in
            matches(pattern: #"<t(?:\s[^>]*)?>([\s\S]*?)</t>"#, in: item)
                .map(xmlUnescape)
                .joined()
        }
    }

    static func table(from xml: String, sharedStrings: [String]) -> [[String]] {
        matches(pattern: #"<row[\s\S]*?</row>"#, in: xml).map { rowXML in
            var cellsByIndex: [Int: String] = [:]
            for cellXML in matches(pattern: #"<c\b[\s\S]*?</c>"#, in: rowXML) {
                guard let ref = firstCapture(pattern: #"r="([A-Z]+)\d+""#, in: cellXML),
                      let columnIndex = columnIndex(from: ref) else { continue }
                let type = firstCapture(pattern: #"t="([^"]+)""#, in: cellXML)
                let value: String
                if type == "inlineStr" {
                    value = matches(pattern: #"<t(?:\s[^>]*)?>([\s\S]*?)</t>"#, in: cellXML)
                        .map(xmlUnescape)
                        .joined()
                } else {
                    let raw = firstCapture(pattern: #"<v>([\s\S]*?)</v>"#, in: cellXML) ?? ""
                    if type == "s", let index = Int(raw), index >= 0, index < sharedStrings.count {
                        value = sharedStrings[index]
                    } else {
                        value = xmlUnescape(raw)
                    }
                }
                cellsByIndex[columnIndex] = value
            }
            let maxIndex = cellsByIndex.keys.max() ?? -1
            guard maxIndex >= 0 else { return [] }
            return (0...maxIndex).map { cellsByIndex[$0] ?? "" }
        }
    }

    private static func columnIndex(from letters: String) -> Int? {
        var value = 0
        for scalar in letters.unicodeScalars {
            let n = Int(scalar.value) - 64
            guard n >= 1, n <= 26 else { return nil }
            value = value * 26 + n
        }
        return value - 1
    }

    private static func matches(pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, options: [], range: range).compactMap { match in
            let targetRange = match.numberOfRanges > 1 ? match.range(at: 1) : match.range(at: 0)
            guard let range = Range(targetRange, in: text) else { return nil }
            return String(text[range])
        }
    }

    private static func firstCapture(pattern: String, in text: String) -> String? {
        matches(pattern: pattern, in: text).first
    }

    private static func xmlUnescape(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
    }
}

private struct MinimalXLSXArchive {
    private let entries: [String: Data]

    init(data: Data) throws {
        self.entries = try Self.readEntries(from: data)
        guard !entries.isEmpty else {
            throw PickupImportParseError.invalidXLSX("The workbook archive is empty.")
        }
    }

    func stringEntry(named name: String) -> String? {
        guard let data = entries[name] else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func firstWorksheetName() -> String {
        entries.keys
            .filter { $0.hasPrefix("xl/worksheets/sheet") && $0.hasSuffix(".xml") }
            .sorted()
            .first ?? "xl/worksheets/sheet1.xml"
    }

    private static func readEntries(from data: Data) throws -> [String: Data] {
        guard let eocd = findEndOfCentralDirectory(in: data) else {
            throw PickupImportParseError.invalidXLSX("ZIP directory was not found.")
        }
        let entryCount = Int(data.uint16LE(at: eocd + 10))
        let centralDirectoryOffset = Int(data.uint32LE(at: eocd + 16))
        var cursor = centralDirectoryOffset
        var result: [String: Data] = [:]

        for _ in 0..<entryCount {
            guard data.uint32LE(at: cursor) == 0x02014b50 else { break }
            let method = data.uint16LE(at: cursor + 10)
            let compressedSize = Int(data.uint32LE(at: cursor + 20))
            let uncompressedSize = Int(data.uint32LE(at: cursor + 24))
            let nameLength = Int(data.uint16LE(at: cursor + 28))
            let extraLength = Int(data.uint16LE(at: cursor + 30))
            let commentLength = Int(data.uint16LE(at: cursor + 32))
            let localHeaderOffset = Int(data.uint32LE(at: cursor + 42))
            let nameData = data.subdata(in: (cursor + 46)..<(cursor + 46 + nameLength))
            let name = String(data: nameData, encoding: .utf8) ?? ""
            if !name.hasSuffix("/") {
                result[name] = try entryData(
                    archive: data,
                    localHeaderOffset: localHeaderOffset,
                    method: method,
                    compressedSize: compressedSize,
                    uncompressedSize: uncompressedSize
                )
            }
            cursor += 46 + nameLength + extraLength + commentLength
        }
        return result
    }

    private static func entryData(
        archive: Data,
        localHeaderOffset: Int,
        method: UInt16,
        compressedSize: Int,
        uncompressedSize: Int
    ) throws -> Data {
        guard archive.uint32LE(at: localHeaderOffset) == 0x04034b50 else {
            throw PickupImportParseError.invalidXLSX("A worksheet entry was malformed.")
        }
        let nameLength = Int(archive.uint16LE(at: localHeaderOffset + 26))
        let extraLength = Int(archive.uint16LE(at: localHeaderOffset + 28))
        let dataStart = localHeaderOffset + 30 + nameLength + extraLength
        let compressed = archive.subdata(in: dataStart..<(dataStart + compressedSize))
        switch method {
        case 0:
            return compressed
        case 8:
            return try inflate(compressed, uncompressedSize: uncompressedSize)
        default:
            throw PickupImportParseError.invalidXLSX("Unsupported XLSX compression method \(method).")
        }
    }

    private static func inflate(_ data: Data, uncompressedSize: Int) throws -> Data {
        var output = Data(count: uncompressedSize)
        let decoded = output.withUnsafeMutableBytes { outBuffer in
            data.withUnsafeBytes { inBuffer in
                compression_decode_buffer(
                    outBuffer.bindMemory(to: UInt8.self).baseAddress!,
                    uncompressedSize,
                    inBuffer.bindMemory(to: UInt8.self).baseAddress!,
                    data.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        guard decoded > 0 else {
            throw PickupImportParseError.invalidXLSX("A compressed worksheet could not be expanded.")
        }
        output.removeSubrange(decoded..<output.count)
        return output
    }

    private static func findEndOfCentralDirectory(in data: Data) -> Int? {
        guard data.count >= 22 else { return nil }
        let lowerBound = max(0, data.count - 65_557)
        var index = data.count - 22
        while index >= lowerBound {
            if data.uint32LE(at: index) == 0x06054b50 {
                return index
            }
            index -= 1
        }
        return nil
    }
}

private extension Data {
    func uint16LE(at offset: Int) -> UInt16 {
        guard offset + 2 <= count else { return 0 }
        return self[offset..<offset + 2].enumerated().reduce(UInt16(0)) { partial, item in
            partial | (UInt16(item.element) << (item.offset * 8))
        }
    }

    func uint32LE(at offset: Int) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        return self[offset..<offset + 4].enumerated().reduce(UInt32(0)) { partial, item in
            partial | (UInt32(item.element) << (item.offset * 8))
        }
    }
}
