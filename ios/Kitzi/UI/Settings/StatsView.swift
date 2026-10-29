import Charts
import SwiftUI

/// Listening stats: the server's per-day listening (last 14 days), streaks, and
/// top books / authors / narrators from the local play history.
struct StatsView: View {
    @Environment(LibraryStore.self) private var library
    @State private var top = PlayHistory.shared.top()
    @State private var loading = false

    private struct Day: Identifiable {
        var date: Date
        var minutes: Double
        var id: Date { date }
    }

    private var lastDays: [Day] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        return (0..<14).reversed().compactMap { back in
            guard let d = cal.date(byAdding: .day, value: -back, to: today) else { return nil }
            return Day(date: d, minutes: (library.perDaySec[LibraryStore.dayKey(d)] ?? 0) / 60)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                    GridRow {
                        tile("Today", Format.hm(library.todaySec), "clock")
                        tile("This week", Format.hm(library.weekSec), "calendar")
                    }
                    GridRow {
                        tile("Streak", "\(library.streakDays) day\(library.streakDays == 1 ? "" : "s")", "flame.fill", tint: .orange)
                        tile("Best streak", "\(library.bestStreak) days", "trophy.fill", tint: .yellow)
                    }
                    GridRow {
                        tile("All time", Format.hm(library.totalListenedSec), "headphones")
                        tile("Days listened", "\(library.perDaySec.values.filter { $0 > 0 }.count)", "checkmark.circle")
                    }
                    GridRow {
                        tile("Books finished", "\(library.finishedCount)", "book.closed.fill", tint: .green)
                        tile("In progress", "\(library.continueListening.count)", "play.fill")
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Last 14 days").font(.headline)
                    Chart(lastDays) { d in
                        BarMark(x: .value("Day", d.date, unit: .day), y: .value("Minutes", d.minutes))
                            .foregroundStyle(Color.accentColor.gradient)
                            .cornerRadius(4)
                    }
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .day, count: 2)) { _ in
                            AxisValueLabel(format: .dateTime.weekday(.narrow))
                        }
                    }
                    .chartYAxisLabel("min")
                    .frame(height: 180)
                }
                .padding(16)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))

                topSection("Top Books", top.books, icon: "book.closed")
                topSection("Top Authors", top.authors, icon: "person")
                topSection("Top Narrators", top.narrators, icon: "mic")

                if top.books.isEmpty {
                    Text("Top books, authors and narrators come from listening on this device (Settings → Detailed listening history).")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .padding(16)
        }
        .kitziBackground()
        .navigationTitle("Listening Stats")
        .overlay { if loading && library.perDaySec.isEmpty { ProgressView() } }
        .refreshable { await reload() }
        .task { await reload() }
    }

    private func reload() async {
        loading = true
        await library.loadListeningStats()
        top = PlayHistory.shared.top()
        loading = false
    }

    private func tile(_ title: String, _ value: String, _ icon: String, tint: Color = .accentColor) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Image(systemName: icon).foregroundStyle(tint)
                Text(value).font(.title3.weight(.bold)).lineLimit(1).minimumScaleFactor(0.7)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    @ViewBuilder
    private func topSection(_ title: String, _ list: [PlayHistory.Top], icon: String) -> some View {
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.headline)
                ForEach(Array(list.prefix(5).enumerated()), id: \.offset) { i, t in
                    HStack(spacing: 12) {
                        if let b = t.book {
                            CoverImage(book: b)
                                .frame(width: 40, height: 40)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        } else {
                            Image(systemName: icon)
                                .frame(width: 40, height: 40)
                                .foregroundStyle(Color.accentColor)
                        }
                        Text("\(i + 1). \(t.name)").lineLimit(1)
                        Spacer()
                        Text(Format.hm(t.sec)).foregroundStyle(.secondary).font(.subheadline)
                    }
                }
            }
            .padding(16)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
    }
}
