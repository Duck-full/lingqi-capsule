import Foundation

enum KnowledgeTransferValidationSeverity: String, Codable, Equatable {
    case warning
    case error
}

struct KnowledgeTransferValidationIssue: Identifiable, Equatable {
    let id = UUID()
    let line: Int?
    let message: String
    let severity: KnowledgeTransferValidationSeverity
}

struct KnowledgeTransferPreview: Equatable {
    let entries: [KnowledgeEntry]
    let issues: [KnowledgeTransferValidationIssue]

    var canImport: Bool {
        !entries.isEmpty && !issues.contains(where: { $0.severity == .error })
    }
}

enum KnowledgeTransferError: LocalizedError {
    case invalidEncoding
    case invalidTemplate
    case invalidBackup
    case unsupportedBackupVersion
    case backupIntegrityFailed

    var errorDescription: String? {
        switch self {
        case .invalidEncoding: return "文件不是可识别的 UTF-8 文本。"
        case .invalidTemplate: return "导入文件与固定模板不一致。"
        case .invalidBackup: return "备份文件格式无效。"
        case .unsupportedBackupVersion: return "该备份文件版本暂不支持。"
        case .backupIntegrityFailed: return "备份文件校验未通过，未写入任何数据。"
        }
    }
}

struct KnowledgeBackupPayload: Codable, Equatable {
    let schemaVersion: Int
    let createdAt: Date
    let entries: [KnowledgeEntry]
    let checksum: String
}

enum KnowledgeTransferService {
    static let importTemplateHeader = ["日期", "标题", "摘要", "正文", "分类", "关键词", "心情", "状态"]

    static var importTemplateText: String {
        [
            csvRow(importTemplateHeader),
            csvRow(["2026-07-21", "示例知识标题", "一句可复用的摘要", "这里填写完整正文。", "项目推进", "需求梳理、复盘", "专注", "已沉淀"])
        ].joined(separator: "\n") + "\n"
    }

    static func previewImport(csvData: Data) throws -> KnowledgeTransferPreview {
        guard var text = String(data: csvData, encoding: .utf8) else {
            throw KnowledgeTransferError.invalidEncoding
        }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }

        let rows = parseCSV(text)
        guard let header = rows.first, header == importTemplateHeader else {
            throw KnowledgeTransferError.invalidTemplate
        }

        var entries: [KnowledgeEntry] = []
        var issues: [KnowledgeTransferValidationIssue] = []
        var fingerprints = Set<String>()

