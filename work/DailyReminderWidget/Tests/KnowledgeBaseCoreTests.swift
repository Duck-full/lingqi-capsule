import Foundation

@main
struct KnowledgeBaseCoreTests {
    static func main() {
        testBuildsCategorizedKnowledgeEntries()
        testSearchMatchesKeywordCategoryAndBody()
        testProfileAggregatesTopDimensions()
        testAppliesManualCategoryAndEditedTags()
        testCreatesBatchExportBundleByCategoryAndMonth()
        testCombinedSearchFiltersByQueryCategoryTimeRangeAndMood()
        testTrendAggregatesByDayWithReadableChineseDate()
        testTrendAxisLabelKeepsMonthUnitForDailyView()
        testTrendAggregatesByMonth()
        testTrendAggregatesByQuarterAndYear()
        testCategorySharesSortAndRatio()
        testKeywordNetworkBuildsCoOccurrenceEdges()
        testExportBundleIncludesFilterAndProfileContext()
        testLargeKnowledgeSetKeepsAggregationsBounded()
        print("KnowledgeBaseCoreTests passed")
    }

    private static func testBuildsCategorizedKnowledgeEntries() {
        let source = KnowledgeSourceEntry(
            date: fixedDate("2026-06-01"),
            text: "今天梳理了产品体验和视觉优化方案，重点处理首页层级、按钮状态与用户路径。",
            keywords: ["产品体验", "视觉优化"],
            summary: "围绕产品体验做了设计整理。",
            mood: "专注"
        )

        let entries = KnowledgeBaseService.entries(from: [source])

        assert(entries.count == 1, "expected one knowledge entry")
        assert(entries[0].category == .productDesign, "expected product design category")
        assert(entries[0].keywords.contains("产品体验"), "expected existing keyword to be preserved")
        assert(entries[0].summary.contains("产品体验"), "expected readable summary")
    }

    private static func testSearchMatchesKeywordCategoryAndBody() {
        let sources = [
            KnowledgeSourceEntry(
                date: fixedDate("2026-06-02"),
                text: "补充了 macOS 通知、打包、签名和性能日志相关实现。",
                keywords: ["性能日志"],
                summary: "完成工程实现。",
                mood: "专注"
            ),
            KnowledgeSourceEntry(
                date: fixedDate("2026-06-03"),
                text: "记录了一次散步和休息后的状态，整体更平静。",
                keywords: ["休息"],
                summary: "生活记录。",
                mood: "松弛"
            )
        ]

        let entries = KnowledgeBaseService.entries(from: sources)
        let results = KnowledgeBaseService.search(entries, query: "工程")

        assert(results.count == 1, "expected one engineering search result")
        assert(results[0].category == .engineering, "expected engineering category")
    }

    private static func testProfileAggregatesTopDimensions() {
        let entries = KnowledgeBaseService.entries(from: [
            KnowledgeSourceEntry(
                date: fixedDate("2026-06-04"),
                text: "需求排期、项目复盘和版本计划需要继续沉淀。",
                keywords: ["需求排期", "版本计划"],
                summary: "项目管理记录。",
                mood: "专注"
            ),
            KnowledgeSourceEntry(
                date: fixedDate("2026-06-05"),
                text: "继续整理需求文档和项目目标。",
                keywords: ["需求文档"],
                summary: "项目推进。",
                mood: "平稳"
            )
        ])

        let profile = KnowledgeBaseService.profile(from: entries)

        assert(profile.totalEntries == 2, "expected two profile entries")
        assert(profile.dominantCategory == .projectManagement, "expected dominant project category")
        assert(profile.topKeywords.contains("需求排期") || profile.topKeywords.contains("需求文档"), "expected project keyword")
    }

    private static func testAppliesManualCategoryAndEditedTags() {
        let entry = KnowledgeBaseService.entries(from: [
            KnowledgeSourceEntry(
                date: fixedDate("2026-06-06"),
                text: "今天把首页视觉层级和输入体验重新梳理，形成下一轮实现计划。",
                keywords: ["视觉层级"],
                summary: "视觉体验记录。",
                mood: "平稳"
            )
        ])[0]

        let edited = KnowledgeBaseService.applyEdits(
            to: entry,
            category: .engineering,
            keywords: ["架构设计", "性能优化", "架构设计", "A"]
        )

        assert(edited.category == .engineering, "expected manual category override")
        assert(edited.keywords == ["架构设计", "性能优化"], "expected cleaned unique edited tags")
        assert(edited.sourceText == entry.sourceText, "expected full source text to be preserved")
        assert(edited.summary == entry.summary, "expected summary to be preserved")
    }

