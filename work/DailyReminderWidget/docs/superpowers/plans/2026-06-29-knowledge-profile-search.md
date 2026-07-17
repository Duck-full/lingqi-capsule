# Knowledge Profile Search Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use test-driven-development before changing code, verification-before-completion before claiming done, and requesting-code-review after implementation.

**Goal:** Upgrade the personal knowledge base with time trends, category distribution, keyword network visualization, and stronger combined search filters for time range and mood.

**Architecture:** Keep knowledge domain logic in `Sources/KnowledgeBaseCore.swift`, extend existing pure Swift tests in `Tests/KnowledgeBaseCoreTests.swift`, then bind the new computed results into `KnowledgeBaseView` inside `Sources/DailyReminderWidget.swift`. UI should stay declarative; filtering and aggregation must not be implemented inside SwiftUI view bodies.

**Tech Stack:** Swift 5, SwiftUI, AppKit export helpers already present in `DailyReminderWidget.swift`, existing shell build through `./build.sh`, pure Swift test binary through `swiftc`.

## Global Constraints

- Do not remove or rewrite existing knowledge detail editing, category/tag override, Word/PDF export, history capsule, reminder, weather, theme, or menu bar features.
- Keep existing `KnowledgeBaseService.search(_:, query:, category:)` and `exportBundle(from:category:month:)` as compatibility wrappers.
- Avoid runtime-heavy work in SwiftUI `body`; compute filter results, profile snapshots, trend points, category shares, and keyword network in explicit reload functions.
- Preserve current local-first behavior and UserDefaults overrides.
- No network API, AI model call, or cloud dependency in this version.
- Existing uncommitted files in the worktree are part of the current local baseline. Stage only task-specific files when committing.

---

## Task 1: Add Combined Filter Model

**Files:**
- Modify: `/Users/zhangaozhe/Documents/Codex/2026-06-13/1-2-3-4-intel-mac/work/DailyReminderWidget/Sources/KnowledgeBaseCore.swift`
- Modify: `/Users/zhangaozhe/Documents/Codex/2026-06-13/1-2-3-4-intel-mac/work/DailyReminderWidget/Tests/KnowledgeBaseCoreTests.swift`

**Implementation:**
Add filter structures near the knowledge models:

```swift
struct KnowledgeTimeRange: Codable, Equatable {
    let start: Date?
    let end: Date?
}

struct KnowledgeSearchFilter: Codable, Equatable {
    var query: String = ""
    var category: KnowledgeCategory?
    var month: Date?
    var timeRange: KnowledgeTimeRange?
    var mood: String?
}
```

Add a new overload:

```swift
static func search(_ entries: [KnowledgeEntry], filter: KnowledgeSearchFilter) -> [KnowledgeEntry]
```

Rules:
- `query` matches title, summary, source text, category title, mood, and keywords.
- `category` filters exact category.
- `month` keeps current month behavior.
- `timeRange.start` is inclusive at start of day.
- `timeRange.end` is inclusive through end of day.
- `mood` matches exact mood after trimming; empty mood means no filter.
- Existing `search(_:, query:, category:)` calls the new overload.

**Tests first:**
Add `testCombinedSearchFiltersByQueryCategoryTimeRangeAndMood()`:

```swift
let filtered = KnowledgeBaseService.search(entries, filter: KnowledgeSearchFilter(
    query: "SwiftUI",
    category: .engineering,
    month: nil,
    timeRange: KnowledgeTimeRange(start: fixedDate("2026-06-01"), end: fixedDate("2026-06-30")),
    mood: "专注"
))
assert(filtered.count == 1)
```

**Verification:**
Run:

```bash
swiftc Sources/KnowledgeBaseCore.swift Tests/KnowledgeBaseCoreTests.swift -o /tmp/KnowledgeBaseCoreTests && /tmp/KnowledgeBaseCoreTests
```

Expected before implementation: compile failure for missing types/functions.
Expected after implementation: test binary prints `KnowledgeBaseCoreTests passed`.

---

## Task 2: Add Time Trend Aggregation

**Files:**
- Modify: `/Users/zhangaozhe/Documents/Codex/2026-06-13/1-2-3-4-intel-mac/work/DailyReminderWidget/Sources/KnowledgeBaseCore.swift`
- Modify: `/Users/zhangaozhe/Documents/Codex/2026-06-13/1-2-3-4-intel-mac/work/DailyReminderWidget/Tests/KnowledgeBaseCoreTests.swift`

