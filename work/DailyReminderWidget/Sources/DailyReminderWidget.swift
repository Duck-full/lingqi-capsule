import SwiftUI
import AppKit
import UserNotifications
import UniformTypeIdentifiers

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
    @Published var items: [ReminderItem] = [] {
        didSet {
            save()
            NotificationScheduler.shared.reschedule(items: items)
        }
    }

    private let fileURL: URL

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folder = support.appendingPathComponent("DailyReminderWidget", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        fileURL = folder.appendingPathComponent("reminders.json")
        load()
    }

    func add(_ item: ReminderItem) {
        items.append(item)
        sort()
    }

    func update(_ item: ReminderItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index] = item
        sort()
    }

    func delete(_ item: ReminderItem) {
        items.removeAll { $0.id == item.id }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: NotificationScheduler.identifiers(for: item))
    }

    func toggleDone(_ item: ReminderItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].isDone.toggle()
    }

    func items(on day: Date) -> [ReminderItem] {
        items.filter { Calendar.current.isDate($0.date, inSameDayAs: day) }
            .sorted { $0.remindAt < $1.remindAt }
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
            items = try decoder.decode([ReminderItem].self, from: data)
            sort()
        } catch {
            items = []
        }
    }

    private func save() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(items)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            NSSound.beep()
        }
    }
}

enum DateKey {
    static func string(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static func display(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.dateFormat = "yyyy年M月d日 EEEE"
        return formatter.string(from: date)
    }
}

final class NoteStore: ObservableObject {
    @Published private var notesByDate: [String: String] = [:] {
        didSet { save() }
    }

    private let fileURL: URL

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folder = support.appendingPathComponent("DailyReminderWidget", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        fileURL = folder.appendingPathComponent("daily-notes.json")
        load()
    }

    func note(for date: Date) -> String {
        notesByDate[DateKey.string(from: date)] ?? ""
    }

    func setNote(_ note: String, for date: Date) {
        let key = DateKey.string(from: date)
        if note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            notesByDate.removeValue(forKey: key)
        } else {
            notesByDate[key] = note
        }
    }

    func hasNote(on date: Date) -> Bool {
        !note(for: date).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        notesByDate = (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(notesByDate) else { return }
        try? data.write(to: fileURL, options: [.atomic])
    }
}

enum NoteExporter {
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