    private static func testCreatesBatchExportBundleByCategoryAndMonth() {
        let entries = KnowledgeBaseService.entries(from: [
            KnowledgeSourceEntry(
                date: fixedDate("2026-06-10"),
                text: "完成 SwiftUI 性能日志、构建脚本和打包流程整理。",
                keywords: ["性能日志"],
                summary: "工程记录。",
                mood: "专注"
            ),
            KnowledgeSourceEntry(
                date: fixedDate("2026-07-01"),
                text: "继续整理 SwiftUI 构建与发布方案。",
                keywords: ["发布方案"],
                summary: "七月工程记录。",
                mood: "专注"
            ),
            KnowledgeSourceEntry(
                date: fixedDate("2026-06-11"),
                text: "优化产品体验和页面留白。",
                keywords: ["产品体验"],
                summary: "产品设计记录。",
                mood: "平稳"
            )
        ])

        let bundle = KnowledgeBaseService.exportBundle(
            from: entries,
            category: .engineering,
            month: fixedDate("2026-06-01")
        )

        assert(bundle.entries.count == 1, "expected one June engineering entry")
        assert(bundle.title.contains("工程技术"), "expected category in export title")
        assert(bundle.title.contains("2026年6月"), "expected month in export title")
        assert(bundle.readableText.contains("性能日志"), "expected entry keyword in readable export")
        assert(!bundle.readableText.contains("产品体验"), "expected product entry to be excluded")
    }

    private static func testCombinedSearchFiltersByQueryCategoryTimeRangeAndMood() {
        let entries = KnowledgeBaseService.entries(from: [
            KnowledgeSourceEntry(
                date: fixedDate("2026-06-12"),
                text: "今天完成 SwiftUI 知识库搜索增强和性能测试计划。",
                keywords: ["SwiftUI", "搜索增强"],
                summary: "工程知识记录。",
                mood: "专注"
            ),
            KnowledgeSourceEntry(
                date: fixedDate("2026-07-12"),
                text: "继续整理 SwiftUI 构建方案。",
                keywords: ["SwiftUI"],
                summary: "七月工程记录。",
                mood: "专注"
            ),
            KnowledgeSourceEntry(
                date: fixedDate("2026-06-13"),
                text: "今天梳理产品视觉体验。",
                keywords: ["产品体验"],
                summary: "产品记录。",
                mood: "平稳"
            )
        ])

        let filtered = KnowledgeBaseService.search(entries, filter: KnowledgeSearchFilter(
            query: "SwiftUI",
            category: .engineering,
            month: nil,
            timeRange: KnowledgeTimeRange(start: fixedDate("2026-06-01"), end: fixedDate("2026-06-30")),
            mood: "专注"
        ))

        assert(filtered.count == 1, "expected one combined search result")
        assert(filtered[0].keywords.contains("SwiftUI"), "expected SwiftUI result")
    }

    private static func testTrendAggregatesByMonth() {
        let entries = KnowledgeBaseService.entries(from: [
            KnowledgeSourceEntry(date: fixedDate("2026-06-01"), text: "SwiftUI 性能优化记录。", keywords: ["SwiftUI"], summary: "工程", mood: "专注"),
            KnowledgeSourceEntry(date: fixedDate("2026-06-15"), text: "SwiftUI 构建脚本整理。", keywords: ["构建脚本"], summary: "工程", mood: "专注"),
            KnowledgeSourceEntry(date: fixedDate("2026-07-01"), text: "七月继续沉淀知识库。", keywords: ["知识库"], summary: "成长", mood: "平稳")
        ])

        let points = KnowledgeBaseService.trend(from: entries, filter: KnowledgeSearchFilter(), granularity: .month)

        assert(points.count == 2, "expected two monthly trend points")
        assert(points[0].title == "2026年6月", "expected June first")
        assert(points[0].entryCount == 2, "expected two June entries")
        assert(points[0].wordCount > 0, "expected June word total")
    }

