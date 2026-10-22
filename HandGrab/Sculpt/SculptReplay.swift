import Foundation
import simd

/// Синтетические траектории кисти (мир, м) вокруг центра скульптуры.
enum SculptTrajectory: String, CaseIterable {
    case spiral, s, wave, knot, pull, rotate

    static var center: SIMD3<Float> { SculptController.center }

    var duration: Double {
        switch self {
        case .spiral: return 4
        case .s: return 3
        case .wave: return 3
        case .knot: return 5
        case .pull: return 2.5
        case .rotate: return 3
        }
    }

    /// Точка пути в доле u ∈ [0, 1].
    func point(_ u: Float) -> SIMD3<Float> {
        let c = Self.center
        switch self {
        case .spiral:
            let a = 6 * Float.pi * u
            return c + SIMD3(0.06 * cos(a), -0.06 + 0.12 * u, 0.06 * sin(a))
        case .s, .rotate:
            return c + SIMD3(-0.045 * sin(2 * .pi * u), 0.075 - 0.15 * u, 0)
        case .wave:
            let a = 6 * Float.pi * u
            return c + SIMD3(-0.12 + 0.24 * u, 0.04 * sin(a), 0.03 * cos(a) - 0.03)
        case .knot:
            // Узел-трилистник (2, 3) на торе.
            let t = 2 * Float.pi * u
            let r = 0.045 + 0.022 * cos(3 * t)
            return c + SIMD3(r * cos(2 * t), 0.024 * sin(3 * t), r * sin(2 * t))
        case .pull:
            // Тяга конца по дуге ~25 см от правого конца 6-сантиметрового мазка.
            let a = Float.pi * u
            return c + SIMD3(0.03 + 0.075 * sin(a), 0.075 * (1 - cos(a)), 0.035 * sin(2 * a))
        }
    }

    /// Плотная полилиния эталона.
    func reference(samples n: Int = 600) -> [SIMD3<Float>] {
        (0...n).map { point(Float($0) / Float(n)) }
    }
}

/// Отклонение узлов мазка от эталонной линии: максимум, среднее, максимум после вычитания среднего сдвига (форма).
enum TrajectoryCheck {
    static func deviation(_ pts: [SIMD3<Float>], ref: [SIMD3<Float>]) -> (max: Float, mean: Float, shapeMax: Float) {
        guard !pts.isEmpty, ref.count > 1 else { return (0, 0, 0) }
        func nearest(_ p: SIMD3<Float>) -> SIMD3<Float> {
            var best = ref[0], bd = Float.greatestFiniteMagnitude
            for i in 1..<ref.count {
                let a = ref[i - 1], b = ref[i]
                let ab = b - a
                let u = clampf(simd_dot(p - a, ab) / max(simd_length_squared(ab), 1e-12), 0, 1)
                let q = a + ab * u
                let d = simd_distance_squared(p, q)
                if d < bd { bd = d; best = q }
            }
            return best
        }
        var offs: [SIMD3<Float>] = []
        for p in pts { offs.append(p - nearest(p)) }
        let mean = offs.reduce(SIMD3<Float>.zero, +) / Float(offs.count)
        let mx = offs.map { simd_length($0) }.max() ?? 0
        let mn = offs.map { simd_length($0) }.reduce(0, +) / Float(offs.count)
        // Форма: сдвинуть узлы на средний сдвиг и перемерить.
        var shape: Float = 0
        for p in pts { shape = max(shape, simd_distance(p - mean, nearest(p - mean))) }
        return (mx, mn, shape)
    }
}

// MARK: Реплей через конвейер трекинга

/// Сценарий одной руки: отрезки времени → (точка щепоти/ладони в мире, щипок 0…1, кулак 0…1).
struct HandScript {
    struct State { var pos: SIMD3<Float>; var pinch: Float; var fist: Float }
    var segs: [(Double, (Float) -> State)] = []
    var start: Double = 0
    var duration: Double { segs.reduce(0) { $0 + $1.0 } }

    mutating func add(_ d: Double, _ f: @escaping (Float) -> State) { segs.append((d, f)) }

