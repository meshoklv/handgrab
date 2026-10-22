import Foundation
import SceneKit
import UIKit
import simd

/// Скиннированная рука из glb (WebXR generic-hand, 25 костей) — кости ведутся нашими 21 точкой.
///
/// Кости в модели плоские (все — дети Armature), поэтому поза задаётся мировыми матрицами:
/// ладонь поворачивается как единое целое (по запястью, указательному и мизинцевому MCP), каждая фаланга —
/// минимальным поворотом своей кости из положения родителя на направление «сустав → следующий сустав» по нашим точкам.
/// Длины пальцев — из модели (масштаб по длине ладони), поэтому пальцы всегда правильной длины.
final class SkinnedHand {
    let root = SCNNode()
    private var bones: [SCNNode] = []
    private var restPos: [SIMD3<Float>] = []
    private var restRot: [simd_quatf] = []
    private var restScale: [SIMD3<Float>] = []
    private let mesh = SCNNode()
    let ok: Bool

    /// Наша точка (0…20) для кости WebXR (0…24); nil — пястная кость (едет вместе с ладонью).
    static let ours: [Int?] = [0,
                               1, 2, 3, 4,
                               nil, 5, 6, 7, 8,
                               nil, 9, 10, 11, 12,
                               nil, 13, 14, 15, 16,
                               nil, 17, 18, 19, 20]
    /// Ребёнок кости в цепочке пальца (для направления); nil — кончик.
    static let child: [Int?] = [nil,
                                2, 3, 4, nil,
                                6, 7, 8, 9, nil,
                                11, 12, 13, 14, nil,
                                16, 17, 18, 19, nil,
                                21, 22, 23, 24, nil]
    static let parent: [Int?] = [nil,
                                 0, 1, 2, 3,
                                 0, 5, 6, 7, 8,
                                 0, 10, 11, 12, 13,
                                 0, 15, 16, 17, 18,
                                 0, 20, 21, 22, 23]

