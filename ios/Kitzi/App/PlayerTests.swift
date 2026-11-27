#if DEBUG
import Foundation

/// A simulator run of the player's position rules (KITZI_TEST_OPEN=playertest):
/// prints "KITZITEST …" lines, and puts the book back where it was.
enum EffectsTests {
    /// Streams the book with voice boost and skip silence on, and reports whether
    /// the tap ran, whether silences were found, and how far playback got.
    static func run() async {
        let library = LibraryStore.shared, player = Player.shared
        for _ in 0..<40 where library.continueListening.isEmpty { try? await Task.sleep(for: .milliseconds(500)) }
        guard let b = library.continueListening.first else { print("KITZITEST effects skipped"); return }
        let original = (try? await library.syncProgressFor(b.id))?.currentTimeSec ?? 0
        if let why = await player.play(b) { print("KITZITEST effects play failed: \(why)"); return }
        let speed = player.speed
        player.setSpeed(1)
        try? await Task.sleep(for: .seconds(4))
        // Off: nothing tapped.
        print("KITZITEST effects off buffers=\(AudioEffects.shared.debugBuffers) local=\(player.nowPlaying?.isLocal ?? false)")
        player.setVoiceBoost(true)
        player.setSkipSilence(true)
        try? await Task.sleep(for: .seconds(2))
        player.refreshPosition()
        let p0 = player.position, t0 = Date(), b0 = AudioEffects.shared.debugBuffers
        try? await Task.sleep(for: .seconds(30))
        player.refreshPosition()
        let fx = AudioEffects.shared
        print("KITZITEST effects on buffers=\(fx.debugBuffers - b0) silences=\(fx.debugSilences) peakAfterBoost=\(String(format: "%.2f", fx.debugPeak)) advanced=\(String(format: "%.1f", player.position - p0))s in=\(String(format: "%.1f", Date().timeIntervalSince(t0)))s playing=\(player.isPlaying)")
        // Off again: the tap comes off and it plays on.
        player.setVoiceBoost(false)
        player.setSkipSilence(false)
        let b1 = fx.debugBuffers
        try? await Task.sleep(for: .seconds(4))
        player.refreshPosition()
        print("KITZITEST effects off again buffers=\(fx.debugBuffers - b1) position=\(Int(player.position)) playing=\(player.isPlaying)")
        player.setSpeed(speed)
        player.pause()
        player.seek(to: original, report: false)
        await player.report()
        await player.stop(keepLast: true)
        print("KITZITEST done")
    }
}

enum RadarTests {
    /// Posts one of the radar's finds as its notification (after asking permission).
    static func notify() async {
        let ok = await Notifier.authorize()
        print("KITZITEST notify authorized=\(ok)")
        await Radar.shared.checkReleases()
        guard let f = Radar.shared.sortedFinds.first else { print("KITZITEST notify no finds"); return }
        try? await Task.sleep(for: .seconds(2))
        await Notifier.releases([f], out: [])
        print("KITZITEST notify posted \(f.title)")
        // And as if it had been tapped.
        try? await Task.sleep(for: .seconds(6))
        NotificationRoute.shared.handle(["open": "audible", "asin": f.asin])
    }

    static func run() async {
        let library = LibraryStore.shared
        for _ in 0..<40 where library.books.isEmpty { try? await Task.sleep(for: .milliseconds(500)) }
        let t0 = Date()
        await Radar.shared.checkReleases()
        let finds = Radar.shared.sortedFinds
        print("KITZITEST radar took=\(String(format: "%.1f", Date().timeIntervalSince(t0)))s finds=\(finds.count) upcoming=\(finds.filter(\.isUpcoming).count)")
        for f in finds.prefix(12) { print("KITZITEST radar \(f.reason) | \(f.title) | \(f.releaseDate ?? "-") | inLibrary=\(library.byId.values.contains { $0.title == f.title })") }
        let t1 = Date()
        await Radar.shared.checkReleases()
        print("KITZITEST radar second run took=\(String(format: "%.1f", Date().timeIntervalSince(t1)))s finds=\(Radar.shared.finds.count)")
        print("KITZITEST done")
    }
}

enum PlayerTests {
    static func log(_ s: String) { print("KITZITEST \(s)") }

    private static func server(_ id: String) async -> Double {
        (try? await LibraryStore.shared.syncProgressFor(id))?.currentTimeSec ?? -1
    }

    static func run() async {
        let library = LibraryStore.shared, player = Player.shared
        for _ in 0..<40 where library.continueListening.isEmpty { try? await Task.sleep(for: .milliseconds(500)) }
        guard let b = library.continueListening.first else { log("playertest skipped: nothing in progress"); return }
        let original = await server(b.id)
        let rewind = AppSettings.shared.smartRewind
        AppSettings.shared.smartRewind = false
        defer { AppSettings.shared.smartRewind = rewind }
        if let why = await player.play(b) { log("playertest play failed: \(why)"); return }
        try? await Task.sleep(for: .seconds(5))
        log("playertest started at=\(Int(player.position)) server=\(Int(original)) total=\(Int(player.nowPlaying?.totalSec ?? 0))")

        // 1. Pause, skip back while paused, play: the skip stays (it used to be
        //    undone as "listened elsewhere").
        player.pause()
        try? await Task.sleep(for: .seconds(4))
        let paused = player.position
        player.skip(-30)
        player.resume()
        try? await Task.sleep(for: .seconds(5))
        player.refreshPosition()
        log("playertest pausedskip paused=\(Int(paused)) now=\(Int(player.position)) ok=\(abs(player.position - (paused - 30 + 5)) < 4)")

        // 2. Smart rewind after a long pause: the rewind stays.
        player.pause()
        try? await Task.sleep(for: .seconds(4))
        let p2 = player.position
        AppSettings.shared.smartRewind = true
        player.debugPausedLongAgo()
        player.resume()
        try? await Task.sleep(for: .seconds(5))
        player.refreshPosition()
        log("playertest smartrewind paused=\(Int(p2)) now=\(Int(player.position)) ok=\(abs(player.position - (p2 - 30 + 5)) < 4)")
        AppSettings.shared.smartRewind = false

        // 3. Really listened elsewhere during a pause: Play goes there.
        player.pause()
        try? await Task.sleep(for: .seconds(4))
        let p3 = player.position
        let elsewhere = p3 + 600
        _ = await API.shared.saveProgress(API.Report(itemId: b.id, currentSec: elsewhere, durationSec: player.nowPlaying?.totalSec,
                                                     finished: false, paused: true, listenedSec: nil))
        player.resume()
        try? await Task.sleep(for: .seconds(5))
        player.refreshPosition()
        log("playertest elsewhere paused=\(Int(p3)) server=\(Int(elsewhere)) now=\(Int(player.position)) ok=\(abs(player.position - (elsewhere + 5)) < 5)")

        // 4. A seek to the very end stops short of it (and doesn't finish the book).
        player.pause()
        try? await Task.sleep(for: .seconds(3))
        let total = player.nowPlaying?.totalSec ?? 0
        player.seek(to: total, report: false)
        log("playertest seekend position=\(Int(player.position)) total=\(Int(total)) ok=\(abs(player.position - (total - 10)) < 1 && library.progress[b.id]?.isFinished != true)")

        // Back where it was.
        player.seek(to: original, report: false)
        await player.report()
        await player.stop(keepLast: true)
        log("playertest restored server=\(Int(await server(b.id))) wanted=\(Int(original))")
        log("done")
    }
}
#endif