**Implementation:**
Add trend types:

```swift
enum KnowledgeTrendGranularity: String, Codable, CaseIterable {
    case day
    case week
    case month
}

struct KnowledgeTrendPoint: Equatable {
    let bucketStart: Date
    let title: String
    let entryCount: Int
    let wordCount: Int
}
```

Add service method:

```swift
static func trend(from entries: [KnowledgeEntry], filter: KnowledgeSearchFilter, granularity: KnowledgeTrendGranularity) -> [KnowledgeTrendPoint]
```

Rules:
- Apply `search(entries, filter:)` first.
- Bucket with `Calendar.current` by day, weekOfYear/yearForWeekOfYear, or month.
- Sort ascending by `bucketStart`.
- `title` uses Chinese display text:
  - day: `M月d日`
  - week: `yyyy年第w周`
  - month: `yyyy年M月`

**Tests first:**
Add `testTrendAggregatesByMonth()`:
- Build entries across June and July.
- Assert two trend points.
- Assert June count and word totals.

**Verification:**

```bash
swiftc Sources/KnowledgeBaseCore.swift Tests/KnowledgeBaseCoreTests.swift -o /tmp/KnowledgeBaseCoreTests && /tmp/KnowledgeBaseCoreTests
```

---

## Task 3: Add Category Share Aggregation

**Files:**
- Modify: `/Users/zhangaozhe/Documents/Codex/2026-06-13/1-2-3-4-intel-mac/work/DailyReminderWidget/Sources/KnowledgeBaseCore.swift`
- Modify: `/Users/zhangaozhe/Documents/Codex/2026-06-13/1-2-3-4-intel-mac/work/DailyReminderWidget/Tests/KnowledgeBaseCoreTests.swift`

**Implementation:**
Add:

```swift
struct KnowledgeCategoryShare: Equatable {
    let category: KnowledgeCategory
    let entryCount: Int
    let wordCount: Int
    let ratio: Double
}
```

Add:

```swift
static func categoryShares(from entries: [KnowledgeEntry], filter: KnowledgeSearchFilter) -> [KnowledgeCategoryShare]
```

Rules:
- Apply combined filter first.
- Include only categories with count > 0.
- Sort by `entryCount` descending, then category title.
- Ratio is `Double(entryCount) / Double(filtered.count)`, or `0` when empty.

**Tests first:**
Add `testCategorySharesSortAndRatio()`:
- Build 3 entries with two in engineering and one in product design.
- Assert engineering first and ratio near `2.0 / 3.0`.

**Verification:**

```bash
swiftc Sources/KnowledgeBaseCore.swift Tests/KnowledgeBaseCoreTests.swift -o /tmp/KnowledgeBaseCoreTests && /tmp/KnowledgeBaseCoreTests
```

---

## Task 4: Add Keyword Network Aggregation

**Files:**
- Modify: `/Users/zhangaozhe/Documents/Codex/2026-06-13/1-2-3-4-intel-mac/work/DailyReminderWidget/Sources/KnowledgeBaseCore.swift`
- Modify: `/Users/zhangaozhe/Documents/Codex/2026-06-13/1-2-3-4-intel-mac/work/DailyReminderWidget/Tests/KnowledgeBaseCoreTests.swift`

**Implementation:**
Add:

```swift
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
```

Add:

```swift
static func keywordNetwork(from entries: [KnowledgeEntry], filter: KnowledgeSearchFilter, maxNodes: Int = 12, maxEdges: Int = 18) -> KnowledgeKeywordNetwork
```

Rules:
- Apply combined filter first.
- Count keyword frequency across entries.
- Nodes: top `maxNodes` keywords by count descending then keyword ascending.
- Edges: for each entry, create unordered keyword pairs among retained nodes; weight is co-occurrence count.
- Sort edges by weight descending, then `left`, then `right`; cap to `maxEdges`.
- Ignore entries with fewer than two retained keywords.

**Tests first:**
Add `testKeywordNetworkBuildsCoOccurrenceEdges()`:
- Two entries share `模型中心` + `知识库`.
- Assert both nodes exist and edge weight is 2.
- Assert caps are respected.

**Verification:**

```bash
swiftc Sources/KnowledgeBaseCore.swift Tests/KnowledgeBaseCoreTests.swift -o /tmp/KnowledgeBaseCoreTests && /tmp/KnowledgeBaseCoreTests
```

