import Foundation
import simd

/// Вытягивание пластилина за кольцо: соседи тянутся с весом exp(−(d/L)²), растянутое добирается кольцами,
/// объём сохраняется (r = r0/√растяжение, не тоньше 0,35·r0). После отпускания — «оседание».
struct PlasticinePull {
    let strokeID: Int
    let ring: Int
    let orig: [StrokeNode]
    private let arc: [Float]
    let g0: SIMD3<Float>
    let step: Float
    /// Окно изменённых узлов в последнем результате (для оседания).
    private(set) var window: ClosedRange<Int> = 0...0
    private(set) var maxShift: Float = 0

    init(stroke: StrokeData, ring: Int, grab: SIMD3<Float>) {
        strokeID = stroke.id
        self.ring = ring
        orig = stroke.nodes
        var a = [Float](repeating: 0, count: orig.count)
        for i in stride(from: 1, to: orig.count, by: 1) { a[i] = a[i - 1] + simd_distance(orig[i].p, orig[i - 1].p) }
        arc = a
        g0 = grab
        step = BrushPreset.of(stroke.kind).ringStep
    }

    /// Новая центральная линия при щепоти в точке g.
    mutating func apply(grab g: SIMD3<Float>) -> [StrokeNode] {
        let delta = g - g0
        let dl = simd_length(delta)
        maxShift = max(maxShift, dl)
        let L: Float = 0.03 + 0.5 * dl
        let a0 = arc[ring]
        // Окно, где вес заметен.
        let reach = L * 2.6
        var j0 = ring, j1 = ring
        while j0 > 0 && a0 - arc[j0 - 1] < reach { j0 -= 1 }
        while j1 < orig.count - 1 && arc[j1 + 1] - a0 < reach { j1 += 1 }
        if dl < 1e-5 { window = j0...j1; return orig }
        var disp = Array(orig[j0...j1])
        for k in disp.indices {
            let d = abs(arc[j0 + k] - a0) / L
            disp[k].p += delta * exp(-d * d)
        }
        // Пересэмплировать окно ровным шагом; радиус по растяжению.
        var out: [StrokeNode] = []
        out.reserveCapacity(orig.count + 64)
        out.append(contentsOf: orig[0..<j0])
        var seg = [Float](repeating: 0, count: disp.count)
        var total: Float = 0
        for k in 1..<max(disp.count, 1) {
            seg[k] = simd_distance(disp[k].p, disp[k - 1].p)
            total += seg[k]
        }
        let m = max(1, Int((total / step).rounded()))
        var k = 1
        var acc: Float = 0
        let startIdx = out.count
        out.append(disp[0])
        if disp.count >= 2 {
            for q in 1..<m {
                let target = Float(q) * total / Float(m)
                while k < disp.count - 1 && acc + seg[k] < target { acc += seg[k]; k += 1 }
                let u = seg[k] > 1e-7 ? (target - acc) / seg[k] : 0
                var nd = lerpNode(disp[k - 1], disp[k], clampf(u, 0, 1))
                let o0 = orig[j0 + k - 1], o1 = orig[j0 + k]
                let origLen = max(simd_distance(o0.p, o1.p), 1e-6)
                let stretch = seg[k] / origLen
                let r0 = o0.r + (o1.r - o0.r) * u
                nd.r = clampf(r0 / max(stretch, 0.4).squareRoot(), 0.35 * r0, 1.6 * r0)
                out.append(nd)
            }
            out.append(disp[disp.count - 1])
        }
        window = startIdx...(out.count - 1)
        out.append(contentsOf: orig[(j1 + 1)...])
        // Конец мазка внутри окна — радиус как у соседа (иначе на тонкой вытянутой части торчит толстая «головка»).
        if j0 == 0, window.count > 2 { out[window.lowerBound].r = out[window.lowerBound + 1].r }
        if j1 == orig.count - 1, window.count > 2 { out[window.upperBound].r = out[window.upperBound - 1].r }
        // Центральная линия в окне — лёгкое сглаживание (пересэмплирование даёт мелкие изломы).
        if window.count > 4 {
            for _ in 0..<2 {
                let src = out.map(\.p)
                for i in (window.lowerBound + 1)..<window.upperBound {
                    out[i].p = src[i] + ((src[i - 1] + src[i + 1]) * 0.5 - src[i]) * 0.35
                }
            }
        }
        // Радиус в окне — сгладить (растяжение по отрезкам ступенчатое).
        if window.count > 4 {
            var rr = out.map(\.r)
            for _ in 0..<4 {
                let src = rr
                for i in (window.lowerBound + 1)..<window.upperBound { rr[i] = (src[i - 1] + 2 * src[i] + src[i + 1]) / 4 }
                if j0 == 0 { rr[window.lowerBound] = rr[window.lowerBound + 1] }
                if j1 == orig.count - 1 { rr[window.upperBound] = rr[window.upperBound - 1] }
            }
            for i in window { out[i].r = rr[i] }
        }
        return out
    }
}

