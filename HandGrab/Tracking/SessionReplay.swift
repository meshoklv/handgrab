import Foundation
import QuartzCore
import simd

/// Журнал событий (захват/отпускание/реплей) в Documents/events.log — для проверки без экрана.
final class EventLog {
    static let shared = EventLog()
    private let q = DispatchQueue(label: "eventlog", qos: .utility)
    private var lines: [String] = []
    private let t0 = CACurrentMediaTime()
    private var url: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("events.log") }

    func write(_ s: String) {
        let line = String(format: "%8.3f ", CACurrentMediaTime() - t0) + s
        q.async {
            self.lines.append(line)
            if self.lines.count > 2000 { self.lines.removeFirst(500) }
            try? (self.lines.joined(separator: "\n") + "\n").data(using: .utf8)?.write(to: self.url, options: .atomic)
        }
    }
}

/// Запись сессии: на каждый кадр распознавания — 21 точка, уверенность, рука, глубина ладони.
/// Documents/sessions/s-ДАТА.jsonl, первая строка — intrinsics. Реплей: запуск с аргументом `-replay s-ДАТА.jsonl`.
final class SessionRecorder {
    private let q = DispatchQueue(label: "recorder", qos: .utility)
    private var handle: FileHandle?
    private var startT: Double = 0
    private var lastT: Double = -100
    private var bytes = 0
    private var pending = Data()
    /// Имя распознавателя для заголовка записи (ставит конвейер).
    static var detectorName = "?"

    static var dir: URL {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("sessions")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// Вызывается на очереди слияния; форматирование и запись — на своей очереди.
    func add(t: Double, hands: [Hand2D], depths: [Float?], intr: Intrinsics, orientation: UInt32) {
        if hands.isEmpty { return }
        q.async { self.write(t: t, hands: hands, depths: depths, intr: intr, orientation: orientation) }
    }

    private func write(t: Double, hands: [Hand2D], depths: [Float?], intr: Intrinsics, orientation: UInt32) {
        // Пауза > 5 с или файл > 8 МБ — новая сессия.
        if handle == nil || t - lastT > 5 || bytes > 8_000_000 { open(t: t, intr: intr, orientation: orientation) }
        lastT = t
        var s = String(format: "{\"t\":%.4f,\"h\":[", t - startT)
        for (k, h) in hands.enumerated() {
            if k > 0 { s += "," }
            s += "{\"p\":[" + h.points.map { String(format: "%.4f,%.4f", $0.x, $0.y) }.joined(separator: ",") + "],"
            s += "\"c\":[" + h.conf.map { String(format: "%.2f", $0) }.joined(separator: ",") + "],"
            s += "\"ch\":\(h.chirality.rawValue),\"z\":" + (k < depths.count && depths[k] != nil ? String(format: "%.4f", depths[k]!) : "null") + "}"
        }
        s += "]}\n"
        let d = s.data(using: .utf8)!
        pending.append(d)
        bytes += d.count
        if pending.count > 32_000 { flush() }
        q.asyncAfter(deadline: .now() + 1) { [weak self] in self?.flush() }
    }

    private func flush() {
        guard let h = handle, !pending.isEmpty else { return }
        try? h.write(contentsOf: pending)
        pending.removeAll(keepingCapacity: true)
    }

    private func open(t: Double, intr: Intrinsics, orientation: UInt32) {
        flush()
        try? handle?.close()
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
        let url = SessionRecorder.dir.appendingPathComponent("s-\(f.string(from: Date())).jsonl")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
        startT = t; bytes = 0
        // chmap 2: метки рук MediaPipe записаны как есть (до 20.10 вечера — перевёрнутыми, см. FileReplay).
        let header = String(format: "{\"v\":1,\"intr\":[%.5f,%.5f,%.5f,%.5f],\"orient\":%u,\"chmap\":2,\"det\":\"%@\"}\n",
                            intr.fx, intr.fy, intr.cx, intr.cy, orientation, SessionRecorder.detectorName)
        pending.append(header.data(using: .utf8)!)
        prune()
    }

    /// Оставить 20 последних сессий.
    private func prune() {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: SessionRecorder.dir.path) else { return }
        let files = items.filter { $0.hasPrefix("s-") }.sorted()
        for f in files.dropLast(20) { try? fm.removeItem(at: SessionRecorder.dir.appendingPathComponent(f)) }
    }
}

/// Источник реплея: кадры (руки + глубина ладони) по времени от начала.
protocol ReplaySource {
    var duration: Double { get }
    var intrinsics: Intrinsics { get }
    /// Снимки сцены: (время, имя файла без расширения).
    var snapshots: [(Double, String)] { get }
    /// Кадры в полуинтервале (from, to].
    func frames(from: Double, to: Double) -> [(Double, [Hand2D], [Float?])]
}

