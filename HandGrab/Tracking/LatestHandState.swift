import Foundation
import os

/// Последнее состояние рук: пишет очередь vision, читает рендер (без блокировок дольше копии).
final class LatestHandState {
    struct Snapshot {
        var hands: [HandFrame?] = [nil, nil]
        var lastSeen: [Double] = [0, 0]
        /// Горизонтальный FOV камеры (по экрану), когда известен из intrinsics.
        var hfovDegrees: Float? = nil
    }

    private let lock = OSAllocatedUnfairLock<Snapshot>(uncheckedState: Snapshot())

    func publish(_ frames: [HandFrame], hfov: Float?) {
        lock.withLockUnchecked { s in
            for f in frames {
                s.hands[f.slot] = f
                s.lastSeen[f.slot] = f.captureTime
            }
            if let h = hfov { s.hfovDegrees = h }
        }
    }

    func read() -> Snapshot { lock.withLockUnchecked { $0 } }
}
