import Foundation
import SceneKit
import UIKit
import simd

/// Виртуальная рука: суставы, кости, перепонки ладони и «ладонь»-эллипсоид; метка-тень на столе под рукой.
/// Размеры — под увеличенную руку (handScale ≈ 1,5). Обновляется на потоке рендера.
final class HandRig {
    let root = SCNNode()
    private var joints: [SCNNode] = []
    private var bones: [SCNNode] = []
    private var webs: [SCNNode] = []
    private let palm = SCNNode()
    /// Реалистичные кисти (скиннированный меш WebXR generic-hand); суставы-капсулы — запасной вариант.
    private let skinL: SkinnedHand
    private let skinR: SkinnedHand
    private let capsules = SCNNode()
    private let marker = SCNNode()
    private var colliders: [SCNNode] = []
    private let baseMaterial: SCNMaterial
    private let tipMaterial: SCNMaterial
    private let highlightMaterial: SCNMaterial
    private var collidersOn = false
    private var lastHighlight = false
    private let skinMaterial: SCNMaterial
    private static let colliderJoints = [4, 8, 12, 16, 20]
    /// Перепонки: пары суставов, которые замыкают ладонь.
    private static let webPairs: [(Int, Int)] = [(1, 5), (5, 9), (9, 13), (13, 17), (0, 17), (2, 5)]

    init(color: UIColor, name: String) {
        root.name = name
        func mat(_ c: UIColor, emission: UIColor = .black) -> SCNMaterial {
            let m = SCNMaterial()
            m.lightingModel = .physicallyBased
            m.diffuse.contents = c
            m.emission.contents = emission
            m.roughness.contents = 0.5
            m.metalness.contents = 0.0
            return m
        }
        baseMaterial = mat(color)
        tipMaterial = mat(color)
        highlightMaterial = mat(.white, emission: color.withAlphaComponent(1))
        // Материал кисти: тёплая светлая кожа, мягкий блик, без прозрачности (сортировка не ломается).
        let skin = SCNMaterial()
        skin.lightingModel = .physicallyBased
        skin.diffuse.contents = UIColor(red: 0.93, green: 0.78, blue: 0.68, alpha: 1)
        skin.roughness.contents = 0.55
        skin.metalness.contents = 0.0
        skin.emission.contents = color.withAlphaComponent(1)
        skin.emission.intensity = 0.0
        // Прозрачный проход нужен, чтобы альфа вершин (растворение у запястья) смешивалась.
        skin.transparency = 0.999
        skin.transparencyMode = .singleLayer
        skin.blendMode = .alpha
        // Альфа вершин (растворение запястья) — явно в выходной цвет (премультиплицированный).
        skin.shaderModifiers = [.fragment: "#pragma transparent\n#pragma body\nfloat a = clamp(_surface.diffuse.a, 0.0, 1.0); _output.color *= a * a;\n"]
        skinMaterial = skin
        skinL = SkinnedHand(resource: "left", material: skin)
        skinR = SkinnedHand(resource: "right", material: skin)
        root.addChildNode(skinL.root)
        root.addChildNode(skinR.root)
        skinL.root.isHidden = true
        skinR.root.isHidden = true

        for i in 0..<HandJoint.count {
            let isTip = HandJoint(rawValue: i)?.isTip ?? false
            let s = SCNSphere(radius: isTip ? 0.0085 : (i == 0 ? 0.013 : 0.0095))
            s.segmentCount = 12
            s.materials = [isTip ? tipMaterial : baseMaterial]
            let n = SCNNode(geometry: s)
            n.castsShadow = true
            capsules.addChildNode(n)
            joints.append(n)
        }
        for i in 0..<HandJoint.boneCount {
            // Кости от запястья толще (пясть), фаланги тоньше к кончику.
            let child = i + 1
            let r: CGFloat = [1, 5, 9, 13, 17].contains(child) ? 0.0095 : 0.0082
            let c = SCNCylinder(radius: r, height: 1)
            c.radialSegmentCount = 10
            c.materials = [baseMaterial]
            let n = SCNNode(geometry: c)
            n.castsShadow = true
            capsules.addChildNode(n)
            bones.append(n)
        }
        for _ in HandRig.webPairs {
            let c = SCNCylinder(radius: 0.009, height: 1)
            c.radialSegmentCount = 8
            c.materials = [baseMaterial]
            let n = SCNNode(geometry: c)
            n.castsShadow = true
            capsules.addChildNode(n)
            webs.append(n)
        }
        let ps = SCNSphere(radius: 1)
        ps.segmentCount = 16
        ps.materials = [baseMaterial]
        palm.geometry = ps
        palm.castsShadow = true
        capsules.addChildNode(palm)
        root.addChildNode(capsules)

        // Метка на столе под точкой хвата: показывает, над чем рука (как тень в VR).
        let disc = SCNCylinder(radius: 0.016, height: 0.001)
        let dm = SCNMaterial()
        dm.lightingModel = .constant
        dm.diffuse.contents = color.withAlphaComponent(0.35)
        dm.writesToDepthBuffer = false
        disc.materials = [dm]
        marker.geometry = disc
        marker.castsShadow = false
        // Метка на столе больше не нужна — тень-пятно есть у курсора (BlobShadow).

        for k in 0..<(HandRig.colliderJoints.count + 1) {
            let n = SCNNode()
            let r: CGFloat = k == HandRig.colliderJoints.count ? 0.04 : 0.013
            let body = SCNPhysicsBody(type: .kinematic, shape: SCNPhysicsShape(geometry: SCNSphere(radius: r), options: nil))
            body.categoryBitMask = 0
            body.collisionBitMask = 0
            n.physicsBody = body
            colliders.append(n)
        }
        root.isHidden = true
    }

