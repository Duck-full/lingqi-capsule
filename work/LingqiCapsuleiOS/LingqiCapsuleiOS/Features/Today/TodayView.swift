import SwiftData
import SwiftUI

struct TodayView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \InspirationEntry.createdAt, order: .reverse) private var inspirations: [InspirationEntry]
    @Query(sort: \ActionItem.createdAt, order: .reverse) private var actions: [ActionItem]
    @State private var draft = ""
    @State private var toast: String?

    private var todayKey: String { DayKey.string(from: Date()) }
    private var todayInspirations: [InspirationEntry] { inspirations.filter { $0.dayKey == todayKey } }
    private var todayActions: [ActionItem] { actions.filter { $0.dayKey == todayKey } }
    private var todayText: String { todayInspirations.reversed().map(\.text).joined(separator: "\n") }
    private var keywords: [String] { InspirationAnalyzer.keywords(from: todayText + "\n" + draft) }

    var body: some View {
        ZStack {
            CapsuleBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    inspirationCard
                    actionCard
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 28)
            }
        }
        .navigationTitle("今日")
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .top) {
            if let toast {
                Text(toast)
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(Date.now.formatted(.dateTime.month(.wide).day().weekday(.wide)))
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundStyle(CapsuleDesign.text)
            Text("随手记录此刻，让今天慢慢形成一颗胶囊。")
                .font(.subheadline)
                .foregroundStyle(CapsuleDesign.secondaryText)
        }
        .padding(.top, 8)
    }

    private var inspirationCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Label("今日胶囊", systemImage: "sparkles")
                        .font(.title2.bold())
                        .foregroundStyle(CapsuleDesign.text)
                    Spacer()
                    Text("\(todayText.count) 字")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(CapsuleDesign.secondaryText)
                }

                ZStack(alignment: .topLeading) {
                    if draft.isEmpty {
                        Text("快速记录此刻的灵感…")
                            .foregroundStyle(CapsuleDesign.secondaryText)
                            .padding(.leading, 5)
                            .padding(.top, 8)
                    }
                    TextEditor(text: $draft)
                        .scrollContentBackground(.hidden)
                        .foregroundStyle(CapsuleDesign.text)
                        .frame(minHeight: 132)
                        .onChange(of: draft) { _, value in
                            if value.count > 2000 { draft = String(value.prefix(2000)) }
                        }
                }
                .padding(10)
                .background(Color.black.opacity(0.16), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(draft.isEmpty ? CapsuleDesign.line : CapsuleDesign.accent.opacity(0.7), lineWidth: 1)
                )

                if !keywords.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(keywords, id: \.self) { KeywordPill(text: $0) }
                        }
                    }
                }

                HStack {
                    Label(InspirationAnalyzer.mood(from: todayText + draft), systemImage: "heart.text.square")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(CapsuleDesign.secondaryText)
                    Spacer()
                    Button("保存灵感", action: saveInspiration)
                        .buttonStyle(.borderedProminent)
                        .tint(CapsuleDesign.accent)
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(20)
        }
    }

    private var actionCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("今日行动", systemImage: "checklist")
                        .font(.headline)
                        .foregroundStyle(CapsuleDesign.text)
                    Spacer()
                    Text("\(todayActions.filter(\.isCompleted).count)/\(todayActions.count)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(CapsuleDesign.secondaryText)
                }

                if todayActions.isEmpty {
                    Text("今天还没有事项。去“行动”添加第一件小事。")
                        .font(.subheadline)
                        .foregroundStyle(CapsuleDesign.secondaryText)
                        .padding(.vertical, 8)
                } else {
                    ForEach(todayActions.prefix(5)) { item in
                        HStack(spacing: 12) {
                            Button {
                                item.isCompleted.toggle()
                                item.updatedAt = Date()
                                try? modelContext.save()
                            } label: {
                                Image(systemName: item.isCompleted ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(item.isCompleted ? CapsuleDesign.mint : CapsuleDesign.secondaryText)
                            }
                            .buttonStyle(.plain)
                            Text(item.title)
                                .foregroundStyle(CapsuleDesign.text)
                                .strikethrough(item.isCompleted)
                            Spacer()
                        }
                    }
                }
            }
            .padding(20)
        }
    }

    private func saveInspiration() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        modelContext.insert(InspirationEntry(text: text))
        try? modelContext.save()
        draft = ""
        withAnimation { toast = "灵感已被小树苗吸收" }
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            await MainActor.run { withAnimation { toast = nil } }
        }
    }
}
