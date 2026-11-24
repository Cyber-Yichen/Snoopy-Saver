import AVFoundation
import Foundation

/// Cooperative cancel flag shared by a background composition and `stop()`.
final class CancelFlag {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

enum MediaTiming {
    /// A missing, failed, zero, or non-finite duration is not playable.
    /// Callers must not substitute a placeholder such as 0.1 seconds.
    static func validatedDuration(seconds: Double, loaded: Bool) -> TimeInterval? {
        guard loaded, seconds.isFinite, seconds > 0 else { return nil }
        return seconds
    }

    static func loopRepeatCount(loopDuration: TimeInterval, desiredLoop: TimeInterval) -> Int? {
        guard loopDuration.isFinite, loopDuration > 0, desiredLoop.isFinite, desiredLoop > 0 else { return nil }
        return max(1, Int((desiredLoop / loopDuration).rounded()))
    }
}

/// Durations are loaded with `loadValuesAsynchronously(forKeys:)`, which is
/// available on the macOS 12 deployment target. The newer async `load(_:)`
/// API is not required. Lookups never read an unloaded `duration` property.
final class MediaTimingCache {
    static let shared = MediaTimingCache()

    private let lock = NSLock()
    private var durations: [URL: TimeInterval?] = [:]
    private var waiters: [URL: [(TimeInterval?) -> Void]] = [:]
    private let queue: OperationQueue

    init() {
        queue = OperationQueue()
        queue.name = "local.snoopy.media-timing"
        queue.maxConcurrentOperationCount = 2
        queue.qualityOfService = .userInitiated
    }

    /// Cached seconds, or nil when the file has no usable duration.
    /// A cache miss returns nil and starts a background load; it does not block.
    func duration(for url: URL) -> TimeInterval? {
        lock.lock()
        let known = durations[url]
        lock.unlock()
        if let known { return known }
        load(url, completion: { _ in })
        return nil
    }

    func prepare(_ urls: [URL], completion: @escaping () -> Void) {
        let unique = Array(Set(urls))
        guard !unique.isEmpty else {
            completion()
            return
        }
        let group = DispatchGroup()
        for url in unique {
            group.enter()
            load(url) { _ in group.leave() }
        }
        group.notify(queue: .global(qos: .userInitiated), execute: completion)
    }

    func load(_ url: URL, completion: @escaping (TimeInterval?) -> Void) {
        lock.lock()
        if let known = durations[url] {
            lock.unlock()
            completion(known)
            return
        }
        waiters[url, default: []].append(completion)
        let shouldStart = waiters[url]?.count == 1
        lock.unlock()
        guard shouldStart else { return }
        queue.addOperation { [weak self] in
            self?.read(url)
        }
    }

    /// Loads a local video track off the main thread. The semaphore waits on
    /// the caller's background queue; `loadValuesAsynchronously` completes on
    /// a different queue, so this does not deadlock that callback.
    static func loadSource(
        _ url: URL,
        cancel: CancelFlag
    ) -> (asset: AVURLAsset, track: AVAssetTrack, duration: CMTime)? {
        if cancel.isCancelled { return nil }
        let asset = AVURLAsset(url: url)
        let ready = DispatchSemaphore(value: 0)
        asset.loadValuesAsynchronously(forKeys: ["duration", "tracks"]) {
            ready.signal()
        }
        guard ready.wait(timeout: .now() + 8) == .success, !cancel.isCancelled else { return nil }
        var error: NSError?
        guard asset.statusOfValue(forKey: "duration", error: &error) == .loaded,
              asset.statusOfValue(forKey: "tracks", error: &error) == .loaded,
              let track = asset.tracks(withMediaType: .video).first,
              let seconds = MediaTiming.validatedDuration(seconds: asset.duration.seconds, loaded: true)
        else { return nil }
        let transformReady = DispatchSemaphore(value: 0)
        track.loadValuesAsynchronously(forKeys: ["preferredTransform"]) {
            transformReady.signal()
        }
        guard transformReady.wait(timeout: .now() + 8) == .success, !cancel.isCancelled else { return nil }
        shared.finish(url, seconds)
        return (asset, track, CMTime(seconds: seconds, preferredTimescale: 600))
    }

    private func read(_ url: URL) {
        let asset = AVURLAsset(url: url)
        asset.loadValuesAsynchronously(forKeys: ["duration"]) { [weak self] in
            var error: NSError?
            let loaded = asset.statusOfValue(forKey: "duration", error: &error) == .loaded
            let value = MediaTiming.validatedDuration(seconds: asset.duration.seconds, loaded: loaded)
            self?.finish(url, value)
        }
    }

    private func finish(_ url: URL, _ value: TimeInterval?) {
        lock.lock()
        durations[url] = value
        let callbacks = waiters.removeValue(forKey: url) ?? []
        lock.unlock()
        callbacks.forEach { $0(value) }
    }
}
