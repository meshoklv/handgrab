import Foundation
import SceneKit
import simd

/// Вид одного мазка в сцене: куски по N колец (соседние куски делят граничное кольцо — без шва).
/// Пока мазок рисуется, кусок 64 кольца и перестраивается только «горячий» хвост;
/// законченный мазок склеивается в крупные куски (меньше вызовов отрисовки).
final class StrokeView {
    static let hotChunk = 64
    static let frozenChunk = 512

    let node = SCNNode()
    private(set) var chunkSize = StrokeView.hotChunk
    private var chunks: [SCNNode] = []
    private(set) var frames: [RingFrame] = []
    /// Шёлк: сглаженное направление поперёк ленты (на весь мазок, чтобы куски стыковались без скачка).
    private(set) var ribbonSides: [SIMD3<Float>] = []
    private(set) var triangles: [Int] = []
    /// Свой материал у светящихся (вспышка у каждого мазка своя).
    private var ownMaterials: [SCNMaterial] = []
    private let kind: BrushKind
    var flashStart: Double = 0
    var flashing = false
    /// Множитель радиуса (оседание пластилина).
    var radiusScale: Float = 1
    var radiusScaleRange: ClosedRange<Int>?

    var totalTriangles: Int { triangles.reduce(0, +) }

    init(kind: BrushKind) {
        self.kind = kind
        node.name = "stroke"
        // Светящиеся кисти — свет, а не предмет: тени не отбрасывают.
        if kind.emissive { node.castsShadow = false }
        let M = SculptMaterials.shared
        switch kind {
        case .neon: ownMaterials = [M.neonCore(), M.neonHalo()]
        case .plasma: ownMaterials = [M.plasma()]
        default: break
        }
    }

    func setChunkSize(_ n: Int) {
        if n != chunkSize { chunkSize = n }
    }

    /// Перестроить куски, затронутые узлами начиная с `dirty`.
    func rebuild(_ s: StrokeData, from dirty: Int) {
        let n = s.nodes.count
        StrokeFrames.update(s.nodes, from: max(0, dirty - 1), frames: &frames)
        if kind == .silk { RibbonMesher.updateSides(nodes: s.nodes, frames: frames, from: max(0, dirty - 1), sides: &ribbonSides) }
        let segs = max(1, n - 1)
        let needed = max(1, (segs + chunkSize - 1) / chunkSize)
        while chunks.count > needed { chunks.removeLast().removeFromParentNode(); triangles.removeLast() }
        // Узел dirty влияет на кольца с dirty−1 (касательная); у пылинок и плазмы ещё и на соседей.
        let first = max(0, min((max(0, dirty - 2)) / chunkSize, needed - 1))
        // Последний кусок перестраиваем всегда (сужение/полусфера на конце).
        for c in 0..<needed where c >= first || c == needed - 1 || c >= chunks.count {
            let a = c * chunkSize
            let b = min((c + 1) * chunkSize, n - 1)
            let cn: SCNNode
            if c < chunks.count { cn = chunks[c] } else {
                cn = SCNNode(); cn.castsShadow = !kind.emissive; node.addChildNode(cn); chunks.append(cn); triangles.append(0)
            }
            triangles[c] = build(s, chunk: cn, range: a...max(a, b), first: c == 0, last: c == needed - 1)
        }
    }

    /// Полная перестройка (после отмены, склейки, загрузки).
    func rebuildAll(_ s: StrokeData) {
        frames.removeAll(keepingCapacity: true)
        ribbonSides.removeAll(keepingCapacity: true)
        for c in chunks { c.removeFromParentNode() }
        chunks.removeAll(); triangles.removeAll()
        rebuild(s, from: 0)
    }

    // MARK: Построение одного куска