        for (offset, row) in rows.dropFirst().enumerated() {
            let line = offset + 2
            guard !row.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { continue }
            guard row.count == importTemplateHeader.count else {
                issues.append(.init(line: line, message: "列数应为 \(importTemplateHeader.count) 列，当前为 \(row.count) 列。", severity: .error))
                continue
            }

            let values = row.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard let date = strictDate(values[0]) else {
                issues.append(.init(line: line, message: "日期需使用 YYYY-MM-DD，例如 2026-07-21。", severity: .error))
                continue
            }
            guard !values[3].isEmpty else {
                issues.append(.init(line: line, message: "正文不能为空。", severity: .error))
                continue
            }
            guard let category = category(for: values[4]) else {
                issues.append(.init(line: line, message: "分类不在支持范围内。", severity: .error))
                continue
            }
            guard let status = status(for: values[7]) else {
                issues.append(.init(line: line, message: "状态应为 待沉淀、已沉淀 或 已归档。", severity: .error))
                continue
            }

            let sourceText = values[3]
            let title = values[1].isEmpty ? derivedTitle(from: sourceText) : values[1]
            let summary = values[2].isEmpty ? derivedSummary(from: sourceText) : values[2]
            let keywords = semanticKeywords(from: values[5])
            let entry = KnowledgeEntry(
                id: UUID(),
                date: date,
                title: title,
                summary: summary,
                keywords: keywords,
                category: category,
                mood: values[6].isEmpty ? "平稳" : values[6],
                sourceText: sourceText,
                wordCount: sourceText.count,
                status: status
            )
            let fingerprint = fingerprint(for: entry)
            if !fingerprints.insert(fingerprint).inserted {
                issues.append(.init(line: line, message: "与文件内上一条知识重复，已忽略。", severity: .warning))
                continue
            }
            entries.append(entry)
        }
        return KnowledgeTransferPreview(entries: entries, issues: issues)
    }

    static func makeBackup(entries: [KnowledgeEntry], createdAt: Date = Date()) throws -> Data {
        let content = BackupContent(schemaVersion: 1, createdAt: createdAt, entries: entries)
        let checksum = try checksum(for: content)
        return try encoder.encode(KnowledgeBackupPayload(schemaVersion: content.schemaVersion, createdAt: content.createdAt, entries: content.entries, checksum: checksum))
    }

    static func restoreBackup(data: Data) throws -> [KnowledgeEntry] {
        guard let payload = try? decoder.decode(KnowledgeBackupPayload.self, from: data) else {
            throw KnowledgeTransferError.invalidBackup
        }
        guard payload.schemaVersion == 1 else { throw KnowledgeTransferError.unsupportedBackupVersion }
        let content = BackupContent(schemaVersion: payload.schemaVersion, createdAt: payload.createdAt, entries: payload.entries)
        guard try checksum(for: content) == payload.checksum else {
            throw KnowledgeTransferError.backupIntegrityFailed
        }
        return payload.entries
    }

    static func mergeImported(_ imported: [KnowledgeEntry], onto existing: [KnowledgeEntry]) -> [KnowledgeEntry] {
        var seen = Set(existing.map(fingerprint(for:)))
        var merged = existing
        for entry in imported where seen.insert(fingerprint(for: entry)).inserted {
            merged.append(entry)
        }
        return merged.sorted { $0.date > $1.date }
    }

    static func fingerprint(for entry: KnowledgeEntry) -> String {
        let day = dayFormatter.string(from: entry.date)
        return [day, entry.title.normalizedKey, entry.sourceText.normalizedKey].joined(separator: "|")
    }

    private struct BackupContent: Codable {
        let schemaVersion: Int
        let createdAt: Date
        let entries: [KnowledgeEntry]
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter
    }()

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static func checksum(for content: BackupContent) throws -> String {
        let data = try encoder.encode(content)
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in data {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    private static func strictDate(_ value: String) -> Date? {
        guard value.range(of: "^\\d{4}-\\d{2}-\\d{2}$", options: .regularExpression) != nil else { return nil }
        return dayFormatter.date(from: value)
    }

    private static func category(for value: String) -> KnowledgeCategory? {
        if value.isEmpty { return .uncategorized }
        return KnowledgeCategory.allCases.first { $0.rawValue == value || $0.title == value }
    }

    private static func status(for value: String) -> KnowledgeStatus? {
        if value.isEmpty { return .published }
        return KnowledgeStatus.allCases.first { $0.rawValue == value || $0.title == value }
    }

    private static func semanticKeywords(from value: String) -> [String] {
        var seen = Set<String>()
        return value
            .components(separatedBy: CharacterSet(charactersIn: "、，,；;|"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { seen.insert($0.normalizedKey).inserted }
    }

    private static func derivedTitle(from text: String) -> String {
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        return firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func derivedSummary(from text: String) -> String {
        text.split(whereSeparator: \.isNewline)
            .map(String.init)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }) ?? text
    }

    private static func csvRow(_ fields: [String]) -> String {
        fields.map { field in
            let escaped = field.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        }.joined(separator: ",")
    }

    private static func parseCSV(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var index = text.startIndex

        while index < text.endIndex {
            let char = text[index]
            if char == "\"" {
                let next = text.index(after: index)
                if quoted, next < text.endIndex, text[next] == "\"" {
                    field.append("\"")
                    index = next
                } else {
                    quoted.toggle()
                }
            } else if char == ",", !quoted {
                row.append(field)
                field = ""
            } else if (char == "\n" || char == "\r"), !quoted {
                if char == "\r" {
                    let next = text.index(after: index)
                    if next < text.endIndex, text[next] == "\n" { index = next }
                }
                row.append(field)
                if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
                row = []
                field = ""
            } else {
                field.append(char)
            }
            index = text.index(after: index)
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }
}

enum KnowledgeImportedEntryStore {
    private static let filename = "knowledge-imported-entries-v1.json"

    static func load() -> [KnowledgeEntry] {
        guard let data = try? Data(contentsOf: storageURL),
              let entries = try? JSONDecoder.iso8601Decoder.decode([KnowledgeEntry].self, from: data) else {
            return []
        }
        return entries
    }

    @discardableResult
    static func append(_ entries: [KnowledgeEntry], excluding existing: [KnowledgeEntry]) throws -> Int {
        let stored = load()
        let existingFingerprints = Set(existing.map(KnowledgeTransferService.fingerprint(for:)))
        var storedFingerprints = Set<String>()
        var retained: [KnowledgeEntry] = []

        for entry in stored {
            let fingerprint = KnowledgeTransferService.fingerprint(for: entry)
            if storedFingerprints.insert(fingerprint).inserted {
                retained.append(entry)
            }
        }

        var additions: [KnowledgeEntry] = []
        for entry in entries {
            let fingerprint = KnowledgeTransferService.fingerprint(for: entry)
            if !storedFingerprints.contains(fingerprint), !existingFingerprints.contains(fingerprint) {
                storedFingerprints.insert(fingerprint)
                additions.append(entry)
            }
        }

        let data = try JSONEncoder.iso8601Encoder.encode(retained + additions)
        try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: storageURL, options: .atomic)
        return additions.count
    }

    private static var storageURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("LingQiCapsule", isDirectory: true).appendingPathComponent(filename)
    }
}

private extension String {
    var normalizedKey: String {
        folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }
}

private extension JSONEncoder {
    static var iso8601Encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var iso8601Decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
