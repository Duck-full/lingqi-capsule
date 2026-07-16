import SwiftUI
import AppKit
import UserNotifications
import UniformTypeIdentifiers
import OSLog

private let inspirationProgressTarget = 300
private let inspirationCharacterLimit = 2000
private let quickInspirationCharacterLimit = 2000
private let defaultWindowSize = NSSize(width: 1291, height: 893)

enum PerformanceDiagnostics {
    private static let logger = Logger(subsystem: "local.codex.lingqi-capsule", category: "performance")
    private static let writeQueue = DispatchQueue(label: "local.codex.lingqi.performance-log", qos: .utility)
    private static let logURL: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folder = support.appendingPathComponent("DailyReminderWidget", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("performance.log")
    }()
    private static var launchStartTime: CFAbsoluteTime?
    private static var didRecordFirstContent = false

    static var isEnabled: Bool {
        if UserDefaults.standard.object(forKey: "performanceDiagnosticsEnabled") == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: "performanceDiagnosticsEnabled")
    }

    @discardableResult
    static func measure<T>(_ name: String, operation: () throws -> T) rethrows -> T {
        let start = CFAbsoluteTimeGetCurrent()
        let result = try operation()
        record(name, milliseconds: (CFAbsoluteTimeGetCurrent() - start) * 1000)
        return result
    }

    static func record(_ name: String, milliseconds: Double, details: String = "") {
        guard isEnabled else { return }
        let rounded = String(format: "%.2f", milliseconds)
        logger.debug("\(name, privacy: .public) \(rounded, privacy: .public)ms \(details, privacy: .public)")
        let line = "\(ISO8601DateFormatter().string(from: Date()))\t\(name)\t\(rounded)ms\t\(details)\n"
        writeQueue.async {
            guard let data = line.data(using: .utf8) else { return }
            if FileManager.default.fileExists(atPath: logURL.path),
               let handle = try? FileHandle(forWritingTo: logURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: logURL, options: [.atomic])
            }
        }
    }

    static func recordFirstContentIfNeeded() {
        guard !didRecordFirstContent else { return }
        didRecordFirstContent = true
        guard let launchStartTime else { return }
        record(
            "app.first-content",
            milliseconds: (CFAbsoluteTimeGetCurrent() - launchStartTime) * 1000
        )
    }

    static func markLaunchStart() {
        if launchStartTime == nil {
            launchStartTime = CFAbsoluteTimeGetCurrent()
        }
    }
}

enum QuickPanelRoute: String {
    case today
    case dailyInspiration
    case summary
    case history
    case theme
    case settings
}

extension Notification.Name {
    static let quickPanelRouteRequested = Notification.Name("local.codex.lingqi.quickPanelRouteRequested")
    static let quickInspirationSaved = Notification.Name("local.codex.lingqi.quickInspirationSaved")
    static let dailyQuestionAnswered = Notification.Name("local.codex.lingqi.dailyQuestionAnswered")
}

enum MainWindowPresenter {
    private static let mainWindowIdentifier = NSUserInterfaceItemIdentifier("lingqi.mainWindow")
    private static let appWindowTitle = "灵栖胶囊Capsule"
    private static let restWindowTitle = "休鼾一下"

    static func configureMainWindowIfNeeded(_ window: NSWindow) {
        guard isMainWindowCandidate(window) else { return }
        window.identifier = mainWindowIdentifier
        window.title = appWindowTitle
    }

    @discardableResult
    static func present(route: QuickPanelRoute? = nil) -> Bool {
        NSApp.setActivationPolicy(.regular)
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)

        if restoreExistingWindow(route: route) {
            return true
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            _ = restoreExistingWindow(route: route)
        }
        return false
    }

    static func isMainWindowCandidate(_ window: NSWindow) -> Bool {
        window.level == .normal
            && window.title != restWindowTitle
            && !(window is NSPanel)
            && window.contentView != nil
            && window.styleMask.contains(.titled)
    }

    @discardableResult
    private static func restoreExistingWindow(route: QuickPanelRoute?) -> Bool {
        guard let window = findMainWindow() else { return false }
        configureMainWindowIfNeeded(window)

        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        if !window.isVisible {
            window.makeKeyAndOrderFront(nil)
        }
        window.orderFrontRegardless()
        window.makeKey()
        NSApp.activate(ignoringOtherApps: true)

        if let route {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .quickPanelRouteRequested, object: route.rawValue)
            }
        }
        return true
    }

    private static func findMainWindow() -> NSWindow? {
        let windows = NSApplication.shared.windows
        return windows.first(where: { $0.identifier == mainWindowIdentifier })
            ?? windows.first(where: { $0.title == appWindowTitle && isMainWindowCandidate($0) })
            ?? windows.first(where: isMainWindowCandidate)
    }

    static func shouldCloseAsMenuPanel(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        return !isMainWindowCandidate(window)
    }
}

enum MenuBarIconProvider {
    static func image() -> NSImage {
        let image = Bundle.main.image(forResource: "MenuBarIconTemplate")
            ?? NSImage(systemSymbolName: "leaf.fill", accessibilityDescription: "灵栖胶囊")
            ?? NSImage(size: NSSize(width: 18, height: 18))
        image.isTemplate = true
        image.size = NSSize(width: 18, height: 18)
        return image
    }
}

final class WindowRenderState: ObservableObject {
    static let shared = WindowRenderState()

    @Published private(set) var isLightweightMode = false
    private var restoreWorkItem: DispatchWorkItem?

    private init() {}

    func prepareForMiniaturize(window: NSWindow?) {
        restoreWorkItem?.cancel()
        isLightweightMode = true
        PerformanceDiagnostics.record("window.miniaturize-prepare", milliseconds: 0)
        window?.contentView?.needsDisplay = true
        window?.contentView?.displayIfNeeded()
    }

    func finishDeminiaturize() {
        PerformanceDiagnostics.record("window.deminiaturize-finished", milliseconds: 0)
        restoreWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            withAnimation(.easeOut(duration: 0.16)) {
                self?.isLightweightMode = false
            }
        }
        restoreWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }
}

enum ReminderFrequency: String, CaseIterable, Codable, Identifiable {
    case once
    case daily
    case weekdays
    case weekly
    case monthly
    case customMinutes
    case customHours

    var id: String { rawValue }

    var title: String {
        switch self {
        case .once: return "仅一次"
        case .daily: return "每天"
        case .weekdays: return "工作日"
        case .weekly: return "每周"
        case .monthly: return "每月"
        case .customMinutes: return "每隔几分钟"
        case .customHours: return "每隔几小时"
        }
    }

    var isCalendarRecurring: Bool {
        switch self {
        case .daily, .weekdays, .weekly, .monthly:
            return true
        case .once, .customMinutes, .customHours:
            return false
        }
    }
}

struct ReminderItem: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var title: String
    var notes: String
    var date: Date
    var remindAt: Date
    var frequency: ReminderFrequency
    var customInterval: Int
    var isDone: Bool = false
    var createdAt: Date = Date()
}

extension ReminderItem {
    func occurs(on day: Date, calendar: Calendar = .current) -> Bool {
        let startOfDay = calendar.startOfDay(for: day)
        let startDate = calendar.startOfDay(for: date)
        guard startOfDay >= startDate else { return false }

        switch frequency {
        case .once, .customMinutes, .customHours:
            return calendar.isDate(day, inSameDayAs: date)
        case .daily:
            return true
        case .weekdays:
            let weekday = calendar.component(.weekday, from: day)
            return (2...6).contains(weekday)
        case .weekly:
            return calendar.component(.weekday, from: day) == calendar.component(.weekday, from: date)
        case .monthly:
            return calendar.component(.day, from: day) == calendar.component(.day, from: date)
        }
    }
}

final class ReminderStore: ObservableObject {
    @Published private(set) var items: [ReminderItem] = []

    private let fileURL: URL
    private let schedulesNotifications: Bool
    private let saveQueue = DispatchQueue(label: "local.codex.lingqi.reminders.save", qos: .utility)
    private var itemsByDay: [String: [ReminderItem]] = [:]
    private var recurringItems: [ReminderItem] = []
    private var pendingSave: DispatchWorkItem?
    private var terminationObserver: NSObjectProtocol?

    init(storageDirectory: URL? = nil, schedulesNotifications: Bool = true) {
        PerformanceDiagnostics.markLaunchStart()
        let support = storageDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folder = storageDirectory ?? support.appendingPathComponent("DailyReminderWidget", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        fileURL = folder.appendingPathComponent("reminders.json")
        self.schedulesNotifications = schedulesNotifications
        load()
        terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            self?.flushSave()
        }
    }

    deinit {
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
        flushSave()
    }

    func add(_ item: ReminderItem) {
        items.append(item)
        sort()
        addToDayIndex(item)
        rebuildRecurringIndex()
        persistAndSchedule(item)
    }

    func update(_ item: ReminderItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        let previousItem = items[index]
        items[index] = item
        sort()
        removeFromDayIndex(previousItem)
        addToDayIndex(item)
        rebuildRecurringIndex()
        persistAndSchedule(item)
    }

    func delete(_ item: ReminderItem) {
        items.removeAll { $0.id == item.id }
        removeFromDayIndex(item)
        rebuildRecurringIndex()
        persist()
        if schedulesNotifications {
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: NotificationScheduler.identifiers(for: item))
        }
    }

    func toggleDone(_ item: ReminderItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].isDone.toggle()
        updateDayIndex(items[index])
        rebuildRecurringIndex()
        persistAndSchedule(items[index])
    }

    func items(on day: Date) -> [ReminderItem] {
        let exactItems = itemsByDay[DateKey.string(from: day)] ?? []
        let exactIDs = Set(exactItems.map(\.id))
        let recurringMatches = recurringItems.filter { item in
            !exactIDs.contains(item.id) && item.occurs(on: day)
        }
        return (exactItems + recurringMatches).sorted { $0.remindAt < $1.remindAt }
    }

    func count(on day: Date) -> Int {
        items(on: day).count
    }

    private func sort() {
        items.sort {
            if Calendar.current.isDate($0.date, inSameDayAs: $1.date) {
                return $0.remindAt < $1.remindAt
            }
            return $0.date < $1.date
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            items = try PerformanceDiagnostics.measure("reminders.decode") {
                try decoder.decode([ReminderItem].self, from: data)
            }
            sort()
            rebuildDayIndex()
            PerformanceDiagnostics.record("reminders.load", milliseconds: 0, details: "count=\(items.count) bytes=\(data.count)")
        } catch {
            items = []
            itemsByDay = [:]
            recurringItems = []
        }
    }

    private func persistAndSchedule(_ item: ReminderItem) {
        persist()
        if schedulesNotifications {
            NotificationScheduler.shared.reschedule(item: item)
        }
    }

    private func persist() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let snapshot = self.items
            let fileURL = self.fileURL
            self.saveQueue.async {
                Self.write(snapshot, to: fileURL)
            }
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    func flushSave() {
        pendingSave?.cancel()
        pendingSave = nil
        let snapshot = items
        let fileURL = fileURL
        saveQueue.sync {
            Self.write(snapshot, to: fileURL)
        }
    }

    private static func write(_ items: [ReminderItem], to fileURL: URL) {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            let start = CFAbsoluteTimeGetCurrent()
            let data = try encoder.encode(items)
            try data.write(to: fileURL, options: [.atomic])
            PerformanceDiagnostics.record(
                "reminders.write",
                milliseconds: (CFAbsoluteTimeGetCurrent() - start) * 1000,
                details: "count=\(items.count) bytes=\(data.count)"
            )
        } catch {
            NSLog("Failed to save reminders: \(error.localizedDescription)")
        }
    }

    private func rebuildDayIndex() {
        itemsByDay = Dictionary(grouping: items, by: { DateKey.string(from: $0.date) })
            .mapValues { $0.sorted { $0.remindAt < $1.remindAt } }
        rebuildRecurringIndex()
    }

    private func rebuildRecurringIndex() {
        recurringItems = items
            .filter { $0.frequency.isCalendarRecurring }
            .sorted { $0.remindAt < $1.remindAt }
    }

    private func addToDayIndex(_ item: ReminderItem) {
        let key = DateKey.string(from: item.date)
        var dayItems = itemsByDay[key] ?? []
        dayItems.append(item)
        dayItems.sort { $0.remindAt < $1.remindAt }
        itemsByDay[key] = dayItems
    }

    private func removeFromDayIndex(_ item: ReminderItem) {
        let key = DateKey.string(from: item.date)
        guard var dayItems = itemsByDay[key] else { return }
        dayItems.removeAll { $0.id == item.id }
        if dayItems.isEmpty {
            itemsByDay.removeValue(forKey: key)
        } else {
            itemsByDay[key] = dayItems
        }
    }

    private func updateDayIndex(_ item: ReminderItem) {
        let key = DateKey.string(from: item.date)
        guard var dayItems = itemsByDay[key],
              let index = dayItems.firstIndex(where: { $0.id == item.id }) else {
            addToDayIndex(item)
            return
        }
        dayItems[index] = item
        itemsByDay[key] = dayItems
    }

    #if PERFORMANCE_BENCHMARK
    func replaceAllForBenchmark(_ newItems: [ReminderItem]) {
        items = newItems
        sort()
        rebuildDayIndex()
    }
    #endif
}

enum DateKey {
    private static let keyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let displayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.dateFormat = "yyyy年M月d日 EEEE"
        return formatter
    }()

    static func string(from date: Date) -> String {
        keyFormatter.string(from: date)
    }

    static func display(from date: Date) -> String {
        displayFormatter.string(from: date)
    }

    static func date(from key: String) -> Date? {
        keyFormatter.date(from: key)
    }
}

final class NoteStore: ObservableObject {
    @Published private var notesByDate: [String: String] = [:]

    private let legacyFileURL: URL
    private let notesFolderURL: URL
    private let migrationMarkerURL: URL
    private let saveQueue = DispatchQueue(label: "local.codex.lingqi.notes.save", qos: .utility)
    private var pendingSave: DispatchWorkItem?
    private var pendingKey: String?
    private var pendingNote: String?
    private var terminationObserver: NSObjectProtocol?

    init(storageDirectory: URL? = nil) {
        let support = storageDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folder = storageDirectory ?? support.appendingPathComponent("DailyReminderWidget", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        legacyFileURL = folder.appendingPathComponent("daily-notes.json")
        notesFolderURL = folder.appendingPathComponent("daily-notes", isDirectory: true)
        migrationMarkerURL = notesFolderURL.appendingPathComponent(".migration-complete")
        try? FileManager.default.createDirectory(at: notesFolderURL, withIntermediateDirectories: true)
        load()
        terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            self?.flushSave()
        }
    }

    deinit {
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
        flushSave()
    }

    func note(for date: Date) -> String {
        notesByDate[DateKey.string(from: date)] ?? ""
    }

    var noteDates: [Date] {
        notesByDate.keys.compactMap { DateKey.date(from: $0) }
    }

    func setNote(_ note: String, for date: Date) {
        let key = DateKey.string(from: date)
        let oldValue = notesByDate[key] ?? ""
        if note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            notesByDate.removeValue(forKey: key)
        } else {
            notesByDate[key] = note
        }
        guard oldValue != note else { return }
        scheduleSave(key: key, note: notesByDate[key])
    }

    func appendNote(_ note: String, for date: Date) {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let existing = self.note(for: date).trimmingCharacters(in: .whitespacesAndNewlines)
        let merged = existing.isEmpty ? trimmed : existing + "\n\n" + trimmed
        setNote(merged, for: date)
    }

    func appendDailyInspiration(question: DailyQuestion, answer: String, for date: Date = Date()) {
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let text = """
        ---

        【今日启发】
        问题：
        \(question.question)

        我的回答：
        \(trimmed)

        时间：
        \(Self.answerTimeFormatter.string(from: Date()))
        """
        appendNote(text, for: date)
    }

    func recentInspirations(limit: Int = 3) -> [RecentInspiration] {
        var result: [RecentInspiration] = []
        let sortedKeys = notesByDate.keys.sorted(by: >)
        for key in sortedKeys {
            guard let date = DateKey.date(from: key), let note = notesByDate[key] else { continue }
            for line in note.components(separatedBy: .newlines).reversed() {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                result.append(RecentInspiration(text: trimmed, date: Calendar.current.isDateInToday(date) ? Date() : date))
                if result.count == limit {
                    return result
                }
            }
        }
        return result
    }

    func hasNote(on date: Date) -> Bool {
        !note(for: date).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func load() {
        let start = CFAbsoluteTimeGetCurrent()
        let fileManager = FileManager.default
        let noteFiles = (try? fileManager.contentsOfDirectory(
            at: notesFolderURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        let legacyExists = fileManager.fileExists(atPath: legacyFileURL.path)
        let migrationCompleted = fileManager.fileExists(atPath: migrationMarkerURL.path)

        if !legacyExists || migrationCompleted {
            notesByDate = Dictionary(uniqueKeysWithValues: noteFiles.compactMap { url in
                guard url.pathExtension == "txt",
                      let note = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                return (url.deletingPathExtension().lastPathComponent, note)
            })
        } else if let data = try? Data(contentsOf: legacyFileURL),
                  let legacyNotes = try? JSONDecoder().decode([String: String].self, from: data) {
            notesByDate = legacyNotes
            migrateLegacyNotes(legacyNotes)
        }
        PerformanceDiagnostics.record(
            "notes.load",
            milliseconds: (CFAbsoluteTimeGetCurrent() - start) * 1000,
            details: "days=\(notesByDate.count)"
        )
    }

    func flushSave() {
        pendingSave?.cancel()
        pendingSave = nil
        let key = pendingKey
        let note = pendingNote
        pendingKey = nil
        pendingNote = nil
        let notesFolderURL = notesFolderURL
        saveQueue.sync {
            if let key {
                Self.write(note, key: key, to: notesFolderURL)
            }
        }
    }

    private func scheduleSave(key: String, note: String?) {
        pendingSave?.cancel()
        pendingKey = key
        pendingNote = note
        let notesFolderURL = notesFolderURL
        let work = DispatchWorkItem {
            Self.write(note, key: key, to: notesFolderURL)
        }
        pendingSave = work
        saveQueue.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    private static func write(_ note: String?, key: String, to folderURL: URL) {
        let start = CFAbsoluteTimeGetCurrent()
        let fileURL = folderURL.appendingPathComponent(key).appendingPathExtension("txt")
        if let note, !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try? note.write(to: fileURL, atomically: true, encoding: .utf8)
        } else {
            try? FileManager.default.removeItem(at: fileURL)
        }
        PerformanceDiagnostics.record(
            "notes.write-day",
            milliseconds: (CFAbsoluteTimeGetCurrent() - start) * 1000,
            details: "key=\(key) chars=\(note?.count ?? 0)"
        )
    }

    private func migrateLegacyNotes(_ notes: [String: String]) {
        let notesFolderURL = notesFolderURL
        let migrationMarkerURL = migrationMarkerURL
        saveQueue.async {
            let start = CFAbsoluteTimeGetCurrent()
            for (key, note) in notes {
                Self.write(note, key: key, to: notesFolderURL)
            }
            try? Data().write(to: migrationMarkerURL, options: [.atomic])
            PerformanceDiagnostics.record(
                "notes.migrate",
                milliseconds: (CFAbsoluteTimeGetCurrent() - start) * 1000,
                details: "days=\(notes.count)"
            )
        }
    }

    private static let answerTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    #if PERFORMANCE_BENCHMARK
    func replaceAllForBenchmark(_ notes: [String: String]) {
        notesByDate = notes
        for (key, note) in notes {
            Self.write(note, key: key, to: notesFolderURL)
        }
    }
    #endif
}

struct RecentInspiration: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let date: Date

    var displayText: String {
        if text.count <= 38 { return text }
        return String(text.prefix(38)) + "..."
    }

    var countText: String {
        "\(text.count) 字"
    }

    var timeText: String {
        if Calendar.current.isDateInToday(date) {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            return formatter.string(from: date)
        }
        if Calendar.current.isDateInYesterday(date) {
            return "昨天"
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.dateFormat = "M月d日"
        return formatter.string(from: date)
    }
}

enum DailyQuestionCategory: String, Codable, CaseIterable {
    case product
    case design
    case growth
    case emotion
    case creativity

    var title: String {
        switch self {
        case .product: return "产品思考"
        case .design: return "设计灵感"
        case .growth: return "成长记录"
        case .emotion: return "情绪记录"
        case .creativity: return "创意探索"
        }
    }
}

struct DailyQuestion: Identifiable, Codable, Equatable {
    var id = UUID()
    var date: Date
    var question: String
    var category: DailyQuestionCategory
    var answer: String?
    var keywords: [String]
    var createdAt = Date()
    var answeredAt: Date?
}

protocol DailyQuestionProvider {
    func getQuestion(for date: Date) -> DailyQuestion
}

struct DailyQuestionRepository {
    struct Template {
        let question: String
        let category: DailyQuestionCategory
        let keywords: [String]
    }

    var questionCount: Int { templates.count }

    func template(at index: Int) -> Template {
        templates[index % templates.count]
    }

    private let templates: [Template] = [
        .init(question: "如果重新设计一个 App，你最想改变什么？", category: .product, keywords: ["产品设计", "体验优化"]),
        .init(question: "最近哪个产品体验让你印象深刻？", category: .product, keywords: ["产品体验", "观察"]),
        .init(question: "一个好产品最应该帮用户省下什么？", category: .product, keywords: ["用户价值", "效率"]),
        .init(question: "你今天遇到的一个小麻烦，可以被怎样的工具解决？", category: .product, keywords: ["问题发现", "工具"]),
        .init(question: "哪个 App 的第一次使用体验值得学习？", category: .product, keywords: ["新手体验", "产品"]),
        .init(question: "如果把一个复杂功能删掉一半，你会保留什么？", category: .product, keywords: ["取舍", "核心功能"]),
        .init(question: "最近有什么产品让你感到被理解？", category: .product, keywords: ["用户共情", "体验"]),
        .init(question: "一个功能什么时候应该保持沉默？", category: .product, keywords: ["克制", "产品判断"]),
        .init(question: "你最常用的 App 里，哪个细节降低了你的负担？", category: .product, keywords: ["细节", "负担"]),
        .init(question: "如果今天只能优化一个按钮，你会优化哪个？", category: .product, keywords: ["交互", "按钮"]),
        .init(question: "什么样的提醒不会打扰你？", category: .product, keywords: ["提醒", "节奏"]),
        .init(question: "你最近放弃使用一个产品的原因是什么？", category: .product, keywords: ["流失", "摩擦"]),
        .init(question: "一个产品怎样表达信任感？", category: .product, keywords: ["信任", "品牌"]),
        .init(question: "如果为自己做一款工具，它每天只做一件什么事？", category: .product, keywords: ["个人工具", "MVP"]),
        .init(question: "哪类功能看起来很强大，但其实让人更累？", category: .product, keywords: ["复杂度", "克制"]),
        .init(question: "你今天看到的一个真实需求是什么？", category: .product, keywords: ["需求", "观察"]),
        .init(question: "一个产品的空状态可以怎样更温柔？", category: .product, keywords: ["空状态", "文案"]),
        .init(question: "如果用户只有十秒，你希望他完成什么？", category: .product, keywords: ["路径", "效率"]),
        .init(question: "哪个功能值得被藏得更深一点？", category: .product, keywords: ["信息架构", "优先级"]),
        .init(question: "一个产品如何让人愿意第二天再回来？", category: .product, keywords: ["留存", "习惯"]),
        .init(question: "最近看到哪个设计让你眼前一亮？", category: .design, keywords: ["设计灵感", "视觉"]),
        .init(question: "什么样的设计细节让你觉得高级？", category: .design, keywords: ["细节", "质感"]),
        .init(question: "你今天注意到的一个配色是什么感觉？", category: .design, keywords: ["配色", "感受"]),
        .init(question: "哪个界面的留白让你觉得舒服？", category: .design, keywords: ["留白", "界面"]),
        .init(question: "如果用一个词描述今天的视觉灵感，会是什么？", category: .design, keywords: ["视觉", "关键词"]),
        .init(question: "什么样的动效让你感到自然？", category: .design, keywords: ["动效", "自然"]),
        .init(question: "一个安静的界面应该避免什么？", category: .design, keywords: ["安静", "克制"]),
        .init(question: "今天有什么材质、光影或纹理值得记录？", category: .design, keywords: ["材质", "光影"]),
        .init(question: "哪种字体气质适合陪伴型产品？", category: .design, keywords: ["字体", "气质"]),
        .init(question: "一个卡片如何显得轻，而不是廉价？", category: .design, keywords: ["卡片", "质感"]),
        .init(question: "你见过最舒服的输入框是什么样的？", category: .design, keywords: ["输入", "交互"]),
        .init(question: "什么样的图标会让你想点击？", category: .design, keywords: ["图标", "吸引力"]),
        .init(question: "如果把今天的心情做成背景，会是什么颜色？", category: .design, keywords: ["情绪", "颜色"]),
        .init(question: "一个界面如何表达安全感？", category: .design, keywords: ["安全感", "界面"]),
        .init(question: "最近哪个页面的层次最清楚？", category: .design, keywords: ["层次", "页面"]),
        .init(question: "什么样的阴影不会显得吵？", category: .design, keywords: ["阴影", "克制"]),
        .init(question: "一个按钮如何在不抢眼的情况下可被发现？", category: .design, keywords: ["按钮", "可发现性"]),
        .init(question: "今天你想借鉴哪一个现实世界的细节？", category: .design, keywords: ["现实灵感", "细节"]),
        .init(question: "哪种布局让你更愿意停留？", category: .design, keywords: ["布局", "停留"]),
        .init(question: "一个设计怎样做到有温度但不甜腻？", category: .design, keywords: ["温度", "克制"]),
        .init(question: "今天完成的一件最有价值的事情是什么？", category: .growth, keywords: ["工作复盘", "价值"]),
        .init(question: "今天最大的收获是什么？", category: .growth, keywords: ["收获", "复盘"]),
        .init(question: "今天哪一刻让你觉得自己在进步？", category: .growth, keywords: ["进步", "觉察"]),
        .init(question: "最近学会了什么新的技能？", category: .growth, keywords: ["学习", "技能"]),
        .init(question: "未来一个月最想提升什么能力？", category: .growth, keywords: ["能力", "目标"]),
        .init(question: "今天有什么事情值得复盘但不必苛责？", category: .growth, keywords: ["复盘", "温和"]),
        .init(question: "哪件小事证明你比以前更稳定了？", category: .growth, keywords: ["稳定", "成长"]),
        .init(question: "你今天主动解决了什么问题？", category: .growth, keywords: ["解决问题", "主动"]),
        .init(question: "有什么知识你想用自己的话重新讲一遍？", category: .growth, keywords: ["知识", "表达"]),
        .init(question: "今天的一个判断是否比过去更清晰？", category: .growth, keywords: ["判断", "清晰"]),
        .init(question: "你想把哪件事做得更慢但更好？", category: .growth, keywords: ["节奏", "质量"]),
        .init(question: "最近哪个反馈最值得认真对待？", category: .growth, keywords: ["反馈", "改进"]),
        .init(question: "今天有什么可以明天少做一点？", category: .growth, keywords: ["减负", "效率"]),
        .init(question: "你正在形成的一个好习惯是什么？", category: .growth, keywords: ["习惯", "积累"]),
        .init(question: "今天有什么事让你更了解自己？", category: .growth, keywords: ["自我理解", "觉察"]),
        .init(question: "你想为未来的自己留下哪条经验？", category: .growth, keywords: ["经验", "沉淀"]),
        .init(question: "今天的注意力花在哪里最值得？", category: .growth, keywords: ["注意力", "价值"]),
        .init(question: "你可以把哪个复杂问题拆小一点？", category: .growth, keywords: ["拆解", "行动"]),
        .init(question: "什么事情正在慢慢变容易？", category: .growth, keywords: ["变化", "成长"]),
        .init(question: "明天只推进一件事，你会选什么？", category: .growth, keywords: ["明日计划", "聚焦"]),
        .init(question: "今天哪个瞬间让你感觉开心？", category: .emotion, keywords: ["开心", "瞬间"]),
        .init(question: "最近有什么事情值得感谢？", category: .emotion, keywords: ["感谢", "关系"]),
        .init(question: "今天有什么情绪想被你看见？", category: .emotion, keywords: ["情绪", "觉察"]),
        .init(question: "哪个瞬间让你松了一口气？", category: .emotion, keywords: ["放松", "瞬间"]),
        .init(question: "今天有没有一个小小的被照顾感？", category: .emotion, keywords: ["照顾", "温暖"]),
        .init(question: "如果给今天的情绪取名，它叫什么？", category: .emotion, keywords: ["命名", "情绪"]),
        .init(question: "今天的你最需要哪一句话？", category: .emotion, keywords: ["自我陪伴", "语言"]),
        .init(question: "有什么担心可以先轻轻放下？", category: .emotion, keywords: ["担心", "放下"]),
        .init(question: "今天身体哪里最需要休息？", category: .emotion, keywords: ["身体", "休息"]),
        .init(question: "你今天对谁产生了善意？", category: .emotion, keywords: ["善意", "关系"]),
        .init(question: "今天有什么事情让你感到安全？", category: .emotion, keywords: ["安全感", "稳定"]),
        .init(question: "一个微小的满足来自哪里？", category: .emotion, keywords: ["满足", "生活"]),
        .init(question: "今天你愿意原谅自己的哪一点？", category: .emotion, keywords: ["原谅", "自我接纳"]),
        .init(question: "最近有什么让你反复想起？", category: .emotion, keywords: ["反复", "线索"]),
        .init(question: "今天的心像什么天气？", category: .emotion, keywords: ["隐喻", "心情"]),
        .init(question: "你可以怎样更温柔地结束今天？", category: .emotion, keywords: ["结束", "温柔"]),
        .init(question: "今天哪个关系让你感到被支持？", category: .emotion, keywords: ["支持", "关系"]),
        .init(question: "有什么快乐很小，但真实存在？", category: .emotion, keywords: ["快乐", "真实"]),
        .init(question: "今天的压力主要来自哪里？", category: .emotion, keywords: ["压力", "来源"]),
        .init(question: "此刻最想对自己说什么？", category: .emotion, keywords: ["自我对话", "此刻"]),
        .init(question: "如果没有限制，你最想创造什么？", category: .creativity, keywords: ["创造", "想象"]),
        .init(question: "今天出现过一个奇怪但有趣的想法吗？", category: .creativity, keywords: ["创意", "有趣"]),
        .init(question: "如果把两个不相关的东西组合，会得到什么？", category: .creativity, keywords: ["组合", "联想"]),
        .init(question: "你想为哪类人做一个小发明？", category: .creativity, keywords: ["发明", "人群"]),
        .init(question: "一个普通物品可以被重新定义成什么？", category: .creativity, keywords: ["再定义", "物品"]),
        .init(question: "如果今天是一张海报，标题是什么？", category: .creativity, keywords: ["海报", "表达"]),
        .init(question: "有什么故事可以从今天的一个细节开始？", category: .creativity, keywords: ["故事", "细节"]),
        .init(question: "你想把哪种感受做成一个产品？", category: .creativity, keywords: ["感受", "产品想象"]),
        .init(question: "如果用声音表达今天，会是什么声音？", category: .creativity, keywords: ["声音", "感官"]),
        .init(question: "一个不可能的想法里，有什么可能的部分？", category: .creativity, keywords: ["可能性", "拆解"]),
        .init(question: "你想设计一个怎样的安静空间？", category: .creativity, keywords: ["空间", "安静"]),
        .init(question: "如果给未来写一封信，第一句是什么？", category: .creativity, keywords: ["未来", "写作"]),
        .init(question: "今天的一个问题可以被怎样诗意地解决？", category: .creativity, keywords: ["诗意", "解决"]),
        .init(question: "你想让一个旧习惯变成什么新仪式？", category: .creativity, keywords: ["仪式", "习惯"]),
        .init(question: "有什么想法值得先画一个粗糙草图？", category: .creativity, keywords: ["草图", "想法"]),
        .init(question: "如果只用三种元素做一个作品，会选什么？", category: .creativity, keywords: ["元素", "作品"]),
        .init(question: "你想创造一个什么样的早晨？", category: .creativity, keywords: ["早晨", "生活设计"]),
        .init(question: "哪个梦或片段可以继续发展？", category: .creativity, keywords: ["梦", "片段"]),
        .init(question: "如果把今天送给别人，你会包装成什么？", category: .creativity, keywords: ["礼物", "表达"]),
        .init(question: "你想给世界增加一点什么温柔的东西？", category: .creativity, keywords: ["温柔", "创造"])
    ]
}

struct LocalDailyQuestionProvider: DailyQuestionProvider {
    var repository = DailyQuestionRepository()
    var calendar = Calendar.current

    func getQuestion(for date: Date) -> DailyQuestion {
        let day = calendar.startOfDay(for: date)
        let offset = calendar.dateComponents([.day], from: Date(timeIntervalSince1970: 0), to: day).day ?? 0
        let template = repository.template(at: abs(offset))
        return DailyQuestion(
            date: day,
            question: template.question,
            category: template.category,
            keywords: template.keywords,
            createdAt: day
        )
    }
}

struct DailyQuestionService {
    private let provider: DailyQuestionProvider
    private let userDefaults: UserDefaults
    private let calendar: Calendar
    private let storageKey = "lingqi.mac.daily.questions"
    private let draftPrefix = "lingqi.mac.daily.question.draft."

    init(provider: DailyQuestionProvider = LocalDailyQuestionProvider(), userDefaults: UserDefaults = .standard, calendar: Calendar = .current) {
        self.provider = provider
        self.userDefaults = userDefaults
        self.calendar = calendar
    }

    func question(for date: Date = Date()) -> DailyQuestion {
        let day = calendar.startOfDay(for: date)
        if let saved = loadQuestions().first(where: { calendar.isDate($0.date, inSameDayAs: day) }) {
            return saved
        }
        return provider.getQuestion(for: day)
    }

    @discardableResult
    func saveAnswer(_ text: String, for date: Date = Date()) -> DailyQuestion {
        var question = self.question(for: date)
        question.answer = String(text.prefix(500))
        question.answeredAt = Date()
        var questions = loadQuestions()
        questions.removeAll { calendar.isDate($0.date, inSameDayAs: question.date) }
        questions.append(question)
        saveQuestions(questions.sorted { $0.date > $1.date })
        clearDraft(for: date)
        return question
    }

    func saveDraft(_ text: String, for date: Date = Date()) {
        userDefaults.set(String(text.prefix(500)), forKey: draftKey(for: date))
    }

    func draft(for date: Date = Date()) -> String {
        userDefaults.string(forKey: draftKey(for: date)) ?? ""
    }

    func answeredQuestions() -> [DailyQuestion] {
        loadQuestions().filter { !($0.answer ?? "").isEmpty }.sorted { $0.date > $1.date }
    }

    private func clearDraft(for date: Date) {
        userDefaults.removeObject(forKey: draftKey(for: date))
    }

    private func draftKey(for date: Date) -> String {
        "\(draftPrefix)\(DateKey.string(from: calendar.startOfDay(for: date)))"
    }

    private func loadQuestions() -> [DailyQuestion] {
        guard let data = userDefaults.data(forKey: storageKey),
              let questions = try? JSONDecoder().decode([DailyQuestion].self, from: data)
        else { return [] }
        return questions
    }

    private func saveQuestions(_ questions: [DailyQuestion]) {
        guard let data = try? JSONEncoder().encode(questions) else { return }
        userDefaults.set(data, forKey: storageKey)
    }
}

enum NoteExporter {
    static func exportDocx(capsule: DailyCapsule) {
        guard let destination = saveURL(extensionName: "docx", date: capsule.date) else { return }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("daily-capsule-\(UUID().uuidString).html")
        let html = htmlDocument(capsule: capsule)
        do {
            try html.write(to: temp, atomically: true, encoding: .utf8)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
            process.arguments = ["-convert", "docx", "-output", destination.path, temp.path]
            try process.run()
            process.waitUntilExit()
            try? FileManager.default.removeItem(at: temp)
            if process.terminationStatus != 0 {
                NSSound.beep()
            }
        } catch {
            NSSound.beep()
        }
    }

    static func exportDocx(note: String, date: Date) {
        guard let destination = saveURL(extensionName: "docx", date: date) else { return }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("daily-note-\(UUID().uuidString).html")
        let html = htmlDocument(note: note, date: date)
        do {
            try html.write(to: temp, atomically: true, encoding: .utf8)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
            process.arguments = ["-convert", "docx", "-output", destination.path, temp.path]
            try process.run()
            process.waitUntilExit()
            try? FileManager.default.removeItem(at: temp)
            if process.terminationStatus != 0 {
                NSSound.beep()
            }
        } catch {
            NSSound.beep()
        }
    }

    static func exportPDF(note: String, date: Date) {
        guard let destination = saveURL(extensionName: "pdf", date: date) else { return }
        let view = NotePDFView(dateTitle: DateKey.display(from: date), note: readableNote(note))
        let data = view.dataWithPDF(inside: view.bounds)
        do {
            try data.write(to: destination, options: [.atomic])
        } catch {
            NSSound.beep()
        }
    }

    static func exportPDF(capsule: DailyCapsule) {
        guard let destination = saveURL(extensionName: "pdf", date: capsule.date) else { return }
        let view = NotePDFView(dateTitle: capsule.displayDate, note: plainText(capsule: capsule))
        let data = view.dataWithPDF(inside: view.bounds)
        do {
            try data.write(to: destination, options: [.atomic])
        } catch {
            NSSound.beep()
        }
    }

    static func exportKnowledgeDocx(bundle: KnowledgeExportBundle) {
        guard let destination = saveURL(extensionName: "docx", suggestedName: bundle.filenameStem) else { return }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("knowledge-bundle-\(UUID().uuidString).html")
        let html = htmlDocument(title: bundle.title, note: bundle.readableText)
        do {
            try html.write(to: temp, atomically: true, encoding: .utf8)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
            process.arguments = ["-convert", "docx", "-output", destination.path, temp.path]
            try process.run()
            process.waitUntilExit()
            try? FileManager.default.removeItem(at: temp)
            if process.terminationStatus != 0 {
                NSSound.beep()
            }
        } catch {
            NSSound.beep()
        }
    }

    static func exportKnowledgePDF(bundle: KnowledgeExportBundle) {
        guard let destination = saveURL(extensionName: "pdf", suggestedName: bundle.filenameStem) else { return }
        let view = NotePDFView(dateTitle: bundle.title, note: readableNote(bundle.readableText))
        let data = view.dataWithPDF(inside: view.bounds)
        do {
            try data.write(to: destination, options: [.atomic])
        } catch {
            NSSound.beep()
        }
    }

    private static func saveURL(extensionName: String, date: Date) -> URL? {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "今日灵感胶囊-\(DateKey.string(from: date)).\(extensionName)"
        if let type = UTType(filenameExtension: extensionName) {
            panel.allowedContentTypes = [type]
        }
        return panel.runModal() == .OK ? panel.url : nil
    }

    private static func saveURL(extensionName: String, suggestedName: String) -> URL? {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "\(suggestedName).\(extensionName)"
        if let type = UTType(filenameExtension: extensionName) {
            panel.allowedContentTypes = [type]
        }
        return panel.runModal() == .OK ? panel.url : nil
    }

    private static func htmlDocument(note: String, date: Date) -> String {
        let body = htmlNoteBody(note)
        return htmlDocument(title: "今日灵感胶囊", subtitle: DateKey.display(from: date), body: body)
    }

    private static func htmlDocument(title: String, note: String) -> String {
        htmlDocument(title: title, subtitle: "", body: htmlNoteBody(note))
    }

    private static func htmlDocument(title: String, subtitle: String, body: String) -> String {
        let subtitleBlock = subtitle.isEmpty ? "" : "<div class=\"date\">\(escape(subtitle))</div>"
        return """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <style>
            body { font-family: -apple-system, BlinkMacSystemFont, "PingFang SC", "Helvetica Neue", Arial, sans-serif; line-height: 1.72; color: #1f1f24; max-width: 760px; margin: 40px auto; }
            h1 { font-size: 25px; margin-bottom: 4px; letter-spacing: 0; }
            h2 { font-size: 18px; margin: 24px 0 10px; }
            .date { color: #666; margin-bottom: 28px; }
            .note { font-size: 15px; }
            p { margin: 0 0 12px; }
            .bullet { padding-left: 16px; text-indent: -12px; }
            .numbered { padding-left: 16px; }
            .quote { margin: 12px 0 16px; padding: 10px 14px; border-left: 4px solid #8ab4ff; background: #f3f6fb; color: #3f4652; border-radius: 8px; }
            .empty { color: #777; }
            hr { border: none; border-top: 1px solid #d8dee8; margin: 22px 0; }
          </style>
        </head>
        <body>
          <h1>\(escape(title))</h1>
          \(subtitleBlock)
          <div class="note">\(body)</div>
        </body>
        </html>
        """
    }

    private static func htmlDocument(capsule: DailyCapsule) -> String {
        let keywordText = capsule.keywords.isEmpty ? "暂无关键词" : capsule.keywords.joined(separator: "、")
        let reminders = capsule.reminders.isEmpty
            ? "<li>暂无事项</li>"
            : capsule.reminders.map { item in
                let state = item.isDone ? "已完成" : "未完成"
                return "<li><strong>\(escape(state))</strong> · \(escape(item.title)) · \(escape(timeText(item.remindAt)))</li>"
            }.joined(separator: "\n")
        return """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <style>
            body { font-family: -apple-system, BlinkMacSystemFont, "PingFang SC", "Helvetica Neue", Arial, sans-serif; line-height: 1.65; color: #1f1f24; }
            h1 { font-size: 24px; margin-bottom: 4px; }
            h2 { font-size: 17px; margin-top: 24px; }
            .date, .meta { color: #666; margin-bottom: 12px; }
            .summary { padding: 14px 16px; border-radius: 14px; background: #f3f6fb; margin: 18px 0; }
            .note { white-space: pre-wrap; font-size: 15px; }
          </style>
        </head>
        <body>
          <h1>灵栖胶囊 Capsule</h1>
          <div class="date">\(escape(capsule.displayDate)) · \(escape(capsule.status.title)) · \(escape(capsule.weatherText))</div>
          <div class="summary">\(escape(capsule.summary))</div>
          <div class="meta">关键词：\(escape(keywordText))</div>
          <div class="meta">心情：\(escape(capsule.mood)) · 完成情况：\(escape(capsule.completionText))</div>
          <h2>今日灵感胶囊</h2>
          <div class="note">\(escape(capsule.noteText.isEmpty ? "这一天还没有记录。" : capsule.noteText))</div>
          <h2>提醒事项</h2>
          <ul>\(reminders)</ul>
        </body>
        </html>
        """
    }

    private static func plainText(capsule: DailyCapsule) -> String {
        let keywordText = capsule.keywords.isEmpty ? "暂无关键词" : capsule.keywords.joined(separator: "、")
        let reminderText = capsule.reminders.isEmpty ? "暂无事项" : capsule.reminders.map { item in
            "\(item.isDone ? "已完成" : "未完成") · \(timeText(item.remindAt)) · \(item.title)"
        }.joined(separator: "\n")
        return """
        \(capsule.summary)

        状态：\(capsule.status.title)
        天气：\(capsule.weatherText)
        心情：\(capsule.mood)
        关键词：\(keywordText)
        完成情况：\(capsule.completionText)

        今日灵感胶囊
        \(capsule.noteText.isEmpty ? "这一天还没有记录。" : capsule.noteText)

        提醒事项
        \(reminderText)
        """
    }

    private static func timeText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    private static func readableNote(_ note: String) -> String {
        let trimmedLines = note
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        var result: [String] = []
        var previousWasBlank = false
        for line in trimmedLines {
            let normalized = readableLine(line)
            if normalized.isEmpty {
                if !previousWasBlank, !result.isEmpty {
                    result.append("")
                }
                previousWasBlank = true
            } else {
                result.append(normalized)
                previousWasBlank = false
            }
        }
        return result.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func readableLine(_ line: String) -> String {
        if line.hasPrefix("## ") {
            return line.replacingOccurrences(of: "## ", with: "")
        }
        if line.hasPrefix("> ") {
            return line.replacingOccurrences(of: "> ", with: "引用：")
        }
        if line == "---" {
            return "----------------"
        }
        return line
    }

    private static func htmlNoteBody(_ note: String) -> String {
        let lines = note
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        guard lines.contains(where: { !$0.isEmpty }) else {
            return "<p class=\"empty\">这一天还没有记录。</p>"
        }

        var fragments: [String] = []
        var previousWasBlank = false
        for line in lines {
            guard !line.isEmpty else {
                previousWasBlank = true
                continue
            }

            if line == "---" {
                fragments.append("<hr>")
            } else if line.hasPrefix("## ") {
                fragments.append("<h2>\(escape(String(line.dropFirst(3))))</h2>")
            } else if line.hasPrefix("- ") {
                fragments.append("<p class=\"bullet\">• \(escape(String(line.dropFirst(2))))</p>")
            } else if isNumberedLine(line) {
                fragments.append("<p class=\"numbered\">\(escape(line))</p>")
            } else if line.hasPrefix("> ") {
                fragments.append("<p class=\"quote\">\(escape(String(line.dropFirst(2))))</p>")
            } else {
                let topMargin = previousWasBlank ? " style=\"margin-top: 16px;\"" : ""
                fragments.append("<p\(topMargin)>\(escape(line))</p>")
            }
            previousWasBlank = false
        }
        return fragments.joined(separator: "\n")
    }

    private static func isNumberedLine(_ line: String) -> Bool {
        guard let dotIndex = line.firstIndex(of: ".") else { return false }
        let prefix = line[..<dotIndex]
        let rest = line[line.index(after: dotIndex)...]
        return !prefix.isEmpty && prefix.allSatisfy(\.isNumber) && rest.hasPrefix(" ")
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

final class NotePDFView: NSView {
    private let dateTitle: String
    private let note: String
    private let pageWidth: CGFloat = 612
    private let margin: CGFloat = 54

    init(dateTitle: String, note: String) {
        self.dateTitle = dateTitle
        self.note = note
        let bodyHeight = (note as NSString).boundingRect(
            with: NSSize(width: pageWidth - 108, height: 10000),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: 13)]
        ).height
        super.init(frame: NSRect(x: 0, y: 0, width: pageWidth, height: max(792, bodyHeight + 190)))
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        bounds.fill()

        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 24),
            .foregroundColor: NSColor(calibratedRed: 0.10, green: 0.10, blue: 0.14, alpha: 1)
        ]
        let dateAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let bodyAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor(calibratedRed: 0.12, green: 0.12, blue: 0.15, alpha: 1),
            .paragraphStyle: {
                let style = NSMutableParagraphStyle()
                style.lineSpacing = 6
                return style
            }()
        ]

        ("今日灵感胶囊" as NSString).draw(at: NSPoint(x: margin, y: bounds.height - 80), withAttributes: titleAttrs)
        (dateTitle as NSString).draw(at: NSPoint(x: margin, y: bounds.height - 108), withAttributes: dateAttrs)
        let bodyRect = NSRect(x: margin, y: margin, width: pageWidth - margin * 2, height: bounds.height - 180)
        (note.isEmpty ? "这一天还没有记录。" : note as NSString).draw(in: bodyRect, withAttributes: bodyAttrs)
    }
}

