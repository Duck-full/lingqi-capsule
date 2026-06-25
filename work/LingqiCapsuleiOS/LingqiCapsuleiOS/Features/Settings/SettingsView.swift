import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \MigrationReceipt.importedAt, order: .reverse) private var receipts: [MigrationReceipt]
    @State private var showingImporter = false
    @State private var importMessage: String?

    var body: some View {
        ZStack {
            CapsuleBackground()
            List {
                Section("同步") {
                    Label("私人 iCloud / CloudKit", systemImage: "icloud")
                    Text("无需注册账号，使用当前 Apple ID 在 iPhone 与 Mac 之间同步。")
                        .font(.footnote)
                        .foregroundStyle(CapsuleDesign.secondaryText)
                }

                Section("数据迁移") {
                    Button {
                        showingImporter = true
                    } label: {
                        Label("导入 Mac 一次性迁移包", systemImage: "square.and.arrow.down")
                    }
                    if let receipt = receipts.first {
                        Text("最近导入：\(receipt.inspirationCount) 条灵感，\(receipt.actionCount) 个事项")
                            .font(.footnote)
                            .foregroundStyle(CapsuleDesign.secondaryText)
                    }
                    if let importMessage {
                        Text(importMessage)
                            .font(.footnote)
                            .foregroundStyle(CapsuleDesign.mint)
                    }
                }

                Section("隐私") {
                    Label("灵感与事项默认保存到用户私人 CloudKit 数据库", systemImage: "hand.raised")
                    Label("应用不包含账号系统、广告或付费功能", systemImage: "checkmark.shield")
                }

                Section("关于") {
                    LabeledContent("版本", value: "0.1.0")
                    LabeledContent("支持系统", value: "iOS 26.0 及以上")
                }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("我的")
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            do {
                guard let url = try result.get().first else { return }
                let counts = try LegacyMigrationService.importPackage(from: url, into: modelContext)
                importMessage = "已导入 \(counts.0) 条灵感和 \(counts.1) 个事项"
            } catch {
                importMessage = "导入失败：\(error.localizedDescription)"
            }
        }
    }
}