    func attachColliders(to parent: SCNNode) {
        colliders.forEach { parent.addChildNode($0) }
    }

    func setCollidersEnabled(_ on: Bool) {
        guard on != collidersOn else { return }
        collidersOn = on
        for c in colliders {
            c.physicsBody?.categoryBitMask = on ? PhysicsCategory.hand : 0
            c.physicsBody?.collisionBitMask = on ? PhysicsCategory.object : 0
        }
    }

    func hide() {
        root.isHidden = true
        if collidersOn { for c in colliders { c.simdPosition = SIMD3(0, 10, 0) } }
    }

    private static func place(_ n: SCNNode, _ a: SIMD3<Float>, _ b: SIMD3<Float>) {
        let d = b - a
        let len = simd_length(d)
        n.simdPosition = (a + b) * 0.5
        if len > 1e-5 { n.simdOrientation = simd_quatf(from: SIMD3(0, 1, 0), to: d / len) }
        n.simdScale = SIMD3(1, max(len, 1e-4), 1)
    }

    /// grabPoint — точка хвата (под ней метка на столе).
    /// false — кисть не рисуется (только метка на столе и коллайдеры), руку показывает курсор.
    var modelVisible = true

    func update(joints j: [SIMD3<Float>], opacity: Float, highlight: Bool, grabPoint: SIMD3<Float>, chirality: Chirality) {
        root.isHidden = opacity <= 0.01
        root.opacity = CGFloat(opacity)
        // Кисть-меш нужной руки; если меш не загрузился или поза не строится — капсулы.
        let skin = chirality == .left ? skinL : skinR
        let other = chirality == .left ? skinR : skinL
        let skinned = modelVisible && skin.pose(j)
        skin.root.isHidden = !skinned
        other.root.isHidden = true
        capsules.isHidden = skinned || !modelVisible
        // Подсветка «можно взять / держу»: лёгкое свечение кожи цветом руки.
        let glow: CGFloat = highlight ? 0.22 : 0
        if skinMaterial.emission.intensity != glow { skinMaterial.emission.intensity = glow }
        for i in 0..<HandJoint.count { joints[i].simdPosition = j[i] }
        for i in 1..<HandJoint.count {
            guard let p = HandJoint(rawValue: i)?.parent?.rawValue else { continue }
            HandRig.place(bones[i - 1], j[p], j[i])
        }
        for (k, (a, b)) in HandRig.webPairs.enumerated() { HandRig.place(webs[k], j[a], j[b]) }

        // Ладонь: сплюснутый эллипсоид в базисе ладони.
        let c = PinchDetector.palmCenter(j)
        let along = j[9] - j[0], across = j[5] - j[17]
        let la = simd_length(along), lc = simd_length(across)
        if la > 1e-4 && lc > 1e-4 {
            let a = along / la
            var b = across - simd_dot(across, a) * a
            if simd_length(b) > 1e-5 {
                b = simd_normalize(b)
                let n = simd_cross(b, a)
                palm.simdOrientation = simd_quatf(simd_float3x3(columns: (b, a, n)))
                palm.simdPosition = c
                palm.simdScale = SIMD3(lc * 0.55, la * 0.5, 0.009)
            }
        }

        // Метка на столе: чем ниже рука, тем ярче и меньше.
        let h = max(0, grabPoint.y - SceneObjects.tableY)
        marker.simdPosition = SIMD3(grabPoint.x, SceneObjects.tableY + 0.0008, grabPoint.z)
        let k = 1 + min(h, 0.3) * 3
        marker.simdScale = SIMD3(k, 1, k)
        marker.opacity = CGFloat(max(0.25, 1 - h * 2.5))

        if highlight != lastHighlight {
            lastHighlight = highlight
            let m = highlight ? highlightMaterial : tipMaterial
            joints[HandJoint.thumbTip.rawValue].geometry?.materials = [m]
            joints[HandJoint.indexTip.rawValue].geometry?.materials = [m]
        }
        if collidersOn {
            for (k, ji) in HandRig.colliderJoints.enumerated() { colliders[k].simdPosition = j[ji] }
            colliders[HandRig.colliderJoints.count].simdPosition = c
        }
    }
}
