import Foundation
import simd

/// Узел мазка (локальные координаты скульптуры, м).
struct StrokeNode: Codable {
    var p: SIMD3<Float>
    /// Радиус трубки / полуширина ленты / разброс пыли.
    var r: Float
    /// Нормаль ленты (ориентация ладони); для трубок не используется.
    var n: SIMD3<Float>
    /// Время от начала мазка, с.
    var t: Float
}

/// Мазок: узлы + кисть + цвет. Значимый тип — копии дешёвые (стек отмены хранит снимки).
struct StrokeData: Codable {
    var id: Int
    var kind: BrushKind
    var color: SIMD3<Float>
    var seed: UInt32
    var nodes: [StrokeNode]
    /// Мазок закончен (у кистей без полусфер — сужение конца).
    var finished: Bool

    var length: Float {
        var l: Float = 0
        for i in stride(from: 1, to: nodes.count, by: 1) { l += simd_distance(nodes[i].p, nodes[i - 1].p) }
        return l
    }

    /// Зеркальная копия по X (локальная плоскость YZ).
    func mirrored(id: Int) -> StrokeData {
        var m = self
        m.id = id
        m.seed = seed &+ 7919
        m.nodes = nodes.map { var q = $0; q.p.x = -q.p.x; q.n.x = -q.n.x; return q }
        return m
    }
}

/// Файл .hgsculpt — все мазки сцены.
struct SculptFile: Codable {
    var version = 1
    var strokes: [StrokeData]
}

/// Рамка сечения: касательная, нормаль, бинормаль + длина дуги от начала.
struct RingFrame {
    var t: SIMD3<Float>
    var n: SIMD3<Float>
    var b: SIMD3<Float>
    var s: Float
}

enum StrokeFrames {
    /// Пересчитать рамки начиная с узла `from` (параллельный перенос от предыдущей рамки).
    /// Излом > 150° — рамка переинициализируется, чтобы трубка не перекручивалась.
    static func update(_ nodes: [StrokeNode], from: Int, frames f: inout [RingFrame]) {
        let n = nodes.count
        if f.count > n { f.removeLast(f.count - n) }
        guard n > 0 else { return }
        let start = max(0, min(from, f.count))
        if f.count < n { f.reserveCapacity(n) }
        for i in start..<n {
            let p = nodes[i].p
            var t: SIMD3<Float>
            if n == 1 { t = [0, 0, -1] } else {
                let a = nodes[max(i - 1, 0)].p, b = nodes[min(i + 1, n - 1)].p
                t = b - a
                if simd_length_squared(t) < 1e-14 { t = i > 0 ? f[i - 1].t : [0, 0, -1] }
                t = simd_normalize(t)
            }
            var nn: SIMD3<Float>
            var s: Float = 0
            if i > 0 {
                let prev = f[i - 1]
                s = prev.s + simd_distance(p, nodes[i - 1].p)
                if simd_dot(prev.t, t) < cos(150 * Float.pi / 180) {
                    nn = anyPerp(t)
                } else {
                    nn = prev.n - simd_dot(prev.n, t) * t
                    if simd_length_squared(nn) < 1e-8 { nn = anyPerp(t) } else { nn = simd_normalize(nn) }
                }
            } else {
                nn = anyPerp(t)
            }
            let fr = RingFrame(t: t, n: nn, b: simd_cross(t, nn), s: s)
            if i < f.count { f[i] = fr } else { f.append(fr) }
        }
    }

    static func anyPerp(_ t: SIMD3<Float>) -> SIMD3<Float> {
        let up: SIMD3<Float> = abs(t.y) < 0.9 ? [0, 1, 0] : [1, 0, 0]
        return simd_normalize(simd_cross(simd_cross(t, up), t))
    }
}

/// Автопроверки мазка (строка STROKE в журнале).
enum StrokeMetrics {
    struct Result {
        var nodes = 0
        var length: Float = 0
        var maxStepRatio: Float = 0
        var maxTwistDeg: Float = 0
        var jitterMM: Float = 0
    }

    static func measure(_ s: StrokeData, frames: [RingFrame]) -> Result {
        var r = Result()
        let nodes = s.nodes
        r.nodes = nodes.count
        guard nodes.count > 2 else { return r }
        let step = BrushPreset.of(s.kind).ringStep
        var jit: Float = 0
        for i in 1..<nodes.count {
            let d = simd_distance(nodes[i].p, nodes[i - 1].p)
            r.length += d
            r.maxStepRatio = max(r.maxStepRatio, d / step)
            if i < frames.count {
                let c = clampf(simd_dot(frames[i].n, frames[i - 1].n), -1, 1)
                r.maxTwistDeg = max(r.maxTwistDeg, acos(c) * 180 / .pi)
            }
            if i >= 2 { jit += simd_length(nodes[i].p - 2 * nodes[i - 1].p + nodes[i - 2].p) }
        }
        r.jitterMM = jit / Float(nodes.count - 2) * 1000
        return r
    }
}
