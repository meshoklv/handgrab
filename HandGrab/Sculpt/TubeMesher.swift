import Foundation
import SceneKit
import simd

/// Буферы вершин одного слоя геометрии.
struct MeshBuffers {
    var pos: [Float] = []
    var nor: [Float] = []
    var uv: [Float] = []
    /// Второй набор текстурных координат (параметры шейдера), пусто — нет.
    var uv2: [Float] = []
    var col: [Float] = []
    /// Касательные (для карты нормалей), пусто — нет.
    var tan: [Float] = []
    var idx: [UInt32] = []
    var primitive: SCNGeometryPrimitiveType = .triangles

    var vertexCount: Int { pos.count / 3 }
    var triangleCount: Int { primitive == .triangles ? idx.count / 3 : 0 }
    var isEmpty: Bool { idx.isEmpty }

    mutating func reserve(vertices v: Int, indices i: Int) {
        pos.reserveCapacity(v * 3); nor.reserveCapacity(v * 3); uv.reserveCapacity(v * 2); col.reserveCapacity(v * 4)
        idx.reserveCapacity(i)
    }

    @inline(__always) mutating func vertex(_ p: SIMD3<Float>, _ n: SIMD3<Float>, _ t: SIMD2<Float>, _ c: SIMD4<Float>) {
        pos.append(p.x); pos.append(p.y); pos.append(p.z)
        nor.append(n.x); nor.append(n.y); nor.append(n.z)
        uv.append(t.x); uv.append(t.y)
        col.append(c.x); col.append(c.y); col.append(c.z); col.append(c.w)
    }

    func geometry(_ materials: [SCNMaterial]) -> SCNGeometry? {
        guard !idx.isEmpty else { return nil }
        let vc = vertexCount
        func src(_ a: [Float], _ sem: SCNGeometrySource.Semantic, _ comps: Int) -> SCNGeometrySource {
            let data = a.withUnsafeBufferPointer { Data(buffer: $0) }
            return SCNGeometrySource(data: data, semantic: sem, vectorCount: vc, usesFloatComponents: true,
                                     componentsPerVector: comps, bytesPerComponent: 4, dataOffset: 0, dataStride: comps * 4)
        }
        var sources = [src(pos, .vertex, 3), src(nor, .normal, 3), src(uv, .texcoord, 2), src(col, .color, 4)]
        if uv2.count == vc * 2 { sources.append(src(uv2, .texcoord, 2)) }
        if tan.count == vc * 3 { sources.append(src(tan, .tangent, 3)) }
        let idata = idx.withUnsafeBufferPointer { Data(buffer: $0) }
        let count = primitive == .triangles ? idx.count / 3 : idx.count
        let el = SCNGeometryElement(data: idata, primitiveType: primitive, primitiveCount: count, bytesPerIndex: 4)
        let g = SCNGeometry(sources: sources, elements: [el])
        g.materials = materials
        return g
    }
}

/// Кольцо трубки до разворачивания в вершины.
struct TubeRing {
    var c: SIMD3<Float>
    var n: SIMD3<Float>
    var b: SIMD3<Float>
    var t: SIMD3<Float>
    var r: Float
    /// Наклон нормали к оси (−1 — назад, 0 — вбок, +1 — вперёд): для полусфер.
    var tilt: Float
    var v: Float
    var col: SIMD4<Float>
    /// Параметры шейдера (длина дуги, зерно) — во второй набор uv.
    var aux: SIMD2<Float> = .zero
}

/// Трубка из колец с полусферами на концах.
enum TubeMesher {
    /// Кольца для узлов `range` (включительно) + полусферы, если отрезок касается начала/конца мазка.
    static func rings(nodes: [StrokeNode], frames: [RingFrame], range: ClosedRange<Int>,
                      radius: (Int) -> Float, color: (Int) -> SIMD4<Float>, vScale: Float,
                      capRings: Int, startCap: Bool, endCap: Bool) -> [TubeRing] {
        var out: [TubeRing] = []
        out.reserveCapacity(range.count + 2 * capRings)
        func ring(_ i: Int) -> TubeRing {
            let f = frames[i]
            return TubeRing(c: nodes[i].p, n: f.n, b: f.b, t: f.t, r: radius(i), tilt: 0, v: f.s * vScale, col: color(i))
        }
        if startCap && capRings > 0 {
            let r0 = ring(range.lowerBound)
            for k in stride(from: capRings, through: 1, by: -1) {
                let phi = Float(k) / Float(capRings) * .pi / 2
                var q = r0
                q.c = r0.c - r0.t * (r0.r * sin(phi))
                q.r = r0.r * cos(phi)
                q.tilt = -sin(phi)
                q.v = r0.v - r0.r * sin(phi) * vScale
                out.append(q)
            }
        }
        for i in range { out.append(ring(i)) }
        if endCap && capRings > 0 {
            let r1 = ring(range.upperBound)
            for k in 1...capRings {
                let phi = Float(k) / Float(capRings) * .pi / 2
                var q = r1
                q.c = r1.c + r1.t * (r1.r * sin(phi))
                q.r = r1.r * cos(phi)
                q.tilt = sin(phi)
                q.v = r1.v + r1.r * sin(phi) * vScale
                out.append(q)
            }
        }
        return out
    }

    /// Развернуть кольца в вершины (sides + 1 на кольцо — шов по u).
    static func mesh(_ rings: [TubeRing], sides: Int, into m: inout MeshBuffers, withAux: Bool = false, withTangents: Bool = false) {
        guard rings.count >= 2 else { return }
        let base = UInt32(m.vertexCount)
        let per = sides + 1
        m.reserve(vertices: m.vertexCount + rings.count * per, indices: m.idx.count + (rings.count - 1) * sides * 6)
        var cs = [Float](repeating: 0, count: per), sn = [Float](repeating: 0, count: per)
        for j in 0..<per {
            let a = Float(j) / Float(sides) * 2 * .pi
            cs[j] = cos(a); sn[j] = sin(a)
        }
        for r in rings {
            let ct = (1 - r.tilt * r.tilt).squareRoot()
            for j in 0..<per {
                let radial = r.n * cs[j] + r.b * sn[j]
                let p = r.c + radial * r.r
                let nrm = radial * ct + r.t * r.tilt
                m.vertex(p, nrm, SIMD2(Float(j) / Float(sides), r.v), r.col)
                if withAux { m.uv2.append(r.aux.x); m.uv2.append(r.aux.y) }
                if withTangents {
                    let tg = r.b * cs[j] - r.n * sn[j]
                    m.tan.append(tg.x); m.tan.append(tg.y); m.tan.append(tg.z)
                }
            }
        }
        for k in 0..<(rings.count - 1) {
            let a = base + UInt32(k * per), b = a + UInt32(per)
            for j in 0..<UInt32(sides) {
                m.idx.append(a + j); m.idx.append(a + j + 1); m.idx.append(b + j)
                m.idx.append(a + j + 1); m.idx.append(b + j + 1); m.idx.append(b + j)
            }
        }
    }
}
