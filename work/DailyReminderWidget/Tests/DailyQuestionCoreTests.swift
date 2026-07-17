import Foundation

@main
struct DailyQuestionCoreTests {
    static func main() {
        testQuestionIsStableWithinSameDay()
        testRepositoryContainsAtLeastOneHundredQuestions()
        testSavingAnswerPersistsAndAppendsToNoteStore()
        print("DailyQuestionCoreTests passed")
    }

    private static func testQuestionIsStableWithinSameDay() {
        var components = DateComponents()
        components.year = 2026
        components.month = 7
        components.day = 9
        components.hour = 9
        let date = Calendar.current.date(from: components)!
        let provider = LocalDailyQuestionProvider(repository: DailyQuestionRepository())

        let morning = provider.getQuestion(for: date)
        let afternoon = provider.getQuestion(for: date.addingTimeInterval(60 * 60 * 8))

        assert(morning.question == afternoon.question, "expected same question within one day")
        assert(morning.category == afternoon.category, "expected same category within one day")
    }

    private static func testRepositoryContainsAtLeastOneHundredQuestions() {
        assert(DailyQuestionRepository().questionCount >= 100, "expected at least 100 local questions")
    }

    private static func testSavingAnswerPersistsAndAppendsToNoteStore() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("daily-question-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let defaults = UserDefaults(suiteName: "DailyQuestionCoreTests.\(UUID().uuidString)")!
        let date = Calendar.current.startOfDay(for: Date())
        let noteStore = NoteStore(storageDirectory: root)
        noteStore.setNote("原有今日灵感", for: date)
        noteStore.flushSave()
        let service = DailyQuestionService(provider: FixedQuestionProvider(), userDefaults: defaults)

        let saved = service.saveAnswer("我想让桌面端记录更自然。", for: date)
        noteStore.appendDailyInspiration(question: saved, answer: "我想让桌面端记录更自然。", for: date)
        noteStore.flushSave()

        let note = noteStore.note(for: date)
        assert(service.answeredQuestions().count == 1, "expected persisted daily question")
        assert(note.contains("原有今日灵感"), "expected existing note to remain")
        assert(note.contains("【今日启发】"), "expected daily inspiration section")
        assert(note.contains("我想让桌面端记录更自然。"), "expected answer appended")
    }
}

private struct FixedQuestionProvider: DailyQuestionProvider {
    func getQuestion(for date: Date) -> DailyQuestion {
        DailyQuestion(
            date: Calendar.current.startOfDay(for: date),
            question: "如果重新设计一个 App，你最想改变什么？",
            category: .product,
            keywords: ["产品设计", "体验优化"]
        )
    }
}
