import CoreMotion
import Foundation
import Observation

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
        guard Player.shared.currentChapter() != nil else { return false }
        cancel()
        mode = .endOfChapter
        run()
        return true
    }

    func addMinutes(_ m: Int) {
        if case .duration(let ends) = mode {
            mode = .duration(endsAt: ends.addingTimeInterval(Double(m) * 60))
        }
    }

    func cancel() {
        task?.cancel(); task = nil
        mode = .off
        remainingSec = 0
        stopShake()
    }

    private func run() {
        let bookId = Player.shared.nowPlaying?.book.id
        // The chapter end is fixed when the timer starts (and re-fixed only after a
        // seek): re-reading the "current" chapter near its end could already see the
        // next one, and the timer would play through it.
        var targetEnd = Player.shared.currentChapter()?.endSec
        var seenSeeks = Player.shared.seekGeneration
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
                    if p.seekGeneration != seenSeeks {
                        seenSeeks = p.seekGeneration
                        targetEnd = p.currentChapter()?.endSec
                    }
                    guard let end = targetEnd else { cancel(); return }
                    remainingSec = max((end - p.position) / max(p.speed, 0.1), 0)
                    if end - p.position <= 0.6 {
                        p.pause(); cancel()
                        Toast.show("Paused at the end of the chapter", action: "Keep listening") { Player.shared.resume() }
                        return
                    }
                }
                try? await Task.sleep(for: .milliseconds(remainingSec < 5 ? 250 : 1000))
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