    private static func testTrendAggregatesByDayWithReadableChineseDate() {
        let entries = KnowledgeBaseService.entries(from: [
            KnowledgeSourceEntry(date: fixedDate("2026-06-14"), text: "今天整理知识库日维度趋势。", keywords: ["知识库"], summary: "趋势", mood: "专注"),
            KnowledgeSourceEntry(date: fixedDate("2026-06-15"), text: "继续补充日维度展示格式。", keywords: ["展示格式"], summary: "趋势", mood: "平稳")
        ])

        let points = KnowledgeBaseService.trend(from: entries, filter: KnowledgeSearchFilter(), granularity: .day)

        assert(points.map(\.title) == ["6月14日", "6月15日"], "expected readable M月d日 daily trend labels")
        assert(points.map(\.entryCount) == [1, 1], "expected daily entry counts")
    }

    private static func testTrendAxisLabelKeepsMonthUnitForDailyView() {
        assert(
            KnowledgeTrendAxisLabelFormatter.shortTitle("6月14日", granularity: .day) == "6月14日",
            "expected daily axis labels to keep month and day units"
        )
        assert(
            KnowledgeTrendAxisLabelFormatter.shortTitle("2026年6月", granularity: .month) == "6月",
            "expected monthly axis labels to remove only the year prefix"
        )
        assert(
            KnowledgeTrendAxisLabelFormatter.shortTitle("2028年12月", granularity: .month) == "12月",
            "expected monthly axis labels to handle future years"
        )
    }

    private static func testTrendAggregatesByQuarterAndYear() {
        let entries = KnowledgeBaseService.entries(from: [
            KnowledgeSourceEntry(date: fixedDate("2026-01-10"), text: "一月沉淀产品体验和项目推进。", keywords: ["产品体验"], summary: "产品", mood: "平稳"),
            KnowledgeSourceEntry(date: fixedDate("2026-03-20"), text: "三月继续整理知识库与复盘。", keywords: ["知识库"], summary: "成长", mood: "专注"),
            KnowledgeSourceEntry(date: fixedDate("2026-04-05"), text: "四月补充工程技术实现记录。", keywords: ["工程技术"], summary: "工程", mood: "专注"),
            KnowledgeSourceEntry(date: fixedDate("2027-01-02"), text: "新一年继续维护个人知识库。", keywords: ["个人知识库"], summary: "成长", mood: "平稳")
        ])

        let quarterPoints = KnowledgeBaseService.trend(from: entries, filter: KnowledgeSearchFilter(), granularity: .quarter)
        let yearPoints = KnowledgeBaseService.trend(from: entries, filter: KnowledgeSearchFilter(), granularity: .year)

        assert(quarterPoints.map(\.title) == ["2026 Q1", "2026 Q2", "2027 Q1"], "expected quarter trend buckets")
        assert(quarterPoints.map(\.entryCount) == [2, 1, 1], "expected quarter entry counts")
        assert(yearPoints.map(\.title) == ["2026", "2027"], "expected year trend buckets")
        assert(yearPoints.map(\.entryCount) == [3, 1], "expected year entry counts")
    }

    private static func testCategorySharesSortAndRatio() {
        let entries = KnowledgeBaseService.entries(from: [
            KnowledgeSourceEntry(date: fixedDate("2026-06-01"), text: "SwiftUI 性能优化和构建脚本。", keywords: ["SwiftUI"], summary: "工程", mood: "专注"),
            KnowledgeSourceEntry(date: fixedDate("2026-06-02"), text: "macOS 通知和打包签名。", keywords: ["通知"], summary: "工程", mood: "专注"),
            KnowledgeSourceEntry(date: fixedDate("2026-06-03"), text: "产品体验和页面留白优化。", keywords: ["产品体验"], summary: "产品", mood: "平稳")
        ])

        let shares = KnowledgeBaseService.categoryShares(from: entries, filter: KnowledgeSearchFilter())

        assert(shares.count >= 2, "expected at least two category shares")
        assert(shares[0].category == .engineering, "expected engineering first")
        assert(abs(shares[0].ratio - (2.0 / 3.0)) < 0.001, "expected engineering ratio")
    }