    func state(at t: Double) -> State? {
        var tt = t - start
        if tt < 0 { return nil }
        for (d, f) in segs {
            if tt <= d { return f(Float(d > 0 ? tt / d : 1)) }
            tt -= d
        }
        return nil
    }

    static func ease(_ u: Float) -> Float { u * u * (3 - 2 * u) }
}

/// Реплей `-replay sculpt-<траектория>[-noise]`: правая рука рисует щипком, для `rotate` левая поворачивает кулаком.
/// Рука строится той же обратной проекцией, что SyntheticReplay.
struct SculptReplay: ReplaySource {
    let intrinsics = Intrinsics(fx: 0.685, fy: 0.913, cx: 0.5, cy: 0.5)
    let anchor: Float = 0.40
    let config: TrackingConfig
    let traj: SculptTrajectory
    var noisy = false
    private(set) var right = HandScript()
    private(set) var left: HandScript?
    private(set) var shots: [(Double, String)] = []
    /// Время начала/конца основного пути (для журнала).
    private(set) var pathStart: Double = 0

    var duration: Double { max(right.duration, (left.map { $0.start + $0.duration }) ?? 0) }
    var snapshots: [(Double, String)] { shots }

    init?(name: String, config: TrackingConfig, noisy: Bool, preset: BrushKind) {
        guard let tr = SculptTrajectory(rawValue: name) else { return nil }
        self.config = config; self.traj = tr; self.noisy = noisy
        let tag = "sculpt-\(preset.key)-\(tr.rawValue)" + (noisy ? "-noise" : "")
        let zMid = Workspace.zMid
        var r = HandScript()
        func hover(_ p: SIMD3<Float>) -> SIMD3<Float> { SIMD3(p.x, p.y, zMid) }
        var t: Double = 0
        func hold(_ p: SIMD3<Float>, _ d: Double, pinch: (Float, Float) = (0, 0)) {
            r.add(d) { u in HandScript.State(pos: p, pinch: pinch.0 + (pinch.1 - pinch.0) * HandScript.ease(u), fist: 0) }
            t += d
        }
        func move(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ d: Double, pinch: Float = 0) {
            r.add(d) { u in HandScript.State(pos: a + (b - a) * HandScript.ease(u), pinch: pinch, fist: 0) }
            t += d
        }
        func path(_ f: @escaping (Float) -> SIMD3<Float>, _ d: Double, shotsPrefix: String?) {
            if let pf = shotsPrefix {
                shots += [(t + d * 0.25, pf + "-25"), (t + d * 0.5, pf + "-50"), (t + d, pf + "-100")]
            }
            r.add(d) { u in HandScript.State(pos: f(u), pinch: 1, fist: 0) }
            t += d
        }
        switch tr {
        case .pull:
            let a = SculptTrajectory.center + SIMD3(-0.03, 0, 0), b = SculptTrajectory.center + SIMD3(0.03, 0, 0)
            hold(hover(a), 0.6); move(hover(a), a, 0.4); hold(a, 0.3, pinch: (0, 1))
            pathStart = t
            path({ a + (b - a) * $0 }, 1.0, shotsPrefix: nil)
            hold(b, 0.3, pinch: (1, 0)); hold(b, 0.6)
            // Щипок на конце → тянуть 25 см по дуге.
            hold(b, 0.3, pinch: (0, 1))
            path({ tr.point($0) }, tr.duration, shotsPrefix: tag)
            let e = tr.point(1)
            hold(e, 0.3, pinch: (1, 0))
            shots.append((t + 0.6, tag + "-settled"))
            hold(e, 0.8)
            // Щипок за середину исходного мазка → тянуть вверх 4 см.
            let mid = SculptTrajectory.center
            move(e, mid + SIMD3(0, 0.02, 0), 0.6)
            move(mid + SIMD3(0, 0.02, 0), mid, 0.3)
            hold(mid, 0.3, pinch: (0, 1))
            path({ mid + SIMD3(0, 0.04, 0.01) * HandScript.ease($0) }, 0.8, shotsPrefix: nil)
            hold(mid + SIMD3(0, 0.04, 0.01), 0.3, pinch: (1, 0))
            shots.append((t + 0.6, tag + "-midpull"))
            hold(mid + SIMD3(0, 0.04, 0.01), 1.0)
        default:
            let p0 = tr.point(0)
            hold(hover(p0), 0.6); move(hover(p0), p0, 0.4); hold(p0, 0.3, pinch: (0, 1))
            pathStart = t
            path({ tr.point($0) }, tr.duration, shotsPrefix: tag)
            let e = tr.point(1)
            hold(e, 0.3, pinch: (1, 0))
            shots.append((t + 0.6, tag + "-settled"))
            hold(e, 0.9)
            move(e, e + SIMD3(0.05, 0.05, 0), 0.5)
            if tr == .rotate {
                hold(e + SIMD3(0.05, 0.05, 0), 3.8)
                var l = HandScript()
                l.start = t
                let c = SculptTrajectory.center + SIMD3(-0.10, -0.02, 0)
                l.add(0.5) { _ in .init(pos: SIMD3(c.x, c.y, zMid), pinch: 0, fist: 0) }
                l.add(0.35) { u in .init(pos: c, pinch: 0, fist: HandScript.ease(u)) }
                l.add(0.3) { _ in .init(pos: c, pinch: 0, fist: 1) }
                l.add(1.0) { u in .init(pos: c + SIMD3(0.08 * HandScript.ease(u), 0, 0), pinch: 0, fist: 1) }
                l.add(0.35) { u in .init(pos: c + SIMD3(0.08, 0, 0), pinch: 0, fist: 1 - HandScript.ease(u)) }
                l.add(1.2) { _ in .init(pos: c + SIMD3(0.08, 0, 0), pinch: 0, fist: 0) }
                shots.append((l.start + 3.4, tag + "-rotated"))
                left = l
            }
        }
        right = r
    }