    init(resource: String, material: SCNMaterial) {
        guard let url = Bundle.main.url(forResource: resource, withExtension: "glb"),
              let data = try? Data(contentsOf: url), let glb = GLB(data) else { ok = false; return }
        guard let nodes = glb.json["nodes"] as? [[String: Any]],
              let skin = (glb.json["skins"] as? [[String: Any]])?.first,
              let jointIdx = skin["joints"] as? [Int],
              let prim = ((glb.json["meshes"] as? [[String: Any]])?.first?["primitives"] as? [[String: Any]])?.first,
              let attrs = prim["attributes"] as? [String: Int],
              let pos = attrs["POSITION"], let nor = attrs["NORMAL"], let jnt = attrs["JOINTS_0"], let wgt = attrs["WEIGHTS_0"],
              let idx = prim["indices"] as? Int, let ibm = skin["inverseBindMatrices"] as? Int,
              jointIdx.count == 25 else { ok = false; return }

        for j in jointIdx {
            let n = nodes[j]
            let t = (n["translation"] as? [Double]).map { SIMD3<Float>(Float($0[0]), Float($0[1]), Float($0[2])) } ?? .zero
            let r = (n["rotation"] as? [Double]).map { simd_quatf(ix: Float($0[0]), iy: Float($0[1]), iz: Float($0[2]), r: Float($0[3])) }
                ?? simd_quatf(angle: 0, axis: [0, 1, 0])
            let s = (n["scale"] as? [Double]).map { SIMD3<Float>(Float($0[0]), Float($0[1]), Float($0[2])) } ?? SIMD3(1, 1, 1)
            let b = SCNNode()
            b.name = n["name"] as? String
            b.simdPosition = t; b.simdOrientation = r; b.simdScale = s
            root.addChildNode(b)
            bones.append(b); restPos.append(t); restRot.append(r.normalized); restScale.append(s)
        }

        let vCount = glb.count(pos)
        let vs = SCNGeometrySource(data: glb.raw(pos), semantic: .vertex, vectorCount: vCount, usesFloatComponents: true,
                                   componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: 12)
        let ns = SCNGeometrySource(data: glb.raw(nor), semantic: .normal, vectorCount: vCount, usesFloatComponents: true,
                                   componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: 12)
        let iCount = glb.count(idx)
        let iBytes = glb.componentSize(idx)
        let el = SCNGeometryElement(data: glb.raw(idx), primitiveType: .triangles, primitiveCount: iCount / 3, bytesPerIndex: iBytes)
        // Запястье растворяется: альфа 0 до сустава запястья (2,2 см меша за ним), 1 через 1,8 см к пальцам (без «обрубка»).
        let wrist0 = restPos[0]
        let axis = simd_normalize(restPos[11] - wrist0)
        var colors = [SIMD4<Float>](repeating: SIMD4(1, 1, 1, 1), count: vCount)
        glb.raw(pos).withUnsafeBytes { raw in
            let f = raw.bindMemory(to: Float.self)
            var ds = [Float](repeating: 0, count: vCount)
            for v in 0..<vCount { ds[v] = simd_dot(SIMD3(f[v * 3], f[v * 3 + 1], f[v * 3 + 2]) - wrist0, axis) }
            let lo = ds.min() ?? 0
            for v in 0..<vCount {
                var u = clampf((ds[v] - lo - 0.022) / 0.018, 0, 1)
                u = u * u * (3 - 2 * u)
                colors[v] = SIMD4(1, 1, 1, u)
            }
        }
        let cs = SCNGeometrySource(data: colors.withUnsafeBufferPointer { Data(buffer: $0) }, semantic: .color, vectorCount: vCount,
                                   usesFloatComponents: true, componentsPerVector: 4, bytesPerComponent: 4, dataOffset: 0, dataStride: 16)
        let geom = SCNGeometry(sources: [vs, ns, cs], elements: [el])
        geom.materials = [material]
        let jBytes = glb.componentSize(jnt)
        let bi = SCNGeometrySource(data: glb.raw(jnt), semantic: .boneIndices, vectorCount: vCount, usesFloatComponents: false,
                                   componentsPerVector: 4, bytesPerComponent: jBytes, dataOffset: 0, dataStride: 4 * jBytes)
        let bw = SCNGeometrySource(data: glb.raw(wgt), semantic: .boneWeights, vectorCount: vCount, usesFloatComponents: true,
                                   componentsPerVector: 4, bytesPerComponent: 4, dataOffset: 0, dataStride: 16)
        let ibmData = glb.raw(ibm)
        var inv: [NSValue] = []
        ibmData.withUnsafeBytes { p in
            let f = p.bindMemory(to: Float.self)
            for k in 0..<25 {
                var m = simd_float4x4()
                for c in 0..<4 { m[c] = SIMD4(f[k * 16 + c * 4], f[k * 16 + c * 4 + 1], f[k * 16 + c * 4 + 2], f[k * 16 + c * 4 + 3]) }
                inv.append(NSValue(scnMatrix4: SCNMatrix4(m)))
            }
        }
        mesh.geometry = geom
        let skinner = SCNSkinner(baseGeometry: geom, bones: bones, boneInverseBindTransforms: inv, boneWeights: bw, boneIndices: bi)
        skinner.skeleton = root
        mesh.skinner = skinner
        mesh.castsShadow = true
        root.addChildNode(mesh)
        ok = true
    }

    /// Базис ладони: x — от мизинца к указательному, y — от запястья к пальцам, z = x × y.
    private static func palmFrame(wrist: SIMD3<Float>, index: SIMD3<Float>, middle: SIMD3<Float>, pinky: SIMD3<Float>) -> simd_float3x3? {
        var y = middle - wrist
        guard simd_length(y) > 1e-5 else { return nil }
        y = simd_normalize(y)
        var x = index - pinky
        x -= simd_dot(x, y) * y
        guard simd_length(x) > 1e-5 else { return nil }
        x = simd_normalize(x)
        return simd_float3x3(columns: (x, y, simd_cross(x, y)))
    }

