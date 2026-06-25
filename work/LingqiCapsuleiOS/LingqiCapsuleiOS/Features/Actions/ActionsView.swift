import SwiftData
import SwiftUI

struct ActionsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ActionItem.createdAt, order: .reverse) private var actions: [ActionItem]
    @State private var showingEditor = false
    @State private var editingItem: ActionItem?

    var body: some View {
        ZStack {
            CapsuleBackground()
            if actions.isEmpty {
                ContentUnavailableView(
                    "还没有行动",
                    systemImage: "checklist",
                    description: Text("添加一件小事，并让系统在合适的时间提醒你。")
                )
            } else {
                List {
                    ForEach(actions) { item in
                        ActionRow(item: item) {
                            editingItem = item
                            showingEditor = true
                        } onDelete: {
                            NotificationService.shared.remove(for: item)
                            modelContext.delete(item)
                            try? modelContext.save()
                        }
                    }
                    .listRowBackground(CapsuleDesign.card)
                }
                .scrollContentBackground(.hidden)
            }
        }
        .navigationTitle("今日行动")
        .toolbar {
            Button {
                editingItem = nil
                showingEditor = true
            } label: {
                Image(systemName: "plus")
            }
        }
        .sheet(isPresented: $showingEditor) {
            ActionEditor(item: editingItem)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }
}

private struct ActionRow: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var item: ActionItem
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button {
                item.isCompleted.toggle()
                item.updatedAt = Date()
                try? modelContext.save()
            } label: {
                Image(systemName: item.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(item.isCompleted ? CapsuleDesign.mint : CapsuleDesign.secondaryText)
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .foregroundStyle(CapsuleDesign.text)
                    .strikethrough(item.isCompleted)
                Text(item.dayKey)
                    .font(.caption)
                    .foregroundStyle(CapsuleDesign.secondaryText)
            }
            Spacer()
            Menu {
                Button("编辑", systemImage: "pencil", action: onEdit)
                Button("删除", systemImage: "trash", role: .destructive, action: onDelete)
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(CapsuleDesign.secondaryText)
            }
        }
        .padding(.vertical, 8)
    }
}

private struct ActionEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    let item: ActionItem?
    @State private var title = ""
    @State private var notes = ""
    @State private var date = Date()
    @State private var reminderEnabled = false
    @State private var reminderDate = Date()
    @State private var frequency = ReminderFrequency.once

    var body: some View {
        NavigationStack {
            Form {
                Section("事项") {
                    TextField("例如：整理今天的想法", text: $title)
                    TextField("备注，可选", text: $notes, axis: .vertical)
                        .lineLimit(3...6)
                    DatePicker("日期", selection: $date, displayedComponents: .date)
                }
                Section("提醒") {
                    Toggle("系统通知", isOn: $reminderEnabled)
                    if reminderEnabled {
                        DatePicker("提醒时间", selection: $reminderDate)
                        Picker("频率", selection: $frequency) {
                            ForEach(ReminderFrequency.allCases) { Text($0.title).tag($0) }
                        }
                    }
                }
            }
            .navigationTitle(item == nil ? "添加事项" : "编辑事项")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", action: save)
                        .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                guard let item else { return }
                title = item.title
                notes = item.notes
                date = DayKey.date(from: item.dayKey) ?? Date()
                reminderEnabled = item.reminderDate != nil
                reminderDate = item.reminderDate ?? Date()
                frequency = item.frequency
            }
        }
    }

    private func save() {
        let record = item ?? ActionItem(title: title, date: date)
        record.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        record.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        record.dayKey = DayKey.string(from: date)
        record.reminderDate = reminderEnabled ? reminderDate : nil
        record.frequency = frequency
        record.updatedAt = Date()
        if item == nil { modelContext.insert(record) }
        try? modelContext.save()
        Task {
            if reminderEnabled {
                _ = await NotificationService.shared.requestAuthorization()
                await NotificationService.shared.schedule(for: record)
            } else {
                NotificationService.shared.remove(for: record)
            }
        }
        dismiss()
    }
}