struct EmotionalCopy {
    let title: String
    let message: String
    let symbol: String

    static let greetings: [EmotionalCopy] = [
        EmotionalCopy(title: "今天也轻一点", message: "先把最重要的一件事放到眼前，剩下的慢慢来。", symbol: "sun.max.fill"),
        EmotionalCopy(title: "欢迎回来", message: "灵栖胶囊已经准备好陪你把今天拆成更容易完成的小步。", symbol: "sparkles"),
        EmotionalCopy(title: "给大脑留点余地", message: "事项可以被记录，心里就不用一直惦记。", symbol: "heart.text.square.fill"),
        EmotionalCopy(title: "从容开工", message: "不用一下子处理所有事，先选择一个清晰的开始。", symbol: "leaf.fill"),
        EmotionalCopy(title: "你已经在路上", message: "打开这一刻，就算是今天的第一个微小推进。", symbol: "checkmark.seal.fill")
    ]

    static let restLines: [EmotionalCopy] = [
        EmotionalCopy(title: "让眼睛慢慢松开", message: "看着柔和的线条移动，呼吸跟着变慢一点。", symbol: "moon.stars.fill"),
        EmotionalCopy(title: "短暂停靠", message: "五分钟不算逃离，是给下一段专注补一点光。", symbol: "water.waves"),
        EmotionalCopy(title: "把肩膀放下来", message: "此刻不用赶进度，只需要让注意力轻轻落地。", symbol: "cloud.moon.fill"),
        EmotionalCopy(title: "休鼾一下", message: "屏幕安静下来，大脑也可以不用一直亮着。", symbol: "sparkle.magnifyingglass")
    ]
}

final class AppIconManager: ObservableObject {
    @Published var statusText = "建议使用 1024×1024 PNG，透明背景，主体居中，四周保留 8%-12% 安全边距。"
    @Published var hasCustomIcon = false

    private let iconURL: URL

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folder = support.appendingPathComponent("DailyReminderWidget", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        iconURL = folder.appendingPathComponent("custom-app-icon.png")
        hasCustomIcon = FileManager.default.fileExists(atPath: iconURL.path)
    }

    func applySavedIcon() {
        guard let image = NSImage(contentsOf: iconURL) else { return }
        NSApp.applicationIconImage = image
        hasCustomIcon = true
        statusText = "已应用自定义图标。Finder 中的安装包图标仍以打包资源为准。"
    }

    func chooseIcon() {
        let panel = NSOpenPanel()
        panel.title = "选择自定义启动图标"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .heic]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setIcon(from: url)
    }

    func resetIcon() {
        try? FileManager.default.removeItem(at: iconURL)
        NSApp.applicationIconImage = nil
        hasCustomIcon = false
        statusText = "已恢复默认图标。"
    }

    private func setIcon(from url: URL) {
        guard let source = NSImage(contentsOf: url) else {
            statusText = "无法读取这张图片，请换一张 PNG 或 JPG。"
            NSSound.beep()
            return
        }

        let normalized = normalize(image: source)
        guard let tiff = normalized.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:]) else {
            statusText = "图标处理失败，请换一张更清晰的图片。"
            NSSound.beep()
            return
        }

        do {
            try data.write(to: iconURL, options: [.atomic])
            NSApp.applicationIconImage = normalized
            hasCustomIcon = true
            statusText = "已保存并应用。规范化为 1024×1024 透明画布，未裁切图片。"
        } catch {
            statusText = "保存失败，请检查文件权限。"
            NSSound.beep()
        }
    }

    private func normalize(image: NSImage) -> NSImage {
        let canvasSize = NSSize(width: 1024, height: 1024)
        let canvas = NSImage(size: canvasSize)
        let imageSize = image.size.width > 0 && image.size.height > 0 ? image.size : canvasSize
        let scale = min(canvasSize.width / imageSize.width, canvasSize.height / imageSize.height) * 0.92
        let drawSize = NSSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let rect = NSRect(
            x: (canvasSize.width - drawSize.width) / 2,
            y: (canvasSize.height - drawSize.height) / 2,
            width: drawSize.width,
            height: drawSize.height
        )

        canvas.lockFocus()
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: canvasSize).fill()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        canvas.unlockFocus()
        return canvas
    }
}

struct WeatherInfo: Equatable {
    var city: String
    var temperature: Double
    var windSpeed: Double
    var code: Int
    var updatedAt: Date

    var summary: String {
        switch code {
        case 0: return "晴朗"
        case 1, 2, 3: return "多云"
        case 45, 48: return "有雾"
        case 51, 53, 55, 56, 57: return "小雨"
        case 61, 63, 65, 66, 67, 80, 81, 82: return "降雨"
        case 71, 73, 75, 77, 85, 86: return "降雪"
        case 95, 96, 99: return "雷阵雨"
        default: return "天气"
        }
    }

    var icon: String {
        switch code {
        case 0: return "sun.max.fill"
        case 1, 2, 3: return "cloud.sun.fill"
        case 45, 48: return "cloud.fog.fill"
        case 51, 53, 55, 56, 57, 61, 63, 65, 66, 67, 80, 81, 82: return "cloud.rain.fill"
        case 71, 73, 75, 77, 85, 86: return "snowflake"
        case 95, 96, 99: return "cloud.bolt.rain.fill"
        default: return "cloud.fill"
        }
    }
}

enum ChineseCityName {
    private static let cityMap: [String: String] = [
        "beijing": "北京",
        "shanghai": "上海",
        "guangzhou": "广州",
        "shenzhen": "深圳",
        "hangzhou": "杭州",
        "chengdu": "成都",
        "wuhan": "武汉",
        "nanjing": "南京",
        "suzhou": "苏州",
        "xi'an": "西安",
        "xian": "西安",
        "tianjin": "天津",
        "chongqing": "重庆",
        "qingdao": "青岛",
        "dalian": "大连",
        "xiamen": "厦门",
        "fuzhou": "福州",
        "jinan": "济南",
        "changsha": "长沙",
        "zhengzhou": "郑州",
        "hong kong": "香港",
        "macau": "澳门",
        "macao": "澳门",
        "taipei": "台北",
        "san francisco": "旧金山",
        "los angeles": "洛杉矶",
        "new york": "纽约",
        "seattle": "西雅图",
        "chicago": "芝加哥",
        "boston": "波士顿"
    ]

    static func displayName(for city: String?) -> String {
        guard let city, !city.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "当前城市"
        }
        let trimmed = city.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.range(of: #"[A-Za-z]"#, options: .regularExpression) == nil {
            return trimmed
        }
        return cityMap[trimmed.lowercased()] ?? "当前城市"
    }
}

enum AppBackgroundLibrary {
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = PerformanceTuning.prefersReducedEffects ? 3 : 6
        cache.totalCostLimit = PerformanceTuning.prefersReducedEffects ? 48 * 1024 * 1024 : 96 * 1024 * 1024
        return cache
    }()

    static let immersiveBackgroundNames = (1...13).map {
        String(format: "ImmersiveVistaBackground%02d", $0)
    }

    static func randomImmersiveBackgroundName() -> String {
        immersiveBackgroundNames.randomElement() ?? "ImmersiveVistaBackground01"
    }

    static func image(named name: String, fileExtension: String = "jpg") -> NSImage? {
        let key = NSString(string: "\(name).\(fileExtension)")
        if let cached = cache.object(forKey: key) {
            return cached
        }
        guard let url = Bundle.main.url(forResource: name, withExtension: fileExtension) else { return nil }
        guard let image = NSImage(contentsOf: url) else { return nil }
        let pixelCost = Int(max(1, image.size.width) * max(1, image.size.height) * 4)
        cache.setObject(image, forKey: key, cost: pixelCost)
        return image
    }

    static func weatherBackgroundName(for code: Int?) -> String {
        guard let code else { return "ImmersiveVistaBackground05" }
        switch code {
        case 0:
            return "ImmersiveVistaBackground07"
        case 1, 2, 3:
            return "ImmersiveVistaBackground05"
        case 45, 48:
            return "ImmersiveVistaBackground04"
        case 51, 53, 55, 56, 57, 61, 63, 65, 66, 67, 80, 81, 82:
            return "ImmersiveVistaBackground06"
        case 71, 73, 75, 77, 85, 86:
            return "ImmersiveVistaBackground10"
        case 95, 96, 99:
            return "ImmersiveVistaBackground09"
        default:
            return "ImmersiveVistaBackground08"
        }
    }
}

final class WeatherStore: ObservableObject {
    @Published var info: WeatherInfo?
    @Published var isLoading = false
    @Published var message = "正在获取当前城市天气..."

    func refresh() {
        guard !isLoading else { return }
        isLoading = true
        message = "正在获取当前城市天气..."

        guard let locationURL = URL(string: "https://ipapi.co/json/") else { return }
        URLSession.shared.dataTask(with: locationURL) { data, _, _ in
            guard
                let data,
                let location = try? JSONDecoder().decode(LocationResponse.self, from: data),
                let latitude = location.latitude,
                let longitude = location.longitude
            else {
                DispatchQueue.main.async {
                    self.isLoading = false
                    self.message = "天气获取失败，点击重试。"
                }
                return
            }

            let city = ChineseCityName.displayName(for: location.city)
            let urlString = "https://api.open-meteo.com/v1/forecast?latitude=\(latitude)&longitude=\(longitude)&current_weather=true"
            guard let weatherURL = URL(string: urlString) else { return }
            URLSession.shared.dataTask(with: weatherURL) { data, _, _ in
                DispatchQueue.main.async {
                    self.isLoading = false
                }
                guard
                    let data,
                    let response = try? JSONDecoder().decode(WeatherResponse.self, from: data),
                    let current = response.current_weather
                else {
                    DispatchQueue.main.async {
                        self.message = "天气获取失败，点击重试。"
                    }
                    return
                }
                DispatchQueue.main.async {
                    self.info = WeatherInfo(city: city, temperature: current.temperature, windSpeed: current.windspeed, code: current.weathercode, updatedAt: Date())
                    self.message = "已更新"
                }
            }.resume()
        }.resume()
    }

    private struct LocationResponse: Decodable {
        var city: String?
        var latitude: Double?
        var longitude: Double?
    }

    private struct WeatherResponse: Decodable {
        var current_weather: CurrentWeather?
    }

    private struct CurrentWeather: Decodable {
        var temperature: Double
        var windspeed: Double
        var weathercode: Int
    }
}

final class NotificationScheduler: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationScheduler()

    func configure() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let openAction = UNNotificationAction(identifier: "OPEN_APP", title: "打开事项", options: [.foreground])
        let category = UNNotificationCategory(identifier: "REMINDER_ITEM", actions: [openAction], intentIdentifiers: [], options: [])
        center.setNotificationCategories([category])
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func authorizationStatus(completion: @escaping (UNAuthorizationStatus) -> Void) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async {
                completion(settings.authorizationStatus)
            }
        }
    }

    func requestPermission(completion: @escaping (Bool) -> Void) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            DispatchQueue.main.async {
                completion(granted)
            }
        }
    }

    static func identifiers(for item: ReminderItem) -> [String] {
        (0..<8).map { "\(item.id.uuidString)-\($0)" }
    }

    func reschedule(items: [ReminderItem]) {
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()
        items.filter { !$0.isDone }.forEach { schedule(item: $0) }
    }

    func reschedule(item: ReminderItem) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: Self.identifiers(for: item))
        guard !item.isDone else { return }
        schedule(item: item)
    }

    func schedule(item: ReminderItem) {
        let content = UNMutableNotificationContent()
        content.title = "灵栖胶囊Capsule"
        content.body = item.notes.isEmpty ? "该处理今天的事项了。" : item.notes
        content.subtitle = item.title
        content.sound = .default
        content.categoryIdentifier = "REMINDER_ITEM"
        content.userInfo = ["itemID": item.id.uuidString]
        attachNotificationIcon(to: content)

        let calendar = Calendar.current
        var dateComponents = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: mergedDateAndTime(item.date, item.remindAt))

        switch item.frequency {
        case .once:
            guard let fireDate = calendar.date(from: dateComponents), fireDate > Date() else { return }
            add(content: content, trigger: UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: false), id: "\(item.id.uuidString)-0")
        case .daily:
            dateComponents.year = nil
            dateComponents.month = nil
            dateComponents.day = nil
            add(content: content, trigger: UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: true), id: "\(item.id.uuidString)-0")
        case .weekdays:
            for weekday in 2...6 {
                var weekdayComponents = dateComponents
                weekdayComponents.year = nil
                weekdayComponents.month = nil
                weekdayComponents.day = nil
                weekdayComponents.weekday = weekday
                add(content: content, trigger: UNCalendarNotificationTrigger(dateMatching: weekdayComponents, repeats: true), id: "\(item.id.uuidString)-\(weekday)")
            }
        case .weekly:
            dateComponents.year = nil
            dateComponents.month = nil
            dateComponents.day = nil
            dateComponents.weekday = calendar.component(.weekday, from: item.date)
            add(content: content, trigger: UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: true), id: "\(item.id.uuidString)-0")
        case .monthly:
            dateComponents.year = nil
            dateComponents.day = calendar.component(.day, from: item.date)
            add(content: content, trigger: UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: true), id: "\(item.id.uuidString)-0")
        case .customMinutes:
            let seconds = max(1, item.customInterval) * 60
            add(content: content, trigger: UNTimeIntervalNotificationTrigger(timeInterval: TimeInterval(max(60, seconds)), repeats: true), id: "\(item.id.uuidString)-0")
        case .customHours:
            let seconds = max(1, item.customInterval) * 3600
            add(content: content, trigger: UNTimeIntervalNotificationTrigger(timeInterval: TimeInterval(seconds), repeats: true), id: "\(item.id.uuidString)-0")
        }
    }

    private func add(content: UNNotificationContent, trigger: UNNotificationTrigger, id: String) {
        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                NSLog("Failed to schedule notification: \(error.localizedDescription)")
            }
        }
    }

    func sendTestNotification() {
        let content = UNMutableNotificationContent()
        content.title = "灵栖胶囊Capsule"
        content.subtitle = "系统通知测试"
        content.body = "如果你看到这条通知，说明 macOS 系统提醒已经可以正常工作。"
        content.sound = .default
        content.categoryIdentifier = "REMINDER_ITEM"
        attachNotificationIcon(to: content)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 3, repeats: false)
        add(content: content, trigger: trigger, id: "system-notification-test-\(UUID().uuidString)")
    }

    private func attachNotificationIcon(to content: UNMutableNotificationContent) {
        guard let url = Bundle.main.url(forResource: "NotificationIcon", withExtension: "png"),
              let attachment = try? UNNotificationAttachment(identifier: "lingqi-notification-icon", url: url, options: nil) else {
            return
        }
        content.attachments = [attachment]
    }

    private func mergedDateAndTime(_ date: Date, _ time: Date) -> Date {
        let calendar = Calendar.current
        var dateParts = calendar.dateComponents([.year, .month, .day], from: date)
        let timeParts = calendar.dateComponents([.hour, .minute], from: time)
        dateParts.hour = timeParts.hour
        dateParts.minute = timeParts.minute
        return calendar.date(from: dateParts) ?? date
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        await MainActor.run {
            MainWindowPresenter.present(route: .today)
        }
    }
}

#if !PERFORMANCE_BENCHMARK
@main
struct DailyReminderWidgetApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var store = ReminderStore()
    @StateObject private var noteStore = NoteStore()
    @StateObject private var iconManager = AppIconManager()
    @StateObject private var weatherStore = WeatherStore()
    @AppStorage("selectedTheme") private var selectedThemeRaw = AppTheme.immersiveVista.rawValue

    init() {
        PerformanceDiagnostics.markLaunchStart()
    }

    var body: some Scene {
        WindowGroup("灵栖胶囊Capsule", id: "main") {
            ContentView()
                .environmentObject(store)
                .environmentObject(noteStore)
                .environmentObject(iconManager)
                .environmentObject(weatherStore)
                .frame(minWidth: defaultWindowSize.width, minHeight: defaultWindowSize.height)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: defaultWindowSize.width, height: defaultWindowSize.height)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }

        MenuBarExtra {
            MenuBarQuickPanel()
                .environmentObject(store)
                .environmentObject(noteStore)
                .environmentObject(weatherStore)
                .environment(\.appTheme, AppTheme(rawValue: selectedThemeRaw) ?? .immersiveVista)
        } label: {
            Image(nsImage: MenuBarIconProvider.image())
                .accessibilityLabel("灵栖胶囊Capsule")
        }
        .menuBarExtraStyle(.window)
    }
}
#endif

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowObservers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationScheduler.shared.configure()
        NSApp.setActivationPolicy(.regular)
        configureWindows()
        DispatchQueue.main.async { [weak self] in
            self?.configureWindows()
        }
        observeWindowTransitions()
    }

    func applicationWillTerminate(_ notification: Notification) {
        for observer in windowObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        windowObservers.removeAll()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainWindowPresenter.present(route: .today)
        return true
    }

    private func configureWindows() {
        for window in NSApplication.shared.windows where MainWindowPresenter.isMainWindowCandidate(window) {
            MainWindowPresenter.configureMainWindowIfNeeded(window)
            window.isMovableByWindowBackground = true
            window.minSize = defaultWindowSize
            window.isOpaque = true
            window.backgroundColor = NSColor(calibratedRed: 0.035, green: 0.060, blue: 0.095, alpha: 1)
            if window.frame.width < defaultWindowSize.width || window.frame.height < defaultWindowSize.height {
                window.setFrame(NSRect(x: window.frame.origin.x, y: window.frame.origin.y, width: defaultWindowSize.width, height: defaultWindowSize.height), display: true)
                window.center()
            }
        }
    }

    private func observeWindowTransitions() {
        let center = NotificationCenter.default
        windowObservers.append(
            center.addObserver(forName: NSWindow.willMiniaturizeNotification, object: nil, queue: .main) { notification in
                WindowRenderState.shared.prepareForMiniaturize(window: notification.object as? NSWindow)
            }
        )
        windowObservers.append(
            center.addObserver(forName: NSWindow.didDeminiaturizeNotification, object: nil, queue: .main) { _ in
                WindowRenderState.shared.finishDeminiaturize()
            }
        )
    }
}

struct ThemePalette {
    let ink: Color
    let plum: Color
    let surface: Color
    let glowA: Color
    let glowB: Color
    let accent: Color
    let accent2: Color
    let warm: Color
    let text: Color = Color.white.opacity(0.94)
    let muted: Color = Color.white.opacity(0.64)
    let card: Color = Color.white.opacity(0.085)
    let cardStrong: Color = Color.white.opacity(0.14)
    let line: Color = Color.white.opacity(0.13)
    var cyan: Color { accent }
    var blue: Color { accent2 }
    var lavender: Color { glowB }
}

enum PerformanceTuning {
    static var prefersReducedEffects: Bool {
        if ProcessInfo.processInfo.isLowPowerModeEnabled {
            return true
        }
        #if arch(x86_64)
        return true
        #else
        return false
        #endif
    }
}

enum AppTheme: String, CaseIterable, Identifiable {
    case neonPulse
    case ios27Glass
    case immersiveVista
    case weatherChild
    case yourName
    case demonBlade
    case natsumeBook
    case futureTech
    case cartoonPop
    case ancientInk
    case auroraMint
    case sunsetSynth
    case deepOcean
    case roseNebula
    case graphiteLaser

    var id: String { rawValue }

    var title: String {
        switch self {
        case .neonPulse: return "霓虹脉冲"
        case .ios27Glass: return "iOS27 毛玻璃"
        case .immersiveVista: return "沉浸风景玻璃"
        case .weatherChild: return "天气之子"
        case .yourName: return "你的名字"
        case .demonBlade: return "鬼灭之刃"
        case .natsumeBook: return "夏目友人帐"
        case .futureTech: return "未来科技感"
        case .cartoonPop: return "卡通风格"
        case .ancientInk: return "古风风格"
        case .auroraMint: return "极光薄荷"
        case .sunsetSynth: return "落日合成"
        case .deepOcean: return "深海蓝焰"
        case .roseNebula: return "玫瑰星云"
        case .graphiteLaser: return "石墨激光"
        }
    }

    var shortTitle: String {
        switch self {
        case .neonPulse: return "霓虹"
        case .ios27Glass: return "玻璃"
        case .immersiveVista: return "沉浸"
        case .weatherChild: return "晴雨"
        case .yourName: return "星河"
        case .demonBlade: return "刃纹"
        case .natsumeBook: return "友人"
        case .futureTech: return "未来"
        case .cartoonPop: return "卡通"
        case .ancientInk: return "古风"
        case .auroraMint: return "极光"
        case .sunsetSynth: return "落日"
        case .deepOcean: return "深海"
        case .roseNebula: return "星云"
        case .graphiteLaser: return "石墨"
        }
    }

    var mood: String {
        switch self {
        case .neonPulse: return "今天的节奏很亮，慢慢推进也会抵达。"
        case .ios27Glass: return "像一层清透玻璃，把今天的重点温柔托起来。"
        case .immersiveVista: return "把自己放进安静风景里，慢慢写下真正重要的事。"
        case .weatherChild: return "云层会散开，先把心里那束光写下来。"
        case .yourName: return "把今天的片段系成结，重要的事就不会走散。"
        case .demonBlade: return "稳住呼吸，今天也可以利落地完成一件事。"
        case .natsumeBook: return "温柔地记录吧，每个细小念头都值得被看见。"
        case .futureTech: return "像启动一段新程序，先跑通最小的一步。"
        case .cartoonPop: return "今天也可以轻快一点，完成一件就给自己加分。"
        case .ancientInk: return "心有章法，事有次第，慢慢来。"
        case .auroraMint: return "给今天一点清透感，先完成一个小动作。"
        case .sunsetSynth: return "别急着把一天填满，留一点余温给自己。"
        case .deepOcean: return "安静也是效率，深呼吸后再开始。"
        case .roseNebula: return "把重要的事温柔地放到眼前。"
        case .graphiteLaser: return "清晰、克制、精准，今天就这样推进。"
        }
    }

    var illustrationSymbol: String {
        switch self {
        case .neonPulse: return "sparkles"
        case .ios27Glass: return "app.gift.fill"
        case .immersiveVista: return "mountain.2.fill"
        case .weatherChild: return "cloud.sun.rain.fill"
        case .yourName: return "sparkle"
        case .demonBlade: return "flame.fill"
        case .natsumeBook: return "leaf.circle.fill"
        case .futureTech: return "cpu.fill"
        case .cartoonPop: return "paintpalette.fill"
        case .ancientInk: return "leaf.fill"
        case .auroraMint: return "drop.fill"
        case .sunsetSynth: return "sunset.fill"
        case .deepOcean: return "water.waves"
        case .roseNebula: return "heart.circle.fill"
        case .graphiteLaser: return "scope"
        }
    }

    var toneLine: String {
        switch self {
        case .neonPulse: return "把今天点亮一点"
        case .ios27Glass: return "清透地开始"
        case .immersiveVista: return "安静沉入风景"
        case .weatherChild: return "等一阵晴光"
        case .yourName: return "把片刻系紧"
        case .demonBlade: return "稳住呼吸"
        case .natsumeBook: return "温柔收集"
        case .futureTech: return "启动清晰模式"
        case .cartoonPop: return "轻快完成一件事"
        case .ancientInk: return "慢而有章法"
        case .auroraMint: return "保持清透呼吸"
        case .sunsetSynth: return "给节奏一点余温"
        case .deepOcean: return "沉稳推进"
        case .roseNebula: return "温柔提醒重要事"
        case .graphiteLaser: return "克制而精准"
        }
    }

    var palette: ThemePalette {
        switch self {
        case .neonPulse:
            return ThemePalette(
                ink: Color(red: 0.06, green: 0.02, blue: 0.18),
                plum: Color(red: 0.16, green: 0.04, blue: 0.37),
                surface: Color(red: 0.09, green: 0.02, blue: 0.27),
                glowA: Color(red: 0.27, green: 0.78, blue: 1.0),
                glowB: Color(red: 0.61, green: 0.38, blue: 1.0),
                accent: Color(red: 0.27, green: 0.78, blue: 1.0),
                accent2: Color(red: 0.28, green: 0.34, blue: 1.0),
                warm: Color(red: 1.0, green: 0.67, blue: 0.32)
            )
        case .ios27Glass:
            return ThemePalette(
                ink: Color(red: 0.05, green: 0.10, blue: 0.17),
                plum: Color(red: 0.10, green: 0.20, blue: 0.34),
                surface: Color(red: 0.08, green: 0.23, blue: 0.32),
                glowA: Color(red: 0.58, green: 0.83, blue: 1.0),
                glowB: Color(red: 0.52, green: 1.0, blue: 0.82),
                accent: Color(red: 0.63, green: 0.86, blue: 1.0),
                accent2: Color(red: 0.47, green: 0.76, blue: 1.0),
                warm: Color(red: 0.82, green: 1.0, blue: 0.92)
            )
        case .immersiveVista:
            return ThemePalette(
                ink: Color(red: 0.04, green: 0.06, blue: 0.06),
                plum: Color(red: 0.12, green: 0.15, blue: 0.14),
                surface: Color(red: 0.18, green: 0.21, blue: 0.18),
                glowA: Color(red: 0.82, green: 0.88, blue: 0.78),
                glowB: Color(red: 0.54, green: 0.66, blue: 0.63),
                accent: Color(red: 0.88, green: 0.92, blue: 0.84),
                accent2: Color(red: 0.60, green: 0.72, blue: 0.68),
                warm: Color(red: 0.96, green: 0.86, blue: 0.66)
            )
        case .weatherChild:
            return ThemePalette(
                ink: Color(red: 0.03, green: 0.12, blue: 0.22),
                plum: Color(red: 0.06, green: 0.26, blue: 0.42),
                surface: Color(red: 0.11, green: 0.34, blue: 0.50),
                glowA: Color(red: 0.42, green: 0.78, blue: 1.0),
                glowB: Color(red: 1.0, green: 0.76, blue: 0.30),
                accent: Color(red: 0.42, green: 0.82, blue: 1.0),
                accent2: Color(red: 0.20, green: 0.55, blue: 0.95),
                warm: Color(red: 1.0, green: 0.82, blue: 0.38)
            )
        case .yourName:
            return ThemePalette(
                ink: Color(red: 0.07, green: 0.05, blue: 0.19),
                plum: Color(red: 0.27, green: 0.10, blue: 0.34),
                surface: Color(red: 0.12, green: 0.12, blue: 0.36),
                glowA: Color(red: 0.50, green: 0.70, blue: 1.0),
                glowB: Color(red: 1.0, green: 0.43, blue: 0.72),
                accent: Color(red: 0.62, green: 0.76, blue: 1.0),
                accent2: Color(red: 0.96, green: 0.42, blue: 0.74),
                warm: Color(red: 1.0, green: 0.72, blue: 0.42)
            )
        case .demonBlade:
            return ThemePalette(
                ink: Color(red: 0.04, green: 0.06, blue: 0.07),
                plum: Color(red: 0.12, green: 0.24, blue: 0.18),
                surface: Color(red: 0.13, green: 0.08, blue: 0.08),
                glowA: Color(red: 0.16, green: 0.82, blue: 0.60),
                glowB: Color(red: 1.0, green: 0.18, blue: 0.14),
                accent: Color(red: 0.28, green: 0.92, blue: 0.68),
                accent2: Color(red: 0.95, green: 0.16, blue: 0.16),
                warm: Color(red: 1.0, green: 0.72, blue: 0.34)
            )
        case .natsumeBook:
            return ThemePalette(
                ink: Color(red: 0.07, green: 0.12, blue: 0.08),
                plum: Color(red: 0.17, green: 0.27, blue: 0.14),
                surface: Color(red: 0.25, green: 0.20, blue: 0.12),
                glowA: Color(red: 0.78, green: 0.94, blue: 0.48),
                glowB: Color(red: 0.97, green: 0.78, blue: 0.42),
                accent: Color(red: 0.82, green: 0.94, blue: 0.50),
                accent2: Color(red: 0.62, green: 0.76, blue: 0.36),
                warm: Color(red: 1.0, green: 0.82, blue: 0.48)
            )
        case .futureTech:
            return ThemePalette(
                ink: Color(red: 0.00, green: 0.03, blue: 0.10),
                plum: Color(red: 0.02, green: 0.10, blue: 0.24),
                surface: Color(red: 0.04, green: 0.05, blue: 0.16),
                glowA: Color(red: 0.15, green: 0.95, blue: 1.0),
                glowB: Color(red: 0.30, green: 0.32, blue: 1.0),
                accent: Color(red: 0.20, green: 0.94, blue: 1.0),
                accent2: Color(red: 0.38, green: 0.42, blue: 1.0),
                warm: Color(red: 0.72, green: 1.0, blue: 0.46)
            )
        case .cartoonPop:
            return ThemePalette(
                ink: Color(red: 0.12, green: 0.04, blue: 0.22),
                plum: Color(red: 0.50, green: 0.16, blue: 0.58),
                surface: Color(red: 0.20, green: 0.10, blue: 0.34),
                glowA: Color(red: 1.0, green: 0.70, blue: 0.22),
                glowB: Color(red: 0.37, green: 0.82, blue: 1.0),
                accent: Color(red: 1.0, green: 0.72, blue: 0.20),
                accent2: Color(red: 0.36, green: 0.78, blue: 1.0),
                warm: Color(red: 1.0, green: 0.42, blue: 0.68)
            )
        case .ancientInk:
            return ThemePalette(
                ink: Color(red: 0.10, green: 0.06, blue: 0.04),
                plum: Color(red: 0.28, green: 0.16, blue: 0.08),
                surface: Color(red: 0.17, green: 0.10, blue: 0.06),
                glowA: Color(red: 0.86, green: 0.62, blue: 0.34),
                glowB: Color(red: 0.48, green: 0.22, blue: 0.12),
                accent: Color(red: 0.90, green: 0.68, blue: 0.38),
                accent2: Color(red: 0.58, green: 0.27, blue: 0.12),
                warm: Color(red: 1.0, green: 0.82, blue: 0.50)
            )
        case .auroraMint:
            return ThemePalette(
                ink: Color(red: 0.02, green: 0.12, blue: 0.15),
                plum: Color(red: 0.04, green: 0.30, blue: 0.28),
                surface: Color(red: 0.03, green: 0.18, blue: 0.24),
                glowA: Color(red: 0.24, green: 1.0, blue: 0.76),
                glowB: Color(red: 0.23, green: 0.72, blue: 1.0),
                accent: Color(red: 0.24, green: 1.0, blue: 0.76),
                accent2: Color(red: 0.16, green: 0.58, blue: 0.95),
                warm: Color(red: 0.95, green: 0.90, blue: 0.46)
            )
        case .sunsetSynth:
            return ThemePalette(
                ink: Color(red: 0.17, green: 0.05, blue: 0.12),
                plum: Color(red: 0.42, green: 0.13, blue: 0.28),
                surface: Color(red: 0.21, green: 0.07, blue: 0.24),
                glowA: Color(red: 1.0, green: 0.47, blue: 0.35),
                glowB: Color(red: 0.72, green: 0.35, blue: 1.0),
                accent: Color(red: 1.0, green: 0.52, blue: 0.33),
                accent2: Color(red: 0.72, green: 0.35, blue: 1.0),
                warm: Color(red: 1.0, green: 0.79, blue: 0.37)
            )
        case .deepOcean:
            return ThemePalette(
                ink: Color(red: 0.01, green: 0.04, blue: 0.14),
                plum: Color(red: 0.02, green: 0.10, blue: 0.28),
                surface: Color(red: 0.03, green: 0.15, blue: 0.26),
                glowA: Color(red: 0.14, green: 0.67, blue: 1.0),
                glowB: Color(red: 0.08, green: 0.28, blue: 0.92),
                accent: Color(red: 0.19, green: 0.75, blue: 1.0),
                accent2: Color(red: 0.16, green: 0.40, blue: 1.0),
                warm: Color(red: 0.39, green: 0.93, blue: 1.0)
            )
        case .roseNebula:
            return ThemePalette(
                ink: Color(red: 0.15, green: 0.03, blue: 0.16),
                plum: Color(red: 0.34, green: 0.08, blue: 0.34),
                surface: Color(red: 0.21, green: 0.04, blue: 0.26),
                glowA: Color(red: 1.0, green: 0.42, blue: 0.79),
                glowB: Color(red: 0.56, green: 0.37, blue: 1.0),
                accent: Color(red: 1.0, green: 0.42, blue: 0.79),
                accent2: Color(red: 0.48, green: 0.39, blue: 1.0),
                warm: Color(red: 1.0, green: 0.74, blue: 0.68)
            )
        case .graphiteLaser:
            return ThemePalette(
                ink: Color(red: 0.03, green: 0.04, blue: 0.06),
                plum: Color(red: 0.11, green: 0.12, blue: 0.18),
                surface: Color(red: 0.06, green: 0.07, blue: 0.11),
                glowA: Color(red: 0.43, green: 0.84, blue: 1.0),
                glowB: Color(red: 0.65, green: 0.68, blue: 0.78),
                accent: Color(red: 0.43, green: 0.84, blue: 1.0),
                accent2: Color(red: 0.78, green: 0.82, blue: 0.92),
                warm: Color(red: 0.98, green: 0.66, blue: 0.25)
            )
        }
    }

