import AppIntents
import SwiftUI
import WidgetKit

/// A play/pause button for Control Center, the Smart Stack and the Action button.
struct KitziPlayControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.bennybar.kitzi.watch.playpause") {
            ControlWidgetButton(action: TogglePlaybackIntent()) {
                Label("Kitzi", systemImage: "headphones")
            }
        }
        .displayName("Play or Pause Kitzi")
        .description("Plays or pauses your audiobook.")
    }
}
