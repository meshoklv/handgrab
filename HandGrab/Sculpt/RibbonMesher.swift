import Foundation
import simd

/// Лента «шёлк»: слегка выгнутая полоса (5 вершин поперёк — живой изгиб и мягкий свет), развёрнутая по ладони;
/// две стороны (лицо и изнанка) отдельными вершинами.
enum RibbonMesher {
    /// Поперечник: столько отрезков поперёк ленты.
    static let across = 4
    /// Изгиб поперёк (доля полуширины).
    static let curl: Float = 0.16
    /// Длина сглаживания поворота ленты, м, и предел скорости поворота, рад/м (≈2,3°/мм).
    static let smoothLen: Float = 0.008
    static let maxTurnRate: Float = 40

    /// Направление «поперёк ленты» для узлов начиная с `from`: желаемое — из нормали ладони, но поворот сглажен
    /// и ограничен по скорости; если ладонь смотрит вдоль линии (направление не определено) — держим прежнее.
    /// Так лента не мнётся и не перекручивается рывком на поворотах.
    static func updateSides(nodes: [StrokeNode], frames: [RingFrame], from: Int, sides: inout [SIMD3<Float>]) {
        let n = min(nodes.count, frames.count)
        if sides.count > n { sides.removeLast(sides.count - n) }
        guard n > 0 else { return }
        let start = max(0, min(from, sides.count))
        for i in start..<n {
            let f = frames[i]
            var want: SIMD3<Float>?
            let proj = nodes[i].n - simd_dot(nodes[i].n, f.t) * f.t
            let pl = simd_length(proj)
            if pl > 0.25 { want = simd_cross(f.t, proj / pl) }
            var side: SIMD3<Float>
            if i == 0 {
                side = want ?? f.b
            } else {
                // Перенести прежнее направление в плоскость сечения.
                var prev = sides[i - 1] - simd_dot(sides[i - 1], f.t) * f.t
                prev = simd_length_squared(prev) > 1e-10 ? simd_normalize(prev) : f.b
                side = prev
                if var w = want {
                    if simd_dot(w, prev) < 0 { w = -w }   // лента двусторонняя: без переворота на 180°
                    let ds = max(f.s - frames[i - 1].s, 1e-5)
                    let ang = acos(clampf(simd_dot(prev, w), -1, 1))
                    if ang > 1e-4 {
                        // Плавно (экспонента по длине) и не быстрее предела.
                        let follow = ang * (1 - exp(-ds / smoothLen))
                        let turn = min(follow, maxTurnRate * ds)
                        let axis = simd_cross(prev, w)
                        if simd_length_squared(axis) > 1e-12 {
                            side = simd_quatf(angle: turn, axis: simd_normalize(axis)).act(prev)
                        }
                    }
                }
            }
            side = simd_normalize(side - simd_dot(side, f.t) * f.t + SIMD3(0, 0, 1e-7))
            if i < sides.count { sides[i] = side } else { sides.append(side) }
        }
    }

    static func mesh(nodes: [StrokeNode], frames: [RingFrame], sides: [SIMD3<Float>], range: ClosedRange<Int>,
                     width: (Int) -> Float, color: (Int) -> SIMD4<Float>, into m: inout MeshBuffers) {
        guard range.count >= 2, sides.count > range.upperBound else { return }
        let per = (across + 1) * 2
        let base = UInt32(m.vertexCount)
        m.reserve(vertices: m.vertexCount + range.count * per, indices: m.idx.count + (range.count - 1) * across * 12)
        for i in range {
            let f = frames[i]
            let side = sides[i]
            let nr = simd_cross(side, f.t)
            let w = width(i)
            let c = nodes[i].p, col = color(i)
            let v = f.s * 100
            let off = nr * 0.00006
            for face in 0..<2 {
                let sgn: Float = face == 0 ? 1 : -1
                for k in 0...across {
                    let a = Float(k) / Float(across) * 2 - 1
                    // Выгиб: середина приподнята по nr, края опущены (корытце), нормаль — по производной профиля.
                    let p = c + side * (w * a) + nr * (curl * w * (1 - a * a)) + off * sgn
                    let nrm = simd_normalize(nr + side * (2 * curl * a)) * sgn
                    m.vertex(p, nrm, SIMD2((a + 1) / 2, v), col)
                }
            }
        }
        let A = UInt32(across + 1)
        for k in 0..<UInt32(range.count - 1) {
            let r0 = base + k * UInt32(per), r1 = r0 + UInt32(per)
            for j in 0..<UInt32(across) {
                // Лицо.
                let a = r0 + j, b = r1 + j
                m.idx += [a, a + 1, b, a + 1, b + 1, b]
                // Изнанка — обратный обход.
                let c = r0 + A + j, d = r1 + A + j
                m.idx += [c, d, c + 1, c + 1, d, d + 1]
            }
        }
    }
}