    // Те же позы, что у SyntheticReplay.
    private func pose(pinch a: Float, fist b: Float, mirror: Bool) -> [SIMD3<Float>] {
        (0..<21).map { i in
            let o = SyntheticReplay.open[i]
            var p = o + (SyntheticReplay.pinch[i] - o) * a + (SyntheticReplay.fist[i] - o) * b
            if mirror { p.x = -p.x }
            return p
        }
    }

    private static func palmCenter(_ p: [SIMD3<Float>]) -> SIMD3<Float> { (p[0] + p[5] + p[9] + p[13] + p[17]) / 5 }

    /// Смещение щепоти от центра ладони в сцене (как в SyntheticReplay).
    private func pinchOffset(mirror: Bool) -> SIMD3<Float> {
        let p = pose(pinch: 1, fist: 0, mirror: mirror), c = Self.palmCenter(p)
        let mid = (p[4] + p[8]) * 0.5 - c
        return Workspace.shapeRotation(config: config).act(mid * config.handScale)
    }

    private func hand(_ s: HandScript.State, mirror: Bool) -> (Hand2D, Float) {
        // Точка из сценария — щепоть (для кулака — ладонь).
        let palm = s.fist > 0.01 ? s.pos : s.pos - pinchOffset(mirror: mirror)
        let (scr, z) = Workspace.inverse(scene: palm, anchor: anchor, config: config)
        let sensor = SIMD2<Float>(scr.y, scr.x)
        let palmCam = intrinsics.ray(sensor) * z
        let p = pose(pinch: s.pinch, fist: s.fist, mirror: mirror)
        let c = Self.palmCenter(p)
        var pts = [SIMD2<Float>](repeating: .zero, count: 21)
        for k in 0..<21 {
            let d = p[k] - c
            let cam = palmCam + SIMD3(-d.y, d.x, d.z)
            pts[k] = SIMD2(cam.x / cam.z * intrinsics.fx + intrinsics.cx, cam.y / cam.z * intrinsics.fy + intrinsics.cy)
        }
        return (Hand2D(points: pts, conf: [Float](repeating: 0.9, count: 21), chirality: mirror ? .left : .right, goodCount: 21), z)
    }

