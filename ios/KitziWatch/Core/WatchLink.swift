import Foundation
import Observation
import WatchConnectivity
import WatchKit

/// The watch's side of the link with the iPhone app: sign-in, books sent from the
/// phone, and the iPhone remote.
@Observable
final class WatchLink: NSObject {
    static let shared = WatchLink()

    /// The iPhone can be asked something right now.
    private(set) var reachable = false
    private var backgroundTasks: [WKWatchConnectivityRefreshBackgroundTask] = []

    func start() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    struct Unreachable: Error {}

    /// Sends a message to the iPhone app (waking it if needed) and waits for its reply.
    func request(_ message: [String: Any], timeout: Double = 10) async throws -> [String: Any] {
        let s = WCSession.default
        // Just launched: the session may still be activating.
        for _ in 0..<20 where !(s.activationState == .activated && s.isReachable) { try? await Task.sleep(for: .seconds(0.25)) }
        guard s.activationState == .activated, s.isReachable else { throw WatchModel.LoginError.phoneUnreachable }
        nonisolated(unsafe) let m = message
        let reply = try await withCheckedThrowingContinuation { (c: CheckedContinuation<ReplyBox, Error>) in
            let once = Once(c)
            Self.send(m, on: s, once: once)
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { once.resume(.failure(WatchModel.LoginError.phoneUnreachable)) }
        }
        return reply.value
    }

    /// Built outside the main actor: WatchConnectivity calls these back on its own queue.
    nonisolated private static func send(_ m: [String: Any], on s: WCSession, once: Once<ReplyBox>) {
        s.sendMessage(m, replyHandler: { reply in
            nonisolated(unsafe) let r = reply
            once.resume(.success(ReplyBox(value: r)))
        },
                      errorHandler: { _ in once.resume(.failure(WatchModel.LoginError.phoneUnreachable)) })
    }

    /// What the iPhone is playing; nil when it's playing nothing or can't be reached.
    func phoneState(command: RemoteCommand? = nil, value: Double? = nil) async -> PhoneState? {
        var m: [String: Any] = [WatchMsg.kind: command == nil ? WatchMsg.state : WatchMsg.command]
        m["cmd"] = command?.rawValue
        m["value"] = value
        guard let reply = try? await request(m, timeout: 6), let data = reply["state"] as? Data else { return nil }
        return try? JSONDecoder().decode(PhoneState.self, from: data)
    }

    fileprivate func updateReachable() {
        reachable = WCSession.default.activationState == .activated && WCSession.default.isReachable
        finishBackgroundTasks()
    }

    func hold(_ task: WKWatchConnectivityRefreshBackgroundTask) {
        backgroundTasks.append(task)
        finishBackgroundTasks()
    }

    /// watchOS woke the app for incoming files: done once nothing is left to receive.
    private func finishBackgroundTasks() {
        guard WCSession.default.activationState == .activated, !WCSession.default.hasContentPending else { return }
        for t in backgroundTasks { t.setTaskCompletedWithSnapshot(false) }
        backgroundTasks = []
    }
}

/// The reply dictionary, carried across the continuation.
nonisolated struct ReplyBox: @unchecked Sendable { var value: [String: Any] }

/// Resumes a continuation once: the reply, the error or the timeout, whichever comes first.
nonisolated final class Once<T: Sendable>: @unchecked Sendable {
    private var c: CheckedContinuation<T, Error>?
    private let lock = NSLock()
    init(_ c: CheckedContinuation<T, Error>) { self.c = c }
    func resume(_ r: Result<T, Error>) {
        lock.lock(); let c = self.c; self.c = nil; lock.unlock()
        c?.resume(with: r)
    }
}

extension WatchLink: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        Task { @MainActor in updateReachable() }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in updateReachable() }
    }

    /// A book's track or cover from the iPhone. The file is deleted when this
    /// returns, so it's moved out first.
    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        let meta = file.metadata ?? [:]
        #if DEBUG
        print("KITZITEST watch didReceive keys=\(meta.keys.sorted()) file=\(file.fileURL.lastPathComponent)")
        #endif
        guard let id = meta["itemId"] as? String else { return }
        let keep = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do { try FileManager.default.moveItem(at: file.fileURL, to: keep) } catch {
            #if DEBUG
            print("KITZITEST watch move failed \(error)")
            #endif
            return
        }
        let index = meta["index"] as? Int
        let manifestData = meta["manifest"] as? Data
        let isCover = meta[WatchMsg.kind] as? String == WatchMsg.cover
        Task { @MainActor in
            let manifest = manifestData.flatMap { try? JSONDecoder().decode(WatchBookManifest.self, from: $0) }
            WatchDownloads.shared.received(id, index: isCover ? nil : index, manifest: isCover ? nil : manifest, file: keep)
            updateReachable()
        }
    }
}