/// Записанная сессия из файла.
struct FileReplay: ReplaySource {
    let intrinsics: Intrinsics
    let items: [(Double, [Hand2D], [Float?])]
    var duration: Double { items.last?.0 ?? 0 }
    var snapshots: [(Double, String)] {
        stride(from: 1.0, to: duration, by: 2.0).map { ($0, String(format: "replay-%03.0f", $0)) }
    }

    init?(url: URL) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var intr = Intrinsics.fallback
        var out: [(Double, [Hand2D], [Float?])] = []
        // Записи до 20.10 (вечер, без "chmap") хранят метки MediaPipe перевёрнутыми — вернуть как выдал MediaPipe.
        var legacyLabels = false
        for line in text.split(separator: "\n") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            if let a = obj["intr"] as? [Double], a.count == 4 {
                intr = Intrinsics(fx: Float(a[0]), fy: Float(a[1]), cx: Float(a[2]), cy: Float(a[3]))
                legacyLabels = obj["chmap"] == nil
                continue
            }
            guard let t = obj["t"] as? Double, let hs = obj["h"] as? [[String: Any]] else { continue }
            var hands: [Hand2D] = [], zs: [Float?] = []
            for h in hs {
                guard let p = h["p"] as? [Double], p.count == 42, let c = h["c"] as? [Double], c.count == 21 else { continue }
                let pts = (0..<21).map { SIMD2(Float(p[2 * $0]), Float(p[2 * $0 + 1])) }
                let conf = c.map(Float.init)
                var ch = Chirality(rawValue: h["ch"] as? Int ?? 0) ?? .unknown
                if legacyLabels { ch = ch == .left ? .right : ch == .right ? .left : .unknown }
                hands.append(Hand2D(points: pts, conf: conf, chirality: ch,
                                    goodCount: conf.filter { $0 > HandFilter.goodConfidence }.count))
                zs.append((h["z"] as? Double).map(Float.init))
            }
            out.append((t, hands, zs))
        }
        guard !out.isEmpty else { return nil }
        intrinsics = intr; items = out
    }

    func frames(from: Double, to: Double) -> [(Double, [Hand2D], [Float?])] {
        items.filter { $0.0 > from && $0.0 <= to }
    }
}

/// Синтетическая рука: появляется в центре, берёт красный куб щипком, переносит, бросает,
/// тянется к дальнему жёлтому шару (рука к телефону), берёт кулаком, несёт к себе, отпускает.
struct SyntheticReplay: ReplaySource {
    let intrinsics = Intrinsics(fx: 0.685, fy: 0.913, cx: 0.5, cy: 0.5)   // iPhone Air, hfov 57°
    /// «Как с живой камеры»: шум точек (σ ≈ 0,4% кадра), шум глубины (σ ≈ 6 мм), кадры распознавания 30 Гц.
    var noisy = false
    let anchor: Float = 0.40
    let config: TrackingConfig
    var duration: Double { 10 }
    var snapshots: [(Double, String)] {
        [(0.8, "synth-0-appear"), (2.15, "synth-1-hover"), (3.1, "synth-2-grabbed"), (4.3, "synth-3-carried"),
         (5.5, "synth-4-dropped"), (6.6, "synth-5-reach-far"), (7.9, "synth-6-fist-carry"), (9.6, "synth-7-end")]
    }

