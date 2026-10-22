import Foundation
import SceneKit
import UIKit
import simd

enum PhysicsCategory {
    static let object = 1
    static let world = 2
    static let hand = 4
}

/// Объект, который можно взять.
final class GrabObject {
    let node: SCNNode
    /// Радиус для выбора при захвате (м).
    let radius: Float
    let home: SIMD3<Float>
    let name: String
    var heldBy: Int?
    private var highlighted = false

    init(node: SCNNode, radius: Float, home: SIMD3<Float>, name: String) {
        self.node = node; self.radius = radius; self.home = home; self.name = name
    }

    /// Подсветка «можно взять» (свечение материала). Вызывать с потока рендера.
    func setHighlight(_ on: Bool) {
        guard on != highlighted else { return }
        highlighted = on
        node.geometry?.firstMaterial?.emission.contents = on ? UIColor(white: 0.35, alpha: 1) : UIColor.black
    }

    var position: SIMD3<Float> { node.presentation.simdWorldPosition }
}

/// Стол, стенки-коллайдеры и 4 объекта.
final class SceneObjects {
    static let tableY: Float = -0.10
    static let tableZNear: Float = -0.14
    static let tableZFar: Float = -0.58
    static let halfWidth: Float = 0.16
    /// Места объектов на столе (x, z) и половины их высот — их же использует синтетический реплей.
    static let homeXZ: [SIMD2<Float>] = [[-0.09, -0.26], [-0.04, -0.47], [0.07, -0.24], [0.09, -0.44]]
    static let halfHeights: [Float] = [0.034, 0.036, 0.03, 0.038]

    let root = SCNNode()
    private(set) var objects: [GrabObject] = []
    private var blobs: [BlobShadow] = []
    private let walls = SCNNode()
    private var wallHalfWidth: Float = 0

    init() {
        root.name = "objects-root"
        buildTable()
        root.addChildNode(walls)
        updateWalls(hfovDegrees: 0)
        buildObjects()
    }

    private func buildTable() {
        let depth = CGFloat(SceneObjects.tableZNear - SceneObjects.tableZFar)
        let box = SCNBox(width: CGFloat(2 * SceneObjects.halfWidth), height: 0.01, length: depth, chamferRadius: 0.002)
        func pbr(_ c: UIColor, rough: CGFloat = 0.8) -> SCNMaterial {
            let m = SCNMaterial()
            m.lightingModel = .physicallyBased
            m.diffuse.contents = c
            m.roughness.contents = rough
            m.metalness.contents = 0.0
            return m
        }
        // Игровой коврик = рабочий объём (тут лежат объекты и до любого места дотягивается рука).
        box.materials = [pbr(UIColor(red: 0.30, green: 0.34, blue: 0.40, alpha: 1))]
        // Окружение: большая столешница, пол и стена — чтобы сцена занимала весь экран и читалась глубина.
        let top = SCNBox(width: 1.1, height: 0.04, length: 1.0, chamferRadius: 0.01)
        top.materials = [pbr(UIColor(red: 0.42, green: 0.31, blue: 0.22, alpha: 1), rough: 0.6)]
        let topNode = SCNNode(geometry: top)
        topNode.simdPosition = SIMD3(0, SceneObjects.tableY - 0.03, -0.30)
        root.addChildNode(topNode)
        let wall = SCNBox(width: 3, height: 2, length: 0.02, chamferRadius: 0)
        wall.materials = [pbr(UIColor(red: 0.20, green: 0.21, blue: 0.24, alpha: 1))]
        let wallNode = SCNNode(geometry: wall)
        wallNode.simdPosition = SIMD3(0, SceneObjects.tableY + 0.6, -0.85)
        root.addChildNode(wallNode)
        let floor = SCNBox(width: 4, height: 0.02, length: 4, chamferRadius: 0)
        floor.materials = [pbr(UIColor(red: 0.13, green: 0.13, blue: 0.15, alpha: 1))]
        let floorNode = SCNNode(geometry: floor)
        floorNode.simdPosition = SIMD3(0, SceneObjects.tableY - 0.75, 0)
        root.addChildNode(floorNode)
        let n = SCNNode(geometry: box)
        n.name = "table"
        n.simdPosition = SIMD3(0, SceneObjects.tableY - 0.005, (SceneObjects.tableZNear + SceneObjects.tableZFar) / 2)
        let body = SCNPhysicsBody(type: .static, shape: SCNPhysicsShape(geometry: box, options: nil))
        body.friction = 0.6
        body.restitution = 0.2
        body.categoryBitMask = PhysicsCategory.world
        body.collisionBitMask = PhysicsCategory.object
        n.physicsBody = body
        root.addChildNode(n)
    }

