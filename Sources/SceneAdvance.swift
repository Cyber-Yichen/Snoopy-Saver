import Foundation

/// Schedules a scene change after a boundary-time callback returns.
///
/// `AVPlayer.removeTimeObserver` guarantees only that no new block starts.
/// An in-flight block may still be running, and `dispatch_sync` back onto
/// that observer queue deadlocks. Scene changes also do enough player and
/// layer work that they should not run inside the callback. The advance
/// therefore happens on a later main-queue turn, and only if the captured
/// epoch and player are still current.
enum SceneAdvance {
    static func deferBoundaryAdvance(
        sessionActive: @escaping () -> Bool,
        epoch: @escaping () -> Int,
        capturedEpoch: Int,
        playerStillCurrent: @escaping () -> Bool,
        advance: @escaping () -> Void
    ) {
        DispatchQueue.main.async {
            guard sessionActive(), epoch() == capturedEpoch, playerStillCurrent() else { return }
            advance()
        }
    }
}