    // Поза руки в «направлениях сцены» до наклона и масштаба: x вправо, y вверх (пальцы), z к себе.
    // Правая рука, ладонь к телефону (−z), большой палец слева.
    static let open: [SIMD3<Float>] = [
        [0, -0.045, 0.005],
        [-0.025, -0.032, -0.005], [-0.045, -0.012, -0.015], [-0.058, 0.008, -0.022], [-0.066, 0.027, -0.026],
        [-0.024, 0.040, 0], [-0.027, 0.080, -0.002], [-0.029, 0.103, -0.003], [-0.030, 0.122, -0.004],
        [-0.007, 0.042, 0], [-0.007, 0.086, -0.002], [-0.007, 0.113, -0.003], [-0.007, 0.135, -0.004],
        [0.011, 0.039, 0], [0.013, 0.080, -0.002], [0.014, 0.106, -0.003], [0.015, 0.127, -0.004],
        [0.027, 0.033, 0.002], [0.031, 0.066, 0], [0.033, 0.085, -0.001], [0.035, 0.103, -0.002],
    ]
    static let pinch: [SIMD3<Float>] = [
        [0, -0.045, 0.005],
        [-0.025, -0.032, -0.008], [-0.042, -0.010, -0.025], [-0.048, 0.015, -0.040], [-0.040, 0.045, -0.052],
        [-0.024, 0.040, 0], [-0.030, 0.076, -0.020], [-0.036, 0.068, -0.040], [-0.039, 0.050, -0.051],
        [-0.007, 0.042, 0], [-0.008, 0.080, -0.020], [-0.009, 0.090, -0.045], [-0.010, 0.080, -0.062],
        [0.011, 0.039, 0], [0.012, 0.074, -0.020], [0.013, 0.082, -0.042], [0.014, 0.072, -0.058],
        [0.027, 0.033, 0.002], [0.030, 0.060, -0.016], [0.031, 0.066, -0.034], [0.032, 0.058, -0.047],
    ]
    static let fist: [SIMD3<Float>] = [
        [0, -0.045, 0.005],
        [-0.025, -0.032, -0.008], [-0.040, -0.012, -0.025], [-0.035, 0.012, -0.040], [-0.020, 0.025, -0.045],
        [-0.024, 0.040, 0], [-0.026, 0.065, -0.030], [-0.025, 0.045, -0.045], [-0.024, 0.028, -0.035],
        [-0.007, 0.042, 0], [-0.007, 0.068, -0.032], [-0.007, 0.046, -0.048], [-0.007, 0.028, -0.038],
        [0.011, 0.039, 0], [0.012, 0.063, -0.030], [0.012, 0.043, -0.044], [0.012, 0.027, -0.035],
        [0.027, 0.033, 0.002], [0.029, 0.055, -0.026], [0.029, 0.038, -0.037], [0.029, 0.024, -0.030],
    ]

    struct Key { let t: Double; let pos: SIMD3<Float>; let pinch: Float; let fist: Float }

    private func pose(pinch a: Float, fist b: Float) -> [SIMD3<Float>] {
        (0..<21).map { i in
            let o = Self.open[i]
            return o + (Self.pinch[i] - o) * a + (Self.fist[i] - o) * b
        }
    }

    private static func palmCenter(_ p: [SIMD3<Float>]) -> SIMD3<Float> { (p[0] + p[5] + p[9] + p[13] + p[17]) / 5 }

    /// Смещение точки хвата от центра ладони в сцене.
    private func grabOffset(fist: Bool) -> SIMD3<Float> {
        if fist { return .zero }
        let p = Self.pinch, c = Self.palmCenter(p)
        let mid = (p[4] + p[8]) * 0.5 - c
        let rot = Workspace.shapeRotation(config: config)
        return rot.act(mid * config.handScale)
    }

    private var keys: [Key] {
        let homes = SceneObjects.homeXZ
        let ty = SceneObjects.tableY
        let red = homes[0], yellow = homes[3]
        let hRed = SceneObjects.halfHeights[0], hYel = SceneObjects.halfHeights[3]
        func above(_ xz: SIMD2<Float>, _ cy: Float, _ h: Float, fist: Bool) -> SIMD3<Float> {
            SIMD3(xz.x, ty + cy + h, xz.y) - grabOffset(fist: fist)
        }
        let start = SIMD3<Float>(0, ty + 0.17, Workspace.zMid)
        return [
            Key(t: 0, pos: start, pinch: 0, fist: 0),
            Key(t: 0.8, pos: start, pinch: 0, fist: 0),
            Key(t: 1.6, pos: above(red, hRed, 0.10, fist: false), pinch: 0, fist: 0),
            Key(t: 2.2, pos: above(red, hRed, 0.01, fist: false), pinch: 0, fist: 0),
            Key(t: 2.7, pos: above(red, hRed, 0.01, fist: false), pinch: 1, fist: 0),
            Key(t: 3.1, pos: above(red, hRed, 0.06, fist: false), pinch: 1, fist: 0),
            Key(t: 4.3, pos: above([-0.10, -0.38], hRed, 0.12, fist: false), pinch: 1, fist: 0),
            Key(t: 4.8, pos: above([-0.10, -0.38], hRed, 0.12, fist: false), pinch: 0, fist: 0),
            Key(t: 5.6, pos: above(yellow, hYel, 0.10, fist: true), pinch: 0, fist: 0),
            Key(t: 6.3, pos: above(yellow, hYel, 0.0, fist: true), pinch: 0, fist: 0),
            Key(t: 6.8, pos: above(yellow, hYel, 0.0, fist: true), pinch: 0, fist: 1),
            Key(t: 7.9, pos: above([-0.08, -0.21], hYel, 0.10, fist: true), pinch: 0, fist: 1),
            Key(t: 8.4, pos: above([-0.08, -0.21], hYel, 0.10, fist: true), pinch: 0, fist: 0),
            Key(t: 10, pos: start, pinch: 0, fist: 0),
        ]
    }

