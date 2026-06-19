import SwiftUI
import AppKit
import UserNotifications
import UniformTypeIdentifiers
import OSLog

private let inspirationProgressTarget = 300
private let inspirationCharacterLimit = 2000
private let quickInspirationCharacterLimit = 200
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
    case summary
    case history
    case theme
    case settings
}

extension Notification.Name {
    static let quickPanelRouteRequested = Notification.Name("local.codex.lingqi.quickPanelRouteRequested")
    static let quickInspirationSaved = Notification.Name("local.codex.lingqi.quickInspirationSaved")
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

final class ReminderStore: ObservableObject {
    @Published private(set) var items: [ReminderItem] = []

    private let fileURL: URL
    private let schedulesNotifications: Bool
    private let saveQueue = DispatchQueue(label: "local.codex.lingqi.reminders.save", qos: .utility)
    private var itemsByDay: [String: [ReminderItem]] = [:]
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
        persistAndSchedule(item)
    }

    func update(_ item: ReminderItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        let previousItem = items[index]
        items[index] = item
        sort()
        removeFromDayIndex(previousItem)
        addToDayIndex(item)
        persistAndSchedule(item)
    }

    func delete(_ item: ReminderItem) {
        items.removeAll { $0.id == item.id }
        removeFromDayIndex(item)
        persist()
        if schedulesNotifications {
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: NotificationScheduler.identifiers(for: item))
        }
    }

    func toggleDone(_ item: ReminderItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].isDone.toggle()
        updateDayIndex(items[index])
        persistAndSchedule(items[index])
    }

    func items(on day: Date) -> [ReminderItem] {
        itemsByDay[DateKey.string(from: day)] ?? []
    }

    func count(on day: Date) -> Int {
        itemsByDay[DateKey.string(from: day)]?.count ?? 0
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
        let merged = existing.isEmpty ? trimmed : existing + "\n" + trimmed
        setNote(merged, for: date)
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
        let view = NotePDFView(dateTitle: DateKey.display(from: date), note: note)
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

    private static func saveURL(extensionName: String, date: Date) -> URL? {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "今日灵感胶囊-\(DateKey.string(from: date)).\(extensionName)"
        if let type = UTType(filenameExtension: extensionName) {
            panel.allowedContentTypes = [type]
        }
        return panel.runModal() == .OK ? panel.url : nil
    }

    private static func htmlDocument(note: String, date: Date) -> String {
        """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <style>
            body { font-family: -apple-system, BlinkMacSystemFont, "PingFang SC", "Helvetica Neue", Arial, sans-serif; line-height: 1.65; color: #1f1f24; }
            h1 { font-size: 24px; margin-bottom: 4px; }
            .date { color: #666; margin-bottom: 24px; }
            .note { white-space: pre-wrap; font-size: 15px; }
          </style>
        </head>
        <body>
          <h1>今日灵感胶囊</h1>
          <div class="date">\(escape(DateKey.display(from: date)))</div>
          <div class="note">\(escape(note))</div>
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
            NSApp.activate(ignoringOtherApps: true)
            NSApplication.shared.windows.first?.makeKeyAndOrderFront(nil)
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
        WindowGroup {
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

        MenuBarExtra("灵栖胶囊Capsule", systemImage: "leaf.fill") {
            MenuBarQuickPanel()
                .environmentObject(store)
                .environmentObject(noteStore)
                .environmentObject(weatherStore)
                .environment(\.appTheme, AppTheme(rawValue: selectedThemeRaw) ?? .immersiveVista)
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

    private func configureWindows() {
        for window in NSApplication.shared.windows where window.level == .normal {
            window.title = "灵栖胶囊Capsule"
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
    @EnvironmentObject private var store: ReminderStore
    @EnvironmentObject private var noteStore: NoteStore
    @EnvironmentObject private var weatherStore: WeatherStore
    @Environment(\.appTheme) private var theme
    @State private var inspirationDraft = ""
    @State private var inspirationAnalysis = InspirationAnalyzer.analyze("")
    @State private var analysisWorkItem: DispatchWorkItem?
    @State private var isInputFocused = false
    @State private var saveFeedback: String?
    @State private var didSave = false

    var body: some View {
        ZStack {
            QuickPanelBackground()
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    QuickPanelHeader(onRefresh: refreshWeather)
                    QuickWeatherBadge()
                    QuickInspirationInputView(
                        text: $inspirationDraft,
                        analysis: inspirationAnalysis,
                        isFocused: $isInputFocused,
                        feedback: saveFeedback
                    )
                    QuickMainActionRow(
                        canSave: canSave,
                        didSave: didSave,
                        onSave: saveInspiration,
                        onOpen: { openMainWindow(route: .today) }
                    )
                    RecentInspirationListView(items: recentInspirations) {
                        openMainWindow(route: .history)
                    }
                    QuickActionGridView { route in
                        openMainWindow(route: route)
                    }
                    Text("愿你的灵感，慢慢发光 ✨")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(QuickPanelStyle.subText)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 2)
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 20)
            }
        }
        .frame(width: 404, height: 648)
        .onAppear {
            inspirationDraft = ""
            inspirationAnalysis = InspirationAnalyzer.analyze(inspirationDraft)
            if weatherStore.info == nil {
                weatherStore.refresh()
            }
        }
        .onDisappear {
            noteStore.flushSave()
        }
    }

    private var recentInspirations: [RecentInspiration] {
        noteStore.recentInspirations(limit: 3)
    }

    private var canSave: Bool {
        !inspirationDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var inspirationProgress: Double {
        min(Double(inspirationDraft.count) / Double(quickInspirationCharacterLimit), 1.0)
    }

    private func openMainWindow(route: QuickPanelRoute = .today) {
        NSApp.activate(ignoringOtherApps: true)
        NSApplication.shared.windows.first?.makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(name: .quickPanelRouteRequested, object: route.rawValue)
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
        scheduleAnalysis(for: limited)
    }

    private func saveInspiration() {
        let trimmed = inspirationDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        noteStore.appendNote(trimmed, for: Date())
        inspirationDraft = ""
        inspirationAnalysis = InspirationAnalyzer.analyze("")
        didSave = true
        saveFeedback = "灵感已被小树苗吸收"
        NotificationCenter.default.post(name: .quickInspirationSaved, object: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation(.easeOut(duration: 0.18)) {
                didSave = false
                saveFeedback = nil
            }
        }
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

enum QuickPanelStyle {
    static let backgroundTop = Color(red: 0.055, green: 0.085, blue: 0.135)
    static let backgroundBottom = Color(red: 0.070, green: 0.095, blue: 0.150)
    static let card = Color.white.opacity(0.075)
    static let cardStrong = Color.white.opacity(0.105)
    static let stroke = Color.white.opacity(0.14)
    static let strokeActive = Color(red: 0.54, green: 0.70, blue: 1.0).opacity(0.55)
    static let text = Color(red: 0.972, green: 0.980, blue: 0.988)
    static let subText = Color(red: 0.58, green: 0.64, blue: 0.72)
    static let weakText = Color(red: 0.40, green: 0.46, blue: 0.55)
    static let blue = Color(red: 0.54, green: 0.70, blue: 1.0)
    static let green = Color(red: 0.65, green: 0.95, blue: 0.82)
    static let purple = Color(red: 0.75, green: 0.52, blue: 0.99)
}

struct QuickPanelBackground: View {
    @Environment(\.appTheme) private var theme

    var body: some View {
        ZStack {
            LinearGradient(colors: [QuickPanelStyle.backgroundTop, QuickPanelStyle.backgroundBottom], startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [theme.palette.accent.opacity(0.20), .clear], center: .topTrailing, startRadius: 10, endRadius: 320)
            RadialGradient(colors: [theme.palette.warm.opacity(0.11), .clear], center: .bottomLeading, startRadius: 10, endRadius: 360)
            Rectangle()
                .fill(.ultraThinMaterial)
                .opacity(0.18)
        }
    }
}

struct QuickGlassCard<Content: View>: View {
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
            .background(QuickPanelStyle.card.opacity(active ? 1.18 : 1), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(active ? QuickPanelStyle.strokeActive : QuickPanelStyle.stroke, lineWidth: active ? 1.2 : 1)
            )
            .shadow(color: Color.black.opacity(active ? 0.20 : 0.12), radius: active ? 14 : 9, x: 0, y: 6)
    }
}

struct QuickPanelHeader: View {
    @Environment(\.appTheme) private var theme
    let onRefresh: () -> Void
    @State private var hoveringRefresh = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "leaf.fill")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(QuickPanelStyle.green)
                .frame(width: 32, height: 32)
                .background(QuickPanelStyle.cardStrong, in: Circle())
                .overlay(Circle().stroke(QuickPanelStyle.stroke, lineWidth: 1))
            Text("灵栖胶囊")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(QuickPanelStyle.text)
            Spacer()
            Circle()
                .fill(QuickPanelStyle.green)
                .frame(width: 7, height: 7)
            Text("已保存本地")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(QuickPanelStyle.green.opacity(0.88))
            Button(action: onRefresh) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(hoveringRefresh ? QuickPanelStyle.text : QuickPanelStyle.subText)
                    .frame(width: 28, height: 28)
                    .background(hoveringRefresh ? QuickPanelStyle.cardStrong : Color.clear, in: Circle())
            }
            .buttonStyle(.plain)
            .onHover { hoveringRefresh = $0 }
            .help("刷新天气")
        }
        .frame(height: 40)
    }
}

struct QuickWeatherBadge: View {
    @EnvironmentObject private var weatherStore: WeatherStore

    var body: some View {
        QuickGlassCard(radius: 16) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(dateText)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(QuickPanelStyle.text)
                    Text(weatherText)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(QuickPanelStyle.subText)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: weatherStore.info?.icon ?? "cloud.sun.fill")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(QuickPanelStyle.blue)
                Text(shortWeatherText)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(QuickPanelStyle.text)
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }

    private var dateText: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.dateFormat = "M月d日 EEEE"
        return formatter.string(from: Date())
    }

    private var weatherText: String {
        guard let info = weatherStore.info else { return weatherStore.message }
        return "\(info.city) \(Int(info.temperature.rounded()))°C \(info.summary)"
    }

    private var shortWeatherText: String {
        guard let info = weatherStore.info else { return "天气" }
        return "\(Int(info.temperature.rounded()))°C \(info.summary)"
    }
}

struct QuickInspirationInputView: View {
    @Binding var text: String
    let analysis: InspirationAnalysis
    @Binding var isFocused: Bool
    let feedback: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text("快速记录此刻的灵感…")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(QuickPanelStyle.weakText)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 13)
                }
                TextEditor(text: $text)
                    .font(.system(size: 14))
                    .foregroundStyle(QuickPanelStyle.text)
                    .scrollContentBackground(.hidden)
                    .background(Color.clear)
                    .frame(height: 110)
                    .onChange(of: text) { value in
                        let limited = String(value.prefix(quickInspirationCharacterLimit))
                        if limited != value { text = limited }
                    }
            }
            .padding(8)
            .background(QuickPanelStyle.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(alignment: .bottomTrailing) {
                Text("\(text.count) / \(quickInspirationCharacterLimit)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(text.count >= quickInspirationCharacterLimit ? Color(red: 0.99, green: 0.65, blue: 0.65) : QuickPanelStyle.subText)
                    .padding(.trailing, 14)
                    .padding(.bottom, 12)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(text.isEmpty ? QuickPanelStyle.stroke : QuickPanelStyle.strokeActive, lineWidth: text.isEmpty ? 1 : 1.2)
            )

            HStack(spacing: 7) {
                if let feedback {
                    Label(feedback, systemImage: "leaf.fill")
                        .foregroundStyle(QuickPanelStyle.green)
                        .transition(.move(edge: .top).combined(with: .opacity))
                } else {
                    Label(analysis.mood, systemImage: analysis.moodSymbol)
                        .foregroundStyle(QuickPanelStyle.subText)
                }
                Spacer()
            }
            .font(.system(size: 11, weight: .semibold))
            .frame(height: 18)
            .animation(.easeInOut(duration: 0.18), value: feedback)
        }
    }
}

struct QuickMainActionRow: View {
    let canSave: Bool
    let didSave: Bool
    let onSave: () -> Void
    let onOpen: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onSave) {
                HStack(spacing: 8) {
                    Image(systemName: didSave ? "checkmark.circle.fill" : "tray.and.arrow.down.fill")
                    Text(didSave ? "已保存" : "保存灵感  ⌘↵")
                }
                .font(.system(size: 13, weight: .bold))
                .frame(maxWidth: .infinity, minHeight: 46)
            }
            .buttonStyle(QuickPrimaryButtonStyle())
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!canSave)
            .opacity(canSave ? 1 : 0.46)

            Button(action: onOpen) {
                Text("打开完整胶囊")
                    .font(.system(size: 13, weight: .bold))
                    .frame(maxWidth: .infinity, minHeight: 46)
            }
            .buttonStyle(QuickSecondaryButtonStyle())
        }
    }
}

struct RecentInspirationListView: View {
    let items: [RecentInspiration]
    let onViewAll: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
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
            }

            if items.isEmpty {
                QuickGlassCard(radius: 14) {
                    Text("还没有灵感记录，先写下第一条吧。")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(QuickPanelStyle.subText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(13)
                }
            } else {
                VStack(spacing: 8) {
                    ForEach(items.prefix(3)) { item in
                        QuickGlassCard(radius: 14) {
                            HStack(alignment: .top, spacing: 10) {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(item.displayText)
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(QuickPanelStyle.text)
                                        .lineLimit(2)
                                    Text(item.timeText)
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(QuickPanelStyle.weakText)
                                }
                                Spacer()
                                Text(item.countText)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(QuickPanelStyle.weakText)
                            }
                            .padding(12)
                        }
                    }
                }
            }
        }
    }
}

struct QuickActionGridView: View {
    let action: (QuickPanelRoute) -> Void
    private let items: [(QuickPanelRoute, String, String)] = [
        (.summary, "今日总结", "doc.text.magnifyingglass"),
        (.history, "历史胶囊", "archivebox"),
        (.theme, "主题换肤", "paintpalette"),
        (.settings, "设置中心", "gearshape")
    ]

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
            ForEach(items, id: \.0.rawValue) { item in
                QuickActionTile(title: item.1, systemImage: item.2) {
                    action(item.0)
                }
            }
        }
    }
}

struct QuickActionTile: View {
    let title: String
    let systemImage: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(QuickPanelStyle.blue.opacity(hovering ? 1 : 0.78))
                Text(title)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(QuickPanelStyle.subText)
                    .noWrap(scale: 0.72)
            }
            .frame(maxWidth: .infinity, minHeight: 76)
            .background(QuickPanelStyle.card.opacity(hovering ? 1.35 : 1), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .stroke(hovering ? QuickPanelStyle.strokeActive : QuickPanelStyle.stroke, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
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
                    colors: [Color(red: 0.49, green: 0.55, blue: 1.0), Color(red: 0.75, green: 0.52, blue: 0.99)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .opacity(configuration.isPressed ? 0.82 : 1),
                in: RoundedRectangle(cornerRadius: 15, style: .continuous)
            )
            .shadow(color: QuickPanelStyle.purple.opacity(configuration.isPressed ? 0.12 : 0.24), radius: 16, x: 0, y: 8)
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
                    Sidebar(selectedDate: $selectedDate, showingEditor: $showingEditor, showingHistory: $showingHistory, selectedThemeRaw: $selectedThemeRaw, compact: compact) {
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
            IconSettingsSheet()
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
        case .today:
            showingHistory = false
        case .summary:
            showingHistory = false
        case .history:
            showingHistory = true
        case .theme:
            showingHistory = false
            showingThemePanel = true
        case .settings:
            showingHistory = false
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
    @Binding var selectedThemeRaw: String
    let compact: Bool
    let onStartRestMode: () -> Void
    @State private var visibleMonth = Date()

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: compact ? 14 : 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("灵栖胶囊Capsule")
                        .font(.system(size: compact ? 26 : 30, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.palette.text)
                        .noWrap(scale: 0.75)
                    Text(todaySummary)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(theme.palette.muted)
                        .noWrap(scale: 0.72)
                }
                .padding(.top, compact ? 14 : 22)

                CalendarPanel(selectedDate: $selectedDate, visibleMonth: $visibleMonth)

                SidebarQuickActionRow(
                    compact: compact,
                    onRest: onStartRestMode,
                    onToday: {
                        selectedDate = Date()
                        showingHistory = false
                    },
                    onNewItem: {
                        showingHistory = false
                        showingEditor = true
                    }
                )

                SidebarHistoryButton(
                    isActive: showingHistory,
                    compact: compact,
                    action: { showingHistory = true }
                )

                InspirationSeedCard(noteCount: noteStore.note(for: Date()).count, compact: compact)
            }
            .padding(.horizontal, compact ? 14 : 24)
            .padding(.bottom, 18)
        }
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
        HStack(spacing: compact ? 7 : 9) {
            SidebarQuickActionButton(
                title: compact ? "休鼾" : "休鼾一下",
                systemImage: "moon.zzz.fill",
                accent: theme.palette.warm,
                action: onRest
            )
            SidebarQuickActionButton(
                title: "今天",
                systemImage: "calendar",
                accent: theme.palette.cyan,
                action: onToday
            )
            SidebarQuickActionButton(
                title: "新事项",
                systemImage: "plus",
                accent: theme.palette.accent,
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
    var isPrimary = false
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .bold))
                Text(title)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .noWrap(scale: 0.62)
            }
            .foregroundStyle(isPrimary ? .white : theme.palette.text)
            .frame(maxWidth: .infinity, minHeight: 42)
            .padding(.horizontal, 8)
            .background(buttonBackground, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .stroke(isPrimary ? Color.white.opacity(0.22) : accent.opacity(isHovering ? 0.74 : 0.36), lineWidth: isHovering ? 1.35 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
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

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)
    private let weekdaySymbols = ["日", "一", "二", "三", "四", "五", "六"]

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Button {
                    moveMonth(-1)
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .background(theme.palette.card.opacity(0.72), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .stroke(theme.palette.line.opacity(0.75), lineWidth: 1)
                )
                Spacer()
                Text(monthTitle)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.palette.text)
                    .noWrap(scale: 0.8)
                Spacer()
                Button {
                    moveMonth(1)
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .background(theme.palette.card.opacity(0.72), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .stroke(theme.palette.line.opacity(0.75), lineWidth: 1)
                )
            }

            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(weekdaySymbols, id: \.self) { symbol in
                    Text(symbol)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(theme.palette.muted)
                        .frame(height: 14)
                }
                ForEach(days, id: \.self) { day in
                    CalendarDayCell(
                        day: day,
                        selectedDate: $selectedDate,
                        visibleMonth: visibleMonth,
                        count: store.count(on: day),
                        hasNote: noteStore.hasNote(on: day)
                    )
                }
            }
            HStack(spacing: 12) {
                CalendarLegendDot(color: theme.palette.cyan, text: "事项")
                CalendarLegendDot(color: theme.palette.warm, text: "灵感")
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 10)
        .glassPanel(radius: 22)
        .hoverLift()
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
                    .font(.system(size: compact ? 14 : 16, weight: .bold))
                    .foregroundStyle(theme.palette.cyan)
                    .frame(width: 34, height: 34)
                    .background(theme.palette.cyan.opacity(0.14), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text("历史胶囊")
                        .font(.system(size: compact ? 13 : 14, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.palette.text)
                        .noWrap()
                    Text("回看每日灵感、事项与总结")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(theme.palette.muted)
                        .noWrap(scale: 0.68)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(theme.palette.muted)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .glassPanel(radius: 17, active: isActive || isHovering)
            .contentShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
        }
        .buttonStyle(.plain)
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

struct InspirationSeedCard: View {
    @Environment(\.appTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let noteCount: Int
    let compact: Bool
    @State private var animateGlow = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [theme.palette.ink.opacity(0.30), theme.palette.surface.opacity(0.18)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Circle()
                    .fill(theme.palette.accent.opacity(0.16))
                    .frame(width: 132, height: 132)
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
                if let image = AppBackgroundLibrary.image(named: "InspirationPlantCapsule", fileExtension: "png") {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(height: compact ? 126 : 152)
                        .shadow(
                            color: PerformanceTuning.prefersReducedEffects ? .clear : theme.palette.accent.opacity(shouldAnimateGlow && animateGlow ? 0.42 : 0.24),
                            radius: PerformanceTuning.prefersReducedEffects ? 0 : (shouldAnimateGlow && animateGlow ? 24 : 14),
                            x: 0,
                            y: PerformanceTuning.prefersReducedEffects ? 0 : 10
                        )
                        .padding(.vertical, 8)
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
                        .offset(y: compact ? 54 : 64)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
            }
            .frame(height: compact ? 142 : 166)
            .overlay(
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .stroke(theme.palette.line.opacity(0.8), lineWidth: 1)
            )

            VStack(alignment: .leading, spacing: 6) {
                Text("今日灵感 \(noteCount) 字")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(theme.palette.text)
                Text(stage.message)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.palette.muted)
                    .lineLimit(2)
            }
        }
        .padding(14)
        .glassPanel(radius: 22, active: noteCount > 0)
        .onAppear {
            animateGlow = noteCount > 0 && shouldAnimateGlow
        }
        .onChange(of: noteCount) { value in
            withAnimation(.easeInOut(duration: 0.28)) {
                animateGlow = value > 0 && shouldAnimateGlow
            }
        }
    }

    private var stage: (title: String, message: String, symbol: String, effect: String) {
        switch noteCount {
        case 0:
            return ("空胶囊", "写下一点灵感，小树苗就会醒来。", "capsule", "等一束光")
        case 1..<60:
            return ("种子已落下", "灵感刚刚开始发光。", "circle.dotted", "灵感醒啦")
        case 60..<160:
            return ("小芽冒出", "今天的想法正在成形。", "leaf", "慢慢发芽")
        case 160..<300:
            return ("树苗生长", "记录已经有了清晰脉络。", "camera.macro", "继续生长")
        default:
            return ("灵感成林", "今天的胶囊很饱满。", "tree", "灵感满格")
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

    var hasContent: Bool {
        !noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !reminders.isEmpty
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
            status: status
        )
    }

    static func historyCapsules(noteStore: NoteStore, reminderStore: ReminderStore, weatherInfo: WeatherInfo?) -> [DailyCapsule] {
        let noteDates = noteStore.noteDates
        let reminderDates = reminderStore.items.map(\.date)
        let keys = Set((noteDates + reminderDates).map { DateKey.string(from: $0) })
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

    var body: some View {
        Group {
            if isCurrentMonth {
                Button {
                    selectedDate = day
                } label: {
                    VStack(spacing: 3) {
                        Text("\(Calendar.current.component(.day, from: day))")
                            .font(.system(size: 12, weight: isSelected ? .bold : .medium))
                            .noWrap(scale: 0.8)
                        HStack(spacing: 3) {
                            Circle()
                                .fill(count > 0 ? theme.palette.cyan : .clear)
                                .frame(width: 4, height: 4)
                            Circle()
                                .fill(hasNote ? theme.palette.warm : .clear)
                                .frame(width: 4, height: 4)
                        }
                        .frame(height: 4)
                    }
                    .foregroundStyle(theme.palette.text)
                    .frame(height: 28)
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
                .hoverLift()
            } else {
                Color.clear
                    .frame(height: 28)
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
        NSApp.activate(ignoringOtherApps: true)
        if let mainWindow = NSApplication.shared.windows.first(where: { $0.title == "灵栖胶囊Capsule" }) {
            mainWindow.makeKeyAndOrderFront(nil)
            return
        }
        NSApplication.shared.windows.first(where: { $0.title != "休鼾一下" })?.makeKeyAndOrderFront(nil)
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
            Color.black.opacity(0.34)
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
                        .foregroundStyle(theme.palette.muted)
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
            .glassPanel(radius: 26, active: true)
            .overlay(
                Image(systemName: theme.illustrationSymbol)
                    .font(.system(size: 120, weight: .ultraLight))
                    .foregroundStyle(theme.palette.accent.opacity(0.08))
                    .offset(x: 150, y: 74)
            )
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

            ZStack(alignment: .topLeading) {
                if draft.isEmpty {
                    Text("写下今天闪过的一个想法……")
                        .font(.system(size: compact ? 12 : 13, weight: .medium))
                        .foregroundStyle(theme.palette.muted.opacity(0.62))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 15)
                }
                TextEditor(text: $draft)
                    .font(.system(size: compact ? 12 : 13))
                    .foregroundStyle(theme.palette.text)
                    .scrollContentBackground(.hidden)
                    .background(Color.clear)
                    .frame(minHeight: compact ? 104 : 122)
                    .onChange(of: draft) { updateDraft($0) }
            }
            .padding(6)
            .background(theme.palette.ink.opacity(0.20), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(alignment: .bottomTrailing) {
                HStack(spacing: 8) {
                    Image(systemName: "leaf")
                    Text("\(draft.count) / \(inspirationCharacterLimit)")
                }
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(theme.palette.muted)
                .padding(.trailing, 18)
                .padding(.bottom, 14)
            }
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
                        .padding(.horizontal, 14)
                        .padding(.vertical, 13)
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

            VStack(alignment: .leading, spacing: 18) {
                FormFieldTitle("事项")
                TextField("例如：喝水、复盘、给客户回电话", text: $title)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 16))

                FormFieldTitle("备注")
                TextField("可选，可写下这件事的背景或补充信息", text: $notes, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(4)

                HStack(spacing: 18) {
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
            .padding(20)
            .glassPanel(radius: 20)

            VStack(alignment: .leading, spacing: 14) {
                FormFieldTitle("提醒频率")
                Picker("提醒频率", selection: $frequency) {
                    ForEach(ReminderFrequency.allCases) { frequency in
                        Text(frequency.title).tag(frequency)
                    }
                }
                .pickerStyle(.segmented)

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

            HStack(spacing: 18) {
                Text("首次使用时，系统会询问通知权限。允许后才能准时弹出提醒。")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.palette.muted)
                    .lineLimit(2)
                    .minimumScaleFactor(0.78)
                Spacer()
                Button("取消") { dismiss() }
                    .buttonStyle(SecondaryButtonStyle())
                    .frame(width: 108)
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
                .frame(width: 112)
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
    }
}
