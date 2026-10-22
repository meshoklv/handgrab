import Foundation
import os

/// Кольцевой буфер для среднего и p95.
struct Ring {
    private var buf: [Double]
    private var idx = 0
    private(set) var count = 0

    init(capacity: Int) { buf = [Double](repeating: 0, count: capacity) }

    mutating func add(_ v: Double) {
        buf[idx] = v
        idx = (idx + 1) % buf.count
        count = min(count + 1, buf.count)
    }

    func meanP95() -> (Double, Double) {
        guard count > 0 else { return (0, 0) }
        let a = Array(buf.prefix(count)).sorted()
        let mean = a.reduce(0, +) / Double(count)
        let p = a[min(count - 1, Int(Double(count) * 0.95))]
        return (mean, p)
    }
}

/// Счётчики конвейера. Пишут все потоки, HUD читает 4 раза в секунду.
final class Metrics {
    static let shared = Metrics()

    struct Info {
        var videoFormat = "—"
        var depthFormat = "—"
        var depthAccuracy = "—"
        var depthQuality = "—"
        var hands = 0
        var meanConf: Float = 0
        var palmCm: Float = .nan
        var pinch = "—"
        var pinchD: Float = .nan
        var fistD: Float = .nan
        var centerDepth: Float = .nan
        var handInvalid: Float = .nan
        var jointInvalid: Float = .nan
        var hfov: Float = .nan
        var predictionMs: Float = 0
        var depthFresh = false
        var scaleCm: Float = .nan
        var detector = "—"
    }

    struct Counters {
        var cam = 0, depth = 0, depthDropped = 0, depthMissing = 0
        var vision = 0, visionSkipped = 0, render = 0
        var visionMs = Ring(capacity: 120)
        var latencyMs = Ring(capacity: 480)
        var deliverMs = Ring(capacity: 120)
        var waitMs = Ring(capacity: 120)
        var doneMs = Ring(capacity: 120)
        var depthAgeMs = Ring(capacity: 120)
        var depthIngests = 0, depthHoles = 0
        var info = Info()
    }

    struct HUDData {
        var camFps: Double = 0, depthFps: Double = 0, visionFps: Double = 0, renderFps: Double = 0
        var visionMean: Double = 0, visionP95: Double = 0
        var latMean: Double = 0, latP95: Double = 0
        var depthDropPct: Double = 0
        var deliverMs: Double = 0, waitMs: Double = 0, doneMs: Double = 0
        var visionSkipPct: Double = 0
        var depthAgeMs: Double = 0
        var palmHolePct: Double = .nan
        var info = Info()
        var thermal = "—"
        /// Загрузка CPU процессом, % одного ядра (сумма по потокам).
        var cpuPct: Double = .nan
    }

    private let lock = OSAllocatedUnfairLock<Counters>(uncheckedState: Counters())
    private var lastSnapshot = CACurrentMediaTimeSafe()
    private var lastCPU = Metrics.cpuSeconds()
    /// Последний снимок HUD (только главный поток).
    private(set) var lastHUD = HUDData()

    func camFrame(depthDelivered: Bool, depthDropped: Bool) {
        lock.withLockUnchecked { c in
            c.cam += 1
            if depthDelivered { c.depth += 1 }
            if depthDropped { c.depthDropped += 1 }
            if !depthDelivered && !depthDropped { c.depthMissing += 1 }
        }
    }
    func visionSkipped() { lock.withLockUnchecked { $0.visionSkipped += 1 } }
    func visionDone(ms: Double) { lock.withLockUnchecked { $0.vision += 1; $0.visionMs.add(ms) } }
    func stages(deliver: Double, wait: Double, done: Double) {
        lock.withLockUnchecked { $0.deliverMs.add(deliver); $0.waitMs.add(wait); $0.doneMs.add(done) }
    }
    /// Сопоставление карты глубины с рукой; hole = на ладони нет валидной глубины.
    func depthIngest(hole: Bool) { lock.withLockUnchecked { $0.depthIngests += 1; if hole { $0.depthHoles += 1 } } }
    /// Возраст самой свежей карты глубины в момент обработки кадра.
    func depthAge(ms: Double) { lock.withLockUnchecked { $0.depthAgeMs.add(ms) } }
    func renderFrame() { lock.withLockUnchecked { $0.render += 1 } }
    func latency(ms: Double) { lock.withLockUnchecked { $0.latencyMs.add(ms) } }
    func updateInfo(_ f: (inout Info) -> Void) { lock.withLockUnchecked { f(&$0.info) } }
    var info: Info { lock.withLockUnchecked { $0.info } }

    /// Снимок для HUD; обнуляет счётчики частот.
    func snapshot() -> HUDData {
        let now = CACurrentMediaTimeSafe()
        let dt = max(now - lastSnapshot, 1e-3)
        lastSnapshot = now
        let r: HUDData = lock.withLockUnchecked { c in
            var h = HUDData()
            h.camFps = Double(c.cam) / dt
            h.depthFps = Double(c.depth) / dt
            h.visionFps = Double(c.vision) / dt
            h.renderFps = Double(c.render) / dt
            (h.visionMean, h.visionP95) = c.visionMs.meanP95()
            (h.latMean, h.latP95) = c.latencyMs.meanP95()
            h.deliverMs = c.deliverMs.meanP95().0
            h.waitMs = c.waitMs.meanP95().0
            h.doneMs = c.doneMs.meanP95().0
            // Глубина 30 Гц против видео 60 Гц: кадр видео без новой карты — норма, это не потеря.
            // Потеря = карты, которые камера сама выбросила.
            h.depthDropPct = (c.depth + c.depthDropped) > 0 ? 100 * Double(c.depthDropped) / Double(c.depth + c.depthDropped) : 0
            h.depthAgeMs = c.depthAgeMs.meanP95().0
            h.palmHolePct = c.depthIngests > 0 ? 100 * Double(c.depthHoles) / Double(c.depthIngests) : .nan
            c.depthIngests = 0; c.depthHoles = 0
            h.visionSkipPct = c.cam > 0 ? 100 * Double(c.visionSkipped) / Double(c.cam) : 0
            h.info = c.info
            c.cam = 0; c.depth = 0; c.depthDropped = 0; c.depthMissing = 0
            c.vision = 0; c.visionSkipped = 0; c.render = 0
            switch ProcessInfo.processInfo.thermalState {
            case .nominal: h.thermal = "норма"
            case .fair: h.thermal = "тёплый"
            case .serious: h.thermal = "ГОРЯЧИЙ"
            case .critical: h.thermal = "КРИТИЧНО"
            @unknown default: h.thermal = "?"
            }
            return h
        }
        var out = r
        let cpu = Metrics.cpuSeconds()
        out.cpuPct = 100 * (cpu - lastCPU) / dt
        lastCPU = cpu
        lastHUD = out
        return out
    }
}

import QuartzCore
@inline(__always) func CACurrentMediaTimeSafe() -> Double { CACurrentMediaTime() }

extension Metrics {
    /// Процессорное время процесса (пользователь + система), с.
    static func cpuSeconds() -> Double {
        var u = rusage()
        getrusage(RUSAGE_SELF, &u)
        return Double(u.ru_utime.tv_sec) + Double(u.ru_utime.tv_usec) / 1e6 + Double(u.ru_stime.tv_sec) + Double(u.ru_stime.tv_usec) / 1e6
    }
}