    var backgroundStyle: ThemeBackgroundStyle {
        switch self {
        case .ios27Glass: return .liquidGlass
        case .immersiveVista: return .immersiveScene
        case .weatherChild: return .animeWeather
        case .yourName: return .animeStars
        case .demonBlade: return .animeBlade
        case .natsumeBook: return .animeForest
        case .futureTech: return .future
        case .cartoonPop: return .cartoon
        case .ancientInk: return .heritage
        default: return .neon
        }
    }

    func symbol(_ role: ThemeSymbolRole) -> String {
        switch (self, role) {
        case (.immersiveVista, .theme): return "mountain.2"
        case (.immersiveVista, .calendar): return "calendar.badge.clock"
        case (.immersiveVista, .note): return "text.alignleft"
        case (.immersiveVista, .notification): return "bell.and.waves.left.and.right"
        case (.immersiveVista, .task): return "checkmark.circle"
        case (.immersiveVista, .mood): return "cloud.rain.fill"
        case (.weatherChild, .theme): return "cloud.sun.rain"
        case (.weatherChild, .calendar): return "sun.max"
        case (.weatherChild, .note): return "cloud.sun.fill"
        case (.weatherChild, .notification): return "cloud.bolt.rain"
        case (.weatherChild, .task): return "checkmark.seal.fill"
        case (.weatherChild, .mood): return "sun.rain.fill"
        case (.yourName, .theme): return "sparkles"
        case (.yourName, .calendar): return "moon.stars.fill"
        case (.yourName, .note): return "paperclip"
        case (.yourName, .notification): return "bell.badge.fill"
        case (.yourName, .task): return "checkmark.circle.fill"
        case (.yourName, .mood): return "star.fill"
        case (.demonBlade, .theme): return "flame"
        case (.demonBlade, .calendar): return "wind"
        case (.demonBlade, .note): return "waveform.path.ecg"
        case (.demonBlade, .notification): return "bell.and.waves.left.and.right"
        case (.demonBlade, .task): return "bolt.circle.fill"
        case (.demonBlade, .mood): return "flame.fill"
        case (.natsumeBook, .theme): return "leaf"
        case (.natsumeBook, .calendar): return "book.closed"
        case (.natsumeBook, .note): return "text.book.closed.fill"
        case (.natsumeBook, .notification): return "bell"
        case (.natsumeBook, .task): return "checkmark.seal"
        case (.natsumeBook, .mood): return "cat.fill"
        case (.ios27Glass, .theme): return "sparkles.rectangle.stack"
        case (.ios27Glass, .calendar): return "calendar.badge.clock"
        case (.ios27Glass, .note): return "capsule.portrait"
        case (.ios27Glass, .notification): return "bell.and.waves.left.and.right"
        case (.ios27Glass, .task): return "checkmark.circle.fill"
        case (.ios27Glass, .mood): return "drop.degreesign.fill"
        case (.futureTech, .theme): return "cpu"
        case (.futureTech, .calendar): return "calendar.badge.clock"
        case (.futureTech, .note): return "doc.text.magnifyingglass"
        case (.futureTech, .notification): return "antenna.radiowaves.left.and.right"
        case (.futureTech, .task): return "checkmark.seal"
        case (.futureTech, .mood): return "bolt.badge.clock"
        case (.cartoonPop, .theme): return "paintpalette"
        case (.cartoonPop, .calendar): return "calendar.badge.plus"
        case (.cartoonPop, .note): return "pencil.and.outline"
        case (.cartoonPop, .notification): return "bell.badge"
        case (.cartoonPop, .task): return "checkmark.circle"
        case (.cartoonPop, .mood): return "heart.circle"
        case (.ancientInk, .theme): return "leaf"
        case (.ancientInk, .calendar): return "calendar"
        case (.ancientInk, .note): return "book.closed"
        case (.ancientInk, .notification): return "bell"
        case (.ancientInk, .task): return "checklist"
        case (.ancientInk, .mood): return "sun.max"
        default:
            switch role {
            case .theme: return "wand.and.stars"
            case .calendar: return "calendar"
            case .note: return "note.text"
            case .notification: return "bell.badge"
            case .task: return "checklist"
            case .mood: return "heart.text.square.fill"
            }
        }
    }
}

enum ThemeBackgroundStyle {
    case neon
    case liquidGlass
    case immersiveScene
    case animeWeather
    case animeStars
    case animeBlade
    case animeForest
    case future
    case cartoon
    case heritage
}

enum ThemeSymbolRole {
    case theme
    case calendar
    case note
    case notification
    case task
    case mood
}

private struct AppThemeKey: EnvironmentKey {
    static let defaultValue: AppTheme = .immersiveVista
}

private struct LightweightRenderingKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var appTheme: AppTheme {
        get { self[AppThemeKey.self] }
        set { self[AppThemeKey.self] = newValue }
    }

    var lightweightRendering: Bool {
        get { self[LightweightRenderingKey.self] }
        set { self[LightweightRenderingKey.self] = newValue }
    }
}

struct GlassPanel: ViewModifier {
    @Environment(\.appTheme) private var theme
    @Environment(\.lightweightRendering) private var lightweightRendering
    @AppStorage("cardOpacityPercent") private var cardOpacityPercent = 20.0
    @AppStorage("cardBlurPercent") private var cardBlurPercent = 45.0
    var radius: CGFloat = 20
    var isActive: Bool = false

    func body(content: Content) -> some View {
        content
            .background(panelMaterial)
            .background(panelBackground)
            .overlay(panelBorder)
            .shadow(
                color: lightweightRendering || PerformanceTuning.prefersReducedEffects ? .clear : panelShadowColor,
                radius: lightweightRendering || PerformanceTuning.prefersReducedEffects ? 0 : panelShadowRadius,
                x: 0,
                y: lightweightRendering || PerformanceTuning.prefersReducedEffects ? 0 : 9
            )
    }

    private var isImmersive: Bool {
        theme.backgroundStyle == .immersiveScene
    }

    private var isLiquid: Bool {
        theme.backgroundStyle == .liquidGlass
    }

    private var baseFill: Color {
        if isImmersive { return Color.black.opacity(userOpacity) }
        if isLiquid { return Color.white.opacity(max(0.12, userOpacity * 0.82)) }
        return theme.palette.card.opacity(max(0.42, userOpacity * 2.4))
    }

    private var gradientColors: [Color] {
        if isImmersive {
            return [Color.white.opacity(userOpacity * 0.9), Color.white.opacity(userOpacity * 0.28), Color.black.opacity(userOpacity * 0.45)]
        }
        if isLiquid {
            return [Color.white.opacity(userOpacity * 1.2), theme.palette.accent.opacity(userOpacity * 0.38), Color.white.opacity(userOpacity * 0.25)]
        }
        return [Color.white.opacity(userOpacity * 0.62), Color.white.opacity(userOpacity * 0.22)]
    }

    private var inactiveStroke: Color {
        if isImmersive { return Color.white.opacity(0.30) }
        if isLiquid { return Color.white.opacity(0.22) }
        return theme.palette.line
    }

    private var panelShadowColor: Color {
        if isActive { return theme.palette.cyan.opacity(0.22) }
        if isImmersive { return Color.black.opacity(0.30) }
        if isLiquid { return Color.black.opacity(0.16) }
        return Color.black.opacity(0.24)
    }

    private var panelShadowRadius: CGFloat {
        if isActive { return 20 }
        return isImmersive ? 18 : 14
    }

    private var panelBackground: some View {
        ZStack {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(baseFill)
            if !lightweightRendering {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: gradientColors,
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
        }
    }

    @ViewBuilder
    private var panelMaterial: some View {
        if PerformanceTuning.prefersReducedEffects {
            Color.clear
        } else {
            VisualEffectBlur(material: materialStyle, blendingMode: .withinWindow)
                .opacity(blurOpacity)
                .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                .allowsHitTesting(false)
        }
    }

    private var panelBorder: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .stroke(isActive ? theme.palette.cyan.opacity(0.78) : inactiveStroke, lineWidth: isActive ? 1.4 : 1)
    }

    private var userOpacity: Double {
        min(0.60, max(0.06, cardOpacityPercent / 100))
    }

    private var blurOpacity: Double {
        min(0.85, max(0.0, cardBlurPercent / 100))
    }

    private var materialStyle: NSVisualEffectView.Material {
        if isImmersive { return .hudWindow }
        if isLiquid { return .sidebar }
        return .popover
    }
}

extension View {
    func glassPanel(radius: CGFloat = 20, active: Bool = false) -> some View {
        modifier(GlassPanel(radius: radius, isActive: active))
    }

    func noWrap(scale: CGFloat = 0.82) -> some View {
        lineLimit(1)
            .minimumScaleFactor(scale)
            .truncationMode(.tail)
    }

    func hoverLift(_ enabled: Bool = true) -> some View {
        modifier(HoverLiftModifier(enabled: enabled))
    }
}

struct VisualEffectBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = PassthroughVisualEffectView()
        view.state = .active
        view.material = material
        view.blendingMode = blendingMode
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.state = .active
        view.material = material
        view.blendingMode = blendingMode
    }
}

final class PassthroughVisualEffectView: NSVisualEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

struct HoverLiftModifier: ViewModifier {
    let enabled: Bool
    @State private var hovering = false

    func body(content: Content) -> some View {
        let shouldAnimate = enabled && !PerformanceTuning.prefersReducedEffects
        content
            .scaleEffect(shouldAnimate && hovering ? 1.018 : 1)
            .offset(y: shouldAnimate && hovering ? -2 : 0)
            .shadow(color: shouldAnimate && hovering ? Color.white.opacity(0.10) : .clear, radius: 16, x: 0, y: 8)
            .animation(.spring(response: 0.24, dampingFraction: 0.82), value: hovering)
            .onHover { inside in
                if shouldAnimate {
                    hovering = inside
                }
            }
    }
}

struct AnimatedGlowBackground: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.lightweightRendering) private var lightweightRendering
    let theme: AppTheme
    @State private var animate = false
    @State private var immersiveBackgroundName = AppBackgroundLibrary.randomImmersiveBackgroundName()

    var body: some View {
        let reducedEffects = reduceMotion || PerformanceTuning.prefersReducedEffects || lightweightRendering
        ZStack {
            if theme.backgroundStyle == .immersiveScene {
                immersiveSceneBackground(reducedEffects: reducedEffects)
            } else {
                LinearGradient(
                    colors: [theme.palette.ink, theme.palette.plum, theme.palette.surface],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Circle()
                    .fill(theme.palette.glowA.opacity(reducedEffects ? 0.16 : 0.24))
                    .frame(width: reducedEffects ? 440 : 520, height: reducedEffects ? 440 : 520)
                    .blur(radius: reducedEffects ? 48 : 70)
                    .offset(x: animate ? 360 : 280, y: animate ? -250 : -170)
                Circle()
                    .fill(theme.palette.glowB.opacity(reducedEffects ? 0.15 : 0.23))
                    .frame(width: reducedEffects ? 500 : 620, height: reducedEffects ? 500 : 620)
                    .blur(radius: reducedEffects ? 56 : 86)
                    .offset(x: animate ? -360 : -260, y: animate ? 330 : 250)
                LinearGradient(
                    colors: [theme.palette.warm.opacity(reducedEffects ? 0.08 : 0.12), .clear, theme.palette.accent2.opacity(reducedEffects ? 0.08 : 0.12)],
                    startPoint: animate ? .bottomTrailing : .bottomLeading,
                    endPoint: .topTrailing
                )
                ThemeBackgroundIllustration(theme: theme, animate: reducedEffects ? false : animate)
                themeDecoration(reducedEffects: reducedEffects)
            }
        }
        .ignoresSafeArea()
        .onAppear {
            guard !reducedEffects, theme.backgroundStyle != .immersiveScene else { return }
            withAnimation(.easeInOut(duration: 5.5).repeatForever(autoreverses: true)) {
                animate.toggle()
            }
        }
    }

    @ViewBuilder
    private func immersiveSceneBackground(reducedEffects: Bool) -> some View {
        GeometryReader { proxy in
            ZStack {
                if let image = AppBackgroundLibrary.image(named: immersiveBackgroundName) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                } else {
                    LinearGradient(colors: [theme.palette.ink, theme.palette.surface], startPoint: .topLeading, endPoint: .bottomTrailing)
                }

                Color.black.opacity(0.28)
                if !lightweightRendering {
                    LinearGradient(
                        colors: [
                            Color.black.opacity(0.50),
                            Color.black.opacity(0.18),
                            theme.palette.ink.opacity(0.70)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    RadialGradient(
                        colors: [theme.palette.warm.opacity(0.18), .clear],
                        center: .topTrailing,
                        startRadius: 20,
                        endRadius: 720
                    )
                } else {
                    theme.palette.ink.opacity(0.34)
                }

                if !reducedEffects {
                    ForEach(0..<8, id: \.self) { index in
                        Capsule()
                            .fill(Color.white.opacity(0.055))
                            .frame(width: 2, height: CGFloat(220 + index * 18))
                            .rotationEffect(.degrees(-14))
                            .offset(x: CGFloat(index * 190 - 620), y: CGFloat(index * 42 - 210))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func themeDecoration(reducedEffects: Bool) -> some View {
        switch theme.backgroundStyle {
        case .immersiveScene:
            EmptyView()
        case .liquidGlass:
            ZStack {
                ForEach(0..<(reducedEffects ? 4 : 7), id: \.self) { index in
                    RoundedRectangle(cornerRadius: 90, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.10),
                                    theme.palette.accent.opacity(0.08),
                                    theme.palette.warm.opacity(0.07)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 90, style: .continuous)
                                .stroke(Color.white.opacity(0.18), lineWidth: 1)
                        )
                        .frame(width: CGFloat(190 + index * 86), height: CGFloat(126 + index * 48))
                        .blur(radius: CGFloat(index % 2) * 0.8)
                        .rotationEffect(.degrees(Double(index) * 10 + (animate ? 5 : -5)))
                        .offset(x: CGFloat(index * 52 - 210), y: CGFloat(index * 28 - 120))
                }
            }
        case .future:
            VStack(spacing: 26) {
                ForEach(0..<(reducedEffects ? 8 : 16), id: \.self) { _ in
                    Rectangle()
                        .fill(theme.palette.accent.opacity(0.055))
                        .frame(height: 1)
                }
            }
            .rotationEffect(.degrees(-8))
            .scaleEffect(1.4)
            .offset(y: animate ? 20 : -20)
        case .cartoon:
            ZStack {
                ForEach(0..<(reducedEffects ? 4 : 8), id: \.self) { index in
                    Circle()
                        .fill((index % 2 == 0 ? theme.palette.warm : theme.palette.accent2).opacity(0.13))
                        .frame(width: CGFloat(70 + index * 14), height: CGFloat(70 + index * 14))
                        .offset(x: CGFloat((index % 4) * 150 - 260), y: CGFloat((index / 2) * 110 - 220) + (animate ? 16 : -16))
                }
            }
        case .animeWeather:
            ZStack {
                RadialGradient(colors: [theme.palette.warm.opacity(0.22), .clear], center: .topTrailing, startRadius: 10, endRadius: 440)
                ForEach(0..<(reducedEffects ? 4 : 8), id: \.self) { index in
                    Image(systemName: index % 3 == 0 ? "cloud.fill" : "drop.fill")
                        .font(.system(size: CGFloat(index % 3 == 0 ? 54 : 20), weight: .semibold))
                        .foregroundStyle((index % 3 == 0 ? Color.white : theme.palette.accent).opacity(index % 3 == 0 ? 0.10 : 0.20))
                        .offset(x: CGFloat(index * 128 - 450) + (animate ? 22 : -22), y: CGFloat((index % 4) * 92 - 210) + (animate ? -12 : 12))
                }
                ForEach(0..<(reducedEffects ? 2 : 5), id: \.self) { index in
                    Capsule()
                        .fill(theme.palette.accent.opacity(0.10))
                        .frame(width: 120, height: 2)
                        .rotationEffect(.degrees(-18))
                        .offset(x: CGFloat(index * 170 - 360), y: CGFloat(index * 54 - 120) + (animate ? 24 : -24))
                }
            }
        case .animeStars:
            ZStack {
                ForEach(0..<(reducedEffects ? 8 : 18), id: \.self) { index in
                    Image(systemName: index % 4 == 0 ? "sparkle" : "star.fill")
                        .font(.system(size: CGFloat(10 + (index % 5) * 4), weight: .semibold))
                        .foregroundStyle((index % 3 == 0 ? theme.palette.warm : theme.palette.accent).opacity(0.18))
                        .offset(x: CGFloat((index * 91) % 780 - 390), y: CGFloat((index * 57) % 520 - 260) + (animate ? 10 : -10))
                        .scaleEffect(animate ? 1.10 : 0.86)
                }
                ForEach(0..<(reducedEffects ? 2 : 4), id: \.self) { index in
                    Capsule()
                        .fill(LinearGradient(colors: [.clear, theme.palette.warm.opacity(0.22), .clear], startPoint: .leading, endPoint: .trailing))
                        .frame(width: 260, height: 2)
                        .rotationEffect(.degrees(-28))
                        .offset(x: CGFloat(index * 180 - 280) + (animate ? 28 : -28), y: CGFloat(index * 84 - 170))
                }
            }
        case .animeBlade:
            ZStack {
                ForEach(0..<(reducedEffects ? 4 : 8), id: \.self) { index in
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill((index % 2 == 0 ? theme.palette.accent : theme.palette.accent2).opacity(0.12))
                        .frame(width: CGFloat(330 + index * 28), height: 8)
                        .rotationEffect(.degrees(index % 2 == 0 ? -34 : 32))
                        .offset(x: CGFloat(index * 52 - 210), y: CGFloat(index * 62 - 220) + (animate ? 16 : -16))
                }
                ForEach(0..<(reducedEffects ? 2 : 5), id: \.self) { index in
                    Image(systemName: index % 2 == 0 ? "flame.fill" : "wind")
                        .font(.system(size: CGFloat(34 + index * 8), weight: .bold))
                        .foregroundStyle((index % 2 == 0 ? theme.palette.accent2 : theme.palette.accent).opacity(0.13))
                        .rotationEffect(.degrees(animate ? 8 : -8))
                        .offset(x: CGFloat(index * 145 - 280), y: CGFloat((index % 3) * 120 - 160))
                }
            }
        case .animeForest:
            ZStack {
                RadialGradient(colors: [theme.palette.warm.opacity(0.14), .clear], center: .bottomLeading, startRadius: 20, endRadius: 520)
                ForEach(0..<(reducedEffects ? 6 : 12), id: \.self) { index in
                    Image(systemName: index % 4 == 0 ? "book.closed.fill" : "leaf.fill")
                        .font(.system(size: CGFloat(18 + (index % 5) * 8), weight: .semibold))
                        .foregroundStyle((index % 4 == 0 ? theme.palette.warm : theme.palette.accent).opacity(0.14))
                        .rotationEffect(.degrees(Double(index * 23) + (animate ? 8 : -8)))
                        .offset(x: CGFloat((index * 87) % 760 - 380), y: CGFloat((index * 69) % 520 - 260) + (animate ? 14 : -14))
                }
                ForEach(0..<(reducedEffects ? 2 : 4), id: \.self) { index in
                    RoundedRectangle(cornerRadius: 90, style: .continuous)
                        .stroke(theme.palette.warm.opacity(0.07), lineWidth: 1)
                        .frame(width: CGFloat(220 + index * 110), height: CGFloat(150 + index * 64))
                        .rotationEffect(.degrees(Double(index * 11) + (animate ? 4 : -4)))
                }
            }
        case .heritage:
            ZStack {
                RadialGradient(colors: [theme.palette.warm.opacity(0.16), .clear], center: .center, startRadius: 20, endRadius: 520)
                ForEach(0..<(reducedEffects ? 3 : 5), id: \.self) { index in
                    RoundedRectangle(cornerRadius: 80, style: .continuous)
                        .stroke(theme.palette.warm.opacity(0.06), lineWidth: 1)
                        .frame(width: CGFloat(260 + index * 120), height: CGFloat(170 + index * 88))
                        .rotationEffect(.degrees(Double(index) * 8 + (animate ? 3 : -3)))
                }
            }
        case .neon:
            EmptyView()
        }
    }
}

struct ThemeBackgroundIllustration: View {
    let theme: AppTheme
    let animate: Bool

    var body: some View {
        ZStack {
            Image(systemName: theme.illustrationSymbol)
                .font(.system(size: 210, weight: .ultraLight))
                .foregroundStyle(theme.palette.accent.opacity(0.08))
                .rotationEffect(.degrees(animate ? 8 : -8))
                .offset(x: 330, y: 210)
            Image(systemName: theme.symbol(.mood))
                .font(.system(size: 150, weight: .light))
                .foregroundStyle(theme.palette.warm.opacity(0.07))
                .rotationEffect(.degrees(animate ? -10 : 10))
                .offset(x: -360, y: -220)
        }
        .blur(radius: 0.2)
    }
}

struct MenuBarQuickPanel: View {
    var body: some View {
        MenuBarQuickPanelView()
    }
}

enum QuickPanelLayout {
    static let width: CGFloat = 392
    static let height: CGFloat = 680
    static let horizontalPadding: CGFloat = 18
    static let verticalPadding: CGFloat = 14
    static let pinnedHeaderHeight: CGFloat = 58
}

enum InspirationGrowthStage: String, Codable, CaseIterable {
    case empty
    case seed
    case sprout
    case seedling
    case growing

    static func stage(for count: Int) -> InspirationGrowthStage {
        switch count {
        case 0:
            return .empty
        case 1...30:
            return .seed
        case 31...100:
            return .sprout
        case 101...200:
            return .seedling
        default:
            return .growing
        }
    }

    var symbol: String {
        switch self {
        case .empty:
            return "sparkles"
        case .seed:
            return "circle.fill"
        case .sprout:
            return "leaf.fill"
        case .seedling:
            return "leaf.circle.fill"
        case .growing:
            return "tree.fill"
        }
    }
}

struct MenuBarQuickPanelView: View {
    @EnvironmentObject private var noteStore: NoteStore
    @EnvironmentObject private var weatherStore: WeatherStore
    @Environment(\.openWindow) private var openWindow
    @AppStorage("menubar.quickInputDraft") private var savedDraft = ""
    @State private var inspirationDraft = ""
    @State private var isInputFocused = false
    @State private var saveFeedback: String?
    @State private var didSave = false
    @State private var isSaving = false
    @State private var logoPulse = false

    var body: some View {
        ZStack {
            QuickPanelBackground()
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
                        QuickInspirationInputView(
                            text: $inspirationDraft,
                            isFocused: $isInputFocused
                        )
                        InspirationStatusHintView(
                            text: statusHintText,
                            symbol: statusHintSymbol,
                            feedback: saveFeedback
                        )
                        PrimaryActionArea(
                            canSave: canSave,
                            didSave: didSave,
                            isSaving: isSaving,
                            onSave: saveInspiration,
                            onOpen: { openMainWindow(route: .today) }
                        )
                        QuickActionGridView { route in
                            openMainWindow(route: route)
                        }
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
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            if let saveFeedback {
                EmotionalToast(message: saveFeedback)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, 68)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .frame(width: QuickPanelLayout.width, height: QuickPanelLayout.height, alignment: .topLeading)
        .onAppear {
            inspirationDraft = String(savedDraft.prefix(quickInspirationCharacterLimit))
            if weatherStore.info == nil {
                weatherStore.refresh()
            }
        }
        .onChange(of: inspirationDraft) { value in
            updateDraft(value)
        }
        .onDisappear {
            savedDraft = inspirationDraft
            noteStore.flushSave()
        }
        .onExitCommand {
            closePanel()
        }
    }

    private var recentInspirations: [RecentInspiration] {
        noteStore.recentInspirations(limit: 2)
    }

    private var canSave: Bool {
        !inspirationDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var todayWordCount: Int {
        noteStore.note(for: Date()).trimmingCharacters(in: .whitespacesAndNewlines).count
    }

    private var statusHintText: String {
        if let saveFeedback { return saveFeedback }
        if canSave { return "灵感正在发光，记得保存" }
        if todayWordCount >= 201 { return "今天的灵感正在慢慢发光" }
        return "小树苗正在等第一颗灵感"
    }

    private var statusHintSymbol: String {
        if saveFeedback != nil { return "leaf.fill" }
        if canSave { return "sparkles" }
        return "leaf"
    }

    private func openMainWindow(route: QuickPanelRoute = .today) {
        let panelWindow = NSApp.keyWindow
        if !MainWindowPresenter.present(route: route) {
            openWindow(id: "main")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                MainWindowPresenter.present(route: route)
            }
        }
        closePanel(panelWindow)
    }

    private func refreshWeather() {
        weatherStore.refresh()
    }

    private func updateDraft(_ value: String) {
        let limited = String(value.prefix(quickInspirationCharacterLimit))
        if limited != value {
            inspirationDraft = limited
            return
        }
        savedDraft = limited
    }

    private func saveInspiration() {
        let trimmed = inspirationDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isSaving = true
        noteStore.appendNote(trimmed, for: Date())
        noteStore.flushSave()
        inspirationDraft = ""
        savedDraft = ""
        withAnimation(.spring(response: 0.28, dampingFraction: 0.72)) {
            didSave = true
            isSaving = false
            logoPulse.toggle()
            saveFeedback = "灵感已被小树苗吸收"
        }
        NotificationCenter.default.post(name: .quickInspirationSaved, object: trimmed)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            withAnimation(.easeOut(duration: 0.18)) {
                didSave = false
                saveFeedback = nil
            }
        }
    }

    private func closePanel(_ panelWindow: NSWindow? = NSApp.keyWindow) {
        guard MainWindowPresenter.shouldCloseAsMenuPanel(panelWindow) else { return }
        panelWindow?.close()
    }
}

enum QuickPanelStyle {
    static var backgroundTop: Color { Color(red: 0.04, green: 0.06, blue: 0.13) }
    static var backgroundMiddle: Color { Color(red: 0.07, green: 0.09, blue: 0.18) }
    static var backgroundBottom: Color { Color(red: 0.10, green: 0.09, blue: 0.22) }
    static var card: Color { Color.white.opacity(0.075) }
    static var cardStrong: Color { Color.white.opacity(0.105) }
    static var stroke: Color { Color.white.opacity(0.15) }
    static var strokeActive: Color { Color(red: 0.61, green: 0.52, blue: 1.0).opacity(0.78) }
    static var text: Color { Color(red: 0.97, green: 0.98, blue: 0.99) }
    static var subText: Color { Color(red: 0.67, green: 0.69, blue: 0.78) }
    static var weakText: Color { Color(red: 0.45, green: 0.48, blue: 0.60) }
    static var blue: Color { Color(red: 0.38, green: 0.65, blue: 0.98) }
    static var green: Color { Color(red: 0.65, green: 0.95, blue: 0.82) }
    static var purple: Color { Color(red: 0.66, green: 0.55, blue: 0.98) }
}

struct QuickPanelBackground: View {
    @Environment(\.appTheme) private var theme

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [theme.palette.ink, theme.palette.plum, theme.palette.surface],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            RadialGradient(colors: [theme.palette.glowA.opacity(0.20), .clear], center: .topLeading, startRadius: 8, endRadius: 300)
            RadialGradient(colors: [theme.palette.glowB.opacity(0.24), .clear], center: .bottomTrailing, startRadius: 20, endRadius: 360)
            Rectangle()
                .fill(.ultraThinMaterial)
                .opacity(0.16)
        }
    }
}

struct QuickGlassCard<Content: View>: View {
    @Environment(\.appTheme) private var theme
    let active: Bool
    let radius: CGFloat
    let content: Content

    init(active: Bool = false, radius: CGFloat = 16, @ViewBuilder content: () -> Content) {
        self.active = active
        self.radius = radius
        self.content = content()
    }

    var body: some View {
        content
            .background(theme.palette.card.opacity(active ? 1.32 : 1), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(active ? theme.palette.accent.opacity(0.78) : theme.palette.line.opacity(1.15), lineWidth: active ? 1.2 : 1)
            )
            .shadow(color: active ? theme.palette.accent.opacity(0.18) : Color.black.opacity(0.12), radius: active ? 14 : 9, x: 0, y: 6)
    }
}

struct HeaderStatusView: View {
    @Environment(\.appTheme) private var theme
    let todayWordCount: Int
    let pulse: Bool
    let onRefresh: () -> Void
    @State private var hoveringRefresh = false

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [theme.palette.accent.opacity(0.40), theme.palette.glowB.opacity(0.18), theme.palette.cardStrong],
                            center: .topLeading,
                            startRadius: 4,
                            endRadius: 34
                        )
                    )
                    .overlay(Circle().stroke(theme.palette.accent.opacity(0.72), lineWidth: 1))
                    .shadow(color: theme.palette.glowB.opacity(pulse ? 0.48 : 0.24), radius: pulse ? 15 : 9, x: 0, y: 0)
                Image(systemName: growthStage.symbol)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(theme.palette.warm)
                    .scaleEffect(pulse ? 1.08 : 1.0)
            }
            .frame(width: 42, height: 42)
            .animation(.spring(response: 0.32, dampingFraction: 0.68), value: pulse)

            VStack(alignment: .leading, spacing: 2) {
                Text("灵栖胶囊")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.palette.text)
                    .lineLimit(1)
                Text("愿灵感慢慢发光")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.palette.muted)
                    .lineLimit(1)
            }
            .layoutPriority(1)
            Spacer()
            HStack(spacing: 6) {
                Circle()
                    .fill(theme.palette.accent)
                    .frame(width: 7, height: 7)
                    .shadow(color: theme.palette.accent.opacity(0.45), radius: 6, x: 0, y: 0)
                Text("本地保存")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(theme.palette.accent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(theme.palette.accent.opacity(0.12), in: Capsule())
            .overlay(Capsule().stroke(theme.palette.accent.opacity(0.24), lineWidth: 1))
            .help("所有灵感默认保存在本机，不上传云端")
            Button(action: onRefresh) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(hoveringRefresh ? theme.palette.text : theme.palette.muted)
                    .frame(width: 28, height: 28)
                    .background(hoveringRefresh ? theme.palette.cardStrong : theme.palette.card.opacity(0.62), in: Circle())
                    .overlay(Circle().stroke(theme.palette.line.opacity(hoveringRefresh ? 1.4 : 0.9), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .focusable(false)
            .onHover { hoveringRefresh = $0 }
            .help("刷新天气")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(height: 58)
        .background(
            LinearGradient(
                colors: [theme.palette.cardStrong.opacity(0.92), theme.palette.card.opacity(0.62)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 22, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(theme.palette.line.opacity(1.18), lineWidth: 1)
        )
        .shadow(color: theme.palette.accent.opacity(0.10), radius: 14, x: 0, y: 8)
    }

    private var growthStage: InspirationGrowthStage {
        InspirationGrowthStage.stage(for: todayWordCount)
    }
}

struct QuickDateWeatherBar: View {
    @EnvironmentObject private var weatherStore: WeatherStore
    @Environment(\.appTheme) private var theme

    var body: some View {
        QuickGlassCard(radius: 15) {
            HStack(spacing: 8) {
                Label(dateText, systemImage: theme.symbol(.calendar))
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.palette.text.opacity(0.88))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                    .layoutPriority(1)
                Spacer()
                Image(systemName: weatherStore.info?.icon ?? "cloud.sun.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(theme.palette.accent)
                Text(weatherText)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(theme.palette.text.opacity(0.86))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
            .padding(.horizontal, 12)
            .frame(height: 44)
        }
    }

    private var dateText: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.dateFormat = "M月d日 E"
        return formatter.string(from: Date())
    }

    private var weatherText: String {
        guard let info = weatherStore.info else { return weatherStore.message }
        return "\(info.city) \(Int(info.temperature.rounded()))°C \(info.summary)"
    }
}

struct QuickInspirationInputView: View {
    @Binding var text: String
    @Binding var isFocused: Bool
    @FocusState private var editorFocused: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text("写下刚刚闪过的一个想法…")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(QuickPanelStyle.weakText)
                    .padding(.top, 16)
                    .padding(.leading, 16)
            }
            TextEditor(text: $text)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(QuickPanelStyle.text)
                .scrollContentBackground(.hidden)
                .background(Color.clear)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 28)
                .focused($editorFocused)
                .onChange(of: text) { value in
                    let limited = String(value.prefix(quickInspirationCharacterLimit))
                    if limited != value { text = limited }
                }
            HStack {
                Text("⌘ + Enter 保存 · Esc 关闭")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(QuickPanelStyle.weakText)
                Spacer()
                Text("\(text.count) / \(quickInspirationCharacterLimit)")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(text.count >= quickInspirationCharacterLimit - 20 ? QuickPanelStyle.green : QuickPanelStyle.subText)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .frame(height: 120)
        .background(QuickPanelStyle.cardStrong, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(editorFocused || !text.isEmpty ? QuickPanelStyle.strokeActive : QuickPanelStyle.stroke, lineWidth: editorFocused || !text.isEmpty ? 1.25 : 1)
        )
        .shadow(color: (editorFocused ? QuickPanelStyle.purple : Color.black).opacity(editorFocused ? 0.30 : 0.14), radius: editorFocused ? 20 : 10, x: 0, y: 8)
        .onChange(of: editorFocused) { value in
            isFocused = value
        }
    }
}

struct InspirationStatusHintView: View {
    let text: String
    let symbol: String
    let feedback: String?

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(feedback == nil ? QuickPanelStyle.subText : QuickPanelStyle.green)
            .frame(height: 14)
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.18), value: text)
    }
}

