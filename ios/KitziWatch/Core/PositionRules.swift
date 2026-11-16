import Foundation

/// The watch's decisions about where a book is, as plain functions (no player,
/// no network), so they can be tested on their own (KitziWatchTests).
/// Times ("at") are all in the server's clock, in ms.
nonisolated enum PositionRules {
    struct Saved: Equatable {
        var sec: Double
        var at: Int64
    }

    /// Where to start: the newest of the watch's saved position and the
    /// server's. When the server didn't answer, the shelf's position (saved
    /// at `fallbackAt`) counts instead, so an old watch position can't beat a
    /// newer one from another device. Nothing known: `fallback`.
    static func start(local: Saved?, server: Saved?, fallback: Double, fallbackAt: Int64) -> Double {
        var found: [Saved] = []
        if let local { found.append(local) }
        if let server {
            found.append(server)
        } else if fallbackAt > 0 {
            found.append(Saved(sec: fallback, at: fallbackAt))
        }
        return found.max { $0.at < $1.at }?.sec ?? fallback
    }

    /// A finished book (within its last 5 s) starts again from the top.
    static func startOrTop(_ start: Double, total: Double) -> Double {
        start >= total - 5 ? 0 : start
    }

    /// On Play after a pause: move to the newer position only when it's really
    /// elsewhere (over 3 s away) and not the very end.
    static func shouldJump(to target: Double, from here: Double, total: Double) -> Bool {
        abs(target - here) > 3 && target < total - 5
    }

    /// Sending a position saved offline: the server keeps its own when it's newer.
    static func serverKeeps(serverAt: Int64, localAt: Int64) -> Bool {
        serverAt > localAt
    }

    /// A book position as (track, seconds into it), from the tracks' lengths.
    static func locate(_ sec: Double, durations: [Double]) -> (Int, Double) {
        var remaining = sec
        for (i, d) in durations.enumerated() {
            if remaining < d || i == durations.count - 1 { return (i, max(remaining, 0)) }
            remaining -= d
        }
        return (0, 0)
    }

    /// How long a stuck stream waits before it's rebuilt, by the attempt (0 =
    /// first); nil: give up and pause.
    static func stallLimit(attempt: Int) -> Double? {
        let limits: [Double] = [15, 30, 60]
        return attempt < limits.count ? limits[attempt] : nil
    }

    /// A chapter's share of the screen: (elapsed in it, left in it, fraction).
    static func chapterProgress(position: Double, start: Double, end: Double) -> (elapsed: Double, left: Double, fraction: Double) {
        let len = max(end - start, 0.001)
        let elapsed = min(max(position - start, 0), len)
        return (elapsed, len - elapsed, elapsed / len)
    }
}
