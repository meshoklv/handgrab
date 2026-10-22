import Foundation
import simd

/// Стабилизатор кисти: 1€ фильтр (в миллиметрах, чтобы β имел смысл) → «поводок» (lazy brush).
struct StrokeStabilizer {
    static let defaultMinCutoff: Float = 1.2
    static let defaultBeta: Float = 0.04
    var euro = OneEuroFilterV<SIMD3<Float>>(minCutoff: StrokeStabilizer.defaultMinCutoff, beta: StrokeStabilizer.defaultBeta, dCutoff: 1.0)
    /// Радиус поводка, м.
    var leash: Float = 0.006
    private(set) var brush: SIMD3<Float>?
    private(set) var filtered: SIMD3<Float>?

    mutating func reset() { euro.reset(); brush = nil; filtered = nil }

    /// Начать с точки кисти (продолжение мазка — с его конца).
    mutating func begin(at p: SIMD3<Float>) {
        euro.reset()
        brush = p
        filtered = p
    }

    /// Сырая точка щипка → точка кисти.
    @discardableResult
    mutating func feed(_ raw: SIMD3<Float>, t: Double) -> SIMD3<Float> {
        let f = euro.filter(raw * 1000, t: t) / 1000
        filtered = f
        guard let b = brush else { brush = f; return f }
        let d = f - b
        let l = simd_length(d)
        if l > leash {
            brush = b + d * ((l - leash) / l)
        }
        return brush!
    }
}

/// Строитель мазка: контрольные точки каждые 3 шага колец → centripetal Catmull–Rom с подшагами (кольца ≈ шаг).
/// Узлы делятся на «зафиксированные» и «хвост» (линейно от последней фиксированной до кисти, перестраивается каждый кадр).
struct StrokeBuilder {
    let ringStep: Float
    var ctrlStep: Float { ringStep * 3 }
    private var ctrl: [StrokeNode] = []
    /// Точка «до первой» (продолжение старого мазка) — для гладкого стыка.
    private var phantomHead: SIMD3<Float>?
    /// Сколько узлов мазка зафиксировано.
    private(set) var committed = 0
    /// Сколько контрольных отрезков уже превращено в кольца.
    private var segDone = 0

    init(ringStep: Float) { self.ringStep = ringStep }

    /// Новый мазок с первой точки.
    mutating func start(_ first: StrokeNode, nodes: inout [StrokeNode]) {
        ctrl = [first]; phantomHead = nil; segDone = 0
        nodes = [first]
        committed = 1
    }

    /// Продолжение существующего мазка с его конца.
    mutating func resume(nodes: [StrokeNode]) {
        guard let last = nodes.last else { return }
        ctrl = [last]
        phantomHead = nodes.count >= 4 ? nodes[nodes.count - 4].p : nil
        segDone = 0
        committed = nodes.count
    }

    /// Добавить положение кисти. Возвращает индекс первого изменённого узла.
    @discardableResult
    mutating func add(_ b: StrokeNode, nodes: inout [StrokeNode]) -> Int {
        let firstDirty = max(0, committed - 1)
        // Контрольные точки ровно через ctrlStep (большой скачок — несколько точек по прямой).
        if var last = ctrl.last {
            var d = simd_distance(b.p, last.p)
            while d >= ctrlStep {
                let k = ctrlStep / d
                last = lerpNode(last, b, k)
                ctrl.append(last)
                d = simd_distance(b.p, last.p)
            }
        }
        // Готовы отрезки ctrl[i]→ctrl[i+1], у которых есть ctrl[i+2].
        nodes.removeLast(nodes.count - committed)
        while segDone + 2 < ctrl.count {
            appendSegment(segDone, end: false, nodes: &nodes)
            segDone += 1
        }
        committed = nodes.count
        // Сборка памяти: старые контрольные точки не нужны (храним 3 для гладкости).
        if segDone > 4 {
            let drop = segDone - 3
            if drop > 0 {
                phantomHead = ctrl[drop - 1].p
                ctrl.removeFirst(drop)
                segDone -= drop
            }
        }
        // Хвост: от последнего зафиксированного узла по оставшимся контрольным точкам до кисти.
        var tailPts = Array(ctrl[segDone...])
        tailPts.append(b)
        var prev = nodes[nodes.count - 1]
        for q in tailPts.dropFirst() {
            let d = simd_distance(prev.p, q.p)
            let m = Int(d / ringStep)
            if m >= 1 {
                for k in 1...m { nodes.append(lerpNode(prev, q, Float(k) * ringStep / d)) }
            }
            if let l = nodes.last, simd_distance(l.p, q.p) > ringStep * 0.3 { nodes.append(q) } else if !nodes.isEmpty, nodes.count > committed {
                nodes[nodes.count - 1] = q
            }
            prev = nodes[nodes.count - 1]
        }
        return min(firstDirty, committed - 1)
    }

