import Foundation

enum KnowledgeCategory: String, Codable, CaseIterable, Identifiable {
    case productDesign
    case engineering
    case projectManagement
    case compliance
    case personalGrowth
    case lifeWellness
    case uncategorized

    var id: String { rawValue }

    var title: String {
        switch self {
        case .productDesign: return "产品设计"
        case .engineering: return "工程技术"
        case .projectManagement: return "项目推进"
        case .compliance: return "合规与发布"
        case .personalGrowth: return "个人成长"
        case .lifeWellness: return "生活与状态"
        case .uncategorized: return "未分类"
        }
    }

    var symbol: String {
        switch self {
        case .productDesign: return "paintpalette"
        case .engineering: return "hammer"
        case .projectManagement: return "checklist"
        case .compliance: return "checkmark.shield"
        case .personalGrowth: return "sparkles"
        case .lifeWellness: return "leaf"
        case .uncategorized: return "tray"
        }
    }
}

enum KnowledgeStatus: String, Codable, CaseIterable, Identifiable {
    case inbox
    case published
    case archived

    var id: String { rawValue }

    var title: String {
        switch self {
        case .inbox: return "待沉淀"
        case .published: return "已沉淀"
        case .archived: return "已归档"
        }
    }
}

struct KnowledgeSourceEntry: Identifiable, Equatable {
    let id: UUID
    let date: Date
    let text: String
    let keywords: [String]
    let summary: String
    let mood: String

    init(id: UUID = UUID(), date: Date, text: String, keywords: [String], summary: String, mood: String) {
        self.id = id
        self.date = date
        self.text = text
        self.keywords = keywords
        self.summary = summary
        self.mood = mood
    }
}

struct KnowledgeEntry: Identifiable, Codable, Equatable {
    let id: UUID
    let date: Date
    let title: String
    let summary: String
    let keywords: [String]
    let category: KnowledgeCategory
    let mood: String
    let sourceText: String
    let wordCount: Int
    let status: KnowledgeStatus
}

struct KnowledgeProfile: Equatable {
    let totalEntries: Int
    let totalWords: Int
    let dominantCategory: KnowledgeCategory
    let categoryCounts: [KnowledgeCategory: Int]
    let topKeywords: [String]
}

struct KnowledgeTimeRange: Codable, Equatable {
    let start: Date?
    let end: Date?

    init(start: Date? = nil, end: Date? = nil) {
        self.start = start
        self.end = end
    }
}

struct KnowledgeSearchFilter: Codable, Equatable {
    var query: String
    var category: KnowledgeCategory?
    var month: Date?
    var timeRange: KnowledgeTimeRange?
    var mood: String?
    var status: KnowledgeStatus?

    init(
        query: String = "",
        category: KnowledgeCategory? = nil,
        month: Date? = nil,
        timeRange: KnowledgeTimeRange? = nil,
        mood: String? = nil,
        status: KnowledgeStatus? = nil
    ) {
        self.query = query
        self.category = category
        self.month = month
        self.timeRange = timeRange
        self.mood = mood
        self.status = status
    }
}

enum KnowledgeTrendGranularity: String, Codable, CaseIterable, Identifiable {
    case day
    case month
    case quarter
    case year

    var id: String { rawValue }

    var title: String {
        switch self {
        case .day: return "日"
        case .month: return "月"
        case .quarter: return "季度"
        case .year: return "年"
        }
    }

    var visiblePointLimit: Int {
        switch self {
        case .day: return 14
        case .month: return 12
        case .quarter: return 8
        case .year: return 6
        }
    }
}

struct KnowledgeTrendPoint: Equatable {
    let bucketStart: Date
    let title: String
    let entryCount: Int
    let wordCount: Int
}

enum KnowledgeTrendAxisLabelFormatter {
    static func shortTitle(_ value: String, granularity: KnowledgeTrendGranularity) -> String {
        switch granularity {
        case .day:
            return value
        case .month:
            guard let yearRange = value.range(of: #"^\d{4}年"#, options: .regularExpression) else {
                return value
            }
            return String(value[yearRange.upperBound...])
        case .quarter, .year:
            return value
        }
    }
}