/// Оседание после отпускания: 3 прохода сглаживания с затуханием + отдача радиуса (+5%, пружина ζ = 0,6).
struct SettleAnim {
    let strokeID: Int
    let start: Double
    var window: ClosedRange<Int>
    var passesDone = 0
    let duration: Double = 0.4

    /// Множитель радиуса в момент t (0…duration): затухающее колебание вокруг 1, первый пик ≈ +5%.
    func radiusScale(now: Double) -> Float {
        let t = Float(now - start)
        let zeta: Float = 0.6, w: Float = 2 * .pi * 3.2
        let wd = w * (1 - zeta * zeta).squareRoot()
        return 1 + 0.125 * exp(-zeta * w * t) * sin(wd * t)
    }

    /// Нужен ли проход сглаживания (в 0, 0,13 и 0,26 с); возвращает силу.
    mutating func smoothingPass(now: Double) -> Float? {
        let t = now - start
        let times = [0.0, 0.13, 0.26]
        guard passesDone < times.count, t >= times[passesDone] else { return nil }
        let strength: Float = [0.5, 0.33, 0.2][passesDone]
        passesDone += 1
        return strength
    }

    static func smooth(_ nodes: inout [StrokeNode], window: ClosedRange<Int>, strength: Float) {
        guard window.count > 2 else { return }
        let src = nodes.map(\.p)
        for i in (window.lowerBound + 1)..<window.upperBound where i > 0 && i < nodes.count - 1 {
            let lap = (src[i - 1] + src[i + 1]) * 0.5 - src[i]
            nodes[i].p = src[i] + lap * strength
        }
    }
}

/// Скругление стыка: при продолжении линии от кончика рука почти всегда уходит под углом к старому концу —
/// участок ±half по дуге заменяется гладкой кривой Эрмита с теми же касательными на краях (без излома, G1).
enum StrokeSmoothing {
    @discardableResult
    static func roundCorner(_ nodes: inout [StrokeNode], at j: Int, half: Float) -> ClosedRange<Int>? {
        let n = nodes.count
        guard n >= 6, j > 1, j < n - 2 else { return nil }
        var lo = j, hi = j
        var a: Float = 0
        while lo > 1 && a < half { a += simd_distance(nodes[lo].p, nodes[lo - 1].p); lo -= 1 }
        var b: Float = 0
        while hi < n - 2 && b < half { b += simd_distance(nodes[hi + 1].p, nodes[hi].p); hi += 1 }
        guard hi - lo >= 4, a > 1e-4, b > 1e-4 else { return nil }
        // Перекрут мал — не трогать (линия и так гладкая).
        let tin = nodes[j].p - nodes[lo].p, tout = nodes[hi].p - nodes[j].p
        if simd_dot(simd_normalize(tin), simd_normalize(tout)) > 0.995 { return nil }
        let p0 = nodes[lo].p, p1 = nodes[hi].p
        var t0 = nodes[lo].p - nodes[lo - 1].p, t1 = nodes[hi + 1].p - nodes[hi].p
        t0 = simd_length_squared(t0) > 1e-14 ? simd_normalize(t0) : simd_normalize(tin)
        t1 = simd_length_squared(t1) > 1e-14 ? simd_normalize(t1) : simd_normalize(tout)
        let L = (a + b) * 0.9
        // Параметр — доля исходной длины дуги (шаг колец почти сохраняется).
        var arc = [Float](repeating: 0, count: hi - lo + 1)
        for k in 1..<arc.count { arc[k] = arc[k - 1] + simd_distance(nodes[lo + k].p, nodes[lo + k - 1].p) }
        let total = max(arc[arc.count - 1], 1e-6)
        for k in 1..<(arc.count - 1) {
            let u = arc[k] / total
            let u2 = u * u, u3 = u2 * u
            let h00 = 2 * u3 - 3 * u2 + 1, h10 = u3 - 2 * u2 + u, h01 = -2 * u3 + 3 * u2, h11 = u3 - u2
            nodes[lo + k].p = p0 * h00 + t0 * (L * h10) + p1 * h01 + t1 * (L * h11)
        }
        return lo...hi
    }
}