struct PrimaryActionArea: View {
    let canSave: Bool
    let didSave: Bool
    let isSaving: Bool
    let onSave: () -> Void
    let onOpen: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onSave) {
                HStack(spacing: 8) {
                    Image(systemName: didSave ? "checkmark.circle.fill" : "sparkles")
                    Text(buttonTitle)
                }
                .font(.system(size: 13, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .frame(maxWidth: .infinity, minHeight: 40)
            }
            .buttonStyle(QuickPrimaryButtonStyle())
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!canSave || isSaving)
            .opacity(canSave ? 1 : 0.46)

            Button(action: onOpen) {
                HStack(spacing: 8) {
                    Text("打开完整胶囊")
                    Image(systemName: "arrow.right")
                }
                .font(.system(size: 12, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .frame(maxWidth: .infinity, minHeight: 40)
            }
            .buttonStyle(QuickSecondaryButtonStyle())
            .keyboardShortcut("o", modifiers: .command)
        }
    }

    private var buttonTitle: String {
        if didSave { return "已保存" }
        if isSaving { return "保存中…" }
        return canSave ? "保存灵感  ⌘↵" : "输入后保存"
    }
}

struct RecentInspirationListView: View {
    let items: [RecentInspiration]
    let onViewAll: () -> Void
    let onOpenItem: (RecentInspiration) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("最近灵感")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(QuickPanelStyle.text)
                Spacer()
                Button(action: onViewAll) {
                    HStack(spacing: 4) {
                        Text("查看全部")
                        Image(systemName: "chevron.right")
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(QuickPanelStyle.subText)
                }
                .buttonStyle(.plain)
                .focusable(false)
            }

            if items.isEmpty {
                QuickGlassCard(radius: 14) {
                    Text("还没有灵感记录，先把第一颗种子放进胶囊吧")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(QuickPanelStyle.subText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
            } else {
                VStack(spacing: 7) {
                    ForEach(items.prefix(2)) { item in
                        RecentInspirationCard(item: item, onOpen: { onOpenItem(item) })
                    }
                }
            }
        }
    }
}

struct RecentInspirationCard: View {
    let item: RecentInspiration
    let onOpen: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onOpen) {
            QuickGlassCard(active: hovering, radius: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .top, spacing: 9) {
                        Circle()
                            .fill(LinearGradient(colors: [QuickPanelStyle.blue, QuickPanelStyle.purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 8, height: 8)
                            .padding(.top, 6)
                        Text(item.displayText)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(QuickPanelStyle.text.opacity(0.90))
                            .lineLimit(2)
                        Spacer(minLength: 8)
                        if hovering {
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(item.text, forType: .string)
                            } label: {
                                Image(systemName: "doc.on.doc")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(QuickPanelStyle.subText)
                                    .frame(width: 24, height: 24)
                                    .background(QuickPanelStyle.cardStrong, in: Circle())
                            }
                            .buttonStyle(.plain)
                            .focusable(false)
                        }
                    }
                    HStack {
                        Text(item.timeText)
                        Spacer()
                        Text(item.countText)
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(QuickPanelStyle.weakText)
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .frame(height: 66)
            }
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hovering = $0 }
    }
}

struct QuickActionGridView: View {
    @Environment(\.appTheme) private var theme
    let action: (QuickPanelRoute) -> Void

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 7), count: 4), spacing: 7) {
            ForEach(items, id: \.0.rawValue) { item in
                QuickActionTile(title: item.1, systemImage: item.2) {
                    action(item.0)
                }
            }
        }
    }

    private var items: [(QuickPanelRoute, String, String)] {
        [
            (.dailyInspiration, "今日启发", "sparkles"),
            (.summary, "今日总结", theme.symbol(.note)),
            (.history, "历史胶囊", "archivebox"),
            (.theme, "主题", "paintpalette"),
            (.settings, "设置", "gearshape")
        ]
    }
}

struct QuickActionTile: View {
    let title: String
    let systemImage: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(QuickPanelStyle.blue.opacity(hovering ? 1 : 0.78))
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(QuickPanelStyle.subText)
                    .noWrap(scale: 0.72)
            }
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(QuickPanelStyle.card.opacity(hovering ? 1.35 : 1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(hovering ? QuickPanelStyle.strokeActive : QuickPanelStyle.stroke, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .focusable(false)
        .scaleEffect(hovering ? 1.02 : 1)
        .animation(.spring(response: 0.20, dampingFraction: 0.82), value: hovering)
        .onHover { hovering = $0 }
    }
}

struct QuickPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color.white)
            .background(
                LinearGradient(
                    colors: [QuickPanelStyle.blue, QuickPanelStyle.purple, Color(red: 0.75, green: 0.52, blue: 0.99)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .opacity(configuration.isPressed ? 0.82 : 1),
                in: RoundedRectangle(cornerRadius: 15, style: .continuous)
            )
            .shadow(color: QuickPanelStyle.purple.opacity(configuration.isPressed ? 0.12 : 0.24), radius: 16, x: 0, y: 8)
            .focusable(false)
    }
}

struct QuickSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(QuickPanelStyle.text.opacity(configuration.isPressed ? 0.72 : 0.92))
            .background(QuickPanelStyle.card.opacity(configuration.isPressed ? 0.65 : 1), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .stroke(QuickPanelStyle.stroke, lineWidth: 1)
            )
            .focusable(false)
    }
}

struct FooterBrandSloganView: View {
    var body: some View {
        Text("愿你的灵感，慢慢发光 ✨")
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(QuickPanelStyle.subText.opacity(0.82))
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, -4)
    }
}

struct ContentView: View {
    @EnvironmentObject private var store: ReminderStore
    @EnvironmentObject private var iconManager: AppIconManager
    @ObservedObject private var windowRenderState = WindowRenderState.shared
    @AppStorage("selectedTheme") private var selectedThemeRaw = AppTheme.immersiveVista.rawValue
    @State private var selectedDate = Date()
    @State private var showingEditor = false
    @State private var editingItem: ReminderItem?
    @State private var showingIconSettings = false
    @State private var showingThemePanel = false
    @State private var showingHistory = false
    @State private var showingKnowledgeBase = false
    @State private var showingDailyGreeting = false
    @State private var greeting = EmotionalCopy.greetings.randomElement() ?? EmotionalCopy.greetings[0]
    @AppStorage("lastDailyGreetingDate") private var lastDailyGreetingDate = ""

    var body: some View {
        GeometryReader { proxy in
            let theme = AppTheme(rawValue: selectedThemeRaw) ?? .immersiveVista
            let compact = proxy.size.width < 1020
            let outerPadding: CGFloat = compact ? 18 : 30
            let innerPadding: CGFloat = compact ? 16 : 24
            let sidebarWidth: CGFloat = compact ? 276 : 300

            ZStack {
                AnimatedGlowBackground(theme: theme)
                HStack(spacing: 0) {
                    Sidebar(selectedDate: $selectedDate, showingEditor: $showingEditor, showingHistory: $showingHistory, showingKnowledgeBase: $showingKnowledgeBase, selectedThemeRaw: $selectedThemeRaw, compact: compact) {
                        RestWindowManager.shared.show(theme: theme) {
                            RestWindowManager.shared.close()
                        }
                    }
                        .frame(width: sidebarWidth)
                    Rectangle()
                        .fill(theme.palette.line)
                        .frame(width: 1)
                    Group {
                        if showingHistory {
                            HistoryCapsulesView(selectedDate: $selectedDate, showingHistory: $showingHistory, compact: compact)
                        } else if showingKnowledgeBase {
                            KnowledgeBaseView(selectedDate: $selectedDate, showingKnowledgeBase: $showingKnowledgeBase, compact: compact)
                        } else {
                            DayDetail(selectedDate: $selectedDate, showingEditor: $showingEditor, editingItem: $editingItem, compact: compact)
                        }
                    }
                    .frame(minWidth: 0, maxWidth: .infinity)
                }
                .padding(innerPadding)
                .glassPanel(radius: 30)
                .padding(outerPadding)
                .animation(.spring(response: 0.34, dampingFraction: 0.86), value: compact)
                Button {
                    showingIconSettings = true
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 14, weight: .bold))
                }
                .buttonStyle(IconButtonStyle(tint: theme.palette.accent))
                .padding(.trailing, outerPadding + 12)
                .padding(.bottom, outerPadding + 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .help("启动图标设置")

                if showingDailyGreeting {
                    DailyOpeningOverlay(copy: greeting) {
                        closeGreeting()
                    }
                    .padding(outerPadding + 22)
                    .transition(.scale(scale: 0.94).combined(with: .opacity))
                }
            }
            .environment(\.appTheme, theme)
            .environment(\.lightweightRendering, windowRenderState.isLightweightMode)
        }
        .preferredColorScheme(.dark)
        .animation(.easeInOut(duration: 0.28), value: selectedThemeRaw)
        .animation(.spring(response: 0.30, dampingFraction: 0.84), value: selectedDate)
        .onAppear {
            PerformanceDiagnostics.recordFirstContentIfNeeded()
            iconManager.applySavedIcon()
            showDailyGreetingIfNeeded()
        }
        .sheet(isPresented: $showingEditor) {
            ReminderEditor(item: editingItem, selectedDate: selectedDate) { item in
                if editingItem == nil {
                    store.add(item)
                } else {
                    store.update(item)
                }
                editingItem = nil
            }
            .environmentObject(store)
        }
        .sheet(isPresented: $showingIconSettings) {
            IconSettingsSheet(selectedThemeRaw: $selectedThemeRaw)
                .environmentObject(iconManager)
                .environmentObject(store)
                .environment(\.appTheme, AppTheme(rawValue: selectedThemeRaw) ?? .immersiveVista)
        }
        .sheet(isPresented: $showingThemePanel) {
            ThemePickerSheet(selectedThemeRaw: $selectedThemeRaw)
                .environment(\.appTheme, AppTheme(rawValue: selectedThemeRaw) ?? .immersiveVista)
        }
        .onChange(of: showingEditor) { isShowing in
            if !isShowing { editingItem = nil }
        }
        .onReceive(NotificationCenter.default.publisher(for: .quickPanelRouteRequested)) { notification in
            guard
                let rawValue = notification.object as? String,
                let route = QuickPanelRoute(rawValue: rawValue)
            else { return }
            handleQuickPanelRoute(route)
        }
    }

    private func handleQuickPanelRoute(_ route: QuickPanelRoute) {
        selectedDate = Date()
        switch route {
        case .today, .dailyInspiration:
            showingHistory = false
            showingKnowledgeBase = false
        case .summary:
            showingHistory = false
            showingKnowledgeBase = false
        case .history:
            showingHistory = true
            showingKnowledgeBase = false
        case .theme:
            showingHistory = false
            showingKnowledgeBase = false
            showingThemePanel = true
        case .settings:
            showingHistory = false
            showingKnowledgeBase = false
            showingIconSettings = true
        }
    }

    private func showDailyGreetingIfNeeded() {
        let today = DateKey.string(from: Date())
        guard lastDailyGreetingDate != today else { return }
        greeting = EmotionalCopy.greetings.randomElement() ?? greeting
        lastDailyGreetingDate = today
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
            showingDailyGreeting = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            closeGreeting()
        }
    }

    private func closeGreeting() {
        withAnimation(.easeOut(duration: 0.22)) {
            showingDailyGreeting = false
        }
    }
}

struct Sidebar: View {
    @EnvironmentObject private var store: ReminderStore
    @EnvironmentObject private var noteStore: NoteStore
    @EnvironmentObject private var iconManager: AppIconManager
    @Environment(\.appTheme) private var theme
    @Binding var selectedDate: Date
    @Binding var showingEditor: Bool
    @Binding var showingHistory: Bool
    @Binding var showingKnowledgeBase: Bool
    @Binding var selectedThemeRaw: String
    let compact: Bool
    let onStartRestMode: () -> Void
    @State private var visibleMonth = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 9 : 11) {
            VStack(alignment: .leading, spacing: compact ? 5 : 6) {
                Text("灵栖胶囊Capsule")
                    .font(.system(size: compact ? 22 : 25, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.palette.text)
                    .noWrap(scale: 0.70)
                Text(todaySummary)
                    .font(.system(size: compact ? 11 : 12, weight: .medium))
                    .foregroundStyle(theme.palette.muted)
                    .noWrap(scale: 0.68)
            }
            .padding(.top, compact ? 10 : 14)

            CalendarPanel(selectedDate: $selectedDate, visibleMonth: $visibleMonth, compact: compact)

            SidebarQuickActionRow(
                compact: compact,
                onRest: onStartRestMode,
                onToday: {
                    selectedDate = Date()
                    showingHistory = false
                    showingKnowledgeBase = false
                },
                onNewItem: {
                    showingHistory = false
                    showingKnowledgeBase = false
                    showingEditor = true
                }
            )

            SidebarKnowledgeButton(
                isActive: showingKnowledgeBase,
                compact: compact,
                action: {
                    showingHistory = false
                    showingKnowledgeBase = true
                }
            )

            SidebarHistoryButton(
                isActive: showingHistory,
                compact: compact,
                action: {
                    showingKnowledgeBase = false
                    showingHistory = true
                }
            )

            InspirationSeedCard(noteCount: noteStore.note(for: Date()).count, compact: compact)
        }
        .padding(.horizontal, compact ? 12 : 18)
        .padding(.bottom, compact ? 10 : 14)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(theme.palette.ink.opacity(0.18))
    }

    private var todaySummary: String {
        let count = store.count(on: Date())
        return count == 0 ? "今天还没有安排，给自己留一点秩序。" : "今天已有 \(count) 个事项等待处理。"
    }
}

struct SidebarQuickActionRow: View {
    @Environment(\.appTheme) private var theme
    let compact: Bool
    let onRest: () -> Void
    let onToday: () -> Void
    let onNewItem: () -> Void

    var body: some View {
        HStack(spacing: compact ? 6 : 7) {
            SidebarQuickActionButton(
                title: compact ? "休鼾" : "休鼾一下",
                systemImage: "moon.zzz.fill",
                accent: theme.palette.warm,
                compact: compact,
                action: onRest
            )
            SidebarQuickActionButton(
                title: "今天",
                systemImage: "calendar",
                accent: theme.palette.cyan,
                compact: compact,
                action: onToday
            )
            SidebarQuickActionButton(
                title: "新事项",
                systemImage: "plus",
                accent: theme.palette.accent,
                compact: compact,
                isPrimary: true,
                action: onNewItem
            )
        }
        .frame(maxWidth: .infinity)
    }
}

struct SidebarQuickActionButton: View {
    @Environment(\.appTheme) private var theme
    let title: String
    let systemImage: String
    let accent: Color
    let compact: Bool
    var isPrimary = false
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: compact ? 4 : 5) {
                Image(systemName: systemImage)
                    .font(.system(size: compact ? 10 : 11, weight: .bold))
                Text(title)
                    .font(.system(size: compact ? 10.5 : 11.5, weight: .bold, design: .rounded))
                    .noWrap(scale: 0.58)
            }
            .foregroundStyle(isPrimary ? .white : theme.palette.text)
            .frame(maxWidth: .infinity, minHeight: compact ? 34 : 37)
            .padding(.horizontal, compact ? 5 : 6)
            .background(buttonBackground, in: RoundedRectangle(cornerRadius: compact ? 13 : 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: compact ? 13 : 14, style: .continuous)
                    .stroke(isPrimary ? Color.white.opacity(0.22) : accent.opacity(isHovering ? 0.74 : 0.36), lineWidth: isHovering ? 1.35 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: compact ? 13 : 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovering ? 1.025 : 1)
        .shadow(color: accent.opacity(isHovering ? 0.22 : 0.10), radius: isHovering ? 14 : 8, x: 0, y: 5)
        .animation(.spring(response: 0.20, dampingFraction: 0.80), value: isHovering)
        .onHover { isHovering = $0 }
    }

    private var buttonBackground: some ShapeStyle {
        if isPrimary {
            return AnyShapeStyle(
                LinearGradient(
                    colors: [theme.palette.cyan.opacity(0.90), theme.palette.accent.opacity(0.86)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        }
        return AnyShapeStyle(
            LinearGradient(
                colors: [accent.opacity(0.22), theme.palette.cardStrong.opacity(0.88)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }
}

struct CalendarPanel: View {
    @EnvironmentObject private var store: ReminderStore
    @EnvironmentObject private var noteStore: NoteStore
    @Environment(\.appTheme) private var theme
    @Binding var selectedDate: Date
    @Binding var visibleMonth: Date
    let compact: Bool

    private let weekdaySymbols = ["日", "一", "二", "三", "四", "五", "六"]

    var body: some View {
        VStack(spacing: compact ? 5 : 6) {
            HStack {
                Button {
                    moveMonth(-1)
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: compact ? 10 : 11, weight: .bold))
                        .frame(width: compact ? 26 : 28, height: compact ? 26 : 28)
                }
                .buttonStyle(.plain)
                .focusable(false)
                .background(theme.palette.card.opacity(0.72), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .stroke(theme.palette.line.opacity(0.75), lineWidth: 1)
                )
                Spacer()
                Text(monthTitle)
                    .font(.system(size: compact ? 12.5 : 13.5, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.palette.text)
                    .noWrap(scale: 0.8)
                Spacer()
                Button {
                    moveMonth(1)
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: compact ? 10 : 11, weight: .bold))
                        .frame(width: compact ? 26 : 28, height: compact ? 26 : 28)
                }
                .buttonStyle(.plain)
                .focusable(false)
                .background(theme.palette.card.opacity(0.72), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .stroke(theme.palette.line.opacity(0.75), lineWidth: 1)
                )
            }

            LazyVGrid(columns: columns, spacing: compact ? 2 : 3) {
                ForEach(weekdaySymbols, id: \.self) { symbol in
                    Text(symbol)
                        .font(.system(size: compact ? 8.5 : 9.5, weight: .bold))
                        .foregroundStyle(theme.palette.muted)
                        .frame(height: compact ? 11 : 12)
                }
                ForEach(days, id: \.self) { day in
                    CalendarDayCell(
                        day: day,
                        selectedDate: $selectedDate,
                        visibleMonth: visibleMonth,
                        count: store.count(on: day),
                        hasNote: noteStore.hasNote(on: day),
                        compact: compact
                    )
                }
            }
            HStack(spacing: compact ? 8 : 10) {
                CalendarLegendDot(color: theme.palette.cyan, text: "事项")
                CalendarLegendDot(color: theme.palette.warm, text: "灵感")
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, compact ? 9 : 10)
        .padding(.vertical, compact ? 8 : 9)
        .glassPanel(radius: compact ? 20 : 21)
        .hoverLift()
    }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: compact ? 2 : 3), count: 7)
    }

    private var monthTitle: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.dateFormat = "yyyy年 M月"
        return formatter.string(from: visibleMonth)
    }

    private var days: [Date] {
        let calendar = Calendar.current
        let interval = calendar.dateInterval(of: .month, for: visibleMonth)!
        let firstWeekday = calendar.component(.weekday, from: interval.start)
        let range = calendar.range(of: .day, in: .month, for: interval.start)!
        let startOffset = 1 - firstWeekday
        let totalCells = Int(ceil(Double(firstWeekday - 1 + range.count) / 7.0)) * 7
        return (0..<totalCells).compactMap { calendar.date(byAdding: .day, value: startOffset + $0, to: interval.start) }
    }

    private func moveMonth(_ value: Int) {
        visibleMonth = Calendar.current.date(byAdding: .month, value: value, to: visibleMonth) ?? visibleMonth
    }
}

struct CalendarLegendDot: View {
    let color: Color
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(text)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.58))
                .noWrap(scale: 0.8)
        }
    }
}

struct SidebarHistoryButton: View {
    @Environment(\.appTheme) private var theme
    let isActive: Bool
    let compact: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: isActive ? "archivebox.fill" : "archivebox")
                    .font(.system(size: compact ? 12 : 14, weight: .bold))
                    .foregroundStyle(theme.palette.cyan)
                    .frame(width: compact ? 28 : 31, height: compact ? 28 : 31)
                    .background(theme.palette.cyan.opacity(0.14), in: RoundedRectangle(cornerRadius: compact ? 9 : 10, style: .continuous))
                VStack(alignment: .leading, spacing: compact ? 2 : 3) {
                    Text("历史胶囊")
                        .font(.system(size: compact ? 12 : 13, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.palette.text)
                        .noWrap()
                    Text("回看每日灵感、事项与总结")
                        .font(.system(size: compact ? 9.5 : 10.5, weight: .medium))
                        .foregroundStyle(theme.palette.muted)
                        .noWrap(scale: 0.62)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: compact ? 9.5 : 10.5, weight: .bold))
                    .foregroundStyle(theme.palette.muted)
            }
            .padding(.horizontal, compact ? 11 : 13)
            .padding(.vertical, compact ? 8 : 10)
            .glassPanel(radius: compact ? 15 : 16, active: isActive || isHovering)
            .contentShape(RoundedRectangle(cornerRadius: compact ? 15 : 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .focusable(false)
        .scaleEffect(isHovering ? 1.012 : 1)
        .animation(.spring(response: 0.22, dampingFraction: 0.82), value: isHovering)
        .onHover { isHovering = $0 }
    }
}

struct SidebarKnowledgeButton: View {
    @Environment(\.appTheme) private var theme
    let isActive: Bool
    let compact: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: isActive ? "brain.head.profile.fill" : "brain.head.profile")
                    .font(.system(size: compact ? 12 : 14, weight: .bold))
                    .foregroundStyle(theme.palette.accent)
                    .frame(width: compact ? 28 : 31, height: compact ? 28 : 31)
                    .background(theme.palette.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: compact ? 9 : 10, style: .continuous))
                VStack(alignment: .leading, spacing: compact ? 2 : 3) {
                    Text("个人知识库")
                        .font(.system(size: compact ? 12 : 13, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.palette.text)
                        .noWrap()
                    Text("沉淀灵感、搜索知识与画像")
                        .font(.system(size: compact ? 9.5 : 10.5, weight: .medium))
                        .foregroundStyle(theme.palette.muted)
                        .noWrap(scale: 0.62)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: compact ? 9.5 : 10.5, weight: .bold))
                    .foregroundStyle(theme.palette.muted)
            }
            .padding(.horizontal, compact ? 11 : 13)
            .padding(.vertical, compact ? 8 : 10)
            .glassPanel(radius: compact ? 15 : 16, active: isActive || isHovering)
            .contentShape(RoundedRectangle(cornerRadius: compact ? 15 : 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .focusable(false)
        .scaleEffect(isHovering ? 1.012 : 1)
        .animation(.spring(response: 0.22, dampingFraction: 0.82), value: isHovering)
        .onHover { isHovering = $0 }
    }
}

struct ThemePickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var theme
    @Binding var selectedThemeRaw: String

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("主题换肤")
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.palette.text)
                    Text("选择一种更适合此刻状态的视觉氛围。")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(theme.palette.muted)
                }
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(IconButtonStyle())
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                ForEach(AppTheme.allCases) { appTheme in
                    ThemeSwatch(appTheme: appTheme, isSelected: currentTheme == appTheme) {
                        selectedThemeRaw = appTheme.rawValue
                    }
                    .frame(height: 44)
                }
            }
        }
        .padding(26)
        .frame(width: 520)
        .background(
            LinearGradient(colors: [theme.palette.ink, theme.palette.plum], startPoint: .topLeading, endPoint: .bottomTrailing)
        )
    }

    private var currentTheme: AppTheme {
        AppTheme(rawValue: selectedThemeRaw) ?? .immersiveVista
    }
}

struct ThemeSwitcher: View {
    @Environment(\.appTheme) private var theme
    @Binding var selectedThemeRaw: String
    let compact: Bool
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack {
                    Label("一键换肤", systemImage: theme.symbol(.theme))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.palette.accent)
                        .noWrap()
                    Spacer()
                    Text(currentTheme.shortTitle)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(theme.palette.muted)
                        .noWrap()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(theme.palette.muted)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
            }
            .buttonStyle(.plain)
            .focusable(false)

            if isExpanded {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                    ForEach(AppTheme.allCases) { appTheme in
                        ThemeSwatch(appTheme: appTheme, isSelected: currentTheme == appTheme) {
                            withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                                selectedThemeRaw = appTheme.rawValue
                            }
                        }
                    }
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(compact ? 12 : 14)
        .glassPanel(radius: 18, active: isExpanded)
        .hoverLift()
    }

    private var currentTheme: AppTheme {
        AppTheme(rawValue: selectedThemeRaw) ?? .immersiveVista
    }
}

struct ThemeSwatch: View {
    let appTheme: AppTheme
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [appTheme.palette.accent, appTheme.palette.accent2],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 16, height: 16)
                    .overlay(Circle().stroke(Color.white.opacity(0.38), lineWidth: 1))
                Text(appTheme.shortTitle)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(appTheme.palette.text)
                    .noWrap(scale: 0.7)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .background(appTheme.palette.cardStrong.opacity(isSelected ? 1 : 0.58), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(isSelected ? appTheme.palette.accent.opacity(0.92) : Color.white.opacity(0.10), lineWidth: isSelected ? 1.4 : 1)
            )
        }
        .buttonStyle(.plain)
        .focusable(false)
        .hoverLift()
        .animation(.spring(response: 0.24, dampingFraction: 0.78), value: isSelected)
    }
}

struct MoodNote: View {
    @Environment(\.appTheme) private var theme
    let themeName: AppTheme

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ThemeMiniIllustration(symbol: theme.illustrationSymbol, size: 38)
            VStack(alignment: .leading, spacing: 5) {
                Text(themeName.toneLine)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(theme.palette.text)
                    .noWrap()
                Text(themeName.mood)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.palette.muted)
                    .lineLimit(2)
                    .minimumScaleFactor(0.82)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .glassPanel(radius: 18)
        .hoverLift()
    }
}

private struct KnowledgeEntryOverride: Codable {
    let categoryRawValue: String
    let keywords: [String]
    var statusRawValue: String?
}

private struct KnowledgeMonthFilter: Identifiable, Equatable {
    let id: String
    let date: Date
    let title: String
}

private enum KnowledgeQuickTimeRange: String, CaseIterable, Identifiable {
    case all
    case sevenDays
    case thirtyDays
    case thisMonth

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "全部时间"
        case .sevenDays: return "近 7 天"
        case .thirtyDays: return "近 30 天"
        case .thisMonth: return "本月"
        }
    }

    func range(referenceDate: Date = Date(), calendar: Calendar = .current) -> KnowledgeTimeRange? {
        switch self {
        case .all:
            return nil
        case .sevenDays:
            return KnowledgeTimeRange(start: calendar.date(byAdding: .day, value: -6, to: referenceDate), end: referenceDate)
        case .thirtyDays:
            return KnowledgeTimeRange(start: calendar.date(byAdding: .day, value: -29, to: referenceDate), end: referenceDate)
        case .thisMonth:
            let start = calendar.date(from: calendar.dateComponents([.year, .month], from: referenceDate))
            return KnowledgeTimeRange(start: start, end: referenceDate)
        }
    }
}

private enum KnowledgeCognitiveState: String {
    case idle
    case active
    case growing
    case saturated

    var title: String {
        switch self {
        case .idle: return "等待沉淀"
        case .active: return "正在沉淀"
        case .growing: return "持续成长"
        case .saturated: return "高能饱满"
        }
    }

    var subtitle: String {
        switch self {
        case .idle: return "写下第一条灵感，知识胶囊会被点亮。"
        case .active: return "今天已经开始形成可复用的知识痕迹。"
        case .growing: return "近期沉淀正在加速，认知结构更清晰。"
        case .saturated: return "今日知识能量很满，适合回看与归纳。"
        }
    }

    var symbol: String {
        switch self {
        case .idle: return "moon.stars"
        case .active: return "sparkles"
        case .growing: return "leaf"
        case .saturated: return "bolt.fill"
        }
    }
}

struct KnowledgeBaseView: View {
    @EnvironmentObject private var noteStore: NoteStore
    @EnvironmentObject private var reminderStore: ReminderStore
    @EnvironmentObject private var weatherStore: WeatherStore
    @Environment(\.appTheme) private var theme
    @Binding var selectedDate: Date
    @Binding var showingKnowledgeBase: Bool
    let compact: Bool
    @State private var query = ""
    @State private var selectedCategory: KnowledgeCategory?
    @State private var selectedMonth: KnowledgeMonthFilter?
    @State private var selectedMood: String?
    @State private var selectedStatus: KnowledgeStatus?
    @State private var selectedTimeRange: KnowledgeQuickTimeRange = .all
    @State private var selectedTrendGranularity: KnowledgeTrendGranularity = .month
    @State private var knowledgeEntries: [KnowledgeEntry] = []
    @State private var profileSnapshot = KnowledgeBaseService.profile(from: [])
    @State private var trendPoints: [KnowledgeTrendPoint] = []
    @State private var categoryShares: [KnowledgeCategoryShare] = []
    @State private var keywordNetwork = KnowledgeKeywordNetwork(nodes: [], edges: [])
    @State private var detailEntry: KnowledgeEntry?
    @State private var entryOverrides: [String: KnowledgeEntryOverride] = [:]
    @State private var hasLoadedKnowledgePage = false

    private var entries: [KnowledgeEntry] {
        knowledgeEntries
    }

    private var activeFilter: KnowledgeSearchFilter {
        KnowledgeSearchFilter(
            query: query,
            category: selectedCategory,
            month: selectedMonth?.date,
            timeRange: selectedTimeRange.range(),
            mood: selectedMood,
            status: selectedStatus
        )
    }

    private var filteredEntries: [KnowledgeEntry] {
        KnowledgeBaseService.search(entries, filter: activeFilter)
    }

    private var publishedKnowledgeFilter: KnowledgeSearchFilter {
        var filter = activeFilter
        filter.status = .published
        return filter
    }

    private var publishedFilteredEntries: [KnowledgeEntry] {
        KnowledgeBaseService.search(entries, filter: publishedKnowledgeFilter)
    }

    private var profile: KnowledgeProfile {
        profileSnapshot
    }

    private var todayEntries: [KnowledgeEntry] {
        entries.filter { Calendar.current.isDateInToday($0.date) }
    }

    private var yesterdayEntries: [KnowledgeEntry] {
        entries.filter { Calendar.current.isDateInYesterday($0.date) }
    }

    private var todayKnowledgeWords: Int {
        todayEntries.reduce(0) { $0 + $1.wordCount }
    }

    private var yesterdayKnowledgeWords: Int {
        yesterdayEntries.reduce(0) { $0 + $1.wordCount }
    }

    private var knowledgeGrowthRate: Int {
        guard yesterdayKnowledgeWords > 0 else { return todayKnowledgeWords > 0 ? 100 : 0 }
        return Int(((Double(todayKnowledgeWords - yesterdayKnowledgeWords) / Double(yesterdayKnowledgeWords)) * 100).rounded())
    }

    private var cognitiveState: KnowledgeCognitiveState {
        if todayKnowledgeWords >= 1200 { return .saturated }
        if todayKnowledgeWords >= 300 || knowledgeGrowthRate >= 50 { return .growing }
        if todayKnowledgeWords > 0 { return .active }
        return .idle
    }

    private var coreKeywords: [String] {
        let todayKeywords = todayEntries.flatMap(\.keywords)
        let scopedKeywords = todayKeywords.isEmpty ? profile.topKeywords : todayKeywords
        var result: [String] = []
        for keyword in scopedKeywords where !result.contains(keyword) {
            result.append(keyword)
            if result.count == 5 { break }
        }
        return result
    }

