import Foundation
import simd

/// «Плазма»: три тонкие нити по пути + ответвления. Изломы молнии считает вершинный шейдер
/// (3 октавы шума по длине дуги, новый узор каждые 2 кадра) — CPU геометрию не трогает.
/// uv  = (u по окружности, огибающая амплитуды 0…1); uv2 = (длина дуги, зерно нити).
enum PlasmaMesher {
    static func mesh(nodes: [StrokeNode], frames: [RingFrame], range: ClosedRange<Int>, seed: UInt32,
                     total: Float, finished: Bool, color: SIMD3<Float>, into m: inout MeshBuffers) {
        guard range.count >= 2 else { return }
        let strands: [(Float, Float, SIMD3<Float>)] = [
            (1.0, 0.1, SIMD3(repeating: 1)),                       // белое ядро
            (0.55, 0.37, color),
            (0.45, 0.73, simd_mix(color, SIMD3(1, 1, 1), SIMD3(repeating: 0.4))),
        ]
        func env(_ s: Float) -> Float {
            let a = hgSmoothstep(0, 0.012, s)
            let b = finished ? hgSmoothstep(0, 0.012, total - s) : 1
            return a * b
        }
        for (rk, sd, col) in strands {
            var rings: [TubeRing] = []
            rings.reserveCapacity(range.count)
            for i in range {
                let f = frames[i]
                var r = TubeRing(c: nodes[i].p, n: f.n, b: f.b, t: f.t, r: nodes[i].r * rk, tilt: 0, v: env(f.s), col: SIMD4(col, 1))
                r.aux = SIMD2(f.s, sd + Float(seed % 97) * 0.013)
                rings.append(r)
            }
            TubeMesher.mesh(rings, sides: 5, into: &m, withAux: true)
        }
        // Ответвления: примерно каждые 3 см с вероятностью 35%, длина 2–5 см.
        let every = 15
        for i in range where i % every == 7 && i < range.upperBound {
            let key = Int32(truncatingIfNeeded: i)
            if hgHash(key, seed &+ 11) > 0.35 { continue }
            let f = frames[i]
            let len = 0.02 + hgHash(key, seed &+ 12) * 0.03
            let ang = hgHash(key, seed &+ 13) * 2 * Float.pi
            let perp = f.n * cos(ang) + f.b * sin(ang)
            var dir = simd_normalize(f.t * 0.8 + perp * (0.6 + hgHash(key, seed &+ 14) * 0.6))
            var pts: [StrokeNode] = [nodes[i]]
            let segs = 10
            for k in 1...segs {
                let kk = Int32(truncatingIfNeeded: Int(key) &* 16 &+ k)
                let jitter = SIMD3<Float>(hgHash(kk, seed &+ 21), hgHash(kk, seed &+ 22), hgHash(kk, seed &+ 23)) * 2 - 1
                dir = simd_normalize(dir + jitter * 0.45)
                var q = pts[k - 1]
                q.p += dir * (len / Float(segs))
                q.r = nodes[i].r * 0.6 * (1 - Float(k) / Float(segs + 1))
                pts.append(q)
            }
            var bf: [RingFrame] = []
            StrokeFrames.update(pts, from: 0, frames: &bf)
            var rings: [TubeRing] = []
            for k in 0..<pts.count {
                let e = env(f.s) * (1 - Float(k) / Float(pts.count)) * 0.6
                var r = TubeRing(c: pts[k].p, n: bf[k].n, b: bf[k].b, t: bf[k].t, r: pts[k].r, tilt: 0, v: e, col: SIMD4(color, 1))
                r.aux = SIMD2(f.s + bf[k].s, 0.5 + Float(k) * 0.0)
                rings.append(r)
            }
            TubeMesher.mesh(rings, sides: 4, into: &m, withAux: true)
        }
    }
}