    func frames(from: Double, to: Double) -> [(Double, [Hand2D], [Float?])] {
        let hz: Double = noisy ? 30 : 60
        var out: [(Double, [Hand2D], [Float?])] = []
        var t = (floor(from * hz) + 1) / hz
        var g = SystemRandomNumberGenerator()
        func n(_ s: Float) -> Float {
            let u1 = Float.random(in: 1e-6..<1, using: &g), u2 = Float.random(in: 0..<1, using: &g)
            return s * (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
        }
        while t <= to {
            var hs: [Hand2D] = [], zs: [Float?] = []
            for (script, mirror) in [(Optional(right), false), (left, true)] {
                guard let sc = script, let st = sc.state(at: t) else { continue }
                var (h, z) = hand(st, mirror: false)
                if mirror { h.chirality = .left }
                if noisy {
                    h.points = h.points.map { $0 + SIMD2(n(0.004), n(0.004)) }
                    z += n(0.006)
                }
                hs.append(h); zs.append(z)
            }
            if !hs.isEmpty { out.append((t, hs, zs)) }
            t += 1.0 / hz
        }
        return out
    }
}

// MARK: Демо без трекинга (изоляция ядра): траектории прямо в кисть

/// Виртуальная рука демо-сценария.
struct DemoHands {
    var hands = [SculptHand(), SculptHand()]
}

/// `-sculptdemo all|bench|art|pull|rotate|<траектория>[-noise]`: кисть получает точки напрямую, без трекинга.
final class SculptDemo {
    enum Step {
        case clear
        case brush(BrushKind, SIMD3<Float>?)
        case thickness(Float)
        case yaw(Float, Float)    // угол, наклон (рад)
        case draw(SculptTrajectory?, (Float) -> SIMD3<Float>, Double, (Float) -> Float, (Float) -> SIMD3<Float>)
        case line(SIMD3<Float>, SIMD3<Float>, Double)
        case wait(Double)
        case snap(String)
        case fistMove(SIMD3<Float>, SIMD3<Float>, Double)
        case bench
        case log(String)
        case allowEdit(Bool)
        case done
    }
    /// Можно ли щипком у мазка тянуть/продолжать его (в «картинах» — нет, каждый мазок новый).
    private(set) var allowEdit = true

    private var steps: [Step] = []
    private var idx = 0
    private var stepStart: Double = -1
    private var phase = 0
    let noisy: Bool
    private var noiseHold = SIMD3<Float>.zero
    private var noiseT: Double = 0
    private(set) var finished = false
    var currentTrajectory: SculptTrajectory?