    private var availableMonths: [KnowledgeMonthFilter] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.dateFormat = "yyyy年M月"
        var seen = Set<String>()
        return entries.compactMap { entry in
            let monthStart = Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: entry.date)) ?? entry.date
            let key = DateKey.string(from: monthStart)
            guard !seen.contains(key) else { return nil }
            seen.insert(key)
            return KnowledgeMonthFilter(id: key, date: monthStart, title: formatter.string(from: monthStart))
        }
    }

    private var availableMoods: [String] {
        Array(Set(entries.map { $0.mood.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }))
            .sorted()
    }

    private var hasActiveFilters: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || selectedCategory != nil
            || selectedMonth != nil
            || selectedMood != nil
            || selectedStatus != nil
            || selectedTimeRange != .all
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: compact ? 14 : 18) {
                header
                if let detailEntry {
                    KnowledgeDetailPanel(entry: detailEntry, compact: compact) {
                        self.detailEntry = nil
                    } saveEdits: { category, keywords, status in
                        saveEntryEdits(entry: detailEntry, category: category, keywords: keywords, status: status)
                    } openSource: {
                        selectedDate = detailEntry.date
                        showingKnowledgeBase = false
                    }
                } else {
                    if profile.totalEntries > 0 {
                        cognitiveHomePanel
                    } else {
                        inboxHint
                    }
                    searchPanel
                    if filteredEntries.isEmpty {
                        emptyState
                    } else {
                        KnowledgeFeedSection(
                            entries: filteredEntries,
                            compact: compact,
                            reuseEntry: copyKnowledgeText,
                            editEntry: { detailEntry = $0 },
                            viewEntry: openKnowledgeSource
                        )
                    }
                }
            }
            .padding(.horizontal, compact ? 20 : 32)
            .padding(.bottom, 26)
        }
        .onAppear {
            loadOverrides()
            reloadKnowledge()
            hasLoadedKnowledgePage = false
            withAnimation(.spring(response: 0.42, dampingFraction: 0.88).delay(0.04)) {
                hasLoadedKnowledgePage = true
            }
        }
        .onReceive(noteStore.objectWillChange) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: reloadKnowledge)
        }
        .onReceive(reminderStore.objectWillChange) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: reloadKnowledge)
        }
        .onChange(of: query) { _ in refreshKnowledgeDerivedState() }
        .onChange(of: selectedCategory) { _ in refreshKnowledgeDerivedState() }
        .onChange(of: selectedMonth) { _ in refreshKnowledgeDerivedState() }
        .onChange(of: selectedMood) { _ in refreshKnowledgeDerivedState() }
        .onChange(of: selectedStatus) { _ in refreshKnowledgeDerivedState() }
        .onChange(of: selectedTimeRange) { _ in refreshKnowledgeDerivedState() }
        .onChange(of: selectedTrendGranularity) { _ in refreshKnowledgeDerivedState() }
    }

    private func reloadKnowledge() {
        let sources = DailyCapsuleService.historyCapsules(noteStore: noteStore, reminderStore: reminderStore, weatherInfo: weatherStore.info)
            .map { capsule in
                KnowledgeSourceEntry(
                    id: UUID(uuidString: capsule.id.uuidSeed) ?? UUID(),
                    date: capsule.date,
                    text: capsule.noteText,
                    keywords: capsule.keywords,
                    summary: capsule.summary,
                    mood: capsule.mood
                )
            }
        let newEntries = KnowledgeBaseService.entries(from: sources).map(applyOverride)
        knowledgeEntries = newEntries
        refreshKnowledgeDerivedState(allEntries: newEntries)
        if let detailEntry, let refreshed = newEntries.first(where: { $0.id == detailEntry.id }) {
            self.detailEntry = refreshed
        }
    }

    private func refreshKnowledgeDerivedState() {
        refreshKnowledgeDerivedState(allEntries: knowledgeEntries)
    }

    private func refreshKnowledgeDerivedState(allEntries: [KnowledgeEntry]) {
        let visiblePublishedEntries = KnowledgeBaseService.search(allEntries, filter: publishedKnowledgeFilter)
        profileSnapshot = KnowledgeBaseService.profile(from: visiblePublishedEntries)
        trendPoints = KnowledgeBaseService.trend(from: allEntries, filter: publishedKnowledgeFilter, granularity: selectedTrendGranularity)
        categoryShares = KnowledgeBaseService.categoryShares(from: allEntries, filter: publishedKnowledgeFilter)
        keywordNetwork = KnowledgeBaseService.keywordNetwork(from: allEntries, filter: publishedKnowledgeFilter)
    }

    private func applyOverride(to entry: KnowledgeEntry) -> KnowledgeEntry {
        guard let override = entryOverrides[entry.id.uuidString],
              let category = KnowledgeCategory(rawValue: override.categoryRawValue) else {
            return entry
        }
        let edited = KnowledgeBaseService.applyEdits(to: entry, category: category, keywords: override.keywords)
        let status = KnowledgeStatus(rawValue: override.statusRawValue ?? "") ?? .published
        return KnowledgeBaseService.applyStatus(to: edited, status: status)
    }

    private func saveEntryEdits(entry: KnowledgeEntry, category: KnowledgeCategory, keywords: [String], status: KnowledgeStatus) {
        let edited = KnowledgeBaseService.applyStatus(
            to: KnowledgeBaseService.applyEdits(to: entry, category: category, keywords: keywords),
            status: status
        )
        entryOverrides[entry.id.uuidString] = KnowledgeEntryOverride(
            categoryRawValue: edited.category.rawValue,
            keywords: edited.keywords,
            statusRawValue: edited.status.rawValue
        )
        persistOverrides()
        knowledgeEntries = knowledgeEntries.map { $0.id == edited.id ? edited : $0 }
        refreshKnowledgeDerivedState()
        detailEntry = edited
    }

    private func loadOverrides() {
        guard let data = UserDefaults.standard.data(forKey: "knowledge.entry.overrides.v1"),
              let decoded = try? JSONDecoder().decode([String: KnowledgeEntryOverride].self, from: data) else {
            entryOverrides = [:]
            return
        }
        entryOverrides = decoded
    }

    private func persistOverrides() {
        guard let data = try? JSONEncoder().encode(entryOverrides) else { return }
        UserDefaults.standard.set(data, forKey: "knowledge.entry.overrides.v1")
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("个人知识库")
                    .font(.system(size: compact ? 28 : 34, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.palette.text)
                    .noWrap()
                Text("从历史灵感中沉淀可搜索、可复用的知识条目。")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(theme.palette.muted)
                    .noWrap(scale: 0.72)
            }
            Spacer()
            Button {
                showingKnowledgeBase = false
                selectedDate = Date()
            } label: {
                Label("回到今天", systemImage: "calendar")
                    .font(.system(size: 12, weight: .bold))
                    .noWrap()
            }
            .buttonStyle(SecondaryButtonStyle())
        }
        .padding(.top, compact ? 16 : 24)
    }

    private var cognitiveHomePanel: some View {
        VStack(alignment: .leading, spacing: compact ? 18 : 24) {
            KnowledgeCoreCard(
                state: cognitiveState,
                todayWords: todayKnowledgeWords,
                growthRate: knowledgeGrowthRate,
                keywords: coreKeywords,
                compact: compact,
                continueAction: continueKnowledgeCapture
            )
            .opacity(hasLoadedKnowledgePage ? 1 : 0)
            .offset(y: hasLoadedKnowledgePage ? 0 : 16)

            KnowledgeInsightSection(
                trendPoints: trendPoints,
                selectedGranularity: $selectedTrendGranularity,
                categoryShares: categoryShares,
                keywordNodes: keywordNetwork.nodes,
                compact: compact,
                selectKeyword: { query = $0 }
            )
            .opacity(hasLoadedKnowledgePage ? 1 : 0)
            .offset(y: hasLoadedKnowledgePage ? 0 : 18)
            .animation(.spring(response: 0.42, dampingFraction: 0.9).delay(0.12), value: hasLoadedKnowledgePage)
        }
    }

    private var inboxHint: some View {
        HStack(spacing: 14) {
            Image(systemName: "tray.full.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(theme.palette.accent)
                .frame(width: 44, height: 44)
                .background(theme.palette.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            VStack(alignment: .leading, spacing: 5) {
                Text("先从待沉淀内容中确认结论")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.palette.text)
                Text("打开一条历史灵感，补充分类和标签后选择“已沉淀”。发布后才会进入搜索、导出和洞察。")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(compact ? 14 : 16)
        .glassPanel(radius: 20)
    }

    private var profilePanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: compact ? 10 : 12) {
                KnowledgeMetricCard(title: "知识条目", value: "\(profile.totalEntries)", detail: "来自历史灵感", symbol: "books.vertical")
                KnowledgeMetricCard(title: "沉淀字数", value: "\(profile.totalWords)", detail: "可继续搜索复用", symbol: "text.quote")
                KnowledgeMetricCard(title: "主要画像", value: profile.dominantCategory.title, detail: "当前知识倾向", symbol: profile.dominantCategory.symbol)
            }
            HStack(alignment: .top, spacing: compact ? 10 : 12) {
                KnowledgeTrendCard(points: trendPoints, selectedGranularity: $selectedTrendGranularity, compact: compact)
                KnowledgeCategoryShareCard(shares: categoryShares, compact: compact)
            }
            KnowledgeKeywordNetworkCard(network: keywordNetwork, compact: compact) { keyword in
                query = keyword
            }
            if !profile.topKeywords.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Label("知识画像关键词", systemImage: "person.crop.circle.badge.checkmark")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.palette.text)
                    FlowPillRow(items: profile.topKeywords, fallback: [])
                }
                .padding(14)
                .glassPanel(radius: 18)
            }
        }
    }

    private var searchPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(theme.palette.muted)
                TextField("搜索关键词、分类、摘要或正文", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(theme.palette.text)
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(theme.palette.muted)
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 42)
            .background(theme.palette.card.opacity(0.72), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).stroke(theme.palette.line, lineWidth: 1))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    KnowledgeCategoryChip(title: "全部", isSelected: selectedCategory == nil) {
                        selectedCategory = nil
                    }
                    ForEach(KnowledgeCategory.allCases.filter { $0 != .uncategorized }) { category in
                        let count = profile.categoryCounts[category, default: 0]
                        KnowledgeCategoryChip(title: "\(category.title) \(count)", isSelected: selectedCategory == category) {
                            selectedCategory = category
                        }
                    }
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    KnowledgeCategoryChip(title: "全部状态", isSelected: selectedStatus == nil) {
                        selectedStatus = nil
                    }
                    ForEach(KnowledgeStatus.allCases) { status in
                        KnowledgeCategoryChip(title: status.title, isSelected: selectedStatus == status) {
                            selectedStatus = selectedStatus == status ? nil : status
                        }
                    }
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    KnowledgeCategoryChip(title: "全部月份", isSelected: selectedMonth == nil) {
                        selectedMonth = nil
                    }
                    ForEach(availableMonths) { month in
                        KnowledgeCategoryChip(title: month.title, isSelected: selectedMonth == month) {
                            selectedMonth = month
                        }
                    }
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(KnowledgeQuickTimeRange.allCases) { range in
                        KnowledgeCategoryChip(title: range.title, isSelected: selectedTimeRange == range) {
                            selectedTimeRange = range
                        }
                    }
                }
            }

            if !availableMoods.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        KnowledgeCategoryChip(title: "全部心情", isSelected: selectedMood == nil) {
                            selectedMood = nil
                        }
                        ForEach(availableMoods, id: \.self) { mood in
                            KnowledgeCategoryChip(title: mood, isSelected: selectedMood == mood) {
                                selectedMood = mood
                            }
                        }
                    }
                }
            }

            if hasActiveFilters {
                Button {
                    clearFilters()
                } label: {
                    Label("清空筛选", systemImage: "xmark.circle")
                        .font(.system(size: 12, weight: .bold))
                        .noWrap(scale: 0.72)
                }
                .buttonStyle(SecondaryButtonStyle())
            }
        }
        .padding(compact ? 16 : 18)
        .background(Color.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(theme.palette.line.opacity(0.56), lineWidth: 1.15))
        .shadow(color: Color.black.opacity(0.16), radius: 18, x: 0, y: 12)
    }

    private var exportPanel: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("批量导出")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.palette.text)
                Text(exportScopeText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.palette.muted)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                exportBatchWord()
            } label: {
                Label("导出 Word", systemImage: "doc.richtext")
                    .font(.system(size: 12, weight: .bold))
                    .noWrap(scale: 0.72)
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(publishedFilteredEntries.isEmpty)
            Button {
                exportBatchPDF()
            } label: {
                Label("导出 PDF", systemImage: "doc.fill")
                    .font(.system(size: 12, weight: .bold))
                    .noWrap(scale: 0.72)
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(publishedFilteredEntries.isEmpty)
        }
        .padding(compact ? 14 : 16)
        .glassPanel(radius: 20)
    }

    private var exportScopeText: String {
        var parts = [selectedCategory?.title ?? "全部分类", selectedMonth?.title ?? "全部月份"]
        if selectedTimeRange != .all { parts.append(selectedTimeRange.title) }
        if let selectedMood { parts.append("心情 \(selectedMood)") }
        parts.append("\(publishedFilteredEntries.count) 条已沉淀知识")
        return parts.joined(separator: " · ")
    }

    private func exportBatchWord() {
        let bundle = KnowledgeBaseService.exportBundle(from: entries, filter: publishedKnowledgeFilter, includeProfile: true)
        NoteExporter.exportKnowledgeDocx(bundle: bundle)
    }

    private func exportBatchPDF() {
        let bundle = KnowledgeBaseService.exportBundle(from: entries, filter: publishedKnowledgeFilter, includeProfile: true)
        NoteExporter.exportKnowledgePDF(bundle: bundle)
    }

    private func continueKnowledgeCapture() {
        selectedDate = Date()
        showingKnowledgeBase = false
    }

    private func openKnowledgeSource(_ entry: KnowledgeEntry) {
        selectedDate = entry.date
        showingKnowledgeBase = false
    }

    private func copyKnowledgeText(_ entry: KnowledgeEntry) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(entry.sourceText.isEmpty ? entry.summary : entry.sourceText, forType: .string)
    }

    private func clearFilters() {
        query = ""
        selectedCategory = nil
        selectedMonth = nil
        selectedMood = nil
        selectedStatus = nil
        selectedTimeRange = .all
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "books.vertical")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(theme.palette.accent)
            Text(entries.isEmpty ? "还没有可沉淀的知识" : "没有匹配的知识条目")
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(theme.palette.text)
            Text(entries.isEmpty ? "继续记录今日胶囊，再从候选内容中确认值得复用的结论。" : "换一个关键词或清空分类筛选再试。")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(theme.palette.muted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 260)
        .glassPanel(radius: 24)
    }
}

private enum CognitiveGlassLevel {
    case l1
    case l2
    case l3

    var opacity: Double {
        switch self {
        case .l1: return 0.20
        case .l2: return 0.155
        case .l3: return 0.105
        }
    }

    var darkOverlayOpacity: Double {
        switch self {
        case .l1: return 0.24
        case .l2: return 0.34
        case .l3: return 0.42
        }
    }

    var borderOpacity: Double {
        switch self {
        case .l1: return 0.82
        case .l2: return 0.62
        case .l3: return 0.52
        }
    }

    var shadowOpacity: Double {
        switch self {
        case .l1: return 0.38
        case .l2: return 0.30
        case .l3: return 0.24
        }
    }

    var innerHighlightOpacity: Double {
        switch self {
        case .l1: return 0.22
        case .l2: return 0.16
        case .l3: return 0.12
        }
    }

    var outerSeparationOpacity: Double {
        switch self {
        case .l1: return 0.16
        case .l2: return 0.24
        case .l3: return 0.30
        }
    }
}

private struct CognitiveGlassCard<Content: View>: View {
    @Environment(\.appTheme) private var theme
    let level: CognitiveGlassLevel
    let radius: CGFloat
    let isActive: Bool
    @ViewBuilder let content: Content

    var body: some View {
        content
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(Color.black.opacity(level.darkOverlayOpacity + (isActive ? 0.035 : 0)))
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(theme.palette.card.opacity(level.opacity + (isActive ? 0.05 : 0)))
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(level.innerHighlightOpacity),
                                    Color.white.opacity(0.015),
                                    Color.black.opacity(level.darkOverlayOpacity * 0.48)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(theme.palette.line.opacity(level.borderOpacity + (isActive ? 0.18 : 0)), lineWidth: isActive ? 1.6 : 1.2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(Color.black.opacity(level.outerSeparationOpacity), lineWidth: 0.8)
                    .blendMode(.multiply)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius - 1, style: .continuous)
                    .stroke(Color.white.opacity(level.innerHighlightOpacity * 0.8), lineWidth: 0.6)
                    .padding(1)
            )
            .shadow(color: theme.palette.accent.opacity(isActive ? 0.22 : 0.035), radius: isActive ? 24 : 10, x: 0, y: 0)
            .shadow(color: Color.black.opacity(level.shadowOpacity), radius: 26, x: 0, y: 18)
    }
}

private struct KnowledgeSectionShell<Content: View>: View {
    @Environment(\.appTheme) private var theme
    let compact: Bool
    @ViewBuilder let content: Content

    private var radius: CGFloat { compact ? 24 : 26 }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 14 : 18) {
            content
        }
        .padding(compact ? 14 : 16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Color.black.opacity(0.24))
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(theme.palette.card.opacity(0.07))
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.09),
                        Color.white.opacity(0.012),
                        Color.black.opacity(0.20)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .stroke(theme.palette.line.opacity(0.50), lineWidth: 1.05)
        )
        .overlay(
            RoundedRectangle(cornerRadius: radius - 1, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 0.6)
                .padding(1)
        )
        .shadow(color: Color.black.opacity(0.26), radius: 22, x: 0, y: 16)
    }
}

private struct KnowledgeCoreCard: View {
    @Environment(\.appTheme) private var theme
    let state: KnowledgeCognitiveState
    let todayWords: Int
    let growthRate: Int
    let keywords: [String]
    let compact: Bool
    let continueAction: () -> Void
    @State private var isHovering = false

    private var displayKeywords: [String] {
        let scoped = keywords.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return scoped.isEmpty ? ["等待记录"] : Array(scoped.prefix(5))
    }

    private var growthText: String {
        if growthRate > 0 { return "+\(growthRate)%" }
        if growthRate < 0 { return "\(growthRate)%" }
        return "0%"
    }

    var body: some View {
        CognitiveGlassCard(level: .l1, radius: compact ? 26 : 30, isActive: isHovering) {
            VStack(alignment: .leading, spacing: compact ? 16 : 20) {
                HStack(alignment: .top, spacing: 16) {
                    ZStack {
                        Circle()
                            .fill(theme.palette.card.opacity(0.18))
                            .frame(width: compact ? 58 : 68, height: compact ? 58 : 68)
                        Circle()
                            .stroke(theme.palette.accent.opacity(0.46), lineWidth: 1.2)
                            .frame(width: compact ? 58 : 68, height: compact ? 58 : 68)
                        Image(systemName: state.symbol)
                            .font(.system(size: compact ? 24 : 28, weight: .semibold))
                            .foregroundStyle(
                                LinearGradient(colors: [theme.palette.accent, theme.palette.warm.opacity(0.86)], startPoint: .topLeading, endPoint: .bottomTrailing)
                            )
                    }

                    VStack(alignment: .leading, spacing: 7) {
                        Text("知识状态：\(state.title)")
                            .font(.system(size: compact ? 20 : 24, weight: .bold, design: .rounded))
                            .foregroundStyle(theme.palette.text)
                            .noWrap(scale: 0.72)
                        Text(state.subtitle)
                            .font(.system(size: compact ? 12 : 13, weight: .medium))
                            .foregroundStyle(theme.palette.muted)
                            .lineLimit(2)
                    }

                    Spacer(minLength: 10)

                    VStack(alignment: .trailing, spacing: 5) {
                        Text("\(todayWords)")
                            .font(.system(size: compact ? 28 : 34, weight: .bold, design: .rounded))
                            .foregroundStyle(theme.palette.text)
                            .contentTransition(.numericText())
                        Text("今日沉淀字数")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(theme.palette.muted)
                        Text("较昨日 \(growthText)")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(growthRate >= 0 ? theme.palette.accent : theme.palette.warm)
                    }
                }

                HStack(alignment: .center, spacing: 10) {
                    ForEach(displayKeywords, id: \.self) { keyword in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(theme.palette.accent.opacity(0.72))
                                .frame(width: 6, height: 6)
                            Text(keyword)
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                .foregroundStyle(theme.palette.text.opacity(0.9))
                                .noWrap(scale: 0.68)
                        }
                        .padding(.horizontal, 12)
                        .frame(height: 32)
                        .background(theme.palette.card.opacity(0.16), in: Capsule())
                        .overlay(Capsule().stroke(theme.palette.line.opacity(0.46), lineWidth: 1))
                    }
                    Spacer(minLength: 8)
                }

                HStack(alignment: .center, spacing: 14) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("下一步")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(theme.palette.muted)
                        Text("把零散灵感继续沉淀成可复用的知识条目。")
                            .font(.system(size: compact ? 12 : 13, weight: .medium))
                            .foregroundStyle(theme.palette.text.opacity(0.86))
                            .lineLimit(2)
                    }
                    Spacer(minLength: 10)
                    Button(action: continueAction) {
                        Label("继续沉淀知识", systemImage: "leaf.fill")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundStyle(theme.palette.text)
                            .noWrap(scale: 0.76)
                            .padding(.horizontal, compact ? 16 : 20)
                            .frame(height: compact ? 42 : 46)
                            .background(
                                LinearGradient(colors: [theme.palette.accent.opacity(0.55), theme.palette.warm.opacity(0.48)], startPoint: .leading, endPoint: .trailing),
                                in: Capsule()
                            )
                            .overlay(Capsule().stroke(Color.white.opacity(0.22), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                }
            }
            .padding(compact ? 18 : 22)
            .frame(maxWidth: .infinity, minHeight: compact ? 224 : 252, alignment: .topLeading)
        }
        .onHover { isHovering = $0 }
        .scaleEffect(isHovering ? 1.004 : 1)
        .animation(.spring(response: 0.24, dampingFraction: 0.88), value: isHovering)
    }
}

private struct KnowledgeInsightSection: View {
    @Environment(\.appTheme) private var theme
    let trendPoints: [KnowledgeTrendPoint]
    @Binding var selectedGranularity: KnowledgeTrendGranularity
    let categoryShares: [KnowledgeCategoryShare]
    let keywordNodes: [KnowledgeKeywordNode]
    let compact: Bool
    let selectKeyword: (String) -> Void

    var body: some View {
        KnowledgeSectionShell(compact: compact) {
            HStack {
                Label("辅助洞察", systemImage: "chart.bar.doc.horizontal")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.palette.text.opacity(0.9))
                Spacer()
                Text("用于观察趋势，不作为主要操作入口")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.palette.muted.opacity(0.72))
                    .lineLimit(1)
            }

            HStack(alignment: .top, spacing: compact ? 14 : 18) {
                TrendMiniChart(points: trendPoints, selectedGranularity: $selectedGranularity, compact: compact)
                TypeBarChart(shares: categoryShares, compact: compact)
            }

            TagCloudView(nodes: keywordNodes, compact: compact, selectKeyword: selectKeyword)
        }
    }
}

private struct TrendMiniChart: View {
    @Environment(\.appTheme) private var theme
    let points: [KnowledgeTrendPoint]
    @Binding var selectedGranularity: KnowledgeTrendGranularity
    let compact: Bool

    private var visiblePoints: [KnowledgeTrendPoint] {
        Array(points.suffix(selectedGranularity.visiblePointLimit))
    }

    private var maxCount: Int {
        max(visiblePoints.map(\.entryCount).max() ?? 1, 1)
    }

    var body: some View {
        CognitiveGlassCard(level: .l2, radius: 20, isActive: false) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Label("时间趋势", systemImage: "waveform.path.ecg")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.palette.text.opacity(0.86))
                    Spacer(minLength: 6)
                    HStack(spacing: 4) {
                        ForEach(KnowledgeTrendGranularity.allCases) { granularity in
                            Button {
                                selectedGranularity = granularity
                            } label: {
                                Text(granularity.title)
                                    .font(.system(size: 10, weight: .bold, design: .rounded))
                                    .foregroundStyle(selectedGranularity == granularity ? theme.palette.text : theme.palette.muted)
                                    .padding(.horizontal, 7)
                                    .frame(height: 22)
                                    .background(selectedGranularity == granularity ? theme.palette.accent.opacity(0.22) : Color.white.opacity(0.055), in: Capsule())
                                    .overlay(Capsule().stroke(selectedGranularity == granularity ? theme.palette.accent.opacity(0.46) : theme.palette.line.opacity(0.24), lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                            .focusable(false)
                        }
                    }
                }

                if visiblePoints.isEmpty {
                    Text("暂无趋势数据")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.palette.muted)
                        .frame(maxWidth: .infinity, minHeight: 72)
                } else {
                    HStack(alignment: .bottom, spacing: 6) {
                        ForEach(visiblePoints, id: \.bucketStart) { point in
                            VStack(spacing: 5) {
                                Capsule()
                                    .fill(theme.palette.accent.opacity(0.48))
                                    .frame(width: compact ? 10 : 12, height: barHeight(for: point))
                                Text(axisTitle(for: point))
                                    .font(.system(size: 8, weight: .semibold))
                                    .foregroundStyle(theme.palette.muted.opacity(0.7))
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .frame(height: compact ? 82 : 92)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: compact ? 154 : 170, alignment: .topLeading)
        }
    }

    private func barHeight(for point: KnowledgeTrendPoint) -> CGFloat {
        let ratio = CGFloat(point.entryCount) / CGFloat(maxCount)
        return max(14, ratio * (compact ? 54 : 62))
    }

    private func axisTitle(for point: KnowledgeTrendPoint) -> String {
        KnowledgeTrendAxisLabelFormatter.shortTitle(point.title, granularity: selectedGranularity)
    }
}

private struct TypeBarChart: View {
    @Environment(\.appTheme) private var theme
    let shares: [KnowledgeCategoryShare]
    let compact: Bool

    private var visibleShares: [KnowledgeCategoryShare] {
        Array(shares.prefix(4))
    }

    var body: some View {
        CognitiveGlassCard(level: .l2, radius: 20, isActive: false) {
            VStack(alignment: .leading, spacing: 12) {
                Label("类型结构", systemImage: "chart.bar.xaxis")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.palette.text.opacity(0.86))

                if visibleShares.isEmpty {
                    Text("暂无分类数据")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.palette.muted)
                        .frame(maxWidth: .infinity, minHeight: 92)
                } else {
                    VStack(spacing: 10) {
                        ForEach(visibleShares, id: \.category) { share in
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Label(share.category.title, systemImage: share.category.symbol)
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(theme.palette.text.opacity(0.82))
                                        .noWrap(scale: 0.68)
                                    Spacer()
                                    Text("\(Int((share.ratio * 100).rounded()))%")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(theme.palette.muted.opacity(0.78))
                                }
                                GeometryReader { proxy in
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(theme.palette.line.opacity(0.32))
                                        Capsule()
                                            .fill(theme.palette.accent.opacity(0.42))
                                            .frame(width: max(10, proxy.size.width * CGFloat(share.ratio)))
                                    }
                                }
                                .frame(height: 5)
                            }
                        }
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: compact ? 154 : 170, alignment: .topLeading)
        }
    }
}

private struct TagCloudView: View {
    @Environment(\.appTheme) private var theme
    let nodes: [KnowledgeKeywordNode]
    let compact: Bool
    let selectKeyword: (String) -> Void

    private var visibleNodes: [KnowledgeKeywordNode] {
        Array(nodes.prefix(compact ? 10 : 12))
    }

    var body: some View {
        CognitiveGlassCard(level: .l2, radius: 20, isActive: false) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("知识标签云", systemImage: "tag")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.palette.text.opacity(0.86))
                    Spacer()
                    Text("\(nodes.count) 个标签")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(theme.palette.muted.opacity(0.72))
                }

                if visibleNodes.isEmpty {
                    Text("继续沉淀后会形成可搜索标签。")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.palette.muted)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: compact ? 88 : 104), spacing: 8)], alignment: .leading, spacing: 8) {
                        ForEach(visibleNodes) { node in
                            Button {
                                selectKeyword(node.keyword)
                            } label: {
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(theme.palette.accent.opacity(0.7))
                                        .frame(width: CGFloat(min(10, 5 + node.count)), height: CGFloat(min(10, 5 + node.count)))
                                    Text(node.keyword)
                                        .font(.system(size: 12, weight: .bold, design: .rounded))
                                        .foregroundStyle(theme.palette.text.opacity(0.86))
                                        .lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 10)
                                .frame(height: 32)
                                .background(theme.palette.card.opacity(0.14), in: Capsule())
                                .overlay(Capsule().stroke(theme.palette.line.opacity(0.38), lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                            .focusable(false)
                        }
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

private struct KnowledgeFeedSection: View {
    @Environment(\.appTheme) private var theme
    let entries: [KnowledgeEntry]
    let compact: Bool
    let reuseEntry: (KnowledgeEntry) -> Void
    let editEntry: (KnowledgeEntry) -> Void
    let viewEntry: (KnowledgeEntry) -> Void

    var body: some View {
        KnowledgeSectionShell(compact: compact) {
            HStack(alignment: .lastTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("知识收件箱")
                        .font(.system(size: compact ? 20 : 22, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.palette.text)
                    Text("待沉淀候选与已确认的可复用条目")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.palette.muted)
                }
                Spacer()
                Text("\(entries.count) 条")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(theme.palette.muted)
            }

            Rectangle()
                .fill(theme.palette.line.opacity(0.28))
                .frame(height: 1)

            LazyVStack(spacing: compact ? 12 : 14) {
                ForEach(entries) { entry in
                    KnowledgeFeedCard(
                        entry: entry,
                        compact: compact,
                        reuse: { reuseEntry(entry) },
                        edit: { editEntry(entry) },
                        view: { viewEntry(entry) }
                    )
                }
            }
        }
    }
}

private struct KnowledgeFeedCard: View {
    @Environment(\.appTheme) private var theme
    let entry: KnowledgeEntry
    let compact: Bool
    let reuse: () -> Void
    let edit: () -> Void
    let view: () -> Void
    @State private var isHovering = false

    var body: some View {
        CognitiveGlassCard(level: .l3, radius: 20, isActive: isHovering) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: entry.category.symbol)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(theme.palette.accent.opacity(0.82))
                        .frame(width: 34, height: 34)
                        .background(theme.palette.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                    VStack(alignment: .leading, spacing: 5) {
                        Text(entry.title)
                            .font(.system(size: compact ? 14 : 15, weight: .bold, design: .rounded))
                            .foregroundStyle(theme.palette.text)
                            .lineLimit(1)
                        Text("\(entry.status.title) · \(dateText(entry.date)) · \(entry.category.title) · \(entry.mood)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(theme.palette.muted.opacity(0.78))
                            .lineLimit(1)
                    }

                    Spacer(minLength: 8)

                    if isHovering {
                        HStack(spacing: 6) {
                            if entry.status == .published {
                                feedAction("复用", "doc.on.doc", reuse)
                            }
                            feedAction("编辑", "slider.horizontal.3", edit)
                            feedAction("查看", "arrow.up.right", view)
                        }
                        .transition(.opacity.combined(with: .move(edge: .trailing)))
                    } else {
                        Text("\(entry.wordCount) 字")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(theme.palette.muted.opacity(0.72))
                    }
                }

                Text(entry.summary)
                    .font(.system(size: compact ? 12 : 13, weight: .medium))
                    .foregroundStyle(theme.palette.text.opacity(0.86))
                    .lineSpacing(3)
                    .lineLimit(2)

                FlowPillRow(items: Array(entry.keywords.prefix(5)), fallback: [entry.category.title])
            }
            .padding(compact ? 14 : 16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .onTapGesture(perform: edit)
        .onHover { isHovering = $0 }
        .scaleEffect(isHovering ? 1.004 : 1)
        .animation(.spring(response: 0.22, dampingFraction: 0.86), value: isHovering)
    }

    private func feedAction(_ title: String, _ systemImage: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 10, weight: .bold))
                .labelStyle(.iconOnly)
                .foregroundStyle(theme.palette.text.opacity(0.9))
                .frame(width: 28, height: 28)
                .background(theme.palette.card.opacity(0.11), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(theme.palette.line.opacity(0.22), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(title)
    }

    private func dateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.dateFormat = Calendar.current.isDateInToday(date) ? "今天 HH:mm" : "M月d日"
        return formatter.string(from: date)
    }
}

struct KnowledgeMetricCard: View {
    @Environment(\.appTheme) private var theme
    let title: String
    let value: String
    let detail: String
    let symbol: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(theme.palette.accent)
                .frame(width: 36, height: 36)
                .background(theme.palette.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(theme.palette.muted)
                    .noWrap(scale: 0.7)
                Text(value)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.palette.text)
                    .noWrap(scale: 0.62)
                Text(detail)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.palette.muted.opacity(0.82))
                    .noWrap(scale: 0.62)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 94)
        .glassPanel(radius: 20)
    }
}

struct KnowledgeTrendCard: View {
    @Environment(\.appTheme) private var theme
    let points: [KnowledgeTrendPoint]
    @Binding var selectedGranularity: KnowledgeTrendGranularity
    let compact: Bool

    private var visiblePoints: [KnowledgeTrendPoint] {
        Array(points.suffix(selectedGranularity.visiblePointLimit))
    }

    private var maxCount: Int {
        max(visiblePoints.map(\.entryCount).max() ?? 1, 1)
    }

    private var cardHeight: CGFloat {
        compact ? 190 : 210
    }

    private var totalEntries: Int {
        visiblePoints.reduce(0) { $0 + $1.entryCount }
    }

    private var peakPoint: KnowledgeTrendPoint? {
        visiblePoints.max {
            if $0.entryCount == $1.entryCount { return $0.bucketStart < $1.bucketStart }
            return $0.entryCount < $1.entryCount
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                Label("时间趋势", systemImage: "chart.xyaxis.line")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.palette.text)
                Spacer(minLength: 8)
                trendGranularityPicker
            }
            if visiblePoints.isEmpty {
                emptyText("暂无趋势数据")
            } else if visiblePoints.count == 1, let point = visiblePoints.first {
                singlePointView(point)
            } else {
                HStack(alignment: .bottom, spacing: 7) {
                    ForEach(visiblePoints, id: \.bucketStart) { point in
                        VStack(spacing: 6) {
                            Text("\(point.entryCount)")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(theme.palette.muted)
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [theme.palette.accent, theme.palette.warm.opacity(0.78)],
                                        startPoint: .bottom,
                                        endPoint: .top
                                    )
                                )
                                .frame(width: compact ? 14 : 18, height: barHeight(for: point))
                            Text(axisTitle(for: point))
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(theme.palette.muted.opacity(0.85))
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: compact ? 100 : 112)
                trendSummary
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: cardHeight, maxHeight: cardHeight, alignment: .topLeading)
        .glassPanel(radius: 18)
    }

    private var trendGranularityPicker: some View {
        HStack(spacing: 4) {
            ForEach(KnowledgeTrendGranularity.allCases) { granularity in
                Button {
                    selectedGranularity = granularity
                } label: {
                    Text(granularity.title)
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(selectedGranularity == granularity ? theme.palette.text : theme.palette.muted)
                        .padding(.horizontal, compact ? 7 : 8)
                        .frame(height: 24)
                        .background(
                            (selectedGranularity == granularity ? theme.palette.accent.opacity(0.24) : Color.white.opacity(0.03)),
                            in: Capsule()
                        )
                        .overlay(Capsule().stroke(selectedGranularity == granularity ? theme.palette.accent.opacity(0.55) : theme.palette.line.opacity(0.65), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .focusable(false)
            }
        }
    }

    private var trendSummary: some View {
        HStack(spacing: 8) {
            Text("当前显示 \(totalEntries) 条")
            if let peakPoint {
                Text("峰值 \(axisTitle(for: peakPoint))")
            }
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(theme.palette.muted.opacity(0.88))
        .lineLimit(1)
    }

    private func singlePointView(_ point: KnowledgeTrendPoint) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .lastTextBaseline) {
                Text(point.title)
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.palette.text)
                Spacer()
                Text("\(point.entryCount) 条")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.palette.accent)
            }
            Text("沉淀 \(point.wordCount) 字，当前维度下数据集中在这一段时间。")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.palette.muted)
                .lineLimit(2)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(theme.palette.line.opacity(0.50))
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [theme.palette.accent, theme.palette.warm.opacity(0.78)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(24, proxy.size.width))
                }
            }
            .frame(height: 8)
        }
        .padding(.top, compact ? 16 : 22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func barHeight(for point: KnowledgeTrendPoint) -> CGFloat {
        let ratio = CGFloat(point.entryCount) / CGFloat(maxCount)
        return max(compact ? 18 : 22, ratio * (compact ? 58 : 68))
    }

    private func axisTitle(for point: KnowledgeTrendPoint) -> String {
        KnowledgeTrendAxisLabelFormatter.shortTitle(point.title, granularity: selectedGranularity)
    }

    private func emptyText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(theme.palette.muted)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct KnowledgeCategoryShareCard: View {
    @Environment(\.appTheme) private var theme
    let shares: [KnowledgeCategoryShare]
    let compact: Bool

    private var visibleShares: [KnowledgeCategoryShare] {
        Array(shares.prefix(compact ? 4 : 5))
    }

    private var cardHeight: CGFloat {
        compact ? 190 : 210
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("类型占比", systemImage: "chart.pie")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(theme.palette.text)
            if visibleShares.isEmpty {
                Text("暂无分类数据")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.palette.muted)
                    .frame(maxWidth: .infinity, minHeight: 90)
            } else {
                VStack(spacing: compact ? 7 : 8) {
                    ForEach(visibleShares, id: \.category) { share in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Label(share.category.title, systemImage: share.category.symbol)
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(theme.palette.text.opacity(0.9))
                                    .noWrap(scale: 0.68)
                                Spacer()
                                Text("\(Int((share.ratio * 100).rounded()))%")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(theme.palette.muted)
                            }
                            GeometryReader { proxy in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(theme.palette.line.opacity(0.50))
                                    Capsule()
                                        .fill(theme.palette.accent.opacity(0.72))
                                        .frame(width: max(8, proxy.size.width * CGFloat(share.ratio)))
                                }
                            }
                            .frame(height: 6)
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: cardHeight, maxHeight: cardHeight, alignment: .topLeading)
        .glassPanel(radius: 18)
    }
}

struct KnowledgeKeywordNetworkCard: View {
    @Environment(\.appTheme) private var theme
    let network: KnowledgeKeywordNetwork
    let compact: Bool
    let selectKeyword: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("关键词网络", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.palette.text)
                Spacer()
                Text("\(network.nodes.count) 个节点")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(theme.palette.muted)
            }
            if network.nodes.isEmpty {
                Text("暂无关键词关系，继续记录后会自动形成连接。")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.palette.muted)
            } else {
                HStack(spacing: 8) {
                    ForEach(network.nodes.prefix(compact ? 6 : 8)) { node in
                        Button {
                            selectKeyword(node.keyword)
                        } label: {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(theme.palette.accent.opacity(0.86))
                                    .frame(width: CGFloat(min(12, 5 + node.count)))
                                Text(node.keyword)
                                    .font(.system(size: 12, weight: .bold, design: .rounded))
                                    .foregroundStyle(theme.palette.text.opacity(0.9))
                                    .noWrap(scale: 0.7)
                            }
                            .padding(.horizontal, 11)
                            .padding(.vertical, 8)
                            .background(theme.palette.card.opacity(0.62), in: Capsule())
                            .overlay(Capsule().stroke(theme.palette.line, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .focusable(false)
                    }
                }
                if !network.edges.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(network.edges.prefix(3)) { edge in
                            Text("\(edge.left) · \(edge.right) · \(edge.weight) 次")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(theme.palette.muted)
                                .lineLimit(1)
                        }
                    }
                }
            }
        }
        .padding(14)
        .glassPanel(radius: 18)
    }
}

struct KnowledgeCategoryChip: View {
    @Environment(\.appTheme) private var theme
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(isSelected ? theme.palette.text : theme.palette.muted)
                .noWrap(scale: 0.72)
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background(isSelected ? theme.palette.accent.opacity(0.20) : theme.palette.card.opacity(0.58), in: Capsule())
                .overlay(Capsule().stroke(isSelected ? theme.palette.accent.opacity(0.72) : theme.palette.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .focusable(false)
    }
}

struct KnowledgeEntryCard: View {
    @Environment(\.appTheme) private var theme
    let entry: KnowledgeEntry
    let compact: Bool
    let openDetail: () -> Void
    let openSource: () -> Void
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: entry.category.symbol)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(theme.palette.accent)
                    .frame(width: 38, height: 38)
                    .background(theme.palette.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                VStack(alignment: .leading, spacing: 5) {
                    Text(entry.title)
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.palette.text)
                        .lineLimit(1)
                    Text("\(dateText(entry.date)) · \(entry.category.title) · \(entry.mood) · \(entry.wordCount) 字")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(theme.palette.muted)
                        .lineLimit(1)
                }
                Spacer()
                HStack(spacing: 8) {
                    Button(action: openDetail) {
                        Label("详情", systemImage: "text.page")
                            .font(.system(size: 11, weight: .bold))
                            .noWrap(scale: 0.7)
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    Button {
                        exportWord()
                    } label: {
                        Label("Word", systemImage: "doc.richtext")
                            .font(.system(size: 11, weight: .bold))
                            .noWrap(scale: 0.7)
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    Button {
                        exportPDF()
                    } label: {
                        Label("PDF", systemImage: "doc.fill")
                            .font(.system(size: 11, weight: .bold))
                            .noWrap(scale: 0.7)
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            }

            Text(entry.summary)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(theme.palette.text.opacity(0.92))
                .lineSpacing(3)
                .lineLimit(2)

            HStack(alignment: .center, spacing: 10) {
                FlowPillRow(items: entry.keywords, fallback: [entry.category.title])
                Spacer(minLength: 10)
                Button(action: openSource) {
                    Label("查看原文", systemImage: "arrow.up.right")
                        .font(.system(size: 11, weight: .bold))
                        .noWrap(scale: 0.7)
                }
                .buttonStyle(SecondaryButtonStyle())
            }
        }
        .padding(compact ? 15 : 17)
        .glassPanel(radius: 22, active: isHovering)
        .scaleEffect(isHovering ? 1.006 : 1)
        .animation(.spring(response: 0.22, dampingFraction: 0.84), value: isHovering)
        .onHover { isHovering = $0 }
        .onTapGesture(perform: openDetail)
    }

    private func exportWord() {
        NoteExporter.exportDocx(note: exportText, date: entry.date)
    }

    private func exportPDF() {
        NoteExporter.exportPDF(note: exportText, date: entry.date)
    }

    private var exportText: String {
        """
        \(entry.title)

        日期：\(dateText(entry.date))
        分类：\(entry.category.title)
        心情：\(entry.mood)
        关键词：\(entry.keywords.isEmpty ? "暂无" : entry.keywords.joined(separator: "、"))

        摘要：
        \(entry.summary)

        原始灵感：
        \(entry.sourceText)
        """
    }

    private func dateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.dateFormat = "yyyy年M月d日"
        return formatter.string(from: date)
    }
}

struct KnowledgeDetailPanel: View {
    @Environment(\.appTheme) private var theme
    let entry: KnowledgeEntry
    let compact: Bool
    let back: () -> Void
    let saveEdits: (KnowledgeCategory, [String], KnowledgeStatus) -> Void
    let openSource: () -> Void
    @State private var selectedCategory: KnowledgeCategory
    @State private var selectedStatus: KnowledgeStatus
    @State private var tagText: String