    /// Поставить кости по 21 точке (сцена). Возвращает false, если позу построить нельзя.
    @discardableResult
    func pose(_ j: [SIMD3<Float>]) -> Bool {
        guard ok, j.count == 21,
              let rf = SkinnedHand.palmFrame(wrist: restPos[0], index: restPos[6], middle: restPos[11], pinky: restPos[21]),
              let cf = SkinnedHand.palmFrame(wrist: j[0], index: j[5], middle: j[9], pinky: j[17]) else { return false }
        let dRoot = simd_quatf(cf * rf.transpose).normalized
        // Масштаб — по длине ладони (запястье → средний MCP).
        let s = simd_distance(j[0], j[9]) / max(simd_distance(restPos[0], restPos[11]), 1e-4)
        var p = [SIMD3<Float>](repeating: .zero, count: 25)
        var d = [simd_quatf](repeating: dRoot, count: 25)
        p[0] = j[0]
        for b in 1..<25 {
            guard let par = SkinnedHand.parent[b] else { continue }
            // Положение — от родителя по длине кости модели (пальцы своей длины, без растяжения).
            p[b] = p[par] + d[par].act(restPos[b] - restPos[par]) * s
            var q = SkinnedHand.ours[b] == nil ? dRoot : d[par]
            if let c = SkinnedHand.child[b], let oa = SkinnedHand.ours[b], let oc = SkinnedHand.ours[c] {
                let want = j[oc] - j[oa]
                let have = q.act(restPos[c] - restPos[b])
                if simd_length(want) > 1e-5 && simd_length(have) > 1e-5 {
                    q = (simd_quatf(from: simd_normalize(have), to: simd_normalize(want)) * q).normalized
                }
            }
            d[b] = q
        }
        for b in 0..<25 {
            bones[b].simdPosition = p[b]
            bones[b].simdOrientation = d[b] * restRot[b]
            bones[b].simdScale = restScale[b] * s
        }
        return true
    }
}

/// Минимальный разбор glb: JSON + бинарный чанк, плотно упакованные accessor'ы.
struct GLB {
    let json: [String: Any]
    let bin: Data

    init?(_ d: Data) {
        guard d.count > 20 else { return nil }
        func u32(_ o: Int) -> Int { Int(d.subdata(in: o..<o + 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }) }
        guard u32(0) == 0x46546C67 else { return nil }
        let jl = u32(12)
        guard let j = try? JSONSerialization.jsonObject(with: d.subdata(in: 20..<20 + jl)) as? [String: Any] else { return nil }
        let bo = 20 + jl
        let bl = u32(bo)
        json = j
        bin = d.subdata(in: bo + 8..<bo + 8 + bl)
    }

    private func accessor(_ i: Int) -> [String: Any] { (json["accessors"] as! [[String: Any]])[i] }
    func count(_ i: Int) -> Int { accessor(i)["count"] as! Int }
    func componentSize(_ i: Int) -> Int {
        switch accessor(i)["componentType"] as! Int { case 5120, 5121: return 1; case 5122, 5123: return 2; default: return 4 }
    }
    func raw(_ i: Int) -> Data {
        let a = accessor(i)
        let bv = (json["bufferViews"] as! [[String: Any]])[a["bufferView"] as! Int]
        let off = (bv["byteOffset"] as? Int ?? 0) + (a["byteOffset"] as? Int ?? 0)
        let comps: Int
        switch a["type"] as! String { case "SCALAR": comps = 1; case "VEC2": comps = 2; case "VEC3": comps = 3; case "VEC4": comps = 4; default: comps = 16 }
        let len = count(i) * comps * componentSize(i)
        return bin.subdata(in: off..<off + len)
    }
}