---

## Task 5: Extend Export Bundle With Filter/Profile Context

**Files:**
- Modify: `/Users/zhangaozhe/Documents/Codex/2026-06-13/1-2-3-4-intel-mac/work/DailyReminderWidget/Sources/KnowledgeBaseCore.swift`
- Modify: `/Users/zhangaozhe/Documents/Codex/2026-06-13/1-2-3-4-intel-mac/work/DailyReminderWidget/Tests/KnowledgeBaseCoreTests.swift`

**Implementation:**
Keep existing export function. Add a new wrapper:

```swift
static func exportBundle(from entries: [KnowledgeEntry], filter: KnowledgeSearchFilter, includeProfile: Bool) -> KnowledgeExportBundle
```

Rules:
- Use `search(entries, filter:)`.
- Title should include active category/month/time range when available.
- `readableText` starts with:
  - title
  - count and word total
  - active filters
  - if `includeProfile`, dominant category and top keywords
- Existing `exportBundle(from:category:month:)` remains as compatibility.

**Tests first:**
Add `testExportBundleIncludesFilterAndProfileContext()`:
- Export by category + mood.
- Assert readable text contains `筛选条件`, category title, mood, top keyword, and matching entry.

**Verification:**

```bash
swiftc Sources/KnowledgeBaseCore.swift Tests/KnowledgeBaseCoreTests.swift -o /tmp/KnowledgeBaseCoreTests && /tmp/KnowledgeBaseCoreTests
```

---

## Task 6: Replace KnowledgeBaseView Filter State With Combined Filter

**Files:**
- Modify: `/Users/zhangaozhe/Documents/Codex/2026-06-13/1-2-3-4-intel-mac/work/DailyReminderWidget/Sources/DailyReminderWidget.swift`

**Implementation:**
In `KnowledgeBaseView`:
- Replace separate filtering path with a `KnowledgeSearchFilter` state or computed filter:

```swift
@State private var query = ""
@State private var selectedCategory: KnowledgeCategory?
@State private var selectedMonth: KnowledgeMonthFilter?
@State private var selectedMood: String?
@State private var selectedTimeRange: KnowledgeQuickTimeRange = .all
```

Add computed:

```swift
private var activeFilter: KnowledgeSearchFilter { ... }
private var filteredEntries: [KnowledgeEntry] {
    KnowledgeBaseService.search(entries, filter: activeFilter)
}
```

Add a local UI enum:

```swift
private enum KnowledgeQuickTimeRange: String, CaseIterable, Identifiable {
    case all
    case sevenDays
    case thirtyDays
    case thisMonth
    case custom
}
```

UI changes:
- Keep the search field.
- Add compact filter rows:
  - Category chips
  - Time range chips: 全部、近7天、近30天、本月
  - Mood chips derived from available entries.
  - Clear filters button appears only when any filter is active.

Export changes:
- `exportBatchWord()` and `exportBatchPDF()` call the new filter-based export with `includeProfile: true`.

**Manual checks:**
- Search by text still works.
- Existing category and month chips still work.
- Clearing filters returns all entries.
- Export buttons remain disabled when no filtered entries.

---

## Task 7: Add Knowledge Profile Dashboard UI

**Files:**
- Modify: `/Users/zhangaozhe/Documents/Codex/2026-06-13/1-2-3-4-intel-mac/work/DailyReminderWidget/Sources/DailyReminderWidget.swift`

**Implementation:**
Add view structs near existing knowledge UI components:

```swift
struct KnowledgeTrendCard: View { ... }
struct KnowledgeCategoryShareCard: View { ... }
struct KnowledgeKeywordNetworkCard: View { ... }
```

Data state in `KnowledgeBaseView`:

```swift
@State private var trendPoints: [KnowledgeTrendPoint] = []
@State private var categoryShares: [KnowledgeCategoryShare] = []
@State private var keywordNetwork = KnowledgeKeywordNetwork(nodes: [], edges: [])
```

Update snapshots inside `reloadKnowledge()` and on filter state changes:

```swift
private func refreshKnowledgeDerivedState() {
    profileSnapshot = KnowledgeBaseService.profile(from: filteredEntries)
    trendPoints = KnowledgeBaseService.trend(from: entries, filter: activeFilter, granularity: .month)
    categoryShares = KnowledgeBaseService.categoryShares(from: entries, filter: activeFilter)
    keywordNetwork = KnowledgeBaseService.keywordNetwork(from: entries, filter: activeFilter)
}
```

