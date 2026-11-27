import CoreMotion
import Foundation
import Observation
import UIKit

/// Sleep timer: a duration, or the end of the current chapter. In the last minute
/// of a duration timer a shake adds five minutes (easier than finding the screen
/// half asleep).
@Observable
final class SleepTimer {
    static let shared = SleepTimer()

    enum Mode: Equatable { case off, duration(endsAt: Date), endOfChapter }
    private(set) var mode: Mode = .off
    /// Seconds left (duration) or left in the chapter (end of chapter).
    private(set) var remainingSec: Double = 0

    private var task: Task<Void, Never>?
    /// The chapter end being waited for (fixed at the start, re-fixed after a seek).
    @ObservationIgnored private var chapterEnd: Double?
    @ObservationIgnored private var seenSeeks = 0
    private let motion = CMMotionManager()
    private var shaking = false

    func start(minutes: Int) {
        cancel()
        let ends = Date().addingTimeInterval(Double(minutes) * 60)
        mode = .duration(endsAt: ends)
        run()
    }

    /// False when the book has no chapters.
    @discardableResult
    func startEndOfChapter() -> Bool {
        guard let end = Player.shared.currentChapter()?.endSec else { return false }
        cancel()
        mode = .endOfChapter
        chapterEnd = end
        seenSeeks = Player.shared.seekGeneration
        run()
        return true
    }

    func addMinutes(_ m: Int) {
        if case .duration(let ends) = mode {
            mode = .duration(endsAt: ends.addingTimeInterval(Double(m) * 60))
            // Back on in the last minute again.
            stopShake()
        }
    }

    /// Back in the foreground: counts on screen again at once.
    func wake() {
        guard mode != .off else { return }
        task?.cancel()
        run()
    }

    func cancel() {
        task?.cancel(); task = nil
        mode = .off
        chapterEnd = nil
        remainingSec = 0
        stopShake()
    }

    private func run() {
        let bookId = Player.shared.nowPlaying?.book.id
        // The chapter end is fixed when the timer starts (and re-fixed only after a
        // seek): re-reading the "current" chapter near its end could already see the
        // next one, and the timer would play through it.
        task = Task {
            while !Task.isCancelled {
                let p = Player.shared
                if p.nowPlaying?.book.id != bookId { cancel(); return }
                switch mode {
                case .off: return
                case .duration(let ends):
                    remainingSec = max(ends.timeIntervalSinceNow, 0)
                    if remainingSec <= 0 {
                        p.pause(); cancel()
                        Toast.show("Sleep timer paused playback", action: "+5 min") {
                            Player.shared.resume(); SleepTimer.shared.start(minutes: 5)
                        }
                        return
                    }
                    if remainingSec <= 60 && AppSettings.shared.shakeExtendsSleep { startShake() }
                case .endOfChapter:
                    p.refreshPosition()
                    if p.seekGeneration != seenSeeks {
                        seenSeeks = p.seekGeneration
                        chapterEnd = p.currentChapter()?.endSec
                    }
                    guard let end = chapterEnd else { cancel(); return }
                    remainingSec = max((end - p.position) / max(p.speed, 0.1), 0)
                    if end - p.position <= 0.6 {
                        p.pause(); cancel()
                        Toast.show("Paused at the end of the chapter", action: "Keep listening") { Player.shared.resume() }
                        return
                    }
                }
                // On screen: a second at a time (the countdown). In the background
                // nothing shows it: sleep to a minute before the end (the shake
                // window), or a few seconds before the chapter ends (positions run
                // at the playing speed; Skip Silence can run faster, and a lock-screen
                // skip can move it, so at most two minutes at a time), then count closely.
                var wait = remainingSec < 5 ? 0.25 : 1
                if UIApplication.shared.applicationState != .active, remainingSec > 70 {
                    if case .duration = mode { wait = remainingSec - 60 }
                    else { wait = min(remainingSec * (p.skipSilence ? 0.3 : 1) - 3, 120) }
                }
                try? await Task.sleep(for: .seconds(wait))
            }
        }
    }

    private func startShake() {
        guard !shaking, motion.isAccelerometerAvailable else { return }
        shaking = true
        motion.accelerometerUpdateInterval = 0.1
        var lastShake = Date.distantPast
        var lastJolt = Date.distantPast
        motion.startAccelerometerUpdates(to: .main) { data, _ in
            guard let a = data?.acceleration else { return }
            let g = sqrt(a.x * a.x + a.y * a.y + a.z * a.z)
            MainActor.assumeIsolated {
                guard g > 2.2 else { return }
                let now = Date()
                // Two strong jolts within half a second is a shake (one is a bump).
                if now.timeIntervalSince(lastJolt) < 0.5, now.timeIntervalSince(lastShake) > 1.5 {
                    lastShake = now
                    SleepTimer.shared.addMinutes(5)
                    Toast.show("Sleep timer +5 min")
                }
                lastJolt = now
            }
        }
    }

    private func stopShake() {
        guard shaking else { return }
        motion.stopAccelerometerUpdates()
        shaking = false
    }
}