struct KnowledgeCategoryShare: Equatable {
    let category: KnowledgeCategory
    let entryCount: Int
    let wordCount: Int
    let ratio: Double
}

struct KnowledgeKeywordNode: Identifiable, Equatable {
    var id: String { keyword }
    let keyword: String
    let count: Int
}

struct KnowledgeKeywordEdge: Identifiable, Equatable {
    var id: String { "\(left)|\(right)" }
    let left: String
    let right: String
    let weight: Int
}

struct KnowledgeKeywordNetwork: Equatable {
    let nodes: [KnowledgeKeywordNode]
    let edges: [KnowledgeKeywordEdge]
}

struct KnowledgeExportBundle: Equatable {
    let title: String
    let filenameStem: String
    let readableText: String
    let entries: [KnowledgeEntry]
}

enum KnowledgeBaseService {
    private static let categoryRules: [(KnowledgeCategory, [String])] = [
        (.productDesign, ["产品", "体验", "视觉", "页面", "交互", "文案", "设计", "主题", "按钮", "用户路径", "留白", "动效"]),
        (.engineering, ["代码", "开发", "修复", "测试", "打包", "签名", "性能", "日志", "SwiftUI", "macOS", "Git", "构建", "通知"]),
        (.projectManagement, ["需求", "排期", "项目", "版本", "目标", "复盘", "推进", "计划", "评审", "文档", "里程碑"]),
        (.compliance, ["合规", "备案", "隐私", "协议", "审核", "上架", "资质", "条款", "安全"]),
        (.personalGrowth, ["学习", "成长", "总结", "方法", "思考", "认知", "知识", "沉淀", "复用"]),
        (.lifeWellness, ["生活", "休息", "睡眠", "散步", "旅行", "放松", "咖啡", "朋友", "心情", "平静"])
    ]

    private static let lowValueTokens = Set(["今天", "进行", "需要", "继续", "相关", "内容", "一个", "一些", "以及", "整体", "部分"])

    static func entries(from sources: [KnowledgeSourceEntry]) -> [KnowledgeEntry] {
        sources
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map(entry(from:))
            .sorted { $0.date > $1.date }
    }

    static func search(_ entries: [KnowledgeEntry], query: String, category: KnowledgeCategory? = nil) -> [KnowledgeEntry] {
        search(entries, filter: KnowledgeSearchFilter(query: query, category: category))
    }

    static func search(_ entries: [KnowledgeEntry], filter: KnowledgeSearchFilter) -> [KnowledgeEntry] {
        let normalizedQuery = filter.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedMood = filter.mood?.trimmingCharacters(in: .whitespacesAndNewlines)
        let calendar = Calendar.current
        return entries.filter { entry in
            if let category = filter.category, entry.category != category { return false }
            if let status = filter.status, entry.status != status { return false }
            if let month = filter.month, !calendar.isDate(entry.date, equalTo: month, toGranularity: .month) { return false }
            if let range = filter.timeRange {
                if let start = range.start, entry.date < calendar.startOfDay(for: start) { return false }
                if let end = range.end,
                   let inclusiveEnd = calendar.date(byAdding: DateComponents(day: 1, second: -1), to: calendar.startOfDay(for: end)),
                   entry.date > inclusiveEnd {
                    return false
                }
            }
            if let normalizedMood, !normalizedMood.isEmpty, entry.mood != normalizedMood { return false }
            guard !normalizedQuery.isEmpty else { return true }
            return entry.title.localizedCaseInsensitiveContains(normalizedQuery)
                || entry.summary.localizedCaseInsensitiveContains(normalizedQuery)
                || entry.sourceText.localizedCaseInsensitiveContains(normalizedQuery)
                || entry.category.title.localizedCaseInsensitiveContains(normalizedQuery)
                || entry.mood.localizedCaseInsensitiveContains(normalizedQuery)
                || entry.keywords.contains { $0.localizedCaseInsensitiveContains(normalizedQuery) }
        }
    }