    init(
        entry: KnowledgeEntry,
        compact: Bool,
        back: @escaping () -> Void,
        saveEdits: @escaping (KnowledgeCategory, [String], KnowledgeStatus) -> Void,
        openSource: @escaping () -> Void
    ) {
        self.entry = entry
        self.compact = compact
        self.back = back
        self.saveEdits = saveEdits
        self.openSource = openSource
        _selectedCategory = State(initialValue: entry.category)
        _selectedStatus = State(initialValue: entry.status)
        _tagText = State(initialValue: entry.keywords.joined(separator: "、"))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 14 : 18) {
            HStack(alignment: .center, spacing: 12) {
                Button(action: back) {
                    Label("返回知识库", systemImage: "chevron.left")
                        .font(.system(size: 12, weight: .bold))
                        .noWrap(scale: 0.7)
                }
                .buttonStyle(SecondaryButtonStyle())
                Spacer()
                Button(action: openSource) {
                    Label("查看当天胶囊", systemImage: "calendar")
                        .font(.system(size: 12, weight: .bold))
                        .noWrap(scale: 0.7)
                }
                .buttonStyle(SecondaryButtonStyle())
            }

            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: selectedCategory.symbol)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(theme.palette.accent)
                        .frame(width: 46, height: 46)
                        .background(theme.palette.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                    VStack(alignment: .leading, spacing: 6) {
                        Text(entry.title)
                            .font(.system(size: compact ? 22 : 26, weight: .bold, design: .rounded))
                            .foregroundStyle(theme.palette.text)
                            .lineLimit(2)
                        Text("\(dateText(entry.date)) · \(entry.mood) · \(entry.wordCount) 字")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(theme.palette.muted)
                    }
                    Spacer()
                    Button {
                        saveEdits(selectedCategory, editedTags, selectedStatus)
                    } label: {
                        Label(selectedStatus == .published ? "发布知识" : "保存调整", systemImage: "checkmark.circle")
                            .font(.system(size: 12, weight: .bold))
                            .noWrap(scale: 0.7)
                    }
                    .buttonStyle(PrimaryButtonStyle())
                }

                Text(entry.summary)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(theme.palette.text.opacity(0.9))
                    .lineSpacing(4)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.palette.card.opacity(0.46), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(theme.palette.line, lineWidth: 1))

                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("知识分类", systemImage: "folder")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(theme.palette.muted)
                        Picker("", selection: $selectedCategory) {
                            ForEach(KnowledgeCategory.allCases) { category in
                                Label(category.title, systemImage: category.symbol).tag(category)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(alignment: .leading, spacing: 8) {
                        Label("沉淀状态", systemImage: "tray")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(theme.palette.muted)
                        Picker("", selection: $selectedStatus) {
                            ForEach(KnowledgeStatus.allCases) { status in
                                Text(status.title).tag(status)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(alignment: .leading, spacing: 8) {
                        Label("标签编辑", systemImage: "tag")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(theme.palette.muted)
                        TextField("用顿号、逗号或空格分隔标签", text: $tagText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(theme.palette.text)
                            .padding(.horizontal, 12)
                            .frame(height: 38)
                            .background(theme.palette.card.opacity(0.58), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(theme.palette.line, lineWidth: 1))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Label("完整正文", systemImage: "doc.text")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.palette.text)
                    ScrollView(.vertical, showsIndicators: true) {
                        Text(entry.sourceText.isEmpty ? "暂无正文内容。" : entry.sourceText)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(theme.palette.text.opacity(0.95))
                            .lineSpacing(5)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.trailing, 10)
                    }
                    .frame(minHeight: compact ? 240 : 320)
                    .padding(16)
                    .background(theme.palette.card.opacity(0.48), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(theme.palette.line, lineWidth: 1))
                }
            }
            .padding(compact ? 16 : 20)
            .glassPanel(radius: 24)
        }
    }

    private var editedTags: [String] {
        tagText
            .components(separatedBy: CharacterSet(charactersIn: "、,，;； \n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func dateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.dateFormat = "yyyy年M月d日"
        return formatter.string(from: date)
    }
}

private extension String {
    var uuidSeed: String {
        let bytes = Array(utf8)
        var hash: UInt64 = 1469598103934665603
        for byte in bytes {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return String(format: "00000000-0000-4000-8000-%012llx", hash & 0x0000ffffffffffff)
    }
}

struct InspirationSeedCard: View {
    @Environment(\.appTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let noteCount: Int
    let compact: Bool
    @State private var animateGlow = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 10) {
            ZStack {
                RoundedRectangle(cornerRadius: compact ? 21 : 23, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [theme.palette.ink.opacity(0.30), theme.palette.surface.opacity(0.18)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Circle()
                    .fill(theme.palette.accent.opacity(0.16))
                    .frame(width: compact ? 104 : 116, height: compact ? 104 : 116)
                    .blur(radius: shouldAnimateGlow && animateGlow ? 22 : 30)
                    .scaleEffect(shouldAnimateGlow && animateGlow ? 1.10 : 0.98)
                    .offset(y: 28)
                if noteCount > 0, shouldAnimateGlow {
                    ForEach(0..<sparkleCount, id: \.self) { index in
                        Image(systemName: sparkleSymbol(index))
                            .font(.system(size: CGFloat(8 + index % 3 * 2), weight: .semibold))
                            .foregroundStyle(index.isMultiple(of: 2) ? theme.palette.warm.opacity(0.82) : theme.palette.accent.opacity(0.78))
                            .shadow(color: theme.palette.accent.opacity(0.22), radius: 8)
                            .offset(
                                x: sparkleOffset(index).x,
                                y: sparkleOffset(index).y + (animateGlow ? -7 : 6)
                            )
                            .opacity(animateGlow ? 0.92 : 0.36)
                            .animation(.easeInOut(duration: 1.8 + Double(index) * 0.16).repeatForever(autoreverses: true), value: animateGlow)
                    }
                }
                if let image = AppBackgroundLibrary.image(named: stage.imageName, fileExtension: "png") {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(height: compact ? 104 : 122)
                        .id(stage.imageName)
                        .shadow(
                            color: PerformanceTuning.prefersReducedEffects ? .clear : theme.palette.accent.opacity(shouldAnimateGlow && animateGlow ? 0.42 : 0.24),
                            radius: PerformanceTuning.prefersReducedEffects ? 0 : (shouldAnimateGlow && animateGlow ? 24 : 14),
                            x: 0,
                            y: PerformanceTuning.prefersReducedEffects ? 0 : 10
                        )
                        .padding(.vertical, 8)
                        .transition(.opacity.combined(with: .scale(scale: 0.985)))
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: stage.symbol)
                            .font(.system(size: compact ? 48 : 58, weight: .light))
                            .foregroundStyle(
                                LinearGradient(colors: [theme.palette.accent, theme.palette.warm.opacity(0.78)], startPoint: .top, endPoint: .bottom)
                            )
                            .shadow(color: theme.palette.accent.opacity(0.26), radius: 18, x: 0, y: 8)
                        Text(stage.title)
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(theme.palette.text)
                    }
                }
                if noteCount > 0 {
                    Text(stage.effect)
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.palette.text.opacity(0.90))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(theme.palette.cardStrong.opacity(0.88), in: Capsule())
                        .overlay(Capsule().stroke(theme.palette.accent.opacity(0.24), lineWidth: 1))
                        .shadow(
                            color: PerformanceTuning.prefersReducedEffects ? .clear : theme.palette.accent.opacity(0.18),
                            radius: PerformanceTuning.prefersReducedEffects ? 0 : 10,
                            x: 0,
                            y: PerformanceTuning.prefersReducedEffects ? 0 : 4
                        )
                        .offset(y: compact ? 42 : 50)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
            }
            .frame(height: compact ? 116 : 134)
            .overlay(
                RoundedRectangle(cornerRadius: compact ? 21 : 23, style: .continuous)
                    .stroke(theme.palette.line.opacity(0.8), lineWidth: 1)
            )

            VStack(alignment: .leading, spacing: compact ? 3 : 4) {
                Text("今日灵感 \(noteCount) 字")
                    .font(.system(size: compact ? 11.5 : 12.5, weight: .bold))
                    .foregroundStyle(theme.palette.text)
                Text(stage.message)
                    .font(.system(size: compact ? 10.5 : 11.5, weight: .medium))
                    .foregroundStyle(theme.palette.muted)
                    .lineLimit(2)
            }
        }
        .padding(compact ? 10 : 12)
        .glassPanel(radius: compact ? 19 : 21, active: noteCount > 0)
        .onAppear {
            animateGlow = noteCount > 0 && shouldAnimateGlow
        }
        .onChange(of: noteCount) { value in
            withAnimation(.easeInOut(duration: 0.28)) {
                animateGlow = value > 0 && shouldAnimateGlow
            }
        }
    }

    private var stage: (title: String, message: String, symbol: String, effect: String, imageName: String) {
        switch noteCount {
        case 0:
            return ("空胶囊", "写下一点灵感，小树苗就会醒来。", "capsule", "等一束光", "CapsuleGrowthState01")
        case 1..<60:
            return ("种子已落下", "灵感刚刚开始发光。", "circle.dotted", "灵感醒啦", "CapsuleGrowthState02")
        case 60..<120:
            return ("小芽冒出", "今天的想法正在成形。", "leaf", "慢慢发芽", "CapsuleGrowthState03")
        case 120..<180:
            return ("树苗舒展", "记录开始长出清晰方向。", "camera.macro", "正在舒展", "CapsuleGrowthState04")
        case 180..<inspirationProgressTarget:
            return ("枝叶生长", "今天的胶囊正在变饱满。", "tree", "继续生长", "CapsuleGrowthState05")
        default:
            return ("灵感成林", "今天的胶囊很饱满。", "tree.fill", "灵感满格", "CapsuleGrowthState06")
        }
    }

    private var sparkleCount: Int {
        min(7, max(2, noteCount / 60 + 2))
    }

    private var shouldAnimateGlow: Bool {
        !reduceMotion && !PerformanceTuning.prefersReducedEffects
    }

    private func sparkleSymbol(_ index: Int) -> String {
        ["sparkle", "leaf.fill", "circle.fill", "sparkles"][index % 4]
    }

    private func sparkleOffset(_ index: Int) -> CGPoint {
        let positions: [CGPoint] = [
            CGPoint(x: -58, y: -48),
            CGPoint(x: 52, y: -54),
            CGPoint(x: -70, y: 2),
            CGPoint(x: 68, y: 14),
            CGPoint(x: -38, y: 54),
            CGPoint(x: 38, y: 48),
            CGPoint(x: 0, y: -68)
        ]
        return positions[index % positions.count]
    }
}

struct ThemeMiniIllustration: View {
    @Environment(\.appTheme) private var theme
    let symbol: String
    let size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [theme.palette.accent.opacity(0.24), theme.palette.warm.opacity(0.16)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Image(systemName: symbol)
                .font(.system(size: size * 0.48, weight: .semibold))
                .foregroundStyle(theme.palette.warm)
        }
        .frame(width: size, height: size)
        .overlay(
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .stroke(Color.white.opacity(0.16), lineWidth: 1)
        )
    }
}

struct CartoonPersonBadge: View {
    @Environment(\.appTheme) private var theme
    let progress: Double
    let compact: Bool

    var body: some View {
        let size: CGFloat = compact ? 44 : 58
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.30, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [theme.palette.warm.opacity(0.22), theme.palette.accent.opacity(0.22)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Circle()
                .fill(theme.palette.warm.opacity(0.95))
                .frame(width: size * 0.34, height: size * 0.34)
                .offset(y: -size * 0.13)
            RoundedRectangle(cornerRadius: size * 0.16, style: .continuous)
                .fill(theme.palette.accent.opacity(0.92))
                .frame(width: size * 0.48, height: size * 0.28)
                .offset(y: size * 0.18)
            HStack(spacing: size * 0.07) {
                Circle().fill(Color.white.opacity(0.90)).frame(width: size * 0.045, height: size * 0.045)
                Circle().fill(Color.white.opacity(0.90)).frame(width: size * 0.045, height: size * 0.045)
            }
            .offset(y: -size * 0.16)
            Image(systemName: progress >= 1 ? "sparkles" : "bolt.fill")
                .font(.system(size: size * 0.20, weight: .bold))
                .foregroundStyle(Color.white)
                .offset(x: size * 0.24, y: -size * 0.25)
        }
        .frame(width: size, height: size)
        .overlay(
            RoundedRectangle(cornerRadius: size * 0.30, style: .continuous)
                .stroke(theme.palette.warm.opacity(progress >= 1 ? 0.86 : 0.38), lineWidth: progress >= 1 ? 1.8 : 1)
        )
        .shadow(color: theme.palette.warm.opacity(progress >= 1 ? 0.32 : 0.12), radius: 16, x: 0, y: 8)
        .animation(.spring(response: 0.28, dampingFraction: 0.78), value: progress)
    }
}

struct InspirationProgressBar: View {
    @Environment(\.appTheme) private var theme
    let progress: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(progress >= 1 ? "很棒，今日灵感爆棚" : "灵感蓄力中")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(progress >= 1 ? theme.palette.warm : theme.palette.cyan)
                Spacer()
                Text("\(Int(progress * 100))%")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.palette.text)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(theme.palette.cardStrong)
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [theme.palette.accent, theme.palette.warm],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(8, proxy.size.width * progress))
                }
            }
            .frame(height: 7)
        }
    }
}

struct InspirationAnalysis {
    let keywords: [String]
    let mood: String
    let moodSymbol: String
}

enum CapsuleStatus: String, CaseIterable {
    case empty
    case inspiration
    case action
    case highEnergy

    var title: String {
        switch self {
        case .empty: return "空胶囊"
        case .inspiration: return "灵感胶囊"
        case .action: return "行动胶囊"
        case .highEnergy: return "高能胶囊"
        }
    }

    var symbol: String {
        switch self {
        case .empty: return "moon.stars.fill"
        case .inspiration: return "sparkles"
        case .action: return "checklist.checked"
        case .highEnergy: return "bolt.fill"
        }
    }
}

struct DailyCapsule: Identifiable, Equatable {
    var id: String { dateKey }
    let date: Date
    let dateKey: String
    let displayDate: String
    let noteText: String
    let summary: String
    let keywords: [String]
    let mood: String
    let moodSymbol: String
    let weatherText: String
    let reminders: [ReminderItem]
    let completedCount: Int
    let status: CapsuleStatus
    let dailyQuestion: DailyQuestion?

    var hasContent: Bool {
        !noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !reminders.isEmpty
            || dailyQuestion?.answer?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    var completionText: String {
        reminders.isEmpty ? "暂无事项" : "\(completedCount)/\(reminders.count) 已完成"
    }

    var excerpt: String {
        let trimmed = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "这一天还没有写下灵感。" }
        if trimmed.count <= 54 { return trimmed }
        return String(trimmed.prefix(54)) + "..."
    }
}

enum SummaryService {
    static func summary(note: String, analysis: InspirationAnalysis, reminders: [ReminderItem]) -> String {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let completed = reminders.filter { $0.isDone }.count
        let total = reminders.count
        let keywordText = analysis.keywords.prefix(3).joined(separator: "、")

        if trimmed.isEmpty && reminders.isEmpty {
            return "今天还没有形成胶囊，写下一点灵感或安排一件小事就会被点亮。"
        }
        if trimmed.isEmpty {
            return total == completed && total > 0 ? "今天的事项已经完成，行动感很稳。" : "今天围绕事项推进中，可以补一段灵感让复盘更完整。"
        }
        if total > 0, completed == total {
            return keywordText.isEmpty ? "今天记录清晰，事项也已收束完成。" : "今天围绕\(keywordText)展开记录，事项也已收束完成。"
        }
        if total > 0 {
            return keywordText.isEmpty ? "今天留下了灵感记录，并推进了 \(completed)/\(total) 项事项。" : "今天的关键词是\(keywordText)，同时推进了 \(completed)/\(total) 项事项。"
        }
        if !keywordText.isEmpty {
            return "今天的灵感集中在\(keywordText)，适合之后继续回看和展开。"
        }
        return "今天留下了一段完整记录，已经被收进历史胶囊。"
    }
}

enum DailyCapsuleService {
    static func capsule(on date: Date, noteStore: NoteStore, reminderStore: ReminderStore, weatherInfo: WeatherInfo?) -> DailyCapsule {
        let note = noteStore.note(for: date)
        let reminders = reminderStore.items(on: date)
        let analysis = InspirationAnalyzer.analyze(note)
        let dailyQuestion = DailyQuestionService().question(for: date)
        let answeredQuestion = dailyQuestion.answer?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? dailyQuestion : nil
        let completed = reminders.filter { $0.isDone }.count
        let weatherText: String
        if Calendar.current.isDateInToday(date), let weatherInfo {
            weatherText = "\(weatherInfo.city) \(Int(weatherInfo.temperature.rounded()))°C · \(weatherInfo.summary)"
        } else {
            weatherText = "未记录"
        }
        let status = status(for: note, reminders: reminders, completedCount: completed)
        return DailyCapsule(
            date: date,
            dateKey: DateKey.string(from: date),
            displayDate: DateKey.display(from: date),
            noteText: note,
            summary: SummaryService.summary(note: note, analysis: analysis, reminders: reminders),
            keywords: analysis.keywords,
            mood: analysis.mood,
            moodSymbol: analysis.moodSymbol,
            weatherText: weatherText,
            reminders: reminders,
            completedCount: completed,
            status: status,
            dailyQuestion: answeredQuestion
        )
    }

    static func historyCapsules(noteStore: NoteStore, reminderStore: ReminderStore, weatherInfo: WeatherInfo?) -> [DailyCapsule] {
        let noteDates = noteStore.noteDates
        let reminderDates = reminderStore.items.map(\.date)
        let questionDates = DailyQuestionService().answeredQuestions().map(\.date)
        let keys = Set((noteDates + reminderDates + questionDates).map { DateKey.string(from: $0) })
        return keys
            .compactMap { DateKey.date(from: $0) }
            .sorted(by: >)
            .map { capsule(on: $0, noteStore: noteStore, reminderStore: reminderStore, weatherInfo: weatherInfo) }
            .filter(\.hasContent)
    }

    private static func status(for note: String, reminders: [ReminderItem], completedCount: Int) -> CapsuleStatus {
        let hasNote = !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard hasNote || !reminders.isEmpty else { return .empty }
        if note.count >= inspirationProgressTarget && (!reminders.isEmpty && completedCount == reminders.count) {
            return .highEnergy
        }
        if !reminders.isEmpty {
            return .action
        }
        return .inspiration
    }
}

enum InspirationAnalyzer {
    private final class AnalysisBox: NSObject {
        let value: InspirationAnalysis

        init(_ value: InspirationAnalysis) {
            self.value = value
        }
    }

    private static let cache: NSCache<NSString, AnalysisBox> = {
        let cache = NSCache<NSString, AnalysisBox>()
        cache.countLimit = 512
        cache.totalCostLimit = 8 * 1024 * 1024
        return cache
    }()

    private static let keywordCandidates = [
        "用户生态", "平台对接", "用户体系", "UGC社区", "内容发布", "审核机制", "合规备案", "隐私条款", "用户协议", "隐私协议",
        "个人信息", "应用上架", "IPC备案", "APP备案", "公安备案", "技术层面", "安卓签名", "iOS签名", "域名配置",
        "会议", "客户", "需求", "项目", "版本", "发布", "沟通", "排期", "复盘", "工作",
        "页面", "视觉", "主题", "图标", "动效", "交互", "文案", "风格", "设计", "体验",
        "代码", "开发", "修复", "测试", "打包", "功能", "逻辑", "优化", "问题", "上线",
        "生活", "吃饭", "散步", "朋友", "天气", "电影", "音乐", "路上", "家庭", "旅行",
        "休息", "睡眠", "放松", "呼吸", "疲惫", "安静", "慢慢", "运动", "阅读", "喝水",
        "重要", "记得", "提醒", "截止", "明天", "今天", "计划", "目标", "待办", "总结",
        "开心", "焦虑", "期待", "难过", "平静", "压力", "喜欢", "感谢", "顺利", "卡住",
        "想法", "灵感", "创意", "脑洞", "尝试", "画面", "记录", "学习", "成长", "完成"
    ]
    private static let sortedKeywordCandidates = keywordCandidates.sorted(by: { $0.count > $1.count })

    private static let moodRules: [(String, String, [String])] = [
        ("晴朗", "sun.max.fill", ["开心", "快乐", "顺利", "喜欢", "感谢", "完成", "期待", "舒服", "棒"]),
        ("绷紧", "bolt.heart.fill", ["焦虑", "压力", "紧张", "烦", "崩溃", "赶", "ddl", "困难", "卡住"]),
        ("松弛", "leaf.fill", ["平静", "放松", "安静", "休息", "睡眠", "散步", "慢慢", "呼吸"]),
        ("专注", "scope", ["工作", "会议", "需求", "代码", "测试", "项目", "发布", "计划"]),
        ("灵感", "sparkles", ["灵感", "创意", "想法", "设计", "画面", "主题", "文案", "优化"])
    ]

    static func analyze(_ text: String) -> InspirationAnalysis {
        let cacheKey = NSString(string: text)
        if let cached = cache.object(forKey: cacheKey) {
            return cached.value
        }
        let start = CFAbsoluteTimeGetCurrent()
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let keywords = extractKeywords(from: cleaned)

        let moodScores: [(String, String, Int)] = moodRules.map { rule in
            let score = rule.2.reduce(0) { partial, token in
                partial + (cleaned.localizedCaseInsensitiveContains(token) ? 1 : 0)
            }
            return (rule.0, rule.1, score)
        }
        let selectedMood = moodScores.sorted {
            if $0.2 == $1.2 { return $0.0 < $1.0 }
            return $0.2 > $1.2
        }.first

        if let selectedMood, selectedMood.2 > 0 {
            let result = InspirationAnalysis(keywords: keywords, mood: selectedMood.0, moodSymbol: selectedMood.1)
            cache.setObject(AnalysisBox(result), forKey: cacheKey, cost: text.utf8.count)
            PerformanceDiagnostics.record("inspiration.analyze", milliseconds: (CFAbsoluteTimeGetCurrent() - start) * 1000, details: "chars=\(text.count)")
            return result
        }
        let result = InspirationAnalysis(
            keywords: keywords,
            mood: cleaned.isEmpty ? "待唤醒" : "平稳",
            moodSymbol: cleaned.isEmpty ? "moon.stars.fill" : "heart.text.square.fill"
        )
        cache.setObject(AnalysisBox(result), forKey: cacheKey, cost: text.utf8.count)
        PerformanceDiagnostics.record("inspiration.analyze", milliseconds: (CFAbsoluteTimeGetCurrent() - start) * 1000, details: "chars=\(text.count)")
        return result
    }

    private static func extractKeywords(from text: String) -> [String] {
        guard !text.isEmpty else { return [] }

        var collected: [String] = []
        let separators = CharacterSet.whitespacesAndNewlines
            .union(.punctuationCharacters)
            .union(CharacterSet(charactersIn: "，。！？、；：,.!?;:（）()【】[]《》<>“”\"'"))
        let fragments = text
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count >= 2 }

        for fragment in fragments {
            if let semanticKeyword = semanticKeyword(from: fragment) {
            appendKeyword(semanticKeyword, to: &collected)
            }
            if collected.count == 4 { break }
        }

        if collected.count < 4 {
            for candidate in sortedKeywordCandidates where text.localizedCaseInsensitiveContains(candidate) {
                appendKeyword(candidate, to: &collected)
                if collected.count == 4 { return collected }
            }
        }

        return collected
    }

    private static func appendKeyword(_ keyword: String, to keywords: inout [String]) {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let normalized = normalizedKeyword(trimmed)
        guard normalized.count >= 2, normalized.count <= 6, !keywords.contains(normalized) else { return }
        keywords.append(normalized)
    }

    private static func semanticKeyword(from fragment: String) -> String? {
        let cleaned = normalizedKeyword(fragment)
        guard cleaned.count >= 2 else { return nil }
        if cleaned.count <= 6 { return cleaned }

        if cleaned.contains("平台"), cleaned.contains("对接") {
            return "平台对接"
        }
        if cleaned.contains("用户"), cleaned.contains("生态") {
            return "用户生态"
        }
        if cleaned.localizedCaseInsensitiveContains("UGC"), cleaned.contains("社区") {
            return "UGC社区"
        }
        if cleaned.contains("隐私"), cleaned.contains("条款") {
            return "隐私条款"
        }
        if cleaned.contains("审核"), cleaned.contains("机制") {
            return "审核机制"
        }

        let connectors = ["以及", "如何", "需要", "哪些", "是否", "可以", "进行", "关于", "针对", "包括", "和", "与", "及", "的"]
        var segments = [cleaned]
        for connector in connectors {
            segments = segments.flatMap { $0.components(separatedBy: connector) }
        }
        return segments
            .map { normalizedKeyword($0) }
            .first { $0.count >= 2 && $0.count <= 6 && !isLowValueKeyword($0) }
    }

    private static func normalizedKeyword(_ keyword: String) -> String {
        var result = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        result = result.replacingOccurrences(of: #"^[0-9一二三四五六七八九十]+[\.、\)]"#, with: "", options: .regularExpression)
        let suffixes = ["以及", "如何", "哪些", "需要", "进行", "关于", "针对", "包括", "内容", "体系", "机制"]
        for suffix in suffixes where result.count > suffix.count + 1 && result.hasSuffix(suffix) {
            result.removeLast(suffix.count)
            break
        }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: "：:，,。.!！?？、；;（）()【】[]《》<>“”\"' "))
    }

    private static func isLowValueKeyword(_ keyword: String) -> Bool {
        ["需要", "哪些", "如何", "以及", "进行", "关于", "针对", "内容", "体系", "机制"].contains(keyword)
    }
}

struct InspirationInsightRow: View {
    @Environment(\.appTheme) private var theme
    let analysis: InspirationAnalysis
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !analysis.keywords.isEmpty {
                HStack(spacing: 7) {
                    ForEach(analysis.keywords, id: \.self) { keyword in
                        Text(keyword)
                            .font(.system(size: compact ? 10 : 11, weight: .bold, design: .rounded))
                            .foregroundStyle(theme.palette.text)
                            .lineLimit(1)
                            .minimumScaleFactor(0.70)
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, compact ? 7 : 9)
                            .padding(.vertical, compact ? 6 : 7)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(theme.palette.accent.opacity(0.15))
                            )
                            .overlay(
                                Capsule(style: .continuous)
                                    .stroke(theme.palette.accent.opacity(0.24), lineWidth: 1)
                            )
                    }
                }
            }

            Label("今日心情：\(analysis.mood)", systemImage: analysis.moodSymbol)
                .font(.system(size: compact ? 11 : 12, weight: .bold, design: .rounded))
                .foregroundStyle(theme.palette.warm)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(theme.palette.warm.opacity(0.12), in: Capsule(style: .continuous))
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(theme.palette.warm.opacity(0.20), lineWidth: 1)
                )
                .noWrap(scale: 0.72)
        }
        .animation(.easeInOut(duration: 0.18), value: analysis.keywords.joined(separator: "|") + analysis.mood)
    }
}

struct CustomIconCard: View {
    @EnvironmentObject private var iconManager: AppIconManager
    @Environment(\.appTheme) private var theme
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "app.badge")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(theme.palette.accent)
                    .frame(width: 32, height: 32)
                    .background(theme.palette.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text("启动图标")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(theme.palette.text)
                        .noWrap()
                    Text(iconManager.hasCustomIcon ? "已使用自定义图标" : "可配置运行时 Dock 图标")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(iconManager.hasCustomIcon ? theme.palette.accent : theme.palette.muted)
                        .noWrap(scale: 0.72)
                }
                Spacer(minLength: 0)
            }

            Text(iconManager.statusText)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.palette.muted)
                .lineLimit(3)
                .minimumScaleFactor(0.76)

            Text("规范：PNG/JPG，建议 1024×1024，透明背景，主体居中，边缘留白，避免文字过小。")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(theme.palette.muted.opacity(0.82))
                .lineLimit(3)
                .minimumScaleFactor(0.75)

            HStack(spacing: 8) {
                Button {
                    iconManager.chooseIcon()
                } label: {
                    Label("选择图片", systemImage: "photo")
                        .font(.system(size: 12, weight: .bold))
                        .noWrap(scale: 0.72)
                }
                .buttonStyle(PrimaryButtonStyle())

                Button {
                    iconManager.resetIcon()
                } label: {
                    Label("默认", systemImage: "arrow.counterclockwise")
                        .font(.system(size: 12, weight: .bold))
                        .noWrap(scale: 0.72)
                }
                .buttonStyle(SecondaryButtonStyle())
            }
        }
        .padding(compact ? 12 : 14)
        .glassPanel(radius: 18, active: iconManager.hasCustomIcon)
        .hoverLift()
    }
}

struct IconSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var theme
    @EnvironmentObject private var reminderStore: ReminderStore
    @Binding var selectedThemeRaw: String
    @AppStorage("cardOpacityPercent") private var cardOpacityPercent = 20.0
    @AppStorage("cardBlurPercent") private var cardBlurPercent = 45.0
    @AppStorage("performanceDiagnosticsEnabled") private var performanceDiagnosticsEnabled = true

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "gearshape")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(theme.palette.accent)
                    .frame(width: 44, height: 44)
                    .background(theme.palette.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                VStack(alignment: .leading, spacing: 5) {
                    Text("设置中心")
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.palette.text)
                        .noWrap(scale: 0.72)
                    Text("把外观、记录、提醒和隐私放在更清晰的位置。")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(theme.palette.muted)
                        .noWrap(scale: 0.7)
                }
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(IconButtonStyle())
            }

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 16) {
                    PreferenceSection(title: "外观", symbol: "paintpalette") {
                        ThemePreferenceCard(selectedThemeRaw: $selectedThemeRaw)
                        CustomIconCard(compact: false)
                        VisualTuningCard(opacityPercent: $cardOpacityPercent, blurPercent: $cardBlurPercent)
                    }

                    PreferenceSection(title: "记录", symbol: "square.and.pencil") {
                        PreferenceInfoRow(title: "今日胶囊自动保存", detail: "输入灵感时会写入本机，每日胶囊不会上传。", symbol: "checkmark.seal")
                        PreferenceInfoRow(title: "灵感字数", detail: "300 字为蓄力目标，单日文本上限为 2000 字。", symbol: "textformat.size")
                        PerformanceDiagnosticsRow(isEnabled: $performanceDiagnosticsEnabled)
                    }

                    PreferenceSection(title: "提醒", symbol: "bell") {
                        NotificationStatusCard(items: reminderStore.items, compact: false)
                    }

                    PreferenceSection(title: "隐私", symbol: "hand.raised") {
                        PreferenceInfoRow(title: "本地数据", detail: "事项、灵感、主题偏好和自定义图标都保存在本机 Application Support。", symbol: "internaldrive")
                        PreferenceInfoRow(title: "天气服务", detail: "天气卡片会访问 ipapi.co 与 open-meteo.com，用于当前城市天气展示。", symbol: "cloud.sun")
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(maxHeight: 620)

            HStack {
                Spacer()
                Button("完成") {
                    dismiss()
                }
                .buttonStyle(PrimaryButtonStyle())
                .frame(width: 120)
            }
        }
        .padding(30)
        .frame(width: 640, height: 760)
        .background(
            ZStack {
                LinearGradient(colors: [theme.palette.ink, theme.palette.plum], startPoint: .topLeading, endPoint: .bottomTrailing)
                Circle()
                    .fill(theme.palette.accent.opacity(0.16))
                    .frame(width: 280, height: 280)
                    .blur(radius: 58)
                    .offset(x: 210, y: -170)
            }
        )
    }
}

struct ThemePreferenceCard: View {
    @Environment(\.appTheme) private var theme
    @Binding var selectedThemeRaw: String

    private var currentTheme: AppTheme {
        AppTheme(rawValue: selectedThemeRaw) ?? .immersiveVista
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [currentTheme.palette.accent.opacity(0.78), currentTheme.palette.accent2.opacity(0.70)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    Image(systemName: currentTheme.symbol(.theme))
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white)
                        .shadow(color: Color.black.opacity(0.22), radius: 6, x: 0, y: 3)
                }
                .frame(width: 42, height: 42)
                .overlay(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .stroke(Color.white.opacity(0.24), lineWidth: 1)
                )

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text("主题换肤")
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundStyle(theme.palette.text)
                        Text(currentTheme.title)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(theme.palette.cyan)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(theme.palette.cyan.opacity(0.12), in: Capsule())
                            .overlay(Capsule().stroke(theme.palette.cyan.opacity(0.22), lineWidth: 1))
                    }
                    Text(currentTheme.mood)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(theme.palette.muted)
                        .lineLimit(2)
                }

                Spacer(minLength: 10)

                Button {
                    let availableThemes = AppTheme.allCases.filter { $0 != currentTheme }
                    selectedThemeRaw = (availableThemes.randomElement() ?? .immersiveVista).rawValue
                } label: {
                    Label("随机", systemImage: "shuffle")
                        .font(.system(size: 12, weight: .bold))
                        .noWrap(scale: 0.76)
                }
                .buttonStyle(SecondaryButtonStyle())
                .frame(width: 82)
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 9), count: 3), spacing: 9) {
                ForEach(AppTheme.allCases) { appTheme in
                    ThemeSwatch(appTheme: appTheme, isSelected: currentTheme == appTheme) {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                            selectedThemeRaw = appTheme.rawValue
                        }
                    }
                    .frame(height: 42)
                }
            }
        }
        .padding(16)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(theme.palette.cardStrong.opacity(0.72))
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                currentTheme.palette.accent.opacity(0.12),
                                currentTheme.palette.accent2.opacity(0.07),
                                Color.clear
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(currentTheme.palette.accent.opacity(0.52), lineWidth: 1.2)
        )
        .shadow(color: currentTheme.palette.accent.opacity(0.12), radius: 18, x: 0, y: 8)
    }
}

struct PerformanceDiagnosticsRow: View {
    @Environment(\.appTheme) private var theme
    @Binding var isEnabled: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "gauge.with.dots.needle.50percent")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(theme.palette.accent)
                .frame(width: 34, height: 34)
                .background(theme.palette.accent.opacity(0.13), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text("本地性能诊断")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(theme.palette.text)
                Text("记录启动、写盘和文本分析耗时，仅保存在本机。")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.palette.muted)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: $isEnabled)
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .padding(12)
        .background(theme.palette.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(theme.palette.line, lineWidth: 1)
        )
    }
}

struct PreferenceSection<Content: View>: View {
    @Environment(\.appTheme) private var theme
    let title: String
    let symbol: String
    let content: Content

    init(title: String, symbol: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: symbol)
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(theme.palette.text)
            content
        }
        .padding(18)
        .glassPanel(radius: 24)
    }
}

struct PreferenceInfoRow: View {
    @Environment(\.appTheme) private var theme
    let title: String
    let detail: String
    let symbol: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(theme.palette.accent)
                .frame(width: 34, height: 34)
                .background(theme.palette.accent.opacity(0.13), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(theme.palette.text)
                Text(detail)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(theme.palette.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(theme.palette.line, lineWidth: 1)
        )
    }
}

struct VisualTuningCard: View {
    @Environment(\.appTheme) private var theme
    @Binding var opacityPercent: Double
    @Binding var blurPercent: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(theme.palette.cyan)
                    .frame(width: 34, height: 34)
                    .background(theme.palette.cyan.opacity(0.15), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text("卡片玻璃质感")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.palette.text)
                    Text("调节功能卡片的透明度与高斯模糊强度。")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(theme.palette.muted)
                }
                Spacer()
                Button("重置") {
                    opacityPercent = 20
                    blurPercent = 45
                }
                .buttonStyle(SecondaryButtonStyle())
                .frame(width: 72)
            }

            tuningSlider(title: "透明度调整", value: $opacityPercent, range: 6...60)
            tuningSlider(title: "高斯模糊值调整", value: $blurPercent, range: 0...85)
        }
        .padding(16)
        .glassPanel(radius: 18, active: true)
    }

    private func tuningSlider(title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack(spacing: 14) {
            Text(title)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(theme.palette.text)
                .frame(width: 104, alignment: .leading)
            Slider(value: value, in: range, step: 1)
                .tint(theme.palette.accent)
            Text("\(Int(value.wrappedValue.rounded()))%")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(theme.palette.cyan)
                .frame(width: 44, alignment: .trailing)
        }
    }
}

struct NotificationStatusCard: View {
    @Environment(\.appTheme) private var theme
    let items: [ReminderItem]
    let compact: Bool
    @State private var status: UNAuthorizationStatus = .notDetermined
    @State private var feedback = "系统通知用于准时提醒你的事项。"
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: status == .authorized ? theme.symbol(.notification) : statusIcon)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(status == .authorized ? theme.palette.accent : theme.palette.warm)
                        .frame(width: 32, height: 32)
                        .background((status == .authorized ? theme.palette.accent : theme.palette.warm).opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("macOS 系统通知")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(theme.palette.text)
                            .noWrap()
                        Text(statusText)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(status == .authorized ? theme.palette.accent : theme.palette.warm)
                            .noWrap(scale: 0.72)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(theme.palette.muted)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
            }
            .buttonStyle(.plain)
            .focusable(false)

            if isExpanded {
                Text(feedback)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.palette.muted)
                    .lineLimit(2)
                    .minimumScaleFactor(0.78)
                    .transition(.opacity)

                HStack(spacing: 10) {
                    Button {
                        requestPermission()
                    } label: {
                        Label(status == .authorized ? "重新检查" : "开启通知", systemImage: "bell.badge")
                            .font(.system(size: 12, weight: .bold))
                            .noWrap(scale: 0.72)
                    }
                    .buttonStyle(SecondaryButtonStyle())

                    Button {
                        sendTest()
                    } label: {
                        Label("测试", systemImage: "paperplane.fill")
                            .font(.system(size: 12, weight: .bold))
                            .noWrap(scale: 0.72)
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(status != .authorized)
                    .opacity(status == .authorized ? 1 : 0.48)
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(compact ? 12 : 14)
        .glassPanel(radius: 18, active: isExpanded || status == .authorized)
        .hoverLift()
        .onAppear(perform: refresh)
    }

    private var statusIcon: String {
        switch status {
        case .authorized, .provisional: return "bell.and.waves.left.and.right.fill"
        case .denied: return "bell.slash.fill"
        case .notDetermined: return "bell.badge.fill"
        @unknown default: return "bell.fill"
        }
    }

    private var statusText: String {
        switch status {
        case .authorized, .provisional: return "已开启，提醒将通过系统通知弹出"
        case .denied: return "未授权，请到系统设置里允许通知"
        case .notDetermined: return "等待授权，点击开启通知"
        @unknown default: return "状态未知，请重新检查"
        }
    }

    private func refresh() {
        NotificationScheduler.shared.authorizationStatus { newStatus in
            status = newStatus
            if newStatus == .authorized || newStatus == .provisional {
                NotificationScheduler.shared.reschedule(items: items)
                feedback = "已同步 \(items.filter { !$0.isDone }.count) 个待提醒事项到系统通知。"
            } else if newStatus == .denied {
                feedback = "macOS 已拒绝通知权限，请在系统设置 > 通知中允许。"
            }
        }
    }

    private func requestPermission() {
        NotificationScheduler.shared.requestPermission { granted in
            refresh()
            feedback = granted ? "通知已开启，提醒会通过 macOS 通知中心弹出。" : "还没有拿到通知权限，请检查系统设置。"
        }
    }

    private func sendTest() {
        NotificationScheduler.shared.sendTestNotification()
        feedback = "测试通知已发送，约 3 秒后会从 macOS 通知中心弹出。"
    }
}

