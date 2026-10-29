import ActivityKit
import SwiftUI
import WidgetKit

@main
struct KitziActivityBundle: WidgetBundle {
    var body: some Widget {
        DownloadLiveActivity()
    }
}

/// Download progress in the Dynamic Island and on the Lock Screen.
struct DownloadLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DownloadActivityAttributes.self) { context in
            LockScreenView(state: context.state)
                .padding(16)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let s = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: s.done ? (s.failed ? "xmark.circle.fill" : "checkmark.circle.fill") : "arrow.down.circle.fill")
                        .font(.title2)
                        .foregroundStyle(s.failed ? Color.red : Color.accentColor)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(s.done ? (s.failed ? "Failed" : "Done") : "\(Int(s.fraction * 100))%")
                        .font(.title3.monospacedDigit().weight(.semibold))
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(s.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                        ProgressView(value: s.done ? 1 : s.fraction).tint(.accentColor)
                        if s.queued > 0 {
                            Text("\(s.queued) more queued").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } compactLeading: {
                Image(systemName: s.done ? (s.failed ? "xmark" : "checkmark") : "arrow.down")
                    .foregroundStyle(s.failed ? Color.red : Color.accentColor)
            } compactTrailing: {
                ProgressView(value: s.done ? 1 : s.fraction)
                    .progressViewStyle(.circular)
                    .tint(.accentColor)
                    .frame(width: 18, height: 18)
            } minimal: {
                ProgressView(value: s.done ? 1 : s.fraction)
                    .progressViewStyle(.circular)
                    .tint(.accentColor)
            }
            .keylineTint(.accentColor)
        }
    }
}

private struct LockScreenView: View {
    let state: DownloadActivityAttributes.ContentState
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: state.done ? (state.failed ? "xmark.circle.fill" : "checkmark.circle.fill") : "arrow.down.circle.fill")
                .font(.largeTitle)
                .foregroundStyle(state.failed ? Color.red : Color.accentColor)
            VStack(alignment: .leading, spacing: 6) {
                Text(state.done ? (state.failed ? "Downloads" : "Downloads finished") : "Downloading")
                    .font(.caption).foregroundStyle(.secondary)
                Text(state.title).font(.headline).lineLimit(1)
                ProgressView(value: state.done ? 1 : state.fraction).tint(.accentColor)
                if state.queued > 0 {
                    Text("\(state.queued) more queued").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }
}