    private func build(_ s: StrokeData, chunk cn: SCNNode, range: ClosedRange<Int>, first: Bool, last: Bool) -> Int {
        for ch in cn.childNodes { ch.removeFromParentNode() }
        cn.geometry = nil
        guard s.nodes.count >= 1, range.upperBound < s.nodes.count else { return 0 }
        let p = BrushPreset.of(s.kind)
        let nodes = s.nodes
        let total = frames.last?.s ?? 0
        let finished = s.finished
        let M = SculptMaterials.shared
        let rs = radiusScale, rr = radiusScaleRange
        func rscale(_ i: Int) -> Float { if let rr, rr.contains(i) { return rs } else { return 1 } }
        // Плавное начало/конец (кроме кистей с полусферами).
        func taper(_ i: Int) -> Float {
            let sv = frames[i].s
            var k = sin(Float.pi / 2 * min(1, sv / 0.005))
            if finished { k *= sin(Float.pi / 2 * min(1, (total - sv) / 0.005)) }
            return max(k, 0.05)
        }
        var tris = 0
        func attach(_ m: MeshBuffers, _ mat: SCNMaterial, order: Int = 0) {
            guard let g = m.geometry([mat]) else { return }
            tris += m.triangleCount
            if cn.geometry == nil && order == 0 { cn.geometry = g } else {
                let ch = SCNNode(geometry: g)
                ch.renderingOrder = order
                ch.castsShadow = !s.kind.emissive
                cn.addChildNode(ch)
            }
        }
        let single = nodes.count == 1
        let lc = hgLinear(s.color)
        let rng = single ? 0...0 : range
        switch s.kind {
        case .plasticine, .chrome:
            let base = lc
            let isClay = s.kind == .plasticine
            var m = MeshBuffers()
            let rings = TubeMesher.rings(nodes: nodes, frames: frames, range: rng, radius: { i in
                var r = nodes[i].r * rscale(i)
                let sv = self.frames[i].s
                if isClay {
                    // Скатан руками: толщина «дышит» на ±3,5% с периодом ~4 см.
                    r *= 1 + 0.035 * hgNoise1(sv * 25 + 1.7, s.seed &+ 5)
                } else {
                    // Жидкий металл: едва заметная пологая волна толщины (±6%, период ~6 см) и капля на концах.
                    r *= 1 + 0.06 * hgNoise1(sv * 16, s.seed &+ 9)
                    let tipIn = hgSmoothstep(0, 0.012, sv)
                    let tipOut = finished ? hgSmoothstep(0, 0.012, total - sv) : 1
                    r *= 0.72 + 0.28 * min(tipIn, tipOut)
                }
                return r
            }, color: { i in
                let sv = self.frames[i].s
                if isClay {
                    // Смешанная глина: оттенок и яркость «плывут» на ±3%.
                    let k = 1 + 0.03 * hgNoise1(sv * 22, s.seed)
                    let c = hgHueShift(base, degrees: 6 * hgNoise1(sv * 9 + 3, s.seed &+ 1)) * k
                    return SIMD4(c, 1)
                }
                return SIMD4(base, 1)
            }, vScale: isClay ? 26 : 10, capRings: p.capRings,
               startCap: first, endCap: last)
            if single { return 0 }
            TubeMesher.mesh(rings, sides: p.sides, into: &m, withTangents: isClay)
            attach(m, isClay ? M.clay : M.chrome)
        case .neon:
            if single { return 0 }
            let core = simd_mix(lc, SIMD3(repeating: 1), SIMD3(repeating: 0.72))
            var m = MeshBuffers()
            let rings = TubeMesher.rings(nodes: nodes, frames: frames, range: rng, radius: { nodes[$0].r },
                                         color: { _ in SIMD4(core, 1) }, vScale: 10, capRings: p.capRings, startCap: first, endCap: last)
            TubeMesher.mesh(rings, sides: p.sides, into: &m)
            attach(m, ownMaterials[0])
            var h = MeshBuffers()
            var hr = TubeMesher.rings(nodes: nodes, frames: frames, range: rng, radius: { nodes[$0].r * 4 },
                                      color: { _ in SIMD4(lc * 0.9, 1) }, vScale: 10, capRings: 4, startCap: first, endCap: last)
                        TubeMesher.mesh(hr, sides: 12, into: &h)
            attach(h, ownMaterials[1], order: 10)
        case .silk:
            if single { return 0 }
            var m = MeshBuffers()
            let sides = ribbonSides
            // Кисточка: конец сужается на 1,5–2,5 см плавно, как мазок кистью.
            func silkTaper(_ i: Int) -> Float {
                let sv = frames[i].s
                var k = hgSmoothstep(0, 0.015, sv)
                if finished { k *= hgSmoothstep(0, 0.025, total - sv) }
                return max(0.04, k.squareRoot())
            }
            RibbonMesher.mesh(nodes: nodes, frames: frames, sides: sides, range: rng, width: { nodes[$0].r * silkTaper($0) }, color: { i in
                let sv = self.frames[i].s
                let k = 0.5 - 0.5 * cos(sv / 0.12 * .pi)
                return SIMD4(hgLinear(hgHueShift(s.color, degrees: 40 * k)), 1)
            }, into: &m)
            attach(m, M.silk)
        case .stardust:
            var d = MeshBuffers()
            DustEmitter.mesh(nodes: nodes, range: rng, lastChunk: last, seed: s.seed, color: lc,
                             spread: { nodes[$0].r * taper($0) }, into: &d)
            attach(d, M.dust, order: 12)
            if !single {
                var sp = MeshBuffers()
                let rings = TubeMesher.rings(nodes: nodes, frames: frames, range: rng, radius: { _ in 0.0003 },
                                             color: { _ in SIMD4(lc, 1) }, vScale: 10, capRings: 0, startCap: false, endCap: false)
                TubeMesher.mesh(rings, sides: 4, into: &sp)
                attach(sp, M.dustSpine, order: 11)
            }
        case .plasma:
            if single { return 0 }
            var m = MeshBuffers()
            PlasmaMesher.mesh(nodes: nodes, frames: frames, range: rng, seed: s.seed, total: total, finished: finished,
                              color: lc, into: &m)
            attach(m, ownMaterials[0], order: 11)
        }
        return tris
    }

    // MARK: Вспышка (неон, плазма)

    /// Яркость по времени: вспышка ×1,8 на 0,15 с, затем мерцание затухает 0,4 с.
    func updateFlash(now: Double) {
        guard flashing, !ownMaterials.isEmpty else { return }
        let t = now - flashStart
        var k: Float = 1
        if t < 0.15 {
            k = 1 + 0.8 * Float(sin(t / 0.15 * .pi / 2))
        } else if t < 0.55 {
            let u = Float((t - 0.15) / 0.4)
            k = 1.8 - 0.8 * u + 0.25 * (1 - u) * sin(Float(t) * 90)
        } else {
            flashing = false
        }
        let base: [Float] = kind == .neon ? [3.0, 1.2] : [2.6]
        for (i, m) in ownMaterials.enumerated() { m.setValue(NSNumber(value: base[i] * k), forKey: "boost") }
    }

    func flash(now: Double) { flashStart = now; flashing = true }
}