    init(name: String) {
        var nm = name
        noisy = nm.hasSuffix("-noise")
        if noisy { nm = String(nm.dropLast("-noise".count)) }
        let C = SculptController.center
        let pressure: (Float) -> Float = { 0.5 + 0.5 * sin(.pi * $0) }
        /// «Ладонь» синтетической руки: непрерывная (перенос рамки вдоль пути) + плавный доворот на 216° за мазок.
        /// Раньше бралась cross(t, Z) — на участках, где путь идёт к камере, она перескакивала, и лента мялась
        /// не из-за кисти, а из-за самой синтетической руки.
        func normalFor(_ tr: @escaping (Float) -> SIMD3<Float>) -> (Float) -> SIMD3<Float> {
            let n = 400
            var tab: [SIMD3<Float>] = []
            var prev: SIMD3<Float>?
            for k in 0...n {
                let u = Float(k) / Float(n)
                let a = tr(max(0, u - 0.004)), b = tr(min(1, u + 0.004))
                let t = simd_normalize(b - a + SIMD3(0, 0, 1e-6))
                var side: SIMD3<Float>
                if let p = prev {
                    side = p - simd_dot(p, t) * t
                    side = simd_length_squared(side) > 1e-10 ? simd_normalize(side) : StrokeFrames.anyPerp(t)
                } else {
                    side = simd_normalize(simd_cross(t, [0, 0, 1]) + SIMD3(1e-4, 0, 0))
                }
                prev = side
                tab.append(simd_quatf(angle: u * .pi * 1.2, axis: t).act(side))
            }
            return { u in tab[min(n, max(0, Int((u * Float(n)).rounded())))] }
        }
        func drawTraj(_ tr: SculptTrajectory) -> Step {
            .draw(tr, { tr.point($0) }, tr.duration, pressure, normalFor { tr.point($0) })
        }
        var s: [Step] = [.wait(1.0)]
        let base: [SculptTrajectory] = [.spiral, .s, .wave]
        switch nm {
        case "bench":
            s += [.bench]
        case "art":
            s += SculptDemo.art()
        case "pull":
            s += SculptDemo.pullScript()
        case "rotate":
            s += [.clear, .brush(.plasticine, nil), drawTraj(.s), .wait(0.6), .snap("sculpt-rotate-before"),
                  .fistMove(C + SIMD3(-0.10, -0.02, 0), C + SIMD3(-0.02, -0.02, 0), 1.0), .wait(1.2), .snap("sculpt-rotate-after")]
        case "all":
            for k in BrushKind.allCases {
                for tr in base {
                    s += [.clear, .brush(k, nil), drawTraj(tr), .wait(0.7), .snap("sculpt-\(k.key)-\(tr.rawValue)" + (noisy ? "-noise" : ""))]
                }
            }
            s += SculptDemo.pullScript()
            s += [.clear, .brush(.plasticine, nil), drawTraj(.s), .wait(0.6),
                  .fistMove(C + SIMD3(-0.10, -0.02, 0), C + SIMD3(-0.02, -0.02, 0), 1.0), .wait(1.2), .snap("sculpt-rotate-after")]
            s += SculptDemo.art()
        default:
            if let tr = SculptTrajectory(rawValue: nm) {
                for k in BrushKind.allCases {
                    s += [.clear, .brush(k, nil), drawTraj(tr), .wait(0.7), .snap("sculpt-\(k.key)-\(tr.rawValue)" + (noisy ? "-noise" : ""))]
                }
            } else if let k = BrushKind.parse(nm) {
                for tr in base {
                    s += [.clear, .brush(k, nil), drawTraj(tr), .wait(0.7), .snap("sculpt-\(k.key)-\(tr.rawValue)" + (noisy ? "-noise" : ""))]
                }
            }
        }
        s += [.log("DEMO DONE"), .done]
        steps = s
    }

    /// Пластилин: мазок 6 см → тяга конца 25 см → тяга за середину.
    static func pullScript() -> [Step] {
        let C = SculptController.center
        let a = C + SIMD3(-0.03, 0, 0), b = C + SIMD3(0.03, 0, 0)
        let tr = SculptTrajectory.pull
        let mid = C
        let up = SIMD3<Float>(0, 0.04, 0.01)
        return [
            .clear, .brush(.plasticine, nil),
            .line(a, b, 0.8), .wait(0.5), .snap("sculpt-plasticine-pull-0"),
            .draw(nil, { tr.point($0) }, tr.duration, { _ in 1 }, { _ in [0, 0, 1] }),
            .wait(0.7), .snap("sculpt-plasticine-pull-end"),
            .draw(nil, { mid + up * HandScript.ease($0) }, 0.8, { _ in 1 }, { _ in [0, 0, 1] }),
            .wait(0.7), .snap("sculpt-plasticine-pull-mid"),
            .yaw(0.6, 0.25), .wait(0.3), .snap("sculpt-plasticine-pull-turned"), .yaw(0, 0),
        ]
    }