    func frames(from: Double, to: Double) -> [(Double, [Hand2D], [Float?])] {
        // Шаг 1/60 с, как у камеры (с шумом — 1/30 с, как Vision на двух руках в v2).
        let hz: Double = noisy ? 30 : 60
        var out: [(Double, [Hand2D], [Float?])] = []
        var t = (floor(from * hz) + 1) / hz
        while t <= to {
            if var f = frame(at: t) {
                if noisy {
                    var g = SystemRandomNumberGenerator()
                    func n(_ s: Float) -> Float {   // гаусс (Бокс — Мюллер)
                        let u1 = Float.random(in: 1e-6..<1, using: &g), u2 = Float.random(in: 0..<1, using: &g)
                        return s * (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
                    }
                    f.0.points = f.0.points.map { $0 + SIMD2(n(0.004), n(0.004)) }
                    f.1 += n(0.006)
                }
                out.append((t, [f.0], [f.1]))
            }
            t += 1.0 / hz
        }
        return out
    }

    func frame(at t: Double) -> (Hand2D, Float)? {
        let ks = keys
        guard let i = ks.lastIndex(where: { $0.t <= t }) else { return nil }
        let a = ks[i], b = ks[min(i + 1, ks.count - 1)]
        var u = b.t > a.t ? Float((t - a.t) / (b.t - a.t)) : 0
        u = u * u * (3 - 2 * u)
        let pos = a.pos + (b.pos - a.pos) * u
        let pinch = a.pinch + (b.pinch - a.pinch) * u
        let fist = a.fist + (b.fist - a.fist) * u
        // Сцена → экран и дистанция → точка ладони в камере.
        let (scr, z) = Workspace.inverse(scene: pos, anchor: anchor, config: config)
        let sensor = SIMD2<Float>(scr.y, scr.x)   // обратное к sensorToScreen (без поворота)
        let palmCam = intrinsics.ray(sensor) * z
        let p = pose(pinch: pinch, fist: fist)
        let c = Self.palmCenter(p)
        var pts = [SIMD2<Float>](repeating: .zero, count: 21)
        for k in 0..<21 {
            let d = p[k] - c                                  // направления сцены (вид от первого лица)
            let cam = palmCam + SIMD3(-d.y, d.x, d.z)         // обратное к cameraDirToScene
            pts[k] = SIMD2(cam.x / cam.z * intrinsics.fx + intrinsics.cx, cam.y / cam.z * intrinsics.fy + intrinsics.cy)
        }
        return (Hand2D(points: pts, conf: [Float](repeating: 0.9, count: 21), chirality: .right, goodCount: 21), z)
    }
}

/// Прогон реплея через конвейер на 60 Гц со снимками сцены.
final class ReplayRunner {
    private let pipeline: TrackingPipeline
    private let source: ReplaySource
    private let loop: Bool
    private var timer: DispatchSourceTimer?
    private let q = DispatchQueue(label: "replay", qos: .userInteractive)
    private var t0: Double = 0
    private var lastTau: Double = 0
    private var shotIndex = 0

    init(pipeline: TrackingPipeline, source: ReplaySource, loop: Bool) {
        self.pipeline = pipeline; self.source = source; self.loop = loop
    }

    func start(after delay: Double = 1.5) {
        let tm = DispatchSource.makeTimerSource(queue: q)
        tm.schedule(deadline: .now() + delay, repeating: 1.0 / 120)
        tm.setEventHandler { [weak self] in self?.tick() }
        timer = tm
        t0 = CACurrentMediaTime() + delay
        EventLog.shared.write("REPLAY START dur=\(String(format: "%.1f", source.duration))")
        tm.resume()
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let tau = now - t0
        for (t, hands, zs) in source.frames(from: lastTau, to: tau) {
            pipeline.inject(hands: hands, palmDepths: zs, t: t0 + t, intrinsics: source.intrinsics)
        }
        lastTau = tau
        let shots = source.snapshots
        while shotIndex < shots.count, shots[shotIndex].0 <= tau {
            let name = shots[shotIndex].1
            shotIndex += 1
            DispatchQueue.main.async { Telemetry.shared.saveSnapshot(name: name) }
        }
        if tau > source.duration + 0.5 {
            EventLog.shared.write("REPLAY DONE")
            if loop {
                t0 = now + 0.5; lastTau = 0; shotIndex = source.snapshots.count
            } else {
                timer?.cancel(); timer = nil
            }
        }
    }
}