    private static func testKeywordNetworkBuildsCoOccurrenceEdges() {
        let entries = KnowledgeBaseService.entries(from: [
            KnowledgeSourceEntry(date: fixedDate("2026-06-01"), text: "模型中心和知识库继续完善。", keywords: ["模型中心", "知识库", "数据标注"], summary: "工程", mood: "专注"),
            KnowledgeSourceEntry(date: fixedDate("2026-06-02"), text: "模型中心和知识库完成联动。", keywords: ["模型中心", "知识库", "联动"], summary: "工程", mood: "专注")
        ])

        let network = KnowledgeBaseService.keywordNetwork(from: entries, filter: KnowledgeSearchFilter(), maxNodes: 3, maxEdges: 2)

        assert(network.nodes.count <= 3, "expected capped keyword nodes")
        assert(network.edges.count <= 2, "expected capped keyword edges")
        assert(network.nodes.contains { $0.keyword == "模型中心" }, "expected model center node")
        assert(network.nodes.contains { $0.keyword == "知识库" }, "expected knowledge base node")
        assert(network.edges.contains { $0.left == "模型中心" && $0.right == "知识库" && $0.weight == 2 }, "expected co-occurrence edge")
    }

    private static func testExportBundleIncludesFilterAndProfileContext() {
        let entries = KnowledgeBaseService.entries(from: [
            KnowledgeSourceEntry(date: fixedDate("2026-06-01"), text: "SwiftUI 性能优化和知识库搜索增强。", keywords: ["SwiftUI", "搜索增强"], summary: "工程", mood: "专注"),
            KnowledgeSourceEntry(date: fixedDate("2026-06-02"), text: "产品体验和页面留白优化。", keywords: ["产品体验"], summary: "产品", mood: "平稳")
        ])

        let bundle = KnowledgeBaseService.exportBundle(
            from: entries,
            filter: KnowledgeSearchFilter(query: "", category: .engineering, month: nil, timeRange: nil, mood: "专注"),
            includeProfile: true
        )

        assert(bundle.entries.count == 1, "expected filtered export entry")
        assert(bundle.readableText.contains("筛选条件"), "expected filter context")
        assert(bundle.readableText.contains("工程技术"), "expected category context")
        assert(bundle.readableText.contains("专注"), "expected mood context")
        assert(bundle.readableText.contains("SwiftUI"), "expected profile keyword context")
    }

    private static func testLargeKnowledgeSetKeepsAggregationsBounded() {
        let calendar = Calendar(identifier: .gregorian)
        let start = fixedDate("2026-01-01")
        let sources = (0..<5_000).map { index in
            let date = calendar.date(byAdding: .day, value: index % 365, to: start)!
            let keyword = index.isMultiple(of: 2) ? "模型中心" : "产品体验"
            return KnowledgeSourceEntry(
                date: date,
                text: "第\(index)条知识记录，围绕\(keyword)、知识库、搜索增强进行沉淀。",
                keywords: [keyword, "知识库", "搜索增强"],
                summary: "批量知识沉淀。",
                mood: index.isMultiple(of: 3) ? "专注" : "平稳"
            )
        }

        let entries = KnowledgeBaseService.entries(from: sources)
        let filter = KnowledgeSearchFilter(query: "知识库", category: nil, month: nil, timeRange: nil, mood: nil)
        let searched = KnowledgeBaseService.search(entries, filter: filter)
        let trend = KnowledgeBaseService.trend(from: entries, filter: filter, granularity: .month)
        let shares = KnowledgeBaseService.categoryShares(from: entries, filter: filter)
        let network = KnowledgeBaseService.keywordNetwork(from: entries, filter: filter, maxNodes: 4, maxEdges: 4)

        assert(entries.count == 5_000, "expected all generated entries")
        assert(!searched.isEmpty, "expected searchable large data")
        assert(trend.count <= 12, "expected monthly trend bounded by one year")
        assert(!shares.isEmpty, "expected category shares")
        assert(network.nodes.count <= 4, "expected bounded nodes")
        assert(network.edges.count <= 4, "expected bounded edges")
    }

    private static func fixedDate(_ value: String) -> Date {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.date(from: value)!
    }
}