struct CalendarDayCell: View {
    @Environment(\.appTheme) private var theme
    let day: Date
    @Binding var selectedDate: Date
    let visibleMonth: Date
    let count: Int
    let hasNote: Bool
    let compact: Bool

    var body: some View {
        Group {
            if isCurrentMonth {
                Button {
                    selectedDate = day
                } label: {
                    VStack(spacing: compact ? 2 : 3) {
                        Text("\(Calendar.current.component(.day, from: day))")
                            .font(.system(size: compact ? 10.5 : 11.5, weight: isSelected ? .bold : .medium))
                            .noWrap(scale: 0.8)
                        HStack(spacing: compact ? 2 : 3) {
                            Circle()
                                .fill(count > 0 ? theme.palette.cyan : .clear)
                                .frame(width: compact ? 3.5 : 4, height: compact ? 3.5 : 4)
                            Circle()
                                .fill(hasNote ? theme.palette.warm : .clear)
                                .frame(width: compact ? 3.5 : 4, height: compact ? 3.5 : 4)
                        }
                        .frame(height: compact ? 3.5 : 4)
                    }
                    .foregroundStyle(theme.palette.text)
                    .frame(height: compact ? 23 : 25)
                    .frame(maxWidth: .infinity)
                    .background(
                        isSelected ?
                        LinearGradient(colors: [theme.palette.blue.opacity(0.36), theme.palette.lavender.opacity(0.18)], startPoint: .topLeading, endPoint: .bottomTrailing) :
                            LinearGradient(colors: [.clear], startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .stroke(isSelected ? theme.palette.cyan.opacity(0.78) : (isToday ? theme.palette.cyan.opacity(0.45) : .clear), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .focusable(false)
                .hoverLift()
            } else {
                Color.clear
                    .frame(height: compact ? 23 : 25)
                    .frame(maxWidth: .infinity)
            }
        }
        .animation(.spring(response: 0.24, dampingFraction: 0.78), value: isSelected)
        .animation(.easeInOut(duration: 0.18), value: hasNote)
        .animation(.easeInOut(duration: 0.18), value: count)
    }

    private var isSelected: Bool { Calendar.current.isDate(day, inSameDayAs: selectedDate) }
    private var isToday: Bool { Calendar.current.isDateInToday(day) }
    private var isCurrentMonth: Bool { Calendar.current.isDate(day, equalTo: visibleMonth, toGranularity: .month) }
}

struct WeatherCard: View {
    @EnvironmentObject private var weatherStore: WeatherStore
    @Environment(\.appTheme) private var theme
    @AppStorage("cardOpacityPercent") private var cardOpacityPercent = 20.0
    let compact: Bool

    var body: some View {
        HStack(spacing: compact ? 12 : 16) {
            Image(systemName: weatherStore.info?.icon ?? "location.fill")
                .font(.system(size: compact ? 22 : 26, weight: .semibold))
                .foregroundStyle(theme.palette.warm)
                .frame(width: compact ? 42 : 50, height: compact ? 42 : 50)
                .background(theme.palette.warm.opacity(0.15), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

            VStack(alignment: .leading, spacing: 5) {
                Text("今日天气")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.76))
                    .noWrap()
                Text(primaryText)
                    .font(.system(size: compact ? 19 : 23, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.white)
                    .noWrap(scale: 0.7)
            }
            .layoutPriority(1)

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 5) {
                Text(secondaryText)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.84))
                    .noWrap(scale: 0.72)
                Button {
                    weatherStore.refresh()
                } label: {
                    Label(weatherStore.isLoading ? "更新中" : "刷新", systemImage: "arrow.clockwise")
                        .font(.system(size: 11, weight: .bold))
                        .noWrap(scale: 0.7)
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(weatherStore.isLoading)
                .opacity(weatherStore.isLoading ? 0.55 : 1)
            }
        }
        .padding(compact ? 14 : 16)
        .background(weatherBackground)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .glassPanel(radius: 20, active: weatherStore.info != nil)
        .hoverLift()
        .onAppear {
            if weatherStore.info == nil {
                weatherStore.refresh()
            }
        }
    }

    private var primaryText: String {
        guard let info = weatherStore.info else { return weatherStore.message }
        return "\(info.city) \(Int(info.temperature.rounded()))°C · \(info.summary)"
    }

    private var secondaryText: String {
        guard let info = weatherStore.info else { return "当前城市" }
        return "风速 \(Int(info.windSpeed.rounded())) km/h"
    }

    private var weatherBackgroundName: String {
        AppBackgroundLibrary.weatherBackgroundName(for: weatherStore.info?.code)
    }

    private var weatherBackground: some View {
        GeometryReader { proxy in
            ZStack {
                if let image = AppBackgroundLibrary.image(named: weatherBackgroundName) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                        .opacity(weatherImageOpacity)
                } else {
                    LinearGradient(colors: [theme.palette.ink, theme.palette.surface], startPoint: .topLeading, endPoint: .bottomTrailing)
                }
                LinearGradient(
                    colors: [
                        Color.black.opacity(0.42),
                        Color.black.opacity(0.22),
                        theme.palette.ink.opacity(0.58)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                theme.palette.accent.opacity(0.10)
            }
        }
    }

    private var weatherImageOpacity: Double {
        min(0.86, max(0.42, cardOpacityPercent / 100 + 0.42))
    }
}

struct RestStartCard: View {
    @Environment(\.appTheme) private var theme
    let compact: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: "moon.zzz.fill")
                    .font(.system(size: compact ? 15 : 17, weight: .semibold))
                    .foregroundStyle(theme.palette.warm)
                    .frame(width: compact ? 28 : 32, height: compact ? 28 : 32)
                    .background(theme.palette.warm.opacity(0.16), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("休鼾一下")
                        .font(.system(size: compact ? 12 : 13, weight: .bold))
                        .foregroundStyle(theme.palette.text)
                        .noWrap(scale: 0.7)
                    Text("5分钟")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(theme.palette.muted)
                        .noWrap(scale: 0.7)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, compact ? 9 : 11)
            .padding(.vertical, compact ? 8 : 10)
            .glassPanel(radius: 16, active: true)
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .focusable(false)
        .hoverLift()
    }
}

struct RestModeView: View {
    @Environment(\.appTheme) private var theme
    @State private var remaining = 300
    @State private var animate = false
    @State private var copy = EmotionalCopy.restLines.randomElement() ?? EmotionalCopy.restLines[0]
    let onExit: () -> Void

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            RestWallpaper(theme: theme, animate: animate)
            VStack(spacing: 26) {
                Spacer()
                Image(systemName: copy.symbol)
                    .font(.system(size: 74, weight: .light))
                    .foregroundStyle(theme.palette.warm)
                    .shadow(color: theme.palette.warm.opacity(0.36), radius: 28)
                    .scaleEffect(animate ? 1.06 : 0.96)
                Text(copy.title)
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.palette.text)
                    .noWrap(scale: 0.7)
                Text(copy.message)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(theme.palette.muted)
                    .multilineTextAlignment(.center)
                    .lineSpacing(6)
                    .frame(maxWidth: 620)
                Text(timeText)
                    .font(.system(size: 74, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(theme.palette.text)
                Button {
                    onExit()
                } label: {
                    Label("退出休鼾", systemImage: "xmark.circle.fill")
                        .font(.system(size: 15, weight: .bold))
                        .noWrap()
                }
                .buttonStyle(SecondaryButtonStyle())
                .frame(width: 150)
                Spacer()
            }
            .padding(42)
        }
        .ignoresSafeArea()
        .onAppear {
            withAnimation(.easeInOut(duration: 5).repeatForever(autoreverses: true)) {
                animate = true
            }
        }
        .onReceive(timer) { _ in
            if remaining <= 1 {
                onExit()
            } else {
                remaining -= 1
            }
        }
    }

    private var timeText: String {
        "\(remaining / 60):\(String(format: "%02d", remaining % 60))"
    }
}

final class RestWindowManager {
    static let shared = RestWindowManager()
    private var window: NSWindow?
    private var isClosing = false

    func show(theme: AppTheme, onClose: @escaping () -> Void) {
        hideRestWindow()
        let frame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let content = RestModeView {
            onClose()
        }
        .environment(\.appTheme, theme)
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.title = "休鼾一下"
        window.contentView = NSHostingView(rootView: content)
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isOpaque = true
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    func close() {
        guard !isClosing else { return }
        isClosing = true
        hideRestWindow()
        restoreMainWindow()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.isClosing = false
        }
    }

    private func hideRestWindow() {
        window?.orderOut(nil)
        window?.contentView = nil
        window = nil
    }

    private func restoreMainWindow() {
        MainWindowPresenter.present(route: .today)
    }
}

struct RestWallpaper: View {
    let theme: AppTheme
    let animate: Bool
    @State private var backgroundName = AppBackgroundLibrary.randomImmersiveBackgroundName()

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if let image = AppBackgroundLibrary.image(named: backgroundName) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                        .scaleEffect(animate ? 1.04 : 1.0)
                } else {
                    LinearGradient(
                        colors: [
                            theme.palette.ink.opacity(0.98),
                            theme.palette.surface.opacity(0.96),
                            theme.palette.accent2.opacity(0.35)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                }

                Color.black.opacity(0.34)
                LinearGradient(
                    colors: [
                        Color.black.opacity(0.58),
                        Color.black.opacity(0.16),
                        theme.palette.ink.opacity(0.62)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                ForEach(0..<8, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 120, style: .continuous)
                        .stroke(
                            LinearGradient(
                                colors: [theme.palette.accent.opacity(0.16), theme.palette.warm.opacity(0.13), .clear],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: CGFloat(1 + index % 3)
                        )
                        .frame(width: CGFloat(260 + index * 120), height: CGFloat(130 + index * 70))
                        .rotationEffect(.degrees(Double(index * 11) + (animate ? 8 : -8)))
                        .offset(x: animate ? CGFloat(index * 9 - 30) : CGFloat(30 - index * 8), y: CGFloat(index * 10 - 45))
                }
                Circle()
                    .fill(theme.palette.accent.opacity(0.18))
                    .frame(width: 420, height: 420)
                    .blur(radius: 90)
                    .offset(x: animate ? -260 : -180, y: animate ? -180 : -260)
                Circle()
                    .fill(theme.palette.warm.opacity(0.16))
                    .frame(width: 520, height: 520)
                    .blur(radius: 100)
                    .offset(x: animate ? 300 : 220, y: animate ? 210 : 280)
            }
        }
    }
}

struct DailyOpeningOverlay: View {
    @Environment(\.appTheme) private var theme
    let copy: EmotionalCopy
    let onClose: () -> Void
    @State private var remaining = 5
    @State private var animate = false

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            Color.black.opacity(0.58)
                .ignoresSafeArea()
                .onTapGesture(perform: onClose)

            VStack(spacing: 20) {
                HStack {
                    ThemeMiniIllustration(symbol: copy.symbol, size: 56)
                        .scaleEffect(animate ? 1.05 : 0.96)
                    Spacer()
                    Button {
                        onClose()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(IconButtonStyle())
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text(copy.title)
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.palette.text)
                        .noWrap(scale: 0.72)
                    Text(copy.message)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(theme.palette.text.opacity(0.82))
                        .lineSpacing(5)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack {
                    Text("自动关闭 \(remaining)s")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(theme.palette.cyan)
                    Spacer()
                    Button("开始今天") {
                        onClose()
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .frame(width: 118)
                }
            }
            .padding(26)
            .frame(width: 460)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .fill(theme.palette.ink.opacity(0.96))
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    theme.palette.surface.opacity(0.72),
                                    theme.palette.plum.opacity(0.64),
                                    theme.palette.ink.opacity(0.90)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    Image(systemName: theme.illustrationSymbol)
                        .font(.system(size: 120, weight: .ultraLight))
                        .foregroundStyle(theme.palette.accent.opacity(0.055))
                        .offset(x: 150, y: 74)
                        .allowsHitTesting(false)
                }
                .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [
                                theme.palette.accent.opacity(0.88),
                                theme.palette.warm.opacity(0.48),
                                theme.palette.accent2.opacity(0.70)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1.5
                    )
            )
            .shadow(color: Color.black.opacity(0.48), radius: 34, x: 0, y: 18)
            .shadow(color: theme.palette.accent.opacity(0.14), radius: 18)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                animate = true
            }
        }
        .onReceive(timer) { _ in
            if remaining <= 1 {
                onClose()
            } else {
                remaining -= 1
            }
        }
    }
}

struct DayDetail: View {
    @EnvironmentObject private var store: ReminderStore
    @EnvironmentObject private var noteStore: NoteStore
    @EnvironmentObject private var weatherStore: WeatherStore
    @Environment(\.appTheme) private var theme
    @Binding var selectedDate: Date
    @Binding var showingEditor: Bool
    @Binding var editingItem: ReminderItem?
    let compact: Bool
    @State private var toastMessage: String?

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: compact ? 18 : 24) {
                HomeEnvironmentHeader(selectedDate: selectedDate, compact: compact) {
                    weatherStore.refresh()
                }
                .padding(.top, compact ? 16 : 28)

                TodayCapsuleHeroCard(selectedDate: selectedDate, capsule: capsule, compact: compact, onCopy: copySummary) {
                    showToast("今日总结已刷新。")
                }

                DailyInspirationPromptCard(selectedDate: selectedDate, compact: compact) { message in
                    showToast(message)
                }

                TodayActionPanel(
                    items: store.items(on: selectedDate),
                    compact: compact,
                    onAdd: { showingEditor = true },
                    onToggle: { item in
                        if !item.isDone {
                            showToast("完成了「\(item.title)」，今天又多了一点确定感。")
                        }
                        store.toggleDone(item)
                    },
                    onEdit: { item in
                        editingItem = item
                        showingEditor = true
                    },
                    onDelete: { item in
                        store.delete(item)
                        showToast("已删除「\(item.title)」。")
                    }
                )
                .padding(.bottom, 28)
            }
            .padding(.horizontal, compact ? 22 : 36)
        }
        .overlay(alignment: .bottom) {
            if let toastMessage {
                EmotionalToast(message: toastMessage)
                    .padding(.bottom, 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    private var dayTitle: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.dateFormat = Calendar.current.isDateInToday(selectedDate) ? "今天 EEEE" : "M月d日 EEEE"
        return formatter.string(from: selectedDate)
    }

    private var capsule: DailyCapsule {
        DailyCapsuleService.capsule(on: selectedDate, noteStore: noteStore, reminderStore: store, weatherInfo: weatherStore.info)
    }

    private func copySummary() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(capsule.summary, forType: .string)
        showToast("今日总结已复制，可以直接贴到复盘或周报里。")
    }

    private func showToast(_ message: String) {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
            toastMessage = message
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            withAnimation(.easeOut(duration: 0.22)) {
                toastMessage = nil
            }
        }
    }
}

struct HomeEnvironmentHeader: View {
    @EnvironmentObject private var weatherStore: WeatherStore
    @Environment(\.appTheme) private var theme
    let selectedDate: Date
    let compact: Bool
    let onRefreshWeather: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text(dayTitle)
                    .font(.system(size: compact ? 27 : 32, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.palette.text)
                    .noWrap(scale: 0.72)
                Text(greetingText)
                    .font(.system(size: compact ? 15 : 17, weight: .medium))
                    .foregroundStyle(theme.palette.muted)
                    .noWrap(scale: 0.72)
                Capsule()
                    .fill(LinearGradient(colors: [theme.palette.accent, theme.palette.warm.opacity(0.76)], startPoint: .leading, endPoint: .trailing))
                    .frame(width: 42, height: 4)
                    .padding(.top, 6)
            }
            .layoutPriority(1)

            Spacer(minLength: 12)

            HStack(spacing: 12) {
                WeatherMiniPill(compact: compact, onRefresh: onRefreshWeather)
                Button(action: onRefreshWeather) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 42, height: 42)
                }
                .buttonStyle(IconButtonStyle(tint: theme.palette.accent))
                .help("刷新天气")
            }
        }
        .onAppear {
            if weatherStore.info == nil {
                weatherStore.refresh()
            }
        }
    }

    private var dayTitle: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.dateFormat = Calendar.current.isDateInToday(selectedDate) ? "M月d日 EEEE" : "M月d日 EEEE"
        return formatter.string(from: selectedDate)
    }

    private var greetingText: String {
        Calendar.current.isDateInToday(selectedDate) ? "今天适合慢慢整理想法" : "回看这一天留下的胶囊"
    }
}

struct WeatherMiniPill: View {
    @EnvironmentObject private var weatherStore: WeatherStore
    @Environment(\.appTheme) private var theme
    let compact: Bool
    let onRefresh: () -> Void

    var body: some View {
        Button(action: onRefresh) {
            HStack(spacing: 10) {
                Image(systemName: weatherStore.info?.icon ?? "cloud.sun.fill")
                    .font(.system(size: compact ? 18 : 22, weight: .semibold))
                    .foregroundStyle(theme.palette.warm)
                VStack(alignment: .leading, spacing: 2) {
                    Text(primary)
                        .font(.system(size: compact ? 13 : 15, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.palette.text)
                        .noWrap(scale: 0.68)
                    Text(secondary)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(theme.palette.muted)
                        .noWrap(scale: 0.7)
                }
            }
            .padding(.horizontal, compact ? 12 : 16)
            .frame(height: compact ? 50 : 58)
            .glassPanel(radius: 18)
        }
        .buttonStyle(.plain)
        .hoverLift()
    }

    private var primary: String {
        guard let info = weatherStore.info else { return "今日天气" }
        return "\(info.city) \(Int(info.temperature.rounded()))°C"
    }

    private var secondary: String {
        guard let info = weatherStore.info else { return weatherStore.message }
        return "\(info.summary) · 风速 \(Int(info.windSpeed.rounded()))"
    }
}

enum InspirationTextFormat: CaseIterable {
    case heading
    case bold
    case italic
    case bullet
    case numbered
    case checklist
    case quote
    case code
    case link
    case mention
    case divider
    case expand

    var title: String {
        switch self {
        case .heading: return "标题"
        case .bold: return "加粗"
        case .italic: return "斜体"
        case .bullet: return "要点"
        case .numbered: return "编号"
        case .checklist: return "待办"
        case .quote: return "引用"
        case .code: return "代码"
        case .link: return "链接"
        case .mention: return "提及"
        case .divider: return "分隔"
        case .expand: return "展开"
        }
    }

    var symbol: String {
        switch self {
        case .heading: return "textformat.size"
        case .bold: return "bold"
        case .italic: return "italic"
        case .bullet: return "list.bullet"
        case .numbered: return "list.number"
        case .checklist: return "checklist"
        case .quote: return "quote.opening"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .link: return "link"
        case .mention: return "at"
        case .divider: return "minus"
        case .expand: return "arrow.up.left.and.arrow.down.right"
        }
    }
}

enum InspirationEditorMode: String, CaseIterable {
    case write
    case preview

    var title: String {
        switch self {
        case .write: return "写"
        case .preview: return "预览"
        }
    }
}

struct InspirationFormatToolbar: View {
    @Environment(\.appTheme) private var theme
    let compact: Bool
    @Binding var mode: InspirationEditorMode
    let canUndo: Bool
    let onSelect: (InspirationTextFormat) -> Void
    let onAttachFile: () -> Void
    let onUndo: () -> Void
    let onExportWord: (() -> Void)?
    let onExportPDF: (() -> Void)?
    let exportDisabled: Bool

    init(
        compact: Bool,
        mode: Binding<InspirationEditorMode>,
        canUndo: Bool,
        exportDisabled: Bool = true,
        onExportWord: (() -> Void)? = nil,
        onExportPDF: (() -> Void)? = nil,
        onAttachFile: @escaping () -> Void,
        onUndo: @escaping () -> Void,
        onSelect: @escaping (InspirationTextFormat) -> Void
    ) {
        self.compact = compact
        self._mode = mode
        self.canUndo = canUndo
        self.exportDisabled = exportDisabled
        self.onExportWord = onExportWord
        self.onExportPDF = onExportPDF
        self.onAttachFile = onAttachFile
        self.onUndo = onUndo
        self.onSelect = onSelect
    }

    var body: some View {
        VStack(spacing: compact ? 7 : 8) {
            HStack(spacing: compact ? 6 : 8) {
                HStack(spacing: 4) {
                    ForEach(InspirationEditorMode.allCases, id: \.self) { item in
                        Button {
                            mode = item
                        } label: {
                            Text(item.title)
                                .font(.system(size: compact ? 10 : 11, weight: .bold, design: .rounded))
                                .foregroundStyle(mode == item ? theme.palette.ink.opacity(0.88) : theme.palette.text.opacity(0.78))
                                .frame(width: compact ? 38 : 44, height: 28)
                                .background(mode == item ? theme.palette.accent.opacity(0.86) : Color.clear, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .focusable(false)
                        .help(item.title)
                    }
                }
                .padding(3)
                .background(theme.palette.cardStrong.opacity(0.52), in: Capsule())
                .overlay(Capsule().stroke(theme.palette.line.opacity(0.72), lineWidth: 1))

                Spacer(minLength: 0)
                if let onExportWord, let onExportPDF {
                    HStack(spacing: compact ? 6 : 8) {
                        ToolbarExportButton(title: compact ? "Word" : "导出 Word", fileType: "W", compact: compact, disabled: exportDisabled, action: onExportWord)
                        ToolbarExportButton(title: compact ? "PDF" : "导出 PDF", fileType: "P", compact: compact, disabled: exportDisabled, action: onExportPDF)
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }
            }

            HStack(spacing: compact ? 5 : 7) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: compact ? 5 : 7) {
                        ForEach(InspirationTextFormat.allCases, id: \.self) { format in
                            formatButton(format)
                        }
                        toolbarButton(title: "附件", symbol: "paperclip", disabled: mode == .preview, action: onAttachFile)
                        toolbarButton(title: "撤销", symbol: "arrow.uturn.backward", disabled: !canUndo, action: onUndo)
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(theme.palette.card.opacity(0.44), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .stroke(theme.palette.line.opacity(0.68), lineWidth: 1)
        )
    }

    private func formatButton(_ format: InspirationTextFormat) -> some View {
        toolbarButton(title: format.title, symbol: format.symbol, disabled: mode == .preview) {
            onSelect(format)
        }
    }

    private func toolbarButton(title: String, symbol: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: compact ? 10 : 11, weight: .bold))
                .labelStyle(.titleAndIcon)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(minWidth: compact ? 46 : 56, minHeight: 30)
                .foregroundStyle(disabled ? theme.palette.muted.opacity(0.42) : theme.palette.text.opacity(0.88))
        }
        .buttonStyle(.plain)
        .focusable(false)
        .disabled(disabled)
        .background(theme.palette.cardStrong.opacity(disabled ? 0.30 : 0.64), in: Capsule())
        .overlay(Capsule().stroke(theme.palette.line.opacity(disabled ? 0.42 : 0.9), lineWidth: 1))
        .hoverLift(!disabled)
        .help(title)
    }
}

struct ToolbarExportButton: View {
    @Environment(\.appTheme) private var theme
    let title: String
    let fileType: String
    let compact: Bool
    let disabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: compact ? 5 : 7) {
                ZStack {
                    Image(systemName: "doc")
                        .font(.system(size: compact ? 13 : 14, weight: .semibold))
                    Text(fileType)
                        .font(.system(size: compact ? 6 : 7, weight: .black, design: .rounded))
                        .offset(y: compact ? 1 : 1.5)
                }
                .frame(width: compact ? 16 : 18, height: compact ? 16 : 18)
                Text(title)
                    .font(.system(size: compact ? 10 : 11, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
            .foregroundStyle(disabled ? theme.palette.muted.opacity(0.56) : theme.palette.text.opacity(0.94))
            .frame(width: compact ? 68 : 94, height: compact ? 30 : 32)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .disabled(disabled)
        .background(
            LinearGradient(
                colors: disabled
                    ? [theme.palette.card.opacity(0.38), theme.palette.card.opacity(0.28)]
                    : [theme.palette.accent.opacity(0.32), theme.palette.cyan.opacity(0.18)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: Capsule()
        )
        .overlay(Capsule().stroke(disabled ? theme.palette.line.opacity(0.46) : theme.palette.accent.opacity(0.62), lineWidth: 1))
        .hoverLift()
        .help(title)
    }
}

struct TodayCapsuleHeroCard: View {
    @EnvironmentObject private var noteStore: NoteStore
    @EnvironmentObject private var reminderStore: ReminderStore
    @EnvironmentObject private var weatherStore: WeatherStore
    @Environment(\.appTheme) private var theme
    let selectedDate: Date
    let capsule: DailyCapsule
    let compact: Bool
    let onCopy: () -> Void
    let onRefreshSummary: () -> Void
    @State private var draft = ""
    @State private var editorMode: InspirationEditorMode = .write
    @State private var isEditorExpanded = false
    @State private var draftHistory: [String] = []
    @State private var analysis = InspirationAnalyzer.analyze("")
    @State private var analysisWorkItem: DispatchWorkItem?

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 16 : 20) {
            HStack(alignment: .top, spacing: 16) {
                CapsuleOrb(status: capsule.status, progress: inspirationProgress, size: compact ? 46 : 56)
                VStack(alignment: .leading, spacing: 7) {
                    Text("今日胶囊")
                        .font(.system(size: compact ? 22 : 26, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.palette.text)
                        .noWrap()
                    Text(capsule.summary)
                        .font(.system(size: compact ? 11 : 13, weight: .medium))
                        .foregroundStyle(theme.palette.muted)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .layoutPriority(1)
                Spacer()
                HStack(spacing: 10) {
                    CapsuleHeroActionButton(
                        title: compact ? "复制" : "复制总结",
                        symbol: "doc.on.doc",
                        compact: compact,
                        action: onCopy
                    )
                    .help("复制今日总结")
                    CapsuleHeroActionButton(
                        title: "刷新",
                        symbol: "arrow.clockwise",
                        compact: compact,
                        action: onRefreshSummary
                    )
                    .help("刷新今日总结")
                }
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(2)
            }

            VStack(spacing: 8) {
                InspirationFormatToolbar(
                    compact: compact,
                    mode: $editorMode,
                    canUndo: !draftHistory.isEmpty,
                    exportDisabled: exportedNoteText.isEmpty,
                    onExportWord: exportWord,
                    onExportPDF: exportPDF,
                    onAttachFile: attachFile,
                    onUndo: undoDraft
                ) { format in
                    applyFormat(format)
                }

                Group {
                    if editorMode == .write {
                        ZStack(alignment: .topLeading) {
                            if draft.isEmpty {
                                Text("写下今天闪过的一个想法……")
                                    .font(.system(size: compact ? 12 : 13, weight: .medium))
                                    .foregroundStyle(theme.palette.muted.opacity(0.62))
                                    .padding(.top, 8)
                            }
                            TextEditor(text: $draft)
                                .font(.system(size: compact ? 12 : 13))
                                .foregroundStyle(theme.palette.text)
                                .scrollContentBackground(.hidden)
                                .background(Color.clear)
                                .frame(minHeight: editorHeight)
                                .onChange(of: draft) { updateDraft($0) }
                        }
                    } else {
                        InspirationMarkdownPreview(text: draft, compact: compact)
                            .frame(minHeight: editorHeight, alignment: .topLeading)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 2)

                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    Image(systemName: "leaf")
                    Text("\(draft.count) / \(inspirationCharacterLimit)")
                }
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(theme.palette.muted)
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
                .allowsHitTesting(false)
            }
            .padding(.top, 8)
            .padding(.horizontal, 8)
            .background(theme.palette.ink.opacity(0.20), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(draft.isEmpty ? theme.palette.line : theme.palette.accent.opacity(0.42), lineWidth: 1)
            )

            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("关键词")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(theme.palette.muted)
                    FlowPillRow(items: analysis.keywords.isEmpty ? capsule.keywords : analysis.keywords, fallback: ["慢慢记录"])
                }
                .layoutPriority(1)
                Spacer()
                VStack(alignment: .leading, spacing: 10) {
                    Text("心情状态")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(theme.palette.muted)
                    HStack(spacing: 9) {
                        Image(systemName: analysis.moodSymbol)
                            .foregroundStyle(theme.palette.accent)
                        Text("状态：\(analysis.mood)")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(theme.palette.text)
                        Circle()
                            .fill(theme.palette.accent)
                            .frame(width: 5, height: 5)
                    }
                    .padding(.horizontal, 13)
                    .padding(.vertical, 10)
                    .background(theme.palette.card, in: Capsule())
                    .overlay(Capsule().stroke(theme.palette.line, lineWidth: 1))
                }
            }
        }
        .padding(compact ? 20 : 24)
        .glassPanel(radius: 28, active: capsule.hasContent || !draft.isEmpty)
        .hoverLift()
        .onAppear {
            draft = noteStore.note(for: selectedDate)
            analysis = InspirationAnalyzer.analyze(draft)
        }
        .onChange(of: selectedDate) { newDate in
            noteStore.flushSave()
            draft = noteStore.note(for: newDate)
            analysis = InspirationAnalyzer.analyze(draft)
        }
        .onDisappear {
            noteStore.flushSave()
        }
    }

    private var inspirationProgress: Double {
        min(Double(draft.count) / Double(inspirationProgressTarget), 1.0)
    }

    private var exportedNoteText: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var editorHeight: CGFloat {
        if isEditorExpanded {
            return compact ? 180 : 220
        }
        return compact ? 96 : 112
    }

    private func updateDraft(_ value: String) {
        let limited = String(value.prefix(inspirationCharacterLimit))
        if limited != value {
            draft = limited
            return
        }
        noteStore.setNote(limited, for: selectedDate)
        analysisWorkItem?.cancel()
        let work = DispatchWorkItem {
            analysis = InspirationAnalyzer.analyze(limited)
        }
        analysisWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
    }

    private func applyFormat(_ format: InspirationTextFormat) {
        if format == .expand {
            withAnimation(.spring(response: 0.26, dampingFraction: 0.84)) {
                isEditorExpanded.toggle()
            }
            return
        }

        let insertion: String
        let needsLeadingBreak = !draft.isEmpty && !draft.hasSuffix("\n")

        switch format {
        case .heading:
            insertion = "\(needsLeadingBreak ? "\n" : "")## "
        case .bold:
            insertion = "**加粗文本**"
        case .italic:
            insertion = "*斜体文本*"
        case .bullet:
            insertion = "\(needsLeadingBreak ? "\n" : "")- "
        case .numbered:
            insertion = "\(needsLeadingBreak ? "\n" : "")1. "
        case .checklist:
            insertion = "\(needsLeadingBreak ? "\n" : "")- [ ] "
        case .quote:
            insertion = "\(needsLeadingBreak ? "\n" : "")> "
        case .code:
            insertion = "`代码`"
        case .link:
            insertion = "[链接文本](https://)"
        case .mention:
            insertion = "@"
        case .divider:
            insertion = "\(needsLeadingBreak ? "\n" : "")---\n"
        case .expand:
            insertion = ""
        }

        insertMarkdown(insertion)
    }

    private func insertMarkdown(_ insertion: String) {
        guard !insertion.isEmpty else { return }
        pushDraftHistory()
        draft = String((draft + insertion).prefix(inspirationCharacterLimit))
        persistDraftAndAnalyze()
    }

    private func attachFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = "添加"
        guard panel.runModal() == .OK else { return }
        let links = panel.urls.map { url in
            "[\(url.lastPathComponent)](\(url.path))"
        }
        guard !links.isEmpty else { return }
        let needsLeadingBreak = !draft.isEmpty && !draft.hasSuffix("\n")
        insertMarkdown("\(needsLeadingBreak ? "\n" : "")\(links.joined(separator: "\n"))\n")
    }

    private func undoDraft() {
        guard let previous = draftHistory.popLast() else { return }
        draft = previous
        persistDraftAndAnalyze()
    }

    private func pushDraftHistory() {
        if draftHistory.last != draft {
            draftHistory.append(draft)
        }
        if draftHistory.count > 12 {
            draftHistory.removeFirst(draftHistory.count - 12)
        }
    }

    private func persistDraftAndAnalyze() {
        noteStore.setNote(draft, for: selectedDate)
        analysisWorkItem?.cancel()
        let work = DispatchWorkItem {
            analysis = InspirationAnalyzer.analyze(draft)
        }
        analysisWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
    }

    private func exportWord() {
        let text = exportedNoteText
        guard !text.isEmpty else { return }
        noteStore.flushSave()
        NoteExporter.exportDocx(note: text, date: selectedDate)
    }

    private func exportPDF() {
        let text = exportedNoteText
        guard !text.isEmpty else { return }
        noteStore.flushSave()
        NoteExporter.exportPDF(note: text, date: selectedDate)
    }
}

struct InspirationMarkdownPreview: View {
    @Environment(\.appTheme) private var theme
    let text: String
    let compact: Bool

    var body: some View {
        ScrollView {
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("预览会显示 Markdown 格式后的内容。")
                    .font(.system(size: compact ? 12 : 13, weight: .medium))
                    .foregroundStyle(theme.palette.muted.opacity(0.62))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)
            } else {
                Text(renderedText)
                    .font(.system(size: compact ? 12 : 13))
                    .foregroundStyle(theme.palette.text.opacity(0.92))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(.top, 8)
            }
        }
        .scrollContentBackground(.hidden)
    }

    private var renderedText: AttributedString {
        (try? AttributedString(markdown: text, options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}

struct CapsuleHeroActionButton: View {
    @Environment(\.appTheme) private var theme
    let title: String
    let symbol: String
    let compact: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: compact ? 6 : 8) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                Text(title)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
            .foregroundStyle(theme.palette.text)
            .frame(width: compact ? 74 : 104, height: 38)
            .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
        .buttonStyle(.plain)
        .background(theme.palette.cardStrong, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(theme.palette.line, lineWidth: 1)
        )
        .hoverLift()
    }
}

struct CapsuleOrb: View {
    @Environment(\.appTheme) private var theme
    @Environment(\.lightweightRendering) private var lightweightRendering
    let status: CapsuleStatus
    let progress: Double
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [theme.palette.accent.opacity(0.82), theme.palette.surface.opacity(0.45), theme.palette.ink.opacity(0.15)],
                        center: .topLeading,
                        startRadius: 2,
                        endRadius: size
                    )
                )
            Circle()
                .stroke(Color.white.opacity(0.30), lineWidth: 1)
            Circle()
                .trim(from: 0, to: max(0.08, progress))
                .stroke(theme.palette.warm.opacity(0.85), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .padding(3)
            Image(systemName: status.symbol)
                .font(.system(size: size * 0.34, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.92))
        }
        .frame(width: size, height: size)
        .shadow(
            color: lightweightRendering || PerformanceTuning.prefersReducedEffects ? .clear : theme.palette.accent.opacity(0.24),
            radius: lightweightRendering || PerformanceTuning.prefersReducedEffects ? 0 : 18,
            x: 0,
            y: lightweightRendering || PerformanceTuning.prefersReducedEffects ? 0 : 8
        )
    }
}

struct FlowPillRow: View {
    @Environment(\.appTheme) private var theme
    let items: [String]
    let fallback: [String]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array((items.isEmpty ? fallback : items).prefix(4)), id: \.self) { item in
                HStack(spacing: 5) {
                    Circle()
                        .fill(theme.palette.accent.opacity(0.85))
                        .frame(width: 5, height: 5)
                    Text(item)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.palette.text.opacity(0.86))
                        .noWrap(scale: 0.72)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(theme.palette.card, in: Capsule())
                .overlay(Capsule().stroke(theme.palette.line, lineWidth: 1))
            }
        }
    }
}

