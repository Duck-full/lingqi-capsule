import SwiftData
import SwiftUI

struct CapsuleTimelineView: View {
    @Query(sort: \InspirationEntry.createdAt, order: .reverse) private var inspirations: [InspirationEntry]
    @Query(sort: \ActionItem.createdAt, order: .reverse) private var actions: [ActionItem]

    private var snapshots: [CapsuleSnapshot] {
        let keys = Set(inspirations.map(\.dayKey) + actions.map(\.dayKey))
        return keys.sorted(by: >).map { key in
            CapsuleSnapshot(
                dayKey: key,
                inspirations: inspirations.filter { $0.dayKey == key },
                actions: actions.filter { $0.dayKey == key }
            )
        }
    }

    var body: some View {
        ZStack {
            CapsuleBackground()
            if snapshots.isEmpty {
                ContentUnavailableView(
                    "还没有历史胶囊",
                    systemImage: "archivebox",
                    description: Text("记录一条灵感或完成一件事项后，这里会形成时间轴。")
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 16) {
                        ForEach(snapshots) { snapshot in
                            NavigationLink {
                                CapsuleDetailView(snapshot: snapshot)
                            } label: {
                                CapsuleTimelineCard(snapshot: snapshot)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(20)
                }
            }
        }
        .navigationTitle("历史胶囊")
    }
}

private struct CapsuleTimelineCard: View {
    let snapshot: CapsuleSnapshot

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(snapshot.date.formatted(.dateTime.year().month().day()))
                        .font(.headline)
                    Spacer()
                    Text(snapshot.mood)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(CapsuleDesign.mint)
                }
                Text(snapshot.fullText.isEmpty ? "这一天主要留下了行动记录。" : snapshot.fullText)
                    .font(.subheadline)
                    .foregroundStyle(CapsuleDesign.secondaryText)
                    .lineLimit(2)
                HStack {
                    ForEach(snapshot.keywords.prefix(3), id: \.self) { KeywordPill(text: $0) }
                    Spacer()
                    Text("\(snapshot.completedCount)/\(snapshot.actions.count) 完成")
                        .font(.caption)
                        .foregroundStyle(CapsuleDesign.secondaryText)
                }
            }
            .foregroundStyle(CapsuleDesign.text)
            .padding(18)
        }
    }
}

private struct CapsuleDetailView: View {
    let snapshot: CapsuleSnapshot

    var body: some View {
        ZStack {
            CapsuleBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(snapshot.fullText.isEmpty ? "这一天没有灵感正文。" : snapshot.fullText)
                        .foregroundStyle(CapsuleDesign.text)
                    Divider().overlay(CapsuleDesign.line)
                    ForEach(snapshot.actions) { item in
                        Label(item.title, systemImage: item.isCompleted ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(CapsuleDesign.text)
                    }
                }
                .padding(22)
            }
        }
        .navigationTitle(snapshot.date.formatted(.dateTime.month().day()))
        .navigationBarTitleDisplayMode(.inline)
    }
}
