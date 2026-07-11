# 菜单栏快捷面板自适应布局 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让菜单栏快捷面板完整显示顶部状态栏，并在内容超出可用高度时保持全部功能可滚动访问。

**Architecture:** 在 `MenuBarQuickPanelView` 内将顶部状态栏与可滚动的内容主体分离。以一组纯数据布局常量统一宽度、默认高度、边距与最小滚动高度；测试只验证这些可回归的布局约束，实际 SwiftUI 视图使用该常量组，不改变已有交互或文案。

**Tech Stack:** Swift 5、SwiftUI、AppKit、`swiftc` 命令行核心测试。

## Global Constraints

- 保持 macOS 13.1 最低版本。
- 不修改快捷面板的保存、跳转、刷新天气或键盘快捷键行为。
- 顶部状态栏必须位于非滚动区域；剩余内容可垂直滚动。
- 不改动当前工作区中与本任务无关的未提交文件。

---

### Task 1: 将快捷面板尺寸约束抽为可测试的布局值

**Files:**
- Modify: `work/DailyReminderWidget/Sources/DailyReminderWidget.swift:2795-2853`
- Create: `work/DailyReminderWidget/Tests/QuickPanelLayoutTests.swift`

**Interfaces:**
- Produces: `QuickPanelLayout.width: CGFloat`、`QuickPanelLayout.height: CGFloat`、`QuickPanelLayout.horizontalPadding: CGFloat`、`QuickPanelLayout.verticalPadding: CGFloat`、`QuickPanelLayout.pinnedHeaderHeight: CGFloat`。
- Consumes: SwiftUI `CGFloat`，由 `MenuBarQuickPanelView` 使用。

- [ ] **Step 1: 写入失败测试**

```swift
private static func testPanelProvidesRoomForPinnedHeaderAndScrollableBody() {
    assert(QuickPanelLayout.width == 392, "expected the existing menu bar width")
    assert(QuickPanelLayout.height >= 680, "expected enough height for the full default panel")
    assert(QuickPanelLayout.pinnedHeaderHeight == 58, "expected the header to reserve its full height")
    assert(QuickPanelLayout.verticalPadding >= 14, "expected top and bottom safe spacing")
}
```

- [ ] **Step 2: 运行测试并确认失败**

Run:

```bash
swiftc -D PERFORMANCE_BENCHMARK -parse-as-library Sources/KnowledgeBaseCore.swift Sources/DailyReminderWidget.swift Tests/QuickPanelLayoutTests.swift -o /tmp/QuickPanelLayoutTests -framework SwiftUI -framework AppKit -framework UserNotifications && /tmp/QuickPanelLayoutTests
```

Expected: 编译失败，提示 `QuickPanelLayout` 尚未定义。

- [ ] **Step 3: 添加最小布局常量实现**

```swift
enum QuickPanelLayout {
    static let width: CGFloat = 392
    static let height: CGFloat = 680
    static let horizontalPadding: CGFloat = 18
    static let verticalPadding: CGFloat = 14
    static let pinnedHeaderHeight: CGFloat = 58
}
```

- [ ] **Step 4: 再次运行测试并确认通过**

Run:

```bash
swiftc -D PERFORMANCE_BENCHMARK -parse-as-library Sources/KnowledgeBaseCore.swift Sources/DailyReminderWidget.swift Tests/QuickPanelLayoutTests.swift -o /tmp/QuickPanelLayoutTests -framework SwiftUI -framework AppKit -framework UserNotifications && /tmp/QuickPanelLayoutTests
```

Expected: 输出 `QuickPanelLayoutTests passed`。

### Task 2: 分离固定顶部状态栏与可滚动主体

**Files:**
- Modify: `work/DailyReminderWidget/Sources/DailyReminderWidget.swift:2807-2853`
- Test: `work/DailyReminderWidget/Tests/QuickPanelLayoutTests.swift`

**Interfaces:**
- Consumes: `QuickPanelLayout` 的尺寸与边距值。
- Produces: 顶部 `HeaderStatusView` 始终完整显示，日期、输入、操作、最近灵感及底部文案位于 `ScrollView` 内。

- [ ] **Step 1: 扩展失败测试**

```swift
private static func testScrollableBodyHasPositiveHeightBelowPinnedHeader() {
    let bodyHeight = QuickPanelLayout.height - QuickPanelLayout.pinnedHeaderHeight - QuickPanelLayout.verticalPadding * 2 - 8
    assert(bodyHeight > 0, "expected a positive scrollable body height")
}
```