    private static func saveURL(extensionName: String, date: Date) -> URL? {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "每日记事-\(DateKey.string(from: date)).\(extensionName)"
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
          <h1>每日记事</h1>
          <div class="date">\(escape(DateKey.display(from: date)))</div>
          <div class="note">\(escape(note))</div>
        </body>
        </html>
        """
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

        ("每日记事" as NSString).draw(at: NSPoint(x: margin, y: bounds.height - 80), withAttributes: titleAttrs)
        (dateTitle as NSString).draw(at: NSPoint(x: margin, y: bounds.height - 108), withAttributes: dateAttrs)
        let bodyRect = NSRect(x: margin, y: margin, width: pageWidth - margin * 2, height: bounds.height - 180)
        (note.isEmpty ? "这一天还没有记录。" : note as NSString).draw(in: bodyRect, withAttributes: bodyAttrs)
    }
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

            let city = location.city ?? "当前城市"
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

    func schedule(item: ReminderItem) {
        let content = UNMutableNotificationContent()
        content.title = "小Ding助手"
        content.body = item.notes.isEmpty ? "该处理今天的事项了。" : item.notes
        content.subtitle = item.title
        content.sound = .default
        content.categoryIdentifier = "REMINDER_ITEM"
        content.userInfo = ["itemID": item.id.uuidString]

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
        content.title = "小Ding助手"
        content.subtitle = "系统通知测试"
        content.body = "如果你看到这条通知，说明 macOS 系统提醒已经可以正常工作。"
        content.sound = .default
        content.categoryIdentifier = "REMINDER_ITEM"
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 3, repeats: false)
        add(content: content, trigger: trigger, id: "system-notification-test-\(UUID().uuidString)")
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

@main
struct DailyReminderWidgetApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var store = ReminderStore()
    @StateObject private var noteStore = NoteStore()
    @StateObject private var iconManager = AppIconManager()
    @StateObject private var weatherStore = WeatherStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environmentObject(noteStore)
                .environmentObject(iconManager)
                .environmentObject(weatherStore)
                .frame(minWidth: 900, minHeight: 560)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationScheduler.shared.configure()
        NSApp.setActivationPolicy(.regular)
        for window in NSApplication.shared.windows {
            window.title = "小Ding助手"
            window.isMovableByWindowBackground = true
            window.minSize = NSSize(width: 900, height: 560)
            if window.frame.width < 1100 || window.frame.height < 720 {
                window.setFrame(NSRect(x: window.frame.origin.x, y: window.frame.origin.y, width: 1180, height: 760), display: true)
                window.center()
            }
        }
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

enum AppTheme: String, CaseIterable, Identifiable {
    case neonPulse
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
        case .futureTech: return .future
        case .cartoonPop: return .cartoon
        case .ancientInk: return .heritage
        default: return .neon
        }
    }

    func symbol(_ role: ThemeSymbolRole) -> String {
        switch (self, role) {
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
    static let defaultValue: AppTheme = .ancientInk
}

extension EnvironmentValues {
    var appTheme: AppTheme {
        get { self[AppThemeKey.self] }
        set { self[AppThemeKey.self] = newValue }
    }
}

struct GlassPanel: ViewModifier {
    @Environment(\.appTheme) private var theme
    var radius: CGFloat = 20
    var isActive: Bool = false

    func body(content: Content) -> some View {
        content
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(theme.palette.card)
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.white.opacity(0.12), Color.white.opacity(0.035)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(isActive ? theme.palette.cyan.opacity(0.78) : theme.palette.line, lineWidth: isActive ? 1.4 : 1)
            )
            .shadow(color: isActive ? theme.palette.cyan.opacity(0.22) : Color.black.opacity(0.24), radius: isActive ? 20 : 14, x: 0, y: 9)
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

struct HoverLiftModifier: ViewModifier {
    let enabled: Bool
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(enabled && hovering ? 1.018 : 1)
            .offset(y: enabled && hovering ? -2 : 0)
            .shadow(color: enabled && hovering ? Color.white.opacity(0.10) : .clear, radius: 16, x: 0, y: 8)
            .animation(.spring(response: 0.24, dampingFraction: 0.82), value: hovering)
            .onHover { inside in
                hovering = inside
            }
    }
}

struct AnimatedGlowBackground: View {
    let theme: AppTheme
    @State private var animate = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [theme.palette.ink, theme.palette.plum, theme.palette.surface],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Circle()
                .fill(theme.palette.glowA.opacity(0.24))
                .frame(width: 520, height: 520)
                .blur(radius: 70)
                .offset(x: animate ? 360 : 280, y: animate ? -250 : -170)
            Circle()
                .fill(theme.palette.glowB.opacity(0.23))
                .frame(width: 620, height: 620)
                .blur(radius: 86)
                .offset(x: animate ? -360 : -260, y: animate ? 330 : 250)
            LinearGradient(
                colors: [theme.palette.warm.opacity(0.12), .clear, theme.palette.accent2.opacity(0.12)],
                startPoint: animate ? .bottomTrailing : .bottomLeading,
                endPoint: .topTrailing
            )
            themeDecoration
        }
        .ignoresSafeArea()
        .onAppear {
            withAnimation(.easeInOut(duration: 5.5).repeatForever(autoreverses: true)) {
                animate.toggle()
            }
        }
    }

    @ViewBuilder
    private var themeDecoration: some View {
        switch theme.backgroundStyle {
        case .future:
            VStack(spacing: 26) {
                ForEach(0..<16, id: \.self) { _ in
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
                ForEach(0..<8, id: \.self) { index in
                    Circle()
                        .fill((index % 2 == 0 ? theme.palette.warm : theme.palette.accent2).opacity(0.13))
                        .frame(width: CGFloat(70 + index * 14), height: CGFloat(70 + index * 14))
                        .offset(x: CGFloat((index % 4) * 150 - 260), y: CGFloat((index / 2) * 110 - 220) + (animate ? 16 : -16))
                }
            }
        case .heritage:
            ZStack {
                RadialGradient(colors: [theme.palette.warm.opacity(0.16), .clear], center: .center, startRadius: 20, endRadius: 520)
                ForEach(0..<5, id: \.self) { index in
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

struct ContentView: View {
    @EnvironmentObject private var store: ReminderStore
    @EnvironmentObject private var iconManager: AppIconManager
    @AppStorage("selectedTheme") private var selectedThemeRaw = AppTheme.ancientInk.rawValue
    @State private var selectedDate = Date()
    @State private var showingEditor = false
    @State private var editingItem: ReminderItem?
    @State private var showingIconSettings = false

    var body: some View {
        GeometryReader { proxy in
            let theme = AppTheme(rawValue: selectedThemeRaw) ?? .ancientInk
            let compact = proxy.size.width < 1020
            let outerPadding: CGFloat = compact ? 10 : 20
            let innerPadding: CGFloat = compact ? 12 : 18
            let sidebarWidth: CGFloat = compact ? 286 : 330

            ZStack {
                AnimatedGlowBackground(theme: theme)
                HStack(spacing: 0) {
                    Sidebar(selectedDate: $selectedDate, showingEditor: $showingEditor, selectedThemeRaw: $selectedThemeRaw, compact: compact)
                        .frame(width: sidebarWidth)
                    Rectangle()
                        .fill(theme.palette.line)
                        .frame(width: 1)
                    DayDetail(selectedDate: $selectedDate, showingEditor: $showingEditor, editingItem: $editingItem, compact: compact)
                        .frame(minWidth: 0, maxWidth: .infinity)
                }
                .padding(innerPadding)
                .glassPanel(radius: 26)
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
            }
            .environment(\.appTheme, theme)
        }
        .preferredColorScheme(.dark)
        .animation(.easeInOut(duration: 0.28), value: selectedThemeRaw)
        .animation(.spring(response: 0.30, dampingFraction: 0.84), value: selectedDate)
        .onAppear {
            NotificationScheduler.shared.reschedule(items: store.items)
            iconManager.applySavedIcon()
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
                .environment(\.appTheme, AppTheme(rawValue: selectedThemeRaw) ?? .ancientInk)
        }
        .onChange(of: showingEditor) { isShowing in
            if !isShowing { editingItem = nil }
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
    @Binding var selectedThemeRaw: String
    let compact: Bool
    @State private var visibleMonth = Date()

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: compact ? 14 : 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("小Ding助手")
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

                Button {
                    showingEditor = true
                } label: {
                    Label("添加今日事项", systemImage: "plus.circle.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .noWrap()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, compact ? 10 : 12)
                }
                .buttonStyle(PrimaryButtonStyle())

                VStack(alignment: .leading, spacing: 12) {
                    Label("快捷概览", systemImage: "sparkles")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.palette.cyan)
                        .noWrap()
                    StatRow(title: "今天", value: "\(store.count(on: Date())) 项")
                    StatRow(title: "选中日期", value: "\(store.count(on: selectedDate)) 项")
                    StatRow(title: "记事", value: noteStore.hasNote(on: selectedDate) ? "已记录" : "空")
                    StatRow(title: "未完成", value: "\(store.items.filter { !$0.isDone }.count) 项")
                }
                .padding(16)
                .glassPanel(radius: 18)

                MoodNote(themeName: AppTheme(rawValue: selectedThemeRaw) ?? .ancientInk)

                ThemeSwitcher(selectedThemeRaw: $selectedThemeRaw, compact: compact)

                NotificationStatusCard(items: store.items, compact: compact)
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

struct CalendarPanel: View {
    @EnvironmentObject private var store: ReminderStore
    @EnvironmentObject private var noteStore: NoteStore
    @Environment(\.appTheme) private var theme
    @Binding var selectedDate: Date
    @Binding var visibleMonth: Date

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 7)
    private let weekdaySymbols = ["日", "一", "二", "三", "四", "五", "六"]

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Button {
                    moveMonth(-1)
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(IconButtonStyle())
                Spacer()
                Text(monthTitle)
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.palette.text)
                    .noWrap(scale: 0.8)
                Spacer()
                Button {
                    moveMonth(1)
                } label: {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(IconButtonStyle())
            }

            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(weekdaySymbols, id: \.self) { symbol in
                    Text(symbol)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(theme.palette.muted)
                        .frame(height: 22)
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
                CalendarLegendDot(color: theme.palette.warm, text: "记事")
                Spacer(minLength: 0)
            }
        }
        .padding(16)
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
        let startOffset = 1 - firstWeekday
        return (0..<42).compactMap { calendar.date(byAdding: .day, value: startOffset + $0, to: interval.start) }
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
        AppTheme(rawValue: selectedThemeRaw) ?? .ancientInk
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
            Image(systemName: theme.symbol(.mood))
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(theme.palette.warm)
                .frame(width: 30, height: 30)
                .background(theme.palette.warm.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 5) {
                Text("今日小能量")
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

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "app.badge")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(theme.palette.accent)
                    .frame(width: 44, height: 44)
                    .background(theme.palette.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                VStack(alignment: .leading, spacing: 5) {
                    Text("启动图标设置")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.palette.text)
                        .noWrap(scale: 0.72)
                    Text("可自定义运行时 Dock 图标，建议使用高清透明 PNG。")
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

            CustomIconCard(compact: false)

            HStack {
                Spacer()
                Button("完成") {
                    dismiss()
                }
                .buttonStyle(PrimaryButtonStyle())
                .frame(width: 120)
            }
        }
        .padding(28)
        .frame(width: 560)
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
                    VStack(spacing: 4) {
                        Text("\(Calendar.current.component(.day, from: day))")
                            .font(.system(size: 13, weight: isSelected ? .bold : .medium))
                            .noWrap(scale: 0.8)
                        HStack(spacing: 3) {
                            Circle()
                                .fill(count > 0 ? theme.palette.cyan : .clear)
                                .frame(width: 5, height: 5)
                            Circle()
                                .fill(hasNote ? theme.palette.warm : .clear)
                                .frame(width: 5, height: 5)
                        }
                        .frame(height: 5)
                    }
                    .foregroundStyle(theme.palette.text)
                    .frame(height: 38)
                    .frame(maxWidth: .infinity)
                    .background(
                        isSelected ?
                        LinearGradient(colors: [theme.palette.blue.opacity(0.44), theme.palette.lavender.opacity(0.26)], startPoint: .topLeading, endPoint: .bottomTrailing) :
                            LinearGradient(colors: [.clear], startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(isSelected ? theme.palette.cyan.opacity(0.9) : (isToday ? theme.palette.cyan.opacity(0.55) : .clear), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .hoverLift()
            } else {
                Color.clear
                    .frame(height: 38)
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
                    .foregroundStyle(theme.palette.muted)
                    .noWrap()
                Text(primaryText)
                    .font(.system(size: compact ? 19 : 23, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.palette.text)
                    .noWrap(scale: 0.7)
            }
            .layoutPriority(1)

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 5) {
                Text(secondaryText)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.palette.cyan)
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
            VStack(alignment: .leading, spacing: compact ? 14 : 18) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(dayTitle)
                            .font(.system(size: compact ? 28 : 34, weight: .bold, design: .rounded))
                            .foregroundStyle(theme.palette.text)
                            .noWrap(scale: 0.72)
                        Text("事项提醒与当天记事都会保存在本机。")
                            .font(.system(size: 13))
                            .foregroundStyle(theme.palette.muted)
                            .noWrap(scale: 0.7)
                    }
                    .layoutPriority(1)
                    Spacer()
                    Button {
                        selectedDate = Date()
                    } label: {
                        Label("今天", systemImage: "calendar")
                            .noWrap()
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .frame(width: compact ? 86 : 100)
                    Button {
                        showingEditor = true
                    } label: {
                        Label("新事项", systemImage: "plus")
                            .noWrap()
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .frame(width: compact ? 94 : 112)
                }
                .padding(.top, compact ? 16 : 24)

                WeatherCard(compact: compact)

                StatusGrid(items: store.items(on: selectedDate), compact: compact)

                NotebookPanel(selectedDate: selectedDate, compact: compact)

                let items = store.items(on: selectedDate)
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Label("提醒事项", systemImage: theme.symbol(.task))
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .foregroundStyle(theme.palette.text)
                            .noWrap()
                        Spacer()
                        Text("\(items.count) 项")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(theme.palette.muted)
                    }
                    if items.isEmpty {
                        EmptyState(showingEditor: $showingEditor)
                            .frame(maxWidth: .infinity, minHeight: compact ? 180 : 220)
                    } else {
                        ForEach(items) { item in
                            ReminderCard(item: item, onToggle: {
                                if !item.isDone {
                                    showToast(for: item)
                                }
                                store.toggleDone(item)
                            }, onEdit: {
                                editingItem = item
                                showingEditor = true
                            }, onDelete: {
                                store.delete(item)
                            })
                        }
                    }
                }
                .padding(.bottom, 24)
            }
            .padding(.horizontal, compact ? 20 : 32)
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

    private func showToast(for item: ReminderItem) {
        let messages = [
            "完成了「\(item.title)」，今天又多了一点确定感。",
            "漂亮，刚刚那一下很关键。",
            "你已经把一件事从脑子里放下了。",
            "小小推进，也算数。"
        ]
        withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
            toastMessage = messages.randomElement()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
            withAnimation(.easeOut(duration: 0.22)) {
                toastMessage = nil
            }
        }
    }
}

struct NotebookPanel: View {
    @EnvironmentObject private var noteStore: NoteStore
    @Environment(\.appTheme) private var theme
    let selectedDate: Date
    let compact: Bool
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Label("当天记事本", systemImage: theme.symbol(.note))
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.palette.text)
                        .noWrap()
                    Text("像备忘录一样记录想法、会议要点、临时信息。")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.palette.muted)
                        .noWrap(scale: 0.72)
                }
                Spacer()
                Button {
                    NoteExporter.exportDocx(note: draft, date: selectedDate)
                } label: {
                    Label("Word", systemImage: "doc.richtext")
                        .font(.system(size: 12, weight: .bold))
                        .noWrap(scale: 0.72)
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .opacity(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.48 : 1)

                Button {
                    NoteExporter.exportPDF(note: draft, date: selectedDate)
                } label: {
                    Label("PDF", systemImage: "doc.fill")
                        .font(.system(size: 12, weight: .bold))
                        .noWrap(scale: 0.72)
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .opacity(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.48 : 1)
            }

            ZStack(alignment: .topLeading) {
                if draft.isEmpty {
                    Text("记录今天重要的信息...")
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
                        noteStore.setNote(value, for: selectedDate)
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
        }
        .onChange(of: selectedDate) { newDate in
            draft = noteStore.note(for: newDate)
        }
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