    /// Три «картины» из нескольких кистей, снимки с разных сторон.
    static func art() -> [Step] {
        let C = SculptController.center
        func knot(_ scale: Float, _ off: SIMD3<Float>, p: Float = 2, q: Float = 3, h: Float = 0.024) -> (Float) -> SIMD3<Float> {
            { u in
                let t = 2 * Float.pi * u
                let r = (0.045 + 0.022 * cos(q * t)) * scale
                return C + off + SIMD3(r * cos(p * t), h * scale * sin(q * t), r * sin(p * t))
            }
        }
        func helix(_ r: Float, _ turns: Float, _ h: Float, _ off: SIMD3<Float>) -> (Float) -> SIMD3<Float> {
            { u in
                let a = 2 * Float.pi * turns * u
                return C + off + SIMD3(r * cos(a), -h / 2 + h * u, r * sin(a))
            }
        }
        let press: (Float) -> Float = { 0.55 + 0.45 * sin(.pi * $0) }
        let full: (Float) -> Float = { _ in 0.9 }
        func twist(_ f: @escaping (Float) -> SIMD3<Float>, _ turns: Float) -> (Float) -> SIMD3<Float> {
            { u in
                let a = f(max(0, u - 0.004)), b = f(min(1, u + 0.004))
                let t = simd_normalize(b - a + SIMD3(0, 0, 1e-6))
                let side = simd_normalize(simd_cross(t, [0, 1, 0]) + SIMD3(1e-4, 0, 0))
                return simd_quatf(angle: u * .pi * turns, axis: t).act(side)
            }
        }
        let z: (Float) -> SIMD3<Float> = { _ in [0, 0, 1] }
        var s: [Step] = [.allowEdit(false)]
        // 1. Глина: узел-трилистник + спираль-основание + капля.
        s += [.clear,
              .brush(.plasticine, Palette.colors[0]), .thickness(1.3), .draw(nil, knot(1.15, [0, 0.02, 0]), 5, full, z),
              .brush(.plasticine, Palette.colors[2]), .thickness(0.7), .draw(nil, helix(0.075, 2.2, 0.03, [0, -0.06, 0]), 4, press, z),
              .brush(.plasticine, Palette.colors[1]), .thickness(0.9), .draw(nil, helix(0.02, 1.5, 0.08, [0, 0.03, 0]), 2.5, press, z),
              .thickness(1), .wait(0.5), .yaw(0.35, 0.2), .wait(0.2), .snap("sculpt-art-clay-1"), .yaw(1.6, 0.35), .wait(0.2), .snap("sculpt-art-clay-2"), .yaw(0, 0)]
        // 2. Свет: неоновый узел, пыль-спираль, плазма-дуга.
        s += [.clear,
              .brush(.neon, [0.2, 0.85, 1.0]), .draw(nil, knot(1.1, [0, 0.01, 0], p: 3, q: 4), 5, full, z),
              .brush(.neon, [1.0, 0.3, 0.75]), .draw(nil, helix(0.085, 1.0, 0.05, [0, 0, 0]), 3, full, z),
              .brush(.stardust, Palette.colors[6]), .thickness(1.6), .draw(nil, helix(0.06, 3, 0.14, [0, 0, 0]), 4, press, z),
              .brush(.plasma, [0.62, 0.42, 1.0]), .thickness(1), .draw(nil, { u in C + SIMD3(-0.1 + 0.2 * u, 0.07 + 0.03 * sin(.pi * u), -0.02) }, 1.5, full, z),
              .wait(0.4), .yaw(0.4, 0.15), .wait(0.2), .snap("sculpt-art-light-1"), .yaw(-0.9, 0.3), .wait(0.2), .snap("sculpt-art-light-2"), .yaw(0, 0)]
        // 3. Шёлк вокруг хрома.
        let chromeKnot = knot(0.85, [0, 0, 0])
        s += [.clear,
              .brush(.chrome, Palette.colors[9]), .thickness(1.4), .draw(nil, chromeKnot, 5, full, z),
              .brush(.chrome, [0.95, 0.75, 0.35]), .thickness(0.8), .draw(nil, helix(0.09, 1.4, 0.10, [0, 0, 0]), 3, press, z),
              .brush(.silk, Palette.colors[4]), .thickness(1.5), .draw(nil, helix(0.065, 2.0, 0.12, [0, 0, 0]), 4, press, twist(helix(0.065, 2.0, 0.12, [0, 0, 0]), 2)),
              .brush(.silk, Palette.colors[3]), .draw(nil, { u in C + SIMD3(-0.11 + 0.22 * u, 0.06 * sin(2 * .pi * u), 0.04 * cos(3 * .pi * u)) }, 3, press,
                                                       twist({ u in C + SIMD3(-0.11 + 0.22 * u, 0.06 * sin(2 * .pi * u), 0.04 * cos(3 * .pi * u)) }, 3)),
              .thickness(1), .wait(0.5), .yaw(0.5, 0.25), .wait(0.2), .snap("sculpt-art-silk-chrome-1"), .yaw(2.2, 0.1), .wait(0.2), .snap("sculpt-art-silk-chrome-2"), .yaw(0, 0)]
        s.append(.allowEdit(true))
        return s
    }

