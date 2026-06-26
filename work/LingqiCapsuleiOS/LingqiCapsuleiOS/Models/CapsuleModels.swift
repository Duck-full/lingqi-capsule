import Foundation
import SwiftData

enum CapsuleDataStack {
    static let cloudContainerIdentifier = "iCloud.com.duckfull.lingqicapsule"

    static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        let schema = Schema([
            InspirationEntry.self,
            ActionItem.self,
            MigrationReceipt.self
        ])
        let configuration = ModelConfiguration(
            "LingqiCapsuleCloud",
            schema: schema,
            isStoredInMemoryOnly: inMemory,
            cloudKitDatabase: inMemory ? .none : .private(cloudContainerIdentifier)
        )
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}

@Model
final class InspirationEntry {
    var id: UUID = UUID()
    var text: String = ""
    var dayKey: String = ""
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    init(text: String, date: Date = Date()) {
        id = UUID()
        self.text = text
        dayKey = DayKey.string(from: date)
        createdAt = date
        updatedAt = date
    }
}

@Model
final class ActionItem {
    var id: UUID = UUID()
    var title: String = ""
    var notes: String = ""
    var dayKey: String = ""
    var reminderDate: Date?
    var frequencyRaw: String = ReminderFrequency.once.rawValue
    var customInterval: Int = 30
    var isCompleted: Bool = false
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    init(
        title: String,
        notes: String = "",
        date: Date = Date(),
        reminderDate: Date? = nil,
        frequency: ReminderFrequency = .once,
        customInterval: Int = 30
    ) {
        id = UUID()
        self.title = title
        self.notes = notes
        dayKey = DayKey.string(from: date)
        self.reminderDate = reminderDate
        frequencyRaw = frequency.rawValue
        self.customInterval = customInterval
        createdAt = Date()
        updatedAt = Date()
    }

    var frequency: ReminderFrequency {
        get { ReminderFrequency(rawValue: frequencyRaw) ?? .once }
        set { frequencyRaw = newValue.rawValue }
    }
}

@Model
final class MigrationReceipt {
    var id: UUID = UUID()
    var source: String = ""
    var importedAt: Date = Date()
    var inspirationCount: Int = 0
    var actionCount: Int = 0

    init(source: String, inspirationCount: Int, actionCount: Int) {
        id = UUID()
        self.source = source
        importedAt = Date()
        self.inspirationCount = inspirationCount
        self.actionCount = actionCount
    }
}

enum ReminderFrequency: String, CaseIterable, Identifiable, Codable {
    case once
    case daily
    case weekdays
    case weekly
    case monthly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .once: "仅一次"
        case .daily: "每天"
        case .weekdays: "工作日"
        case .weekly: "每周"
        case .monthly: "每月"
        }
    }
}

enum DayKey {
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func string(from date: Date) -> String {
        formatter.string(from: date)
    }

    static func date(from string: String) -> Date? {
        formatter.date(from: string)
    }
}

struct CapsuleSnapshot: Identifiable {
    let dayKey: String
    let inspirations: [InspirationEntry]
    let actions: [ActionItem]

    var id: String { dayKey }
    var date: Date { DayKey.date(from: dayKey) ?? Date() }
    var fullText: String { inspirations.map(\.text).joined(separator: "\n") }
    var keywords: [String] { InspirationAnalyzer.keywords(from: fullText) }
    var mood: String { InspirationAnalyzer.mood(from: fullText) }
    var completedCount: Int { actions.filter(\.isCompleted).count }
}