- [ ] **Step 2: 运行测试并确认当前布局无法满足结构要求**

Run:

```bash
swiftc -D PERFORMANCE_BENCHMARK -parse-as-library Sources/KnowledgeBaseCore.swift Sources/DailyReminderWidget.swift Tests/QuickPanelLayoutTests.swift -o /tmp/QuickPanelLayoutTests -framework SwiftUI -framework AppKit -framework UserNotifications && /tmp/QuickPanelLayoutTests
```

Expected: 在 Task 1 尚未添加布局常量时编译失败；Task 1 完成后该断言通过，作为布局结构的回归保护。

- [ ] **Step 3: 以固定头部和滚动主体改写视图层级**

```swift
VStack(alignment: .leading, spacing: 8) {
    HeaderStatusView(
        todayWordCount: todayWordCount,
        pulse: logoPulse,
        onRefresh: refreshWeather
    )
        .frame(height: QuickPanelLayout.pinnedHeaderHeight)
    ScrollView(.vertical, showsIndicators: false) {
        VStack(alignment: .leading, spacing: 8) {
            QuickDateWeatherBar()
            QuickInspirationInputView(text: $inspirationDraft, isFocused: $isInputFocused)
            InspirationStatusHintView(text: statusHintText, symbol: statusHintSymbol, feedback: saveFeedback)
            PrimaryActionArea(
                canSave: canSave,
                didSave: didSave,
                isSaving: isSaving,
                onSave: saveInspiration,
                onOpen: { openMainWindow(route: .today) }
            )
            QuickActionGridView { route in openMainWindow(route: route) }
            RecentInspirationListView(
                items: recentInspirations,
                onViewAll: { openMainWindow(route: .history) },
                onOpenItem: { _ in openMainWindow(route: .history) }
            )
            FooterBrandSloganView()
        }
        .padding(.bottom, QuickPanelLayout.verticalPadding)
    }
}
.padding(.horizontal, QuickPanelLayout.horizontalPadding)
.padding(.top, QuickPanelLayout.verticalPadding)
.frame(width: QuickPanelLayout.width, height: QuickPanelLayout.height, alignment: .top)
```

- [ ] **Step 4: 运行布局测试并确认通过**

Run:

```bash
swiftc -D PERFORMANCE_BENCHMARK -parse-as-library Sources/KnowledgeBaseCore.swift Sources/DailyReminderWidget.swift Tests/QuickPanelLayoutTests.swift -o /tmp/QuickPanelLayoutTests -framework SwiftUI -framework AppKit -framework UserNotifications && /tmp/QuickPanelLayoutTests
```

Expected: 输出 `QuickPanelLayoutTests passed`。

### Task 3: 完整回归验证

**Files:**
- Modify: `work/DailyReminderWidget/Sources/DailyReminderWidget.swift`
- Test: `work/DailyReminderWidget/Tests/QuickPanelLayoutTests.swift`

- [ ] **Step 1: 构建应用**

Run:

```bash
./build.sh
```

Expected: 命令退出码为 0，并输出 `.app` 与 `.dmg` 路径。

- [ ] **Step 2: 运行已有核心测试**

Run:

```bash
swiftc Sources/KnowledgeBaseCore.swift Tests/KnowledgeBaseCoreTests.swift -o /tmp/KnowledgeBaseCoreTests && /tmp/KnowledgeBaseCoreTests
swiftc -D PERFORMANCE_BENCHMARK -parse-as-library Sources/KnowledgeBaseCore.swift Sources/DailyReminderWidget.swift Tests/DailyQuestionCoreTests.swift -o /tmp/DailyQuestionCoreTests -framework SwiftUI -framework AppKit -framework UserNotifications && /tmp/DailyQuestionCoreTests
```

Expected: 分别输出 `KnowledgeBaseCoreTests passed` 与 `DailyQuestionCoreTests passed`。

- [ ] **Step 3: 提交本任务文件**

```bash
git add work/DailyReminderWidget/Sources/DailyReminderWidget.swift work/DailyReminderWidget/Tests/QuickPanelLayoutTests.swift work/DailyReminderWidget/docs/superpowers/plans/2026-07-11-menu-bar-panel-adaptive-layout.md
git commit -m "fix: adapt menu bar quick panel layout"
```
