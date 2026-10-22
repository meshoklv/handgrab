import Foundation
import simd

/// «Звёздная пыль»: билборды вдоль пути (разворот к камере — в вершинном шейдере), 3–6 точек на шаг.
/// Точки детерминированы (зерно мазка + номер узла): перестройка куска даёт те же самые точки.
enum DustEmitter {
    static func mesh(nodes: [StrokeNode], range: ClosedRange<Int>, lastChunk: Bool, seed: UInt32,
                     color: SIMD3<Float>, spread: (Int) -> Float, into m: inout MeshBuffers) {
        let upper = lastChunk ? range.upperBound : range.upperBound - 1
        guard upper >= range.lowerBound else { return }
        m.uv2.reserveCapacity((upper - range.lowerBound + 1) * 6 * 8)
        for i in range.lowerBound...upper {
            let nd = nodes[i]
            var speed: Float = 0.2
            if i > 0 {
                let dt = nd.t - nodes[i - 1].t
                if dt > 1e-4 { speed = simd_distance(nd.p, nodes[i - 1].p) / dt }
            }
            let count = 3 + Int(clampf(speed / 0.35, 0, 1) * 3.0)
            let sp = spread(i) * 1.5
            for k in 0..<count {
                let key = Int32(truncatingIfNeeded: i &* 8 &+ k)
                func h(_ salt: UInt32) -> Float { hgHash(key, seed &+ salt) }
                // Точка в шаре (плотнее к центру).
                let dir = simd_normalize(SIMD3<Float>(h(1) * 2 - 1, h(2) * 2 - 1, h(3) * 2 - 1) + SIMD3(1e-4, 0, 0))
                let rad = pow(h(4), 1.6) * sp
                let c = nd.p + dir * rad
                let size = (0.0008 + h(5) * 0.0017) * 0.5
                let s = h(6)
                // Цвет: оттенок ±25°, яркость 0,6…1,5 (HDR под bloom).
                var col = hgHueShift(color, degrees: (h(7) - 0.5) * 50)
                col = col * (0.6 + h(8) * 0.9)
                if h(9) > 0.9 { col = SIMD3(repeating: 1.6) }   // редкие белые искры
                let c4 = SIMD4(col, 1)
                let base = UInt32(m.vertexCount)
                for (u, v) in [(Float(0), Float(0)), (1, 0), (1, 1), (0, 1)] {
                    m.vertex(c, [0, 0, 1], SIMD2(u, v), c4)
                    m.uv2.append(s); m.uv2.append(size)
                }
                m.idx += [base, base + 1, base + 2, base, base + 2, base + 3]
            }
        }
    }
}