struct DailyInspirationPromptCard: View {
    @EnvironmentObject private var noteStore: NoteStore
    @Environment(\.appTheme) private var theme
    let selectedDate: Date
    let compact: Bool
    let onSaved: (String) -> Void
    @State private var question: DailyQuestion?
    @State private var draft = ""
    @State private var isEditorFocused = false
    @State private var hasAnswered = false
    @State private var isGrowing = false
    private let service = DailyQuestionService()

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 13 : 16) {
            HStack(alignment: .center, spacing: 14) {
                DailyInspirationSeedFeedback(isGrowing: isGrowing, hasAnswered: hasAnswered, compact: compact)
                VStack(alignment: .leading, spacing: 5) {
                    Label("今日启发", systemImage: "sparkles")
                        .font(.system(size: compact ? 17 : 19, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.palette.text)
                    Text(statusText)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(hasAnswered ? theme.palette.accent : theme.palette.muted)
                }
                Spacer()
                if let question {
                    Text(question.category.title)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(theme.palette.accent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(theme.palette.accent.opacity(0.12), in: Capsule())
                        .overlay(Capsule().stroke(theme.palette.accent.opacity(0.24), lineWidth: 1))
                }
            }

            if let question {
                Text("“\(question.question)”")
                    .font(.system(size: compact ? 18 : 21, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.palette.text)
                    .lineSpacing(5)
                    .fixedSize(horizontal: false, vertical: true)

                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(theme.palette.ink.opacity(isEditorFocused ? 0.26 : 0.18))
                        .overlay(
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .stroke(isEditorFocused ? theme.palette.accent.opacity(0.52) : theme.palette.line, lineWidth: 1)
                        )
                    if draft.isEmpty {
                        Text("写下你的想法……")
                            .font(.system(size: compact ? 12 : 13, weight: .medium))
                            .foregroundStyle(theme.palette.muted.opacity(0.66))
                            .padding(.horizontal, 14)
                            .padding(.top, 13)
                    }
                    TextEditor(text: Binding(
                        get: { draft },
                        set: { updateDraft($0) }
                    ))
                    .font(.system(size: compact ? 12 : 13))
                    .foregroundStyle(theme.palette.text)
                    .scrollContentBackground(.hidden)
                    .background(Color.clear)
                    .padding(.horizontal, 8)
                    .padding(.top, 5)
                    .padding(.bottom, 24)
                    .frame(minHeight: compact ? 96 : 118)
                    .onTapGesture { isEditorFocused = true }

                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            Text("\(draft.count) / 500")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(draft.count >= 500 ? theme.palette.warm : theme.palette.muted)
                                .padding(.trailing, 13)
                                .padding(.bottom, 9)
                        }
                    }
                }

                HStack {
                    FlowPillRow(items: question.keywords, fallback: [question.category.title])
                    Spacer()
                    if hasAnswered {
                        Label(answerTimeText(question), systemImage: "checkmark.circle.fill")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(theme.palette.accent)
                    } else {
                        Button(action: saveAnswer) {
                            Label(canSave ? "保存回答" : "开始思考", systemImage: canSave ? "tray.and.arrow.down.fill" : "pencil")
                                .font(.system(size: 12, weight: .bold))
                                .noWrap()
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(!canSave)
                        .opacity(canSave ? 1 : 0.45)
                        .frame(width: compact ? 120 : 136)
                    }
                }
            }
        }
        .padding(compact ? 18 : 22)
        .glassPanel(radius: 24, active: hasAnswered || !draft.isEmpty)
        .hoverLift()
        .onAppear(perform: loadQuestion)
        .onChange(of: selectedDate) { _ in loadQuestion() }
    }

    private var canSave: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !hasAnswered
    }

    private var statusText: String {
        if hasAnswered { return "今日启发已完成" }
        if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "今天的问题正在等待你的回答。" }
        return "正在记录你的想法"
    }

    private func loadQuestion() {
        let loaded = service.question(for: selectedDate)
        question = loaded
        draft = loaded.answer ?? service.draft(for: selectedDate)
        hasAnswered = loaded.answer?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private func updateDraft(_ value: String) {
        let limited = String(value.prefix(500))
        if limited != value {
            draft = limited
            return
        }
        draft = limited
        service.saveDraft(limited, for: selectedDate)
    }

    private func saveAnswer() {
        guard let question else { return }
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let saved = service.saveAnswer(trimmed, for: selectedDate)
        noteStore.appendDailyInspiration(question: saved, answer: trimmed, for: selectedDate)
        noteStore.flushSave()
        self.question = saved
        hasAnswered = true
        withAnimation(.spring(response: 0.38, dampingFraction: 0.80)) {
            isGrowing = true
        }
        onSaved("灵感种子已吸收")
        NotificationCenter.default.post(name: .dailyQuestionAnswered, object: question.id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            withAnimation(.easeOut(duration: 0.22)) {
                isGrowing = false
            }
        }
    }

    private func answerTimeText(_ question: DailyQuestion) -> String {
        guard let answeredAt = question.answeredAt else { return "已保存" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.dateFormat = "HH:mm"
        return "回答于 \(formatter.string(from: answeredAt))"
    }
}

struct DailyInspirationSeedFeedback: View {
    @Environment(\.appTheme) private var theme
    let isGrowing: Bool
    let hasAnswered: Bool
    let compact: Bool

    var body: some View {
        ZStack {
            ForEach(0..<6, id: \.self) { index in
                Circle()
                    .fill(theme.palette.accent.opacity(isGrowing ? 0.30 : 0))
                    .frame(width: 5, height: 5)
                    .offset(y: isGrowing ? -30 : -10)
                    .rotationEffect(.degrees(Double(index) * 60))
                    .scaleEffect(isGrowing ? 1.15 : 0.55)
            }
            Image(systemName: hasAnswered ? "leaf.circle.fill" : "leaf")
                .font(.system(size: compact ? 24 : 28, weight: .semibold))
                .foregroundStyle(theme.palette.accent)
                .frame(width: compact ? 48 : 56, height: compact ? 48 : 56)
                .background(theme.palette.accent.opacity(0.12), in: Circle())
                .overlay(Circle().stroke(theme.palette.accent.opacity(hasAnswered ? 0.48 : 0.22), lineWidth: 1))
                .shadow(color: theme.palette.accent.opacity(isGrowing ? 0.55 : 0.18), radius: isGrowing ? 18 : 8)
                .scaleEffect(isGrowing ? 1.10 : 1)
        }
        .frame(width: compact ? 54 : 64, height: compact ? 54 : 64)
    }
}

struct DailyQuestionHistoryBlock: View {
    @Environment(\.appTheme) private var theme
    let question: DailyQuestion
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label("Daily Inspiration", systemImage: "sparkles")
                    .font(.system(size: compact ? 13 : 14, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.palette.text)
                Spacer()
                Text(DateKey.string(from: question.date))
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(theme.palette.muted)
            }
            Text("今日启发：\(question.question)")
                .font(.system(size: compact ? 12 : 13, weight: .semibold))
                .foregroundStyle(theme.palette.text)
                .fixedSize(horizontal: false, vertical: true)
            if let answer = question.answer, !answer.isEmpty {
                Text("我的回答：\(answer)")
                    .font(.system(size: compact ? 12 : 13, weight: .medium))
                    .foregroundStyle(theme.palette.muted)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            FlowPillRow(items: question.keywords, fallback: [question.category.title])
        }
        .padding(compact ? 13 : 16)
        .background(theme.palette.card.opacity(0.56), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(theme.palette.line, lineWidth: 1))
    }
}

struct TodayActionPanel: View {
    @Environment(\.appTheme) private var theme
    let items: [ReminderItem]
    let compact: Bool
    let onAdd: () -> Void
    let onToggle: (ReminderItem) -> Void
    let onEdit: (ReminderItem) -> Void
    let onDelete: (ReminderItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Label("今日行动", systemImage: "checklist.checked")
                    .font(.system(size: compact ? 18 : 20, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.palette.text)
                    .noWrap()
                Spacer()
                Text("已完成 \(doneCount)/\(max(items.count, 1))")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(theme.palette.muted)
                ProgressView(value: items.isEmpty ? 0 : Double(doneCount), total: Double(max(items.count, 1)))
                    .progressViewStyle(.linear)
                    .tint(theme.palette.accent)
                    .frame(width: compact ? 110 : 160)
                Button(action: onAdd) {
                    Label("添加提醒", systemImage: "bell")
                        .font(.system(size: 12, weight: .bold))
                        .noWrap()
                }
                .buttonStyle(SecondaryButtonStyle())
            }

            if items.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "checklist")
                        .font(.system(size: 32, weight: .light))
                        .foregroundStyle(theme.palette.accent)
                    Text("今天还没有行动事项")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.palette.text)
                    Text("添加一个提醒，让今天有一个温柔的落点。")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(theme.palette.muted)
                    Button(action: onAdd) {
                        Label("添加提醒事项", systemImage: "plus.circle.fill")
                            .font(.system(size: 13, weight: .bold))
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .frame(width: 160)
                }
                .frame(maxWidth: .infinity, minHeight: 170)
            } else {
                LazyVGrid(columns: gridColumns, spacing: 10) {
                    ForEach(items.prefix(5)) { item in
                        CompactReminderRow(
                            item: item,
                            onToggle: { onToggle(item) },
                            onEdit: { onEdit(item) },
                            onDelete: { onDelete(item) }
                        )
                    }
                }
                if items.count > 5 {
                    Text("其余 \(items.count - 5) 项已收起，保持首页轻盈。")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.palette.muted)
                }
            }
        }
        .padding(compact ? 18 : 22)
        .glassPanel(radius: 26)
    }

    private var gridColumns: [GridItem] {
        let count = compact ? 1 : 2
        return Array(repeating: GridItem(.flexible(), spacing: 12), count: count)
    }

    private var doneCount: Int {
        items.filter(\.isDone).count
    }
}

struct CompactReminderRow: View {
    @Environment(\.appTheme) private var theme
    let item: ReminderItem
    let onToggle: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onToggle) {
                Image(systemName: item.isDone ? "checkmark.square.fill" : "square")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(item.isDone ? theme.palette.accent : theme.palette.muted)
            }
            .buttonStyle(.plain)
            Button(action: onEdit) {
                HStack {
                    Text(item.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(item.isDone ? theme.palette.muted : theme.palette.text)
                        .strikethrough(item.isDone, color: theme.palette.muted)
                        .noWrap(scale: 0.72)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .layoutPriority(1)
            Text(timeText)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(theme.palette.muted)
                .noWrap(scale: 0.8)
                .frame(width: 42, alignment: .trailing)
            ReminderRowIconButton(symbol: "pencil", tint: theme.palette.accent, action: onEdit)
                .help("编辑事项")
            ReminderRowIconButton(symbol: "trash", tint: theme.palette.warm, action: onDelete)
                .help("删除事项")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .background(theme.palette.card.opacity(item.isDone ? 0.62 : 1), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(theme.palette.line, lineWidth: 1)
        )
        .hoverLift()
    }

    private var timeText: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: item.remindAt)
    }
}

struct ReminderRowIconButton: View {
    @Environment(\.appTheme) private var theme
    let symbol: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(tint.opacity(0.90))
                .frame(width: 26, height: 26)
                .background(theme.palette.cardStrong.opacity(0.72), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(theme.palette.line.opacity(0.82), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .scaleEffect(1)
    }
}

struct SummaryCard: View {
    @Environment(\.appTheme) private var theme
    let capsule: DailyCapsule
    let compact: Bool
    let onCopy: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: compact ? 10 : 14) {
            Image(systemName: capsule.status.symbol)
                .font(.system(size: compact ? 18 : 20, weight: .bold))
                .foregroundStyle(theme.palette.warm)
                .frame(width: compact ? 38 : 44, height: compact ? 38 : 44)
                .background(theme.palette.warm.opacity(0.14), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("今日总结")
                        .font(.system(size: compact ? 15 : 16, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.palette.text)
                        .noWrap()
                    Text(capsule.status.title)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(theme.palette.cyan)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(theme.palette.cyan.opacity(0.12), in: Capsule())
                    Spacer()
                    Button(action: onCopy) {
                        Label("复制", systemImage: "doc.on.doc")
                            .font(.system(size: 12, weight: .bold))
                            .noWrap()
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
                Text(capsule.summary)
                    .font(.system(size: compact ? 13 : 14, weight: .medium))
                    .foregroundStyle(theme.palette.text)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Label(capsule.mood, systemImage: capsule.moodSymbol)
                    Label(capsule.completionText, systemImage: "checkmark.circle")
                    Label(capsule.weatherText, systemImage: "cloud.sun.fill")
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.palette.muted)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            }
            .layoutPriority(1)
        }
        .padding(compact ? 13 : 16)
        .glassPanel(radius: 19, active: capsule.hasContent)
        .hoverLift()
    }
}

struct HistoryCapsulesView: View {
    @EnvironmentObject private var noteStore: NoteStore
    @EnvironmentObject private var reminderStore: ReminderStore
    @EnvironmentObject private var weatherStore: WeatherStore
    @Environment(\.appTheme) private var theme
    @Binding var selectedDate: Date
    @Binding var showingHistory: Bool
    let compact: Bool
    @State private var detailCapsule: DailyCapsule?

    private var capsules: [DailyCapsule] {
        DailyCapsuleService.historyCapsules(noteStore: noteStore, reminderStore: reminderStore, weatherInfo: weatherStore.info)
    }

    private var groupedCapsules: [(String, [DailyCapsule])] {
        let groups = Dictionary(grouping: capsules) { capsule in
            monthTitle(for: capsule.date)
        }
        return groups
            .map { ($0.key, $0.value.sorted { $0.date > $1.date }) }
            .sorted { lhs, rhs in
                guard let left = lhs.1.first?.date, let right = rhs.1.first?.date else { return lhs.0 > rhs.0 }
                return left > right
            }
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: compact ? 14 : 18) {
                header
                if let detailCapsule {
                    CapsuleDetailPanel(capsule: detailCapsule, compact: compact) {
                        withAnimation(.spring(response: 0.26, dampingFraction: 0.84)) {
                            self.detailCapsule = nil
                        }
                    }
                } else if capsules.isEmpty {
                    historyEmpty
                } else {
                    LazyVStack(alignment: .leading, spacing: compact ? 18 : 22) {
                        ForEach(groupedCapsules, id: \.0) { group in
                            VStack(alignment: .leading, spacing: 14) {
                                Text(group.0)
                                    .font(.system(size: 15, weight: .bold, design: .rounded))
                                    .foregroundStyle(theme.palette.muted)
                                    .padding(.leading, 4)
                                VStack(spacing: 0) {
                                    ForEach(group.1) { capsule in
                                        HStack(alignment: .top, spacing: 14) {
                                            VStack(spacing: 6) {
                                                Circle()
                                                    .fill(theme.palette.accent.opacity(0.82))
                                                    .frame(width: 9, height: 9)
                                                Rectangle()
                                                    .fill(theme.palette.line)
                                                    .frame(width: 1)
                                            }
                                            .frame(width: 18)
                                            CapsuleHistoryCard(capsule: capsule, compact: compact) {
                                                withAnimation(.spring(response: 0.26, dampingFraction: 0.84)) {
                                                    detailCapsule = capsule
                                                    selectedDate = capsule.date
                                                }
                                            }
                                        }
                                        .padding(.bottom, 16)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, compact ? 20 : 32)
            .padding(.bottom, 24)
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 6) {
                Text(detailCapsule == nil ? "历史胶囊" : "胶囊详情")
                    .font(.system(size: compact ? 28 : 34, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.palette.text)
                    .noWrap()
                Text("按日期回看灵感、事项、心情和当天总结。")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.palette.muted)
                    .noWrap(scale: 0.7)
            }
            Spacer()
            Button {
                withAnimation(.spring(response: 0.26, dampingFraction: 0.84)) {
                    showingHistory = false
                    detailCapsule = nil
                }
            } label: {
                Label("回到今天", systemImage: "calendar")
                    .font(.system(size: 12, weight: .bold))
                    .noWrap()
            }
            .buttonStyle(SecondaryButtonStyle())
        }
        .padding(.top, compact ? 16 : 24)
    }

    private var historyEmpty: some View {
        VStack(spacing: 14) {
            Image(systemName: "archivebox")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(theme.palette.cyan)
            Text("还没有历史胶囊")
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(theme.palette.text)
            Text("写下一段今日灵感，或添加一个提醒事项，胶囊就会自动生成。")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(theme.palette.muted)
                .multilineTextAlignment(.center)
            Button {
                showingHistory = false
                selectedDate = Date()
            } label: {
                Label("去记录今天", systemImage: "sparkles")
                    .font(.system(size: 13, weight: .bold))
            }
            .buttonStyle(PrimaryButtonStyle())
            .frame(width: 160)
        }
        .frame(maxWidth: .infinity, minHeight: compact ? 320 : 420)
        .glassPanel(radius: 24)
    }

    private func monthTitle(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.dateFormat = "yyyy年 M月"
        return formatter.string(from: date)
    }
}

struct CapsuleHistoryCard: View {
    @Environment(\.appTheme) private var theme
    let capsule: DailyCapsule
    let compact: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: compact ? 12 : 16) {
                CapsuleOrb(status: capsule.status, progress: capsule.reminders.isEmpty ? 0.35 : Double(capsule.completedCount) / Double(max(capsule.reminders.count, 1)), size: compact ? 42 : 48)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(capsule.displayDate)
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundStyle(theme.palette.text)
                            .noWrap()
                        Text(capsule.status.title)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(theme.palette.accent)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(theme.palette.accent.opacity(0.12), in: Capsule())
                        Text(capsule.completionText)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(theme.palette.muted)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(theme.palette.card, in: Capsule())
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(theme.palette.muted)
                    }
                    Text(capsule.summary)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(theme.palette.text)
                        .lineLimit(2)
                    if let question = capsule.dailyQuestion {
                        Label(question.question, systemImage: "sparkles")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(theme.palette.accent)
                            .lineLimit(1)
                    }
                    FlowPillRow(items: capsule.keywords, fallback: [capsule.mood])
                }
                .layoutPriority(1)
            }
            .padding(compact ? 15 : 18)
            .frame(maxWidth: .infinity, minHeight: compact ? 120 : 132, maxHeight: 150)
            .glassPanel(radius: 22, active: isHovering)
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovering ? 1.008 : 1)
        .animation(.spring(response: 0.22, dampingFraction: 0.84), value: isHovering)
        .onHover { isHovering = $0 }
    }
}

struct CapsuleDetailPanel: View {
    @Environment(\.appTheme) private var theme
    let capsule: DailyCapsule
    let compact: Bool
    let onBack: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Button(action: onBack) {
                    Label("返回列表", systemImage: "chevron.left")
                        .font(.system(size: 12, weight: .bold))
                }
                .buttonStyle(SecondaryButtonStyle())
                Spacer()
                Button {
                    NoteExporter.exportDocx(capsule: capsule)
                } label: {
                    Label("Word", systemImage: "doc.richtext")
                        .font(.system(size: 12, weight: .bold))
                }
                .buttonStyle(SecondaryButtonStyle())
                Button {
                    NoteExporter.exportPDF(capsule: capsule)
                } label: {
                    Label("PDF", systemImage: "doc.fill")
                        .font(.system(size: 12, weight: .bold))
                }
                .buttonStyle(PrimaryButtonStyle())
            }

            SummaryCard(capsule: capsule, compact: compact) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(capsule.summary, forType: .string)
            }

            if let question = capsule.dailyQuestion {
                DailyQuestionHistoryBlock(question: question, compact: compact)
            }

            VStack(alignment: .leading, spacing: 10) {
                Label("灵感原文", systemImage: "text.alignleft")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.palette.text)
                Text(capsule.noteText.isEmpty ? "这一天还没有记录。" : capsule.noteText)
                    .font(.system(size: 14))
                    .foregroundStyle(theme.palette.text)
                    .textSelection(.enabled)
                    .lineSpacing(5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(theme.palette.ink.opacity(0.22), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .padding(16)
            .glassPanel(radius: 20)

            VStack(alignment: .leading, spacing: 10) {
                Label("提醒事项", systemImage: "checklist")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.palette.text)
                if capsule.reminders.isEmpty {
                    Text("暂无事项")
                        .font(.system(size: 13))
                        .foregroundStyle(theme.palette.muted)
                } else {
                    ForEach(capsule.reminders) { item in
                        HStack {
                            Image(systemName: item.isDone ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(item.isDone ? theme.palette.cyan : theme.palette.muted)
                            Text(item.title)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(theme.palette.text)
                            Spacer()
                            Text(item.frequency.title)
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(theme.palette.muted)
                        }
                        .padding(10)
                        .background(theme.palette.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
            }
            .padding(16)
            .glassPanel(radius: 20)
        }
    }
}

struct NotebookPanel: View {
    @EnvironmentObject private var noteStore: NoteStore
    @EnvironmentObject private var reminderStore: ReminderStore
    @EnvironmentObject private var weatherStore: WeatherStore
    @Environment(\.appTheme) private var theme
    let selectedDate: Date
    let compact: Bool
    @State private var draft = ""
    @State private var inspirationAnalysis = InspirationAnalyzer.analyze("")
    @State private var analysisWorkItem: DispatchWorkItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                CartoonPersonBadge(progress: inspirationProgress, compact: compact)
                VStack(alignment: .leading, spacing: 4) {
                    Label("今日灵感胶囊", systemImage: theme.symbol(.note))
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.palette.text)
                        .noWrap()
                    Text(inspirationMessage)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(draft.count >= inspirationProgressTarget ? theme.palette.warm : theme.palette.cyan)
                        .noWrap(scale: 0.72)
                }
                Spacer()
                Button {
                    NoteExporter.exportDocx(capsule: capsule)
                } label: {
                    Label("Word", systemImage: "doc.richtext")
                        .font(.system(size: 12, weight: .bold))
                        .noWrap(scale: 0.72)
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .opacity(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.48 : 1)

                Button {
                    NoteExporter.exportPDF(capsule: capsule)
                } label: {
                    Label("PDF", systemImage: "doc.fill")
                        .font(.system(size: 12, weight: .bold))
                        .noWrap(scale: 0.72)
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .opacity(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.48 : 1)
            }

            InspirationProgressBar(progress: inspirationProgress)

            InspirationInsightRow(analysis: inspirationAnalysis, compact: compact)

            ZStack(alignment: .topLeading) {
                if draft.isEmpty {
                    Text("快来记录今日灵感吧，在这里，你可以畅所欲言。")
                        .font(.system(size: 15))
                        .foregroundStyle(theme.palette.muted.opacity(0.58))
                        .padding(.top, 8)
                }
                TextEditor(text: $draft)
                    .font(.system(size: 15))
                    .foregroundStyle(theme.palette.text)
                    .scrollContentBackground(.hidden)
                    .background(Color.clear)
                    .frame(minHeight: compact ? 128 : 158)
                    .onChange(of: draft) { value in
                        updateDraft(value)
                    }
            }
            .padding(8)
            .background(theme.palette.ink.opacity(0.26), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(theme.palette.line, lineWidth: 1)
            )
        }
        .padding(compact ? 14 : 16)
        .glassPanel(radius: 20, active: noteStore.hasNote(on: selectedDate))
        .hoverLift()
        .animation(.easeInOut(duration: 0.20), value: draft.isEmpty)
        .onAppear {
            draft = noteStore.note(for: selectedDate)
            inspirationAnalysis = InspirationAnalyzer.analyze(draft)
        }
        .onChange(of: selectedDate) { newDate in
            noteStore.flushSave()
            draft = noteStore.note(for: newDate)
            inspirationAnalysis = InspirationAnalyzer.analyze(draft)
        }
        .onDisappear {
            noteStore.flushSave()
        }
    }

    private var inspirationProgress: Double {
        min(Double(draft.count) / Double(inspirationProgressTarget), 1.0)
    }

    private var inspirationMessage: String {
        draft.count >= inspirationProgressTarget ? "很棒，今日灵感爆棚" : "灵感蓄力中 \(Int(inspirationProgress * 100))% · \(draft.count)/\(inspirationProgressTarget)"
    }

    private var capsule: DailyCapsule {
        DailyCapsuleService.capsule(on: selectedDate, noteStore: noteStore, reminderStore: reminderStore, weatherInfo: weatherStore.info)
    }

    private func updateDraft(_ value: String) {
        let limited = String(value.prefix(inspirationCharacterLimit))
        if limited != value {
            draft = limited
            return
        }
        noteStore.setNote(limited, for: selectedDate)
        scheduleAnalysis(for: limited)
    }

    private func applyFormat(_ format: InspirationTextFormat) {
        var insertion = ""
        let needsLeadingBreak = !draft.isEmpty && !draft.hasSuffix("\n")

        switch format {
        case .heading:
            insertion = "\(needsLeadingBreak ? "\n" : "")## "
        case .bold:
            insertion = "**加粗文本**"
        case .italic:
            insertion = "*斜体文本*"
        case .bullet:
            insertion = "\(needsLeadingBreak ? "\n" : "")- "
        case .numbered:
            insertion = "\(needsLeadingBreak ? "\n" : "")1. "
        case .checklist:
            insertion = "\(needsLeadingBreak ? "\n" : "")- [ ] "
        case .quote:
            insertion = "\(needsLeadingBreak ? "\n" : "")> "
        case .code:
            insertion = "`代码`"
        case .link:
            insertion = "[链接文本](https://)"
        case .mention:
            insertion = "@"
        case .divider:
            insertion = "\(needsLeadingBreak ? "\n" : "")---\n"
        case .expand:
            insertion = ""
        }

        guard !insertion.isEmpty else { return }
        draft = String((draft + insertion).prefix(inspirationCharacterLimit))
        noteStore.setNote(draft, for: selectedDate)
        scheduleAnalysis(for: draft)
    }

    private func scheduleAnalysis(for text: String) {
        analysisWorkItem?.cancel()
        let work = DispatchWorkItem {
            inspirationAnalysis = InspirationAnalyzer.analyze(text)
        }
        analysisWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
    }
}

struct EmotionalToast: View {
    @Environment(\.appTheme) private var theme
    let message: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .foregroundStyle(theme.palette.warm)
            Text(message)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.palette.text)
                .noWrap(scale: 0.72)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(theme.palette.cardStrong, in: Capsule())
        .overlay(Capsule().stroke(theme.palette.accent.opacity(0.7), lineWidth: 1))
        .shadow(color: theme.palette.accent.opacity(0.26), radius: 16, x: 0, y: 8)
    }
}

struct StatusGrid: View {
    @Environment(\.appTheme) private var theme
    let items: [ReminderItem]
    let compact: Bool

    var body: some View {
        GeometryReader { proxy in
            let useTwoColumns = proxy.size.width < 560
            let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: useTwoColumns ? 2 : 3)
            LazyVGrid(columns: columns, spacing: 10) {
                StatusTile(title: "事项", value: "\(items.count)", subtitle: "选中日期", systemImage: theme.symbol(.calendar), compact: compact)
                StatusTile(title: "完成率", value: completionRate, subtitle: "已完成 \(doneCount) 项", systemImage: "checkmark.circle", compact: compact)
                StatusTile(title: "下一次提醒", value: nextTime, subtitle: nextTitle, systemImage: theme.symbol(.notification), compact: compact)
            }
        }
        .frame(height: compact ? 170 : 96)
    }

    private var doneCount: Int {
        items.filter { $0.isDone }.count
    }

    private var completionRate: String {
        guard !items.isEmpty else { return "0%" }
        return "\(Int((Double(doneCount) / Double(items.count)) * 100))%"
    }

    private var nextItem: ReminderItem? {
        items.filter { !$0.isDone }.sorted { $0.remindAt < $1.remindAt }.first
    }

    private var nextTime: String {
        guard let item = nextItem else { return "无" }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: item.remindAt)
    }

    private var nextTitle: String {
        nextItem?.frequency.title ?? "暂无待提醒"
    }
}

struct StatusTile: View {
    @Environment(\.appTheme) private var theme
    let title: String
    let value: String
    let subtitle: String
    let systemImage: String
    let compact: Bool

    var body: some View {
        HStack(spacing: compact ? 8 : 12) {
            Image(systemName: systemImage)
                .font(.system(size: compact ? 16 : 18, weight: .semibold))
                .foregroundStyle(theme.palette.cyan)
                .frame(width: compact ? 30 : 34, height: compact ? 30 : 34)
                .background(theme.palette.cyan.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(theme.palette.muted)
                    .noWrap(scale: 0.75)
                Text(value)
                    .font(.system(size: compact ? 17 : 20, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.palette.text)
                    .noWrap(scale: 0.7)
                Text(subtitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.palette.cyan.opacity(0.82))
                    .noWrap(scale: 0.65)
            }
            .layoutPriority(1)
            Spacer(minLength: 0)
        }
        .padding(compact ? 11 : 14)
        .frame(maxWidth: .infinity, minHeight: compact ? 78 : 96)
        .glassPanel(radius: 16)
        .hoverLift()
    }
}

struct ReminderCard: View {
    @Environment(\.appTheme) private var theme
    let item: ReminderItem
    let onToggle: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Button(action: onToggle) {
                Image(systemName: item.isDone ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 24))
                    .foregroundStyle(item.isDone ? theme.palette.cyan : theme.palette.muted)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 7) {
                Text(item.title)
                    .font(.system(size: 18, weight: .semibold))
                    .strikethrough(item.isDone, color: theme.palette.muted)
                    .foregroundStyle(item.isDone ? theme.palette.muted : theme.palette.text)
                    .noWrap(scale: 0.72)
                if !item.notes.isEmpty {
                    Text(item.notes)
                        .font(.system(size: 13))
                        .foregroundStyle(theme.palette.muted)
                        .noWrap(scale: 0.68)
                }
                HStack(spacing: 10) {
                    Label(timeText, systemImage: "bell.fill")
                        .noWrap(scale: 0.75)
                    Text(item.frequency.title)
                        .noWrap(scale: 0.75)
                    if item.frequency == .customMinutes || item.frequency == .customHours {
                        Text("间隔 \(item.customInterval)")
                            .noWrap(scale: 0.75)
                    }
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.palette.cyan)
            }
            .layoutPriority(1)

            Spacer()

            Button(action: onEdit) {
                Image(systemName: "pencil")
            }
            .buttonStyle(IconButtonStyle())

            Button(action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(IconButtonStyle(tint: Color(red: 0.72, green: 0.18, blue: 0.18)))
        }
        .padding(18)
        .glassPanel(radius: 18, active: !item.isDone)
        .hoverLift()
    }

    private var timeText: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: item.remindAt)
    }
}

struct EmptyState: View {
    @Environment(\.appTheme) private var theme
    @Binding var showingEditor: Bool

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "calendar.badge.plus")
                .font(.system(size: 58, weight: .light))
                .foregroundStyle(theme.palette.cyan)
            Text("这一天还很清爽")
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundStyle(theme.palette.text)
                .noWrap(scale: 0.75)
            Text("添加一个事项，应用会按你设定的频率在本机提醒。")
                .font(.system(size: 14))
                .foregroundStyle(theme.palette.muted)
                .noWrap(scale: 0.7)
            Button {
                showingEditor = true
            } label: {
                Label("添加事项", systemImage: "plus.circle.fill")
                    .noWrap()
            }
            .buttonStyle(PrimaryButtonStyle())
            .frame(width: 150)
        }
        .padding(40)
    }
}

struct ReminderEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var theme
    @State private var title: String
    @State private var notes: String
    @State private var date: Date
    @State private var remindAt: Date
    @State private var frequency: ReminderFrequency
    @State private var customInterval: Int

    private let existingID: UUID?
    private let createdAt: Date

    let onSave: (ReminderItem) -> Void

    init(item: ReminderItem?, selectedDate: Date, onSave: @escaping (ReminderItem) -> Void) {
        _title = State(initialValue: item?.title ?? "")
        _notes = State(initialValue: item?.notes ?? "")
        _date = State(initialValue: item?.date ?? selectedDate)
        _remindAt = State(initialValue: item?.remindAt ?? Date())
        _frequency = State(initialValue: item?.frequency ?? .once)
        _customInterval = State(initialValue: item?.customInterval ?? 30)
        existingID = item?.id
        createdAt = item?.createdAt ?? Date()
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: existingID == nil ? "plus.circle.fill" : "pencil.circle.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(theme.palette.accent)
                    .frame(width: 46, height: 46)
                    .background(theme.palette.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                VStack(alignment: .leading, spacing: 5) {
                    Text(existingID == nil ? "添加事项" : "编辑事项")
                        .font(.system(size: 27, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.palette.text)
                        .noWrap(scale: 0.72)
                    Text("设置日期、时间与提醒频率，保存后会同步到 macOS 系统通知。")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(theme.palette.muted)
                        .noWrap(scale: 0.7)
                }
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(IconButtonStyle())
            }

            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 9) {
                    FormFieldTitle("事项")
                    TextField("例如：喝水、复盘、给客户回电话", text: $title)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(theme.palette.text)
                        .padding(.horizontal, 16)
                        .frame(minHeight: 50)
                        .background(
                            theme.palette.ink.opacity(0.28),
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(title.isEmpty ? theme.palette.line : theme.palette.accent.opacity(0.44), lineWidth: 1)
                        )
                }

                VStack(alignment: .leading, spacing: 9) {
                    FormFieldTitle("备注")
                    ZStack(alignment: .topLeading) {
                        if notes.isEmpty {
                            Text("可选，可写下这件事的背景或补充信息")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(theme.palette.muted.opacity(0.60))
                                .padding(.leading, 5)
                                .padding(.top, 8)
                        }
                        TextEditor(text: $notes)
                            .font(.system(size: 14))
                            .foregroundStyle(theme.palette.text)
                            .scrollContentBackground(.hidden)
                            .background(Color.clear)
                    }
                    .padding(10)
                    .frame(minHeight: 104)
                    .background(
                        theme.palette.ink.opacity(0.28),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(notes.isEmpty ? theme.palette.line : theme.palette.accent.opacity(0.38), lineWidth: 1)
                    )
                }

                HStack(spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        FormFieldTitle("日期")
                        DatePicker("", selection: $date, displayedComponents: .date)
                            .labelsHidden()
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        FormFieldTitle("提醒时间")
                        DatePicker("", selection: $remindAt, displayedComponents: .hourAndMinute)
                            .labelsHidden()
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(24)
            .glassPanel(radius: 20)

            VStack(alignment: .leading, spacing: 14) {
                FormFieldTitle("提醒频率")
                Picker("提醒频率", selection: $frequency) {
                    ForEach(ReminderFrequency.allCases) { frequency in
                        Text(frequency.title).tag(frequency)
                    }
                }
                .pickerStyle(.segmented)

                Text(frequencyHelperText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.palette.muted)
                    .fixedSize(horizontal: false, vertical: true)

                if frequency == .customMinutes || frequency == .customHours {
                    Stepper(value: $customInterval, in: 1...240) {
                        Text(frequency == .customMinutes ? "每隔 \(customInterval) 分钟提醒" : "每隔 \(customInterval) 小时提醒")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(theme.palette.text)
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .padding(20)
            .glassPanel(radius: 20, active: frequency == .customMinutes || frequency == .customHours)

            HStack(alignment: .center, spacing: 18) {
                Text("首次使用时，系统会询问通知权限。允许后才能准时弹出提醒。")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.palette.muted)
                    .lineLimit(2)
                    .minimumScaleFactor(0.78)
                Spacer()
                HStack(spacing: 12) {
                    Button("取消") { dismiss() }
                        .buttonStyle(SecondaryButtonStyle())
                        .frame(width: 118, height: 48)
                    Button("保存") {
                        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else {
                            NSSound.beep()
                            return
                        }
                        onSave(ReminderItem(id: existingID ?? UUID(), title: trimmed, notes: notes.trimmingCharacters(in: .whitespacesAndNewlines), date: date, remindAt: remindAt, frequency: frequency, customInterval: customInterval, createdAt: createdAt))
                        dismiss()
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .frame(width: 118, height: 48)
                }
                .fixedSize(horizontal: true, vertical: true)
            }
            .padding(.top, 2)
        }
        .padding(30)
        .frame(width: 700)
        .background(
            ZStack {
                LinearGradient(colors: [theme.palette.ink, theme.palette.plum], startPoint: .topLeading, endPoint: .bottomTrailing)
                Circle()
                    .fill(theme.palette.accent.opacity(0.14))
                    .frame(width: 360, height: 360)
                    .blur(radius: 72)
                    .offset(x: 250, y: -220)
            }
        )
    }

    private var frequencyHelperText: String {
        switch frequency {
        case .daily:
            return "会从起始日期起每日显示在日历与今日行动中，删除该事项即可取消后续重复提醒。"
        case .weekdays:
            return "会从起始日期起同步到每个工作日，周末不显示，删除该事项即可取消整组提醒。"
        case .weekly:
            return "会按所选日期的星期重复显示，删除该事项即可取消整组提醒。"
        case .monthly:
            return "会按所选日期的日期号每月重复显示，删除该事项即可取消整组提醒。"
        case .customMinutes, .customHours:
            return "会按固定间隔触发系统通知，首页仅在起始日期显示。"
        case .once:
            return "只在所选日期显示并提醒一次。"
        }
    }
}

struct FormFieldTitle: View {
    @Environment(\.appTheme) private var theme
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(theme.palette.cyan)
            .noWrap()
    }
}

struct StatRow: View {
    @Environment(\.appTheme) private var theme
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
                .foregroundStyle(theme.palette.muted)
            Spacer()
            Text(value)
                .fontWeight(.bold)
                .foregroundStyle(theme.palette.text)
        }
        .font(.system(size: 13))
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.appTheme) private var theme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(
                LinearGradient(
                    colors: [
                        theme.palette.cyan.opacity(configuration.isPressed ? 0.72 : 0.95),
                        theme.palette.blue.opacity(configuration.isPressed ? 0.66 : 0.9)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.white.opacity(0.26), lineWidth: 1)
            )
            .shadow(color: theme.palette.cyan.opacity(0.22), radius: 12, x: 0, y: 5)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.18, dampingFraction: 0.72), value: configuration.isPressed)
            .focusable(false)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.appTheme) private var theme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(theme.palette.text)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(theme.palette.cardStrong.opacity(configuration.isPressed ? 0.65 : 1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(theme.palette.line, lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.18, dampingFraction: 0.72), value: configuration.isPressed)
            .focusable(false)
    }
}

struct IconButtonStyle: ButtonStyle {
    @Environment(\.appTheme) private var theme
    var tint: Color?

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(tint ?? theme.palette.accent)
            .frame(width: 32, height: 32)
            .background(theme.palette.cardStrong.opacity(configuration.isPressed ? 0.55 : 1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(theme.palette.line, lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.90 : 1)
            .animation(.spring(response: 0.16, dampingFraction: 0.72), value: configuration.isPressed)
            .focusable(false)
    }
}