UI behavior:
- Trend card: simple bar/line visualization using SwiftUI rectangles and labels, no external chart dependency.
- Category share card: horizontal stacked/row bars with category, count, percentage.
- Keyword network card: nodes as semantic pills; top edges shown as `关键词 A · 关键词 B · n次`; tapping a node sets query to that keyword.
- Empty states are explicit and small.

Performance constraints:
- Do not animate all bars on every keystroke.
- Avoid `GeometryReader` inside large `ForEach` lists unless needed.
- Cap keyword nodes/edges per service defaults.

**Manual checks:**
- Profile cards update when category/time/mood filters change.
- Keyword pill tap filters results.
- Empty knowledge base does not crash and displays empty state.

---

## Task 8: Add Stress-Oriented Pure Swift Test

**Files:**
- Modify: `/Users/zhangaozhe/Documents/Codex/2026-06-13/1-2-3-4-intel-mac/work/DailyReminderWidget/Tests/KnowledgeBaseCoreTests.swift`

**Implementation:**
Add `testLargeKnowledgeSetKeepsAggregationsBounded()`:
- Generate 5,000 `KnowledgeSourceEntry` values across 365 days.
- Build entries.
- Run combined search, trend, category shares, keyword network.
- Assert:
  - entries count is 5,000
  - trend points count is reasonable for selected granularity
  - keyword nodes <= maxNodes
  - keyword edges <= maxEdges
  - search results are non-empty for a known term

Avoid brittle wall-clock assertions. The goal is deterministic behavior and bounded output size.

**Verification:**

```bash
swiftc Sources/KnowledgeBaseCore.swift Tests/KnowledgeBaseCoreTests.swift -o /tmp/KnowledgeBaseCoreTests && /tmp/KnowledgeBaseCoreTests
```

---

## Task 9: Full Build And Regression Verification

**Files:**
- No direct code changes unless failures require fixes.

**Commands:**

```bash
git diff --check
swiftc Sources/KnowledgeBaseCore.swift Tests/KnowledgeBaseCoreTests.swift -o /tmp/KnowledgeBaseCoreTests && /tmp/KnowledgeBaseCoreTests
./build.sh
git status --short
```

Expected:
- `git diff --check` prints no whitespace errors.
- Test binary prints `KnowledgeBaseCoreTests passed`.
- `./build.sh` succeeds. Existing warning about `MainActor.run` may remain if unrelated.
- `git status --short` shows only intended files modified.

Manual app verification:
- Launch built app.
- Open knowledge base.
- Confirm combined filters work:
  - query only
  - category only
  - month only
  - time range only
  - mood only
  - combined query + category + mood
- Confirm profile dashboard updates under filters.
- Confirm keyword network pill click filters results.
- Confirm detail page still opens and supports category/tag edits.
- Confirm batch Word/PDF export still produces readable files.
- Confirm existing reminder, daily capsule, weather, theme, and menu bar quick input paths still open.

---

## Implementation Order

1. Task 1: Combined filter model and tests.
2. Task 2: Time trend aggregation and tests.
3. Task 3: Category share aggregation and tests.
4. Task 4: Keyword network aggregation and tests.
5. Task 5: Export context extension and tests.
6. Task 6: SwiftUI combined filter controls.
7. Task 7: SwiftUI profile dashboard cards.
8. Task 8: 5,000-entry bounded aggregation test.
9. Task 9: Full verification.

This order keeps domain behavior testable before UI work and limits regression risk in the main SwiftUI file.

---

## Commit Plan

Use path-specific staging to avoid accidentally committing unrelated local work:

```bash
git add Sources/KnowledgeBaseCore.swift Tests/KnowledgeBaseCoreTests.swift
git commit -m "feat: add knowledge profile aggregations"
git add Sources/DailyReminderWidget.swift
git commit -m "feat: add knowledge profile and search UI"
```

If implementation is done in one pass, a single commit is acceptable:

```bash
git add Sources/KnowledgeBaseCore.swift Tests/KnowledgeBaseCoreTests.swift Sources/DailyReminderWidget.swift
git commit -m "feat: upgrade knowledge profile search"
```

Do not stage generated `.app`, `.dmg`, exported Word/PDF files, or unrelated local artifacts.
