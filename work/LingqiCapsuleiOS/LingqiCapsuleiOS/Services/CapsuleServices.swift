import Foundation
import SwiftData
import UserNotifications

enum InspirationAnalyzer {
    private static let positiveWords = ["开心", "完成", "进展", "喜欢", "期待", "感谢", "顺利", "灵感"]
    private static let tiredWords = ["累", "疲惫", "焦虑", "压力", "难过", "烦", "失眠"]
    private static let stopWords: Set<String> = ["今天", "这个", "那个", "然后", "因为", "所以", "还是", "需要"]

    static func keywords(from text: String) -> [String] {
        let tokens = text
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .flatMap { segment -> [String] in
                guard segment.count > 6 else { return [segment] }
                return stride(from: 0, to: segment.count, by: 4).map { offset in
                    let start = segment.index(segment.startIndex, offsetBy: offset)
                    let end = segment.index(start, offsetBy: min(6, segment.distance(from: start, to: segment.endIndex)), limitedBy: segment.endIndex) ?? segment.endIndex
                    return String(segment[start..<end])
                }
            }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 2 && $0.count <= 6 && !stopWords.contains($0) }

        let counts = Dictionary(grouping: tokens, by: { $0 }).mapValues(\.count)
        return counts
            .sorted { lhs, rhs in
                lhs.value == rhs.value ? lhs.key.count > rhs.key.count : lhs.value > rhs.value
            }
            .prefix(4)
            .map(\.key)
    }

    static func mood(from text: String) -> String {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "待唤醒" }
        let positive = positiveWords.filter(text.contains).count
        let tired = tiredWords.filter(text.contains).count
        if positive > tired { return "晴朗" }
        if tired > positive { return "需要休息" }
        return "平稳"
    }
}

@MainActor
final class NotificationService {
    static let shared = NotificationService()

    func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])) ?? false
    }

    func schedule(for item: ActionItem) async {
        guard let reminderDate = item.reminderDate else { return }
        let content = UNMutableNotificationContent()
        content.title = "灵栖胶囊 Capsule"
        content.body = item.title
        content.sound = .default

        let calendar = Calendar.current
        var components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: reminderDate)
        let repeats: Bool
        switch item.frequency {
        case .once:
            repeats = false
        case .daily:
            components.year = nil
            components.month = nil
            components.day = nil
            repeats = true
        case .weekdays, .weekly:
            components.year = nil
            components.month = nil
            components.day = nil
            components.weekday = calendar.component(.weekday, from: reminderDate)
            repeats = true
        case .monthly:
            components.year = nil
            components.month = nil
            repeats = true
        }

        let request = UNNotificationRequest(
            identifier: item.id.uuidString,
            content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: repeats)
        )
        try? await UNUserNotificationCenter.current().add(request)
    }

    func remove(for item: ActionItem) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [item.id.uuidString])
    }
}

struct LegacyMigrationPackage: Codable {
    struct Note: Codable {
        let date: String
        let text: String
    }

    struct Reminder: Codable {
        let id: UUID?
        let title: String
        let notes: String?
        let date: Date
        let remindAt: Date?
        let frequency: String?
        let customInterval: Int?
        let isDone: Bool?
        let createdAt: Date?
    }

    let version: Int
    let exportedAt: Date
    let notes: [Note]
    let reminders: [Reminder]
}

enum LegacyMigrationService {
    @MainActor
    static func importPackage(from url: URL, into context: ModelContext) throws -> (Int, Int) {
        let hasAccess = url.startAccessingSecurityScopedResource()
        defer {
            if hasAccess { url.stopAccessingSecurityScopedResource() }
        }

        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let package = try decoder.decode(LegacyMigrationPackage.self, from: data)

        for note in package.notes where !note.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let date = DayKey.date(from: note.date) ?? Date()
            context.insert(InspirationEntry(text: note.text, date: date))
        }

        for reminder in package.reminders {
            let item = ActionItem(
                title: reminder.title,
                notes: reminder.notes ?? "",
                date: reminder.date,
                reminderDate: reminder.remindAt,
                frequency: ReminderFrequency(rawValue: reminder.frequency ?? "") ?? .once,
                customInterval: reminder.customInterval ?? 30
            )
            if let id = reminder.id { item.id = id }
            item.isCompleted = reminder.isDone ?? false
            item.createdAt = reminder.createdAt ?? Date()
            context.insert(item)
        }

        context.insert(MigrationReceipt(
            source: "macOS v\(package.version)",
            inspirationCount: package.notes.count,
            actionCount: package.reminders.count
        ))
        try context.save()
        return (package.notes.count, package.reminders.count)
    }
}