    static func profile(from entries: [KnowledgeEntry]) -> KnowledgeProfile {
        let counts = Dictionary(grouping: entries, by: \.category).mapValues(\.count)
        let dominant = KnowledgeCategory.allCases
            .filter { $0 != .uncategorized }
            .sorted {
                let left = counts[$0, default: 0]
                let right = counts[$1, default: 0]
                if left == right { return $0.title < $1.title }
                return left > right
            }
            .first ?? .uncategorized

        let keywordCounts = entries
            .flatMap(\.keywords)
            .reduce(into: [String: Int]()) { partial, keyword in
                partial[keyword, default: 0] += 1
            }

        let topKeywords = keywordCounts
            .sorted {
                if $0.value == $1.value { return $0.key < $1.key }
                return $0.value > $1.value
            }
            .prefix(8)
            .map(\.key)

        return KnowledgeProfile(
            totalEntries: entries.count,
            totalWords: entries.reduce(0) { $0 + $1.wordCount },
            dominantCategory: entries.isEmpty ? .uncategorized : dominant,
            categoryCounts: counts,
            topKeywords: topKeywords
        )
    }

    static func trend(from entries: [KnowledgeEntry], filter: KnowledgeSearchFilter, granularity: KnowledgeTrendGranularity) -> [KnowledgeTrendPoint] {
        let filtered = search(entries, filter: filter)
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: filtered) { entry in
            bucketStart(for: entry.date, granularity: granularity, calendar: calendar)
        }
        return grouped.keys.sorted().map { start in
            let bucketEntries = grouped[start] ?? []
            return KnowledgeTrendPoint(
                bucketStart: start,
                title: trendTitle(for: start, granularity: granularity, calendar: calendar),
                entryCount: bucketEntries.count,
                wordCount: bucketEntries.reduce(0) { $0 + $1.wordCount }
            )
        }
    }

    static func categoryShares(from entries: [KnowledgeEntry], filter: KnowledgeSearchFilter) -> [KnowledgeCategoryShare] {
        let filtered = search(entries, filter: filter)
        guard !filtered.isEmpty else { return [] }
        let grouped = Dictionary(grouping: filtered, by: \.category)
        return grouped.map { category, categoryEntries in
            KnowledgeCategoryShare(
                category: category,
                entryCount: categoryEntries.count,
                wordCount: categoryEntries.reduce(0) { $0 + $1.wordCount },
                ratio: Double(categoryEntries.count) / Double(filtered.count)
            )
        }
        .sorted {
            if $0.entryCount == $1.entryCount { return $0.category.title < $1.category.title }
            return $0.entryCount > $1.entryCount
        }
    }

    static func keywordNetwork(
        from entries: [KnowledgeEntry],
        filter: KnowledgeSearchFilter,
        maxNodes: Int = 12,
        maxEdges: Int = 18
    ) -> KnowledgeKeywordNetwork {
        let filtered = search(entries, filter: filter)
        let keywordCounts = filtered
            .flatMap(\.keywords)
            .reduce(into: [String: Int]()) { partial, keyword in
                partial[keyword, default: 0] += 1
            }

        let nodes = keywordCounts
            .sorted {
                if $0.value == $1.value { return $0.key < $1.key }
                return $0.value > $1.value
            }
            .prefix(maxNodes)
            .map { KnowledgeKeywordNode(keyword: $0.key, count: $0.value) }

        let retained = Set(nodes.map(\.keyword))
        var edgeCounts: [String: (left: String, right: String, weight: Int)] = [:]
        for entry in filtered {
            let keywords = Array(Set(entry.keywords.filter { retained.contains($0) })).sorted()
            guard keywords.count >= 2 else { continue }
            for leftIndex in 0..<(keywords.count - 1) {
                for rightIndex in (leftIndex + 1)..<keywords.count {
                    let left = keywords[leftIndex]
                    let right = keywords[rightIndex]
                    let key = "\(left)|\(right)"
                    let current = edgeCounts[key]?.weight ?? 0
                    edgeCounts[key] = (left, right, current + 1)
                }
            }
        }

        let edges = edgeCounts.values
            .map { KnowledgeKeywordEdge(left: $0.left, right: $0.right, weight: $0.weight) }
            .sorted {
                if $0.weight == $1.weight {
                    if $0.left == $1.left { return $0.right < $1.right }
                    return $0.left < $1.left
                }
                return $0.weight > $1.weight
            }
            .prefix(maxEdges)

        return KnowledgeKeywordNetwork(nodes: nodes, edges: Array(edges))
    }

    static func applyEdits(to entry: KnowledgeEntry, category: KnowledgeCategory, keywords: [String]) -> KnowledgeEntry {
        var cleanedKeywords: [String] = []
        for keyword in keywords {
            appendKeyword(keyword, to: &cleanedKeywords)
            if cleanedKeywords.count == 6 { break }
        }
        return KnowledgeEntry(
            id: entry.id,
            date: entry.date,
            title: entry.title,
            summary: entry.summary,
            keywords: cleanedKeywords,
            category: category,
            mood: entry.mood,
            sourceText: entry.sourceText,
            wordCount: entry.wordCount,
            status: entry.status
        )
    }

    static func applyStatus(to entry: KnowledgeEntry, status: KnowledgeStatus) -> KnowledgeEntry {
        KnowledgeEntry(
            id: entry.id,
            date: entry.date,
            title: entry.title,
            summary: entry.summary,
            keywords: entry.keywords,
            category: entry.category,
            mood: entry.mood,
            sourceText: entry.sourceText,
            wordCount: entry.wordCount,
            status: status
        )
    }

    static func exportBundle(from entries: [KnowledgeEntry], category: KnowledgeCategory?, month: Date?) -> KnowledgeExportBundle {
        let filtered = entries
            .filter { entry in
                if let category, entry.category != category { return false }
                if let month, !Calendar.current.isDate(entry.date, equalTo: month, toGranularity: .month) { return false }
                return true
            }
            .sorted { $0.date > $1.date }

        let categoryTitle = category?.title ?? "全部分类"
        let monthTitle = month.map(monthDisplayText) ?? "全部月份"
        let title = "个人知识库 · \(categoryTitle) · \(monthTitle)"
        let filenameStem = "个人知识库-\(safeFilename(categoryTitle))-\(safeFilename(monthTitle))"
        let readableText = exportReadableText(title: title, entries: filtered)
        return KnowledgeExportBundle(title: title, filenameStem: filenameStem, readableText: readableText, entries: filtered)
    }

    static func exportBundle(from entries: [KnowledgeEntry], filter: KnowledgeSearchFilter, includeProfile: Bool) -> KnowledgeExportBundle {
        let filtered = search(entries, filter: filter).sorted { $0.date > $1.date }
        let scopeTitle = exportScopeTitle(filter: filter)
        let title = "个人知识库 · \(scopeTitle)"
        let filenameStem = "个人知识库-\(safeFilename(scopeTitle))"
        let readableText = exportReadableText(title: title, entries: filtered, filter: filter, includeProfile: includeProfile)
        return KnowledgeExportBundle(title: title, filenameStem: filenameStem, readableText: readableText, entries: filtered)
    }

    private static func entry(from source: KnowledgeSourceEntry) -> KnowledgeEntry {
        let text = normalize(source.text)
        let keywords = normalizedKeywords(existing: source.keywords, text: text)
        let category = category(for: text, keywords: keywords)
        let title = title(for: source, keywords: keywords, category: category)
        let summary = readableSummary(from: source.summary, fallback: text, category: category)

        return KnowledgeEntry(
            id: source.id,
            date: source.date,
            title: title,
            summary: summary,
            keywords: keywords,
            category: category,
            mood: source.mood,
            sourceText: text,
            wordCount: text.count,
            status: .inbox
        )
    }

    private static func category(for text: String, keywords: [String]) -> KnowledgeCategory {
        let haystack = ([text] + keywords).joined(separator: " ")
        let scores = categoryRules.map { category, tokens in
            (category, tokens.reduce(0) { $0 + (haystack.localizedCaseInsensitiveContains($1) ? 1 : 0) })
        }
        return scores.sorted {
            if $0.1 == $1.1 { return $0.0.title < $1.0.title }
            return $0.1 > $1.1
        }.first(where: { $0.1 > 0 })?.0 ?? .uncategorized
    }

    private static func normalizedKeywords(existing: [String], text: String) -> [String] {
        var result: [String] = []
        for keyword in existing {
            appendKeyword(keyword, to: &result)
            if result.count == 6 { return result }
        }

        let separators = CharacterSet.whitespacesAndNewlines
            .union(.punctuationCharacters)
            .union(CharacterSet(charactersIn: "，。！？、；：,.!?;:（）()【】[]《》<>“”\"'"))
        let fragments = text
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 2 }

        for fragment in fragments {
            if let semantic = semanticKeyword(from: fragment) {
                appendKeyword(semantic, to: &result)
                if result.count == 6 { return result }
            }
        }
        return result
    }

    private static func appendKeyword(_ keyword: String, to result: inout [String]) {
        let normalized = normalizeKeyword(keyword)
        guard normalized.count >= 2, normalized.count <= 8, !lowValueTokens.contains(normalized), !result.contains(normalized) else { return }
        result.append(normalized)
    }

    private static func semanticKeyword(from fragment: String) -> String? {
        let cleaned = normalizeKeyword(fragment)
        guard cleaned.count >= 2 else { return nil }
        if cleaned.count <= 8, !lowValueTokens.contains(cleaned) {
            return cleaned
        }
        for connector in ["以及", "进行", "需要", "关于", "针对", "和", "与", "的"] {
            let pieces = cleaned.components(separatedBy: connector).map(normalizeKeyword)
            if let piece = pieces.first(where: { $0.count >= 2 && $0.count <= 8 && !lowValueTokens.contains($0) }) {
                return piece
            }
        }
        return nil
    }

    private static func title(for source: KnowledgeSourceEntry, keywords: [String], category: KnowledgeCategory) -> String {
        if let keyword = keywords.first {
            return "\(category.title) · \(keyword)"
        }
        let firstLine = source.text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? category.title
        return firstLine.count <= 18 ? firstLine : String(firstLine.prefix(18)) + "..."
    }

    private static func readableSummary(from summary: String, fallback text: String, category: KnowledgeCategory) -> String {
        let candidate = normalize(summary.isEmpty ? text : summary)
        guard !candidate.isEmpty else { return "\(category.title)知识点待补充。" }
        if candidate.count <= 72 { return candidate }
        return String(candidate.prefix(72)) + "..."
    }

    private static func normalize(_ text: String) -> String {
        text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizeKeyword(_ keyword: String) -> String {
        var result = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        result = result.replacingOccurrences(of: #"^[0-9一二三四五六七八九十]+[\.、\)]"#, with: "", options: .regularExpression)
        return result.trimmingCharacters(in: CharacterSet(charactersIn: "：:，,。.!！?？、；;（）()【】[]《》<>“”\"' "))
    }

    private static func monthDisplayText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.dateFormat = "yyyy年M月"
        return formatter.string(from: date)
    }

    private static func bucketStart(for date: Date, granularity: KnowledgeTrendGranularity, calendar: Calendar) -> Date {
        switch granularity {
        case .day:
            return calendar.startOfDay(for: date)
        case .month:
            let components = calendar.dateComponents([.year, .month], from: date)
            return calendar.date(from: components) ?? calendar.startOfDay(for: date)
        case .quarter:
            let components = calendar.dateComponents([.year, .month], from: date)
            let month = components.month ?? 1
            let quarterStartMonth = ((month - 1) / 3) * 3 + 1
            return calendar.date(from: DateComponents(year: components.year, month: quarterStartMonth)) ?? calendar.startOfDay(for: date)
        case .year:
            let components = calendar.dateComponents([.year], from: date)
            return calendar.date(from: components) ?? calendar.startOfDay(for: date)
        }
    }

    private static func trendTitle(for date: Date, granularity: KnowledgeTrendGranularity, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        switch granularity {
        case .day:
            formatter.dateFormat = "M月d日"
            return formatter.string(from: date)
        case .month:
            formatter.dateFormat = "yyyy年M月"
            return formatter.string(from: date)
        case .quarter:
            let year = calendar.component(.year, from: date)
            let quarter = ((calendar.component(.month, from: date) - 1) / 3) + 1
            return "\(year) Q\(quarter)"
        case .year:
            return "\(calendar.component(.year, from: date))"
        }
    }

    private static func exportReadableText(title: String, entries: [KnowledgeEntry]) -> String {
        exportReadableText(title: title, entries: entries, filter: nil, includeProfile: false)
    }

    private static func exportReadableText(title: String, entries: [KnowledgeEntry], filter: KnowledgeSearchFilter?, includeProfile: Bool) -> String {
        guard !entries.isEmpty else {
            let filterText = filter.map { "\n筛选条件：\(filterDescription($0))\n" } ?? ""
            return """
            \(title)
            \(filterText)

            暂无匹配的知识条目。
            """
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.dateFormat = "yyyy年M月d日"

        let body = entries.enumerated().map { index, entry in
            let keywords = entry.keywords.isEmpty ? "暂无" : entry.keywords.joined(separator: "、")
            return """
            \(index + 1). \(entry.title)
            日期：\(formatter.string(from: entry.date))
            分类：\(entry.category.title)
            心情：\(entry.mood)
            关键词：\(keywords)

            摘要：
            \(entry.summary)

            正文：
            \(entry.sourceText)
            """
        }.joined(separator: "\n\n---\n\n")

        let filterText = filter.map { "\n筛选条件：\(filterDescription($0))" } ?? ""
        let profileText: String
        if includeProfile {
            let profile = profile(from: entries)
            let keywords = profile.topKeywords.isEmpty ? "暂无" : profile.topKeywords.joined(separator: "、")
            profileText = """

            知识画像：
            主要类型：\(profile.dominantCategory.title)
            高频关键词：\(keywords)
            """
        } else {
            profileText = ""
        }

        return """
        \(title)
        \(filterText)

        共 \(entries.count) 条知识，\(entries.reduce(0) { $0 + $1.wordCount }) 字。
        \(profileText)

        \(body)
        """
    }

    private static func exportScopeTitle(filter: KnowledgeSearchFilter) -> String {
        var parts: [String] = []
        if let category = filter.category {
            parts.append(category.title)
        } else {
            parts.append("全部分类")
        }
        if let month = filter.month {
            parts.append(monthDisplayText(month))
        }
        if let range = filter.timeRange {
            parts.append(timeRangeDisplayText(range))
        }
        if let mood = filter.mood?.trimmingCharacters(in: .whitespacesAndNewlines), !mood.isEmpty {
            parts.append("心情-\(mood)")
        }
        let query = filter.query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            parts.append("搜索-\(query)")
        }
        return parts.joined(separator: "-")
    }

    private static func filterDescription(_ filter: KnowledgeSearchFilter) -> String {
        var parts: [String] = []
        if let category = filter.category { parts.append("分类 \(category.title)") }
        if let month = filter.month { parts.append("月份 \(monthDisplayText(month))") }
        if let range = filter.timeRange { parts.append("时间 \(timeRangeDisplayText(range))") }
        if let mood = filter.mood?.trimmingCharacters(in: .whitespacesAndNewlines), !mood.isEmpty { parts.append("心情 \(mood)") }
        let query = filter.query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty { parts.append("关键词 \(query)") }
        return parts.isEmpty ? "全部知识" : parts.joined(separator: "；")
    }

    private static func timeRangeDisplayText(_ range: KnowledgeTimeRange) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.dateFormat = "yyyy年M月d日"
        switch (range.start, range.end) {
        case let (start?, end?):
            return "\(formatter.string(from: start))至\(formatter.string(from: end))"
        case let (start?, nil):
            return "\(formatter.string(from: start))之后"
        case let (nil, end?):
            return "\(formatter.string(from: end))之前"
        default:
            return "全部时间"
        }
    }

    private static func safeFilename(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        return value
            .components(separatedBy: invalid)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