    /// Невидимые стенки по краям стола, спереди, сзади и сверху (угол обзора больше не влияет).
    func updateWalls(hfovDegrees: Float) {
        let half = SceneObjects.halfWidth
        if abs(half - wallHalfWidth) < 0.002 { return }
        wallHalfWidth = half
        walls.childNodes.forEach { $0.removeFromParentNode() }
        let zMid = (SceneObjects.tableZNear + SceneObjects.tableZFar) / 2
        let zLen = CGFloat(SceneObjects.tableZNear - SceneObjects.tableZFar) + 0.1
        func wall(_ w: CGFloat, _ h: CGFloat, _ l: CGFloat, _ p: SIMD3<Float>) {
            let n = SCNNode()
            let body = SCNPhysicsBody(type: .static, shape: SCNPhysicsShape(geometry: SCNBox(width: w, height: h, length: l, chamferRadius: 0), options: nil))
            body.categoryBitMask = PhysicsCategory.world
            body.collisionBitMask = PhysicsCategory.object
            body.restitution = 0.3
            n.physicsBody = body
            n.simdPosition = p
            walls.addChildNode(n)
        }
        let h: CGFloat = 0.6
        let yMid = SceneObjects.tableY + 0.3
        wall(0.04, h, zLen, SIMD3(-half - 0.02, yMid, zMid))
        wall(0.04, h, zLen, SIMD3(half + 0.02, yMid, zMid))
        wall(CGFloat(2 * half + 0.1), h, 0.04, SIMD3(0, yMid, SceneObjects.tableZFar - 0.02))
        wall(CGFloat(2 * half + 0.1), h, 0.04, SIMD3(0, yMid, SceneObjects.tableZNear + 0.04))
        wall(CGFloat(2 * half + 0.1), 0.04, zLen, SIMD3(0, SceneObjects.tableY + 0.35, zMid))
    }

    private func buildObjects() {
        let specs: [(SCNGeometry, UIColor, Float)] = [
            // геометрия, цвет, радиус выбора
            (SCNBox(width: 0.068, height: 0.068, length: 0.068, chamferRadius: 0.006), .systemRed, 0.04),
            (SCNSphere(radius: 0.036), .systemBlue, 0.036),
            (SCNBox(width: 0.06, height: 0.06, length: 0.06, chamferRadius: 0.005), .systemGreen, 0.036),
            (SCNSphere(radius: 0.038), .systemYellow, 0.038),
        ]
        let masses: [CGFloat] = [0.2, 0.12, 0.15, 0.15]
        for (i, s) in specs.enumerated() {
            let m = SCNMaterial()
            m.lightingModel = .physicallyBased
            m.diffuse.contents = s.1
            m.roughness.contents = 0.45
            m.metalness.contents = 0.05
            s.0.materials = [m]
            let n = SCNNode(geometry: s.0)
            n.name = "obj\(i)"
            let xz = SceneObjects.homeXZ[i]
            let home = SIMD3<Float>(xz.x, SceneObjects.tableY + SceneObjects.halfHeights[i] + 0.001, xz.y)
            n.simdPosition = home
            n.castsShadow = true
            let body = SCNPhysicsBody(type: .dynamic, shape: SCNPhysicsShape(geometry: s.0, options: nil))
            body.mass = masses[i]
            body.friction = 0.6
            body.restitution = 0.2
            body.damping = 0.3
            body.angularDamping = 0.6
            body.rollingFriction = 0.02
            body.categoryBitMask = PhysicsCategory.object
            body.collisionBitMask = PhysicsCategory.object | PhysicsCategory.world | PhysicsCategory.hand
            body.contactTestBitMask = 0
            body.allowsResting = true
            n.physicsBody = body
            root.addChildNode(n)
            let blob = BlobShadow(radius: SceneObjects.halfHeights[i] * 1.15)
            root.addChildNode(blob.node)
            blobs.append(blob)
            objects.append(GrabObject(node: n, radius: s.2, home: home, name: ["красный куб", "синий шар", "зелёный куб", "жёлтый шар"][i]))
        }
    }

    /// Тени-пятна под объектами (каждый кадр, поток рендера). Над краем стола — не рисуются.
    func updateBlobs() {
        for (o, b) in zip(objects, blobs) {
            let p = o.position
            let onTable = abs(p.x) < SceneObjects.halfWidth + 0.02 && p.z < SceneObjects.tableZNear + 0.02 && p.z > SceneObjects.tableZFar - 0.02
            b.update(at: p, tableY: SceneObjects.tableY, bottom: SceneObjects.halfHeights[objects.firstIndex { $0 === o } ?? 0],
                     strength: onTable && p.y > SceneObjects.tableY - 0.05 ? 1 : 0)
        }
    }

    /// Вернуть все объекты на стол.
    func resetAll() {
        for o in objects { reset(o) }
    }

    func reset(_ o: GrabObject) {
        o.heldBy = nil
        guard let body = o.node.physicsBody else { return }
        body.type = .dynamic
        o.node.simdPosition = o.home
        o.node.simdOrientation = simd_quatf(angle: 0, axis: SIMD3(0, 1, 0))
        body.velocity = SCNVector3Zero
        body.angularVelocity = SCNVector4Zero
        body.resetTransform()
    }

    /// Объекты, вылетевшие за сцену, — на место.
    func recoverLost() {
        for o in objects where o.heldBy == nil {
            let p = o.position
            if p.y < SceneObjects.tableY - 0.5 || abs(p.x) > 1 || p.z > 0 || p.z < -1.5 { reset(o) }
        }
    }
}