    /// Конец мазка: дотянуть до точки щипка, зафиксировать всё.
    mutating func finish(at b: StrokeNode, nodes: inout [StrokeNode]) {
        add(b, nodes: &nodes)
        nodes.removeLast(nodes.count - committed)
        if let l = ctrl.last, simd_distance(l.p, b.p) > ringStep { ctrl.append(b) }
        while segDone + 1 < ctrl.count {
            appendSegment(segDone, end: true, nodes: &nodes)
            segDone += 1
        }
        committed = nodes.count
    }

    private mutating func appendSegment(_ i: Int, end: Bool, nodes: inout [StrokeNode]) {
        let p1 = ctrl[i], p2 = ctrl[i + 1]
        let p0 = i > 0 ? ctrl[i - 1].p : (phantomHead ?? (2 * p1.p - p2.p))
        let p3 = i + 2 < ctrl.count ? ctrl[i + 2].p : 2 * p2.p - p1.p
        let chord = simd_distance(p1.p, p2.p)
        let m = max(1, Int((chord / ringStep).rounded()))
        for k in 1...m {
            let u = Float(k) / Float(m)
            var q = lerpNode(p1, p2, u)
            q.p = StrokeBuilder.catmullRom(p0, p1.p, p2.p, p3, u)
            nodes.append(q)
        }
    }

    static func catmullRom(_ p0: SIMD3<Float>, _ p1: SIMD3<Float>, _ p2: SIMD3<Float>, _ p3: SIMD3<Float>, _ u: Float) -> SIMD3<Float> {
        func knot(_ ti: Float, _ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float { ti + max(simd_distance(a, b).squareRoot(), 1e-4) }
        let t0: Float = 0, t1 = knot(t0, p0, p1), t2 = knot(t1, p1, p2), t3 = knot(t2, p2, p3)
        let t = t1 + (t2 - t1) * u
        let a1 = (t1 - t) / (t1 - t0) * p0 + (t - t0) / (t1 - t0) * p1
        let a2 = (t2 - t) / (t2 - t1) * p1 + (t - t1) / (t2 - t1) * p2
        let a3 = (t3 - t) / (t3 - t2) * p2 + (t - t2) / (t3 - t2) * p3
        let b1 = (t2 - t) / (t2 - t0) * a1 + (t - t0) / (t2 - t0) * a2
        let b2 = (t3 - t) / (t3 - t1) * a2 + (t - t1) / (t3 - t1) * a3
        return (t2 - t) / (t2 - t1) * b1 + (t - t1) / (t2 - t1) * b2
    }
}

@inline(__always) func lerpNode(_ a: StrokeNode, _ b: StrokeNode, _ u: Float) -> StrokeNode {
    var n = a.n + (b.n - a.n) * u
    if simd_length_squared(n) > 1e-8 { n = simd_normalize(n) } else { n = b.n }
    return StrokeNode(p: a.p + (b.p - a.p) * u, r: a.r + (b.r - a.r) * u, n: n, t: a.t + (b.t - a.t) * u)
}