    /// Текущий шаг. Контроллер вызывает каждый кадр; возвращает виртуальные руки или команду.
    enum Action { case none, clear, brush(BrushKind, SIMD3<Float>?), thickness(Float), yaw(Float, Float), snap(String), bench, log(String) }

    func step(now: Double, hands: inout DemoHands) -> Action {
        hands = DemoHands()
        guard idx < steps.count else { finished = true; return .none }
        if stepStart < 0 { stepStart = now; phase = 0 }
        let t = now - stepStart
        func next() { idx += 1; stepStart = -1 }
        switch steps[idx] {
        case .clear: next(); return .clear
        case .brush(let k, let c): next(); return .brush(k, c)
        case .thickness(let v): next(); return .thickness(v)
        case .yaw(let a, let p): next(); return .yaw(a, p)
        case .snap(let n):
            // Снимок делает главный поток — сцену не трогаем ещё 0,3 с.
            if phase == 0 { phase = 1; return .snap(n) }
            if t >= 0.3 { next() }
            return .none
        case .log(let s): next(); return .log(s)
        case .bench: next(); return .bench
        case .done: finished = true; next(); return .none
        case .allowEdit(let v): allowEdit = v; next(); return .none
        case .wait(let d):
            if t >= d { next() }
            return .none
        case .line(let a, let b, let d):
            return pinchPath(t: t, d: d, f: { a + (b - a) * $0 }, p: { _ in 1 }, n: { _ in [0, 0, 1] }, hands: &hands, next: next)
        case .draw(let tr, let f, let d, let p, let n):
            currentTrajectory = tr
            return pinchPath(t: t, d: d, f: f, p: p, n: n, hands: &hands, next: next)
        case .fistMove(let a, let b, let d):
            var h = SculptHand()
            h.visible = true; h.fist = true
            let u = Float(min(1, max(0, (t - 0.2) / d)))
            h.palm = a + (b - a) * HandScript.ease(u)
            h.pinchPoint = h.palm
            if t > d + 0.4 { h.fist = false }
            hands.hands[0] = h
            if t > d + 0.6 { next() }
            return .none
        }
    }

    /// Щипок: 0,2 с щипок на месте → путь → отпустить (0,2 с без щипка до следующего шага).
    private func pinchPath(t: Double, d: Double, f: (Float) -> SIMD3<Float>, p: (Float) -> Float, n: (Float) -> SIMD3<Float>,
                           hands: inout DemoHands, next: () -> Void) -> Action {
        var h = SculptHand()
        h.visible = true
        let u = Float(min(1, max(0, (t - 0.05) / d)))
        var pos = f(u)
        if noisy {
            // Шум «как у трекинга»: 30 Гц, σ ≈ 2 мм.
            if t - noiseT > 1.0 / 30 || t < noiseT {
                noiseT = t
                var g = SystemRandomNumberGenerator()
                func gauss() -> Float {
                    let u1 = Float.random(in: 1e-6..<1, using: &g), u2 = Float.random(in: 0..<1, using: &g)
                    return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
                }
                noiseHold = SIMD3(gauss(), gauss(), gauss()) * 0.002
            }
            pos += noiseHold
        }
        h.pinchPoint = pos
        h.palm = pos
        h.palmNormal = n(u)
        h.pinching = t < d + 0.05
        h.pinchD = 0.55 - 0.4 * clampf(p(u), 0, 1)
        hands.hands[1] = h
        if t > d + 0.35 { next() }
        return .none
    }
}
