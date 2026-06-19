import Foundation
import Darwin

private struct BenchmarkMetric: Codable {
    let name: String
    let milliseconds: Double
    let details: String
}

private struct BenchmarkReport: Codable {
    let generatedAt: String
    let architecture: String
    let operatingSystem: String
    let reminderCount: Int
    let dayCount: Int
    let noteCharactersPerDay: Int
    let peakResidentMemoryMB: Double
    let metrics: [BenchmarkMetric]
}

@main
enum PerformanceBenchmark {
    static func main() throws {
        UserDefaults.standard.set(false, forKey: "performanceDiagnosticsEnabled")

        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("lingqi-performance-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let calendar = Calendar(identifier: .gregorian)
        let today = calendar.startOfDay(for: Date())
        let dayCount = 365
        let reminderCount = 5_000
        let noteCharactersPerDay = 2_000
        var metrics: [BenchmarkMetric] = []

        let fixtures = measure("fixture.generate", details: "\(reminderCount) reminders") {
            makeFixtures(
                calendar: calendar,
                today: today,
                dayCount: dayCount,
                reminderCount: reminderCount,
                noteCharactersPerDay: noteCharactersPerDay
            )
        }
        metrics.append(fixtures.metric)

        let reminderStore = ReminderStore(storageDirectory: root, schedulesNotifications: false)
        let reminderWrite = measure("reminders.initial-write", details: "\(reminderCount) reminders") {
            reminderStore.replaceAllForBenchmark(fixtures.value.reminders)
            reminderStore.flushSave()
        }
        metrics.append(reminderWrite.metric)

        let noteStore = NoteStore(storageDirectory: root)
        let noteWrite = measure("notes.initial-write", details: "\(dayCount) days") {
            noteStore.replaceAllForBenchmark(fixtures.value.notes)
        }
        metrics.append(noteWrite.metric)

        let legacyRoot = root.appendingPathComponent("legacy-migration", isDirectory: true)
        try fileManager.createDirectory(at: legacyRoot, withIntermediateDirectories: true)
        try JSONEncoder().encode(fixtures.value.notes).write(
            to: legacyRoot.appendingPathComponent("daily-notes.json"),
            options: [.atomic]
        )
        let migration = measure("notes.legacy-migration", details: "JSON to per-day files") {
            let legacyStore = NoteStore(storageDirectory: legacyRoot)
            legacyStore.flushSave()
            precondition(legacyStore.note(for: today).count == noteCharactersPerDay)
        }
        metrics.append(migration.metric)

        let reload = measure("stores.reload", details: "disk to memory") {
            (
                ReminderStore(storageDirectory: root, schedulesNotifications: false),
                NoteStore(storageDirectory: root)
            )
        }
        metrics.append(reload.metric)

        let query = measure("reminders.query-365-days", details: "indexed day lookup") {
            var total = 0
            for offset in 0..<dayCount {
                let date = calendar.date(byAdding: .day, value: -offset, to: today)!
                total += reload.value.0.count(on: date)
                total += reload.value.0.items(on: date).count
            }
            return total
        }
        metrics.append(query.metric)

        let analyze = measure("inspiration.analyze-365-days", details: "\(noteCharactersPerDay) chars/day") {
            for offset in 0..<dayCount {
                let date = calendar.date(byAdding: .day, value: -offset, to: today)!
                _ = InspirationAnalyzer.analyze(reload.value.1.note(for: date))
            }
        }
        metrics.append(analyze.metric)

        let cachedAnalyze = measure("inspiration.cached-365-days", details: "second analysis pass") {
            for offset in 0..<dayCount {
                let date = calendar.date(byAdding: .day, value: -offset, to: today)!
                _ = InspirationAnalyzer.analyze(reload.value.1.note(for: date))
            }
        }
        metrics.append(cachedAnalyze.metric)

        let history = measure("capsules.build-history", details: "365 daily capsules") {
            DailyCapsuleService.historyCapsules(
                noteStore: reload.value.1,
                reminderStore: reload.value.0,
                weatherInfo: nil
            )
        }
        metrics.append(history.metric)

        let interactionMutation = measure("reminders.single-toggle-ui", details: "without waiting for disk") {
            if let item = reload.value.0.items.first {
                reload.value.0.toggleDone(item)
            }
        }
        metrics.append(interactionMutation.metric)

        let flushMutation = measure("reminders.single-toggle-flush", details: "including JSON persistence") {
            if let item = reload.value.0.items.dropFirst().first {
                reload.value.0.toggleDone(item)
                reload.value.0.flushSave()
            }
        }
        metrics.append(flushMutation.metric)

        let inputDate = calendar.date(byAdding: .day, value: 1, to: today)!
        let inputText = String(fixtures.value.notes.values.first?.prefix(noteCharactersPerDay) ?? "")
        let typing = measure("notes.type-2000-characters", details: "autosave debounce path") {
            var current = ""
            current.reserveCapacity(inputText.count)
            for character in inputText {
                current.append(character)
                reload.value.1.setNote(current, for: inputDate)
            }
            reload.value.1.flushSave()
        }
        metrics.append(typing.metric)

        let report = BenchmarkReport(
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            architecture: architectureName,
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            reminderCount: reminderCount,
            dayCount: dayCount,
            noteCharactersPerDay: noteCharactersPerDay,
            peakResidentMemoryMB: peakResidentMemoryMB(),
            metrics: metrics
        )

        let outputURL = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "performance-report.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: outputURL, options: [.atomic])

        print("Lingqi Capsule performance benchmark")
        print("Architecture: \(report.architecture)")
        print(String(format: "Peak RSS: %.1f MB", report.peakResidentMemoryMB))
        for metric in metrics {
            print(String(format: "%-32s %8.2f ms  %@", (metric.name as NSString).utf8String!, metric.milliseconds, metric.details))
        }
        print("Report: \(outputURL.path)")
    }

    private static func makeFixtures(
        calendar: Calendar,
        today: Date,
        dayCount: Int,
        reminderCount: Int,
        noteCharactersPerDay: Int
    ) -> (reminders: [ReminderItem], notes: [String: String]) {
        let noteSeed = "今天围绕产品体验、性能优化、交互细节和发布计划进行记录。保持专注，也给自己留一点呼吸。"
        let note = String(repeating: noteSeed, count: noteCharactersPerDay / noteSeed.count + 1)
            .prefix(noteCharactersPerDay)
        var notes: [String: String] = [:]
        for offset in 0..<dayCount {
            let date = calendar.date(byAdding: .day, value: -offset, to: today)!
            notes[DateKey.string(from: date)] = String(note)
        }

        var reminders: [ReminderItem] = []
        reminders.reserveCapacity(reminderCount)
        for index in 0..<reminderCount {
            let dayOffset = index % dayCount
            let date = calendar.date(byAdding: .day, value: -dayOffset, to: today)!
            let remindAt = calendar.date(byAdding: .minute, value: index % 1_440, to: date)!
            reminders.append(
                ReminderItem(
                    title: "性能测试事项 \(index + 1)",
                    notes: "用于 5,000 条事项压力测试",
                    date: date,
                    remindAt: remindAt,
                    frequency: .once,
                    customInterval: 1,
                    isDone: index.isMultiple(of: 3),
                    createdAt: date
                )
            )
        }
        return (reminders, notes)
    }

    private static func measure<T>(_ name: String, details: String, operation: () throws -> T) rethrows -> (value: T, metric: BenchmarkMetric) {
        let start = CFAbsoluteTimeGetCurrent()
        let value = try operation()
        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
        return (value, BenchmarkMetric(name: name, milliseconds: elapsed, details: details))
    }

    private static var architectureName: String {
        #if arch(x86_64)
        return "x86_64"
        #elseif arch(arm64)
        return "arm64"
        #else
        return "unknown"
        #endif
    }

    private static func peakResidentMemoryMB() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        return Double(usage.ru_maxrss) / 1024.0 / 1024.0
    }
}
