import SwiftUI
import WidgetKit

@main
struct KitziWatchWidgets: WidgetBundle {
    var body: some Widget { NowListeningWidget() }
}

struct NowListeningEntry: TimelineEntry {
    var date: Date
    var book: WidgetBook?
}

/// The watch app reloads the widget when the book or its progress changes.
struct NowListeningProvider: TimelineProvider {
    func placeholder(in context: Context) -> NowListeningEntry {
        NowListeningEntry(date: .now, book: WidgetBook(title: "Audiobook", author: "Author", progress: 0.4, remainingSec: 7200, isPlaying: false))
    }

    func getSnapshot(in context: Context, completion: @escaping (NowListeningEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : NowListeningEntry(date: .now, book: WidgetBook.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NowListeningEntry>) -> Void) {
        completion(Timeline(entries: [NowListeningEntry(date: .now, book: WidgetBook.load())], policy: .never))
    }
}

/// The book you're listening to: a progress ring, or the title with the time left.
struct NowListeningWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "NowListening", provider: NowListeningProvider()) { entry in
            NowListeningView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Kitzi")
        .description("The audiobook you're listening to.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline, .accessoryCorner])
    }
}

struct NowListeningView: View {
    let entry: NowListeningEntry
    @Environment(\.widgetFamily) private var family

    private static func hm(_ sec: Double) -> String {
        let s = max(0, Int(sec)), h = s / 3600, m = (s % 3600) / 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }

    var body: some View {
        let b = entry.book
        let progress = min(max(b?.progress ?? 0, 0), 1)
        switch family {
        case .accessoryCircular:
            Gauge(value: progress) {
                Image(systemName: "headphones")
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .widgetAccentable()
        case .accessoryCorner:
            Image(systemName: "headphones").font(.title3).widgetAccentable()
                .widgetLabel { Gauge(value: progress) { Text("Kitzi") } }
        case .accessoryInline:
            if let b { Text("\(b.title) · \(Self.hm(b.remainingSec)) left") } else { Text("Kitzi") }
        default:
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: b?.isPlaying == true ? "waveform" : "headphones").widgetAccentable()
                    Text(b?.title ?? "Kitzi").font(.headline).lineLimit(1)
                }
                if let b {
                    Text("\(Self.hm(b.remainingSec)) left").font(.caption).foregroundStyle(.secondary)
                    Gauge(value: progress) { EmptyView() }.gaugeStyle(.accessoryLinearCapacity).widgetAccentable()
                } else {
                    Text("Nothing in progress").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
