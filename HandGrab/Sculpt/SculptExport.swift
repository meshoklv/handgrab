import Foundation
import SceneKit
import UIKit
import simd

/// Сохранение: PNG (снимок сцены, ещё и в «Фото»), USDZ (геометрия с простыми PBR-материалами), .hgsculpt (JSON мазков).
/// Файлы — в Documents/sculpt (видно в «Файлах»: общий доступ к Documents уже включён).
enum SculptExport {
    static var dir: URL {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("sculpt")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// Вызывается на потоке рендера.
    static func save(strokes: [StrokeData], transform: SculptTransform) {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
        let name = "sculpt-" + f.string(from: Date())
        let json = dir.appendingPathComponent(name + ".hgsculpt")
        let png = dir.appendingPathComponent(name + ".png")
        let usdz = dir.appendingPathComponent(name + ".usdz")
        // Сцена для USDZ собирается здесь (данные мазков — копия), пишется в фоне.
        let scene = exportScene(strokes: strokes, transform: transform)
        let file = SculptFile(strokes: strokes)
        DispatchQueue.main.async {
            var urls: [URL] = []
            if let img = Telemetry.shared.sceneView?.snapshot(), let data = img.pngData() {
                try? data.write(to: png, options: .atomic)
                urls.append(png)
                UIImageWriteToSavedPhotosAlbum(img, nil, nil, nil)
            }
            DispatchQueue.global(qos: .userInitiated).async {
                if let d = try? JSONEncoder().encode(file) { try? d.write(to: json, options: .atomic); urls.append(json) }
                let ok = scene.write(to: usdz, options: nil, delegate: nil, progressHandler: nil)
                if ok { urls.append(usdz) }
                EventLog.shared.write("SCULPT сохранено \(name): png=\(urls.contains(png)) usdz=\(ok) мазков=\(strokes.count)")
                DispatchQueue.main.async {
                    SculptState.shared.exported = urls
                    let note = strokes.contains { $0.kind.emissive } ? " · свечение в USDZ без bloom" : ""
                    SculptState.shared.showToast("Сохранено: PNG в «Фото», USDZ и мазки в «Файлах»" + note)
                }
            }
        }
    }

    /// Чистая сцена: обычные массивы вершин и PBR-материалы (без шейдеров).
    static func exportScene(strokes: [StrokeData], transform: SculptTransform) -> SCNScene {
        let scene = SCNScene()
        let pivot = SCNNode()
        scene.rootNode.addChildNode(pivot)
        // Центр скульптуры — в начале координат, ориентация как на экране.
        pivot.simdOrientation = transform.rotation
        var dustLeft = 5000
        for s in strokes where s.nodes.count >= 2 {
            var frames: [RingFrame] = []
            StrokeFrames.update(s.nodes, from: 0, frames: &frames)
            let range = 0...(s.nodes.count - 1)
            let p = BrushPreset.of(s.kind)
            let nodes = s.nodes.map { n -> StrokeNode in var q = n; q.p -= SculptController.center; return q }
            var m = MeshBuffers()
            let mat = SCNMaterial()
            mat.lightingModel = .physicallyBased
            mat.diffuse.contents = Palette.ui(s.color)
            mat.roughness.contents = NSNumber(value: 0.6)
            mat.metalness.contents = NSNumber(value: 0.0)
            let col: (Int) -> SIMD4<Float> = { _ in SIMD4(s.color, 1) }
            switch s.kind {
            case .plasticine, .chrome, .neon, .plasma:
                let rk: Float = s.kind == .plasma ? 1.5 : 1
                let rings = TubeMesher.rings(nodes: nodes, frames: frames, range: range, radius: { nodes[$0].r * rk }, color: col, vScale: 10,
                                             capRings: max(p.capRings, 4), startCap: true, endCap: true)
                TubeMesher.mesh(rings, sides: min(p.sides, 16), into: &m)
                if s.kind == .chrome { mat.metalness.contents = NSNumber(value: 1.0); mat.roughness.contents = NSNumber(value: 0.08) }
                if s.kind == .neon || s.kind == .plasma { mat.emission.contents = Palette.ui(s.color) }
            case .silk:
                var sides: [SIMD3<Float>] = []
                RibbonMesher.updateSides(nodes: nodes, frames: frames, from: 0, sides: &sides)
                RibbonMesher.mesh(nodes: nodes, frames: frames, sides: sides, range: range, width: { nodes[$0].r }, color: col, into: &m)
                mat.roughness.contents = NSNumber(value: 0.35)
            case .stardust:
                // Пыль — мелкие октаэдры (≤ 5 тыс. на сцену).
                var dust = MeshBuffers()
                DustEmitter.mesh(nodes: nodes, range: range, lastChunk: true, seed: s.seed, color: s.color, spread: { nodes[$0].r }, into: &dust)
                let count = min(dust.vertexCount / 4, dustLeft)
                dustLeft -= count
                for k in 0..<count {
                    let o = k * 4 * 3
                    let c = SIMD3(dust.pos[o], dust.pos[o + 1], dust.pos[o + 2])
                    let r = dust.uv2[k * 8 + 1]
                    let base = UInt32(m.vertexCount)
                    let dirs: [SIMD3<Float>] = [[1, 0, 0], [-1, 0, 0], [0, 1, 0], [0, -1, 0], [0, 0, 1], [0, 0, -1]]
                    for d in dirs { m.vertex(c + d * r, d, .zero, SIMD4(s.color, 1)) }
                    let faces: [(UInt32, UInt32, UInt32)] = [(0, 2, 4), (2, 1, 4), (1, 3, 4), (3, 0, 4), (2, 0, 5), (1, 2, 5), (3, 1, 5), (0, 3, 5)]
                    for (a, b, c2) in faces { m.idx += [base + a, base + b, base + c2] }
                }
                mat.emission.contents = Palette.ui(s.color)
            }
            if let g = m.geometry([mat]) { pivot.addChildNode(SCNNode(geometry: g)) }
        }
        return scene
    }
}
