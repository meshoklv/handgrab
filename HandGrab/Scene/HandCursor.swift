import Foundation
import SceneKit
import UIKit
import simd

/// 3D-курсор руки — классическая стрелка-указатель (как в macOS/Windows): белое объёмное тело со скруглёнными
/// фасками, тёмная окантовка, лёгкий глянец, мягкая тень-пятно на столе. Остриё — точка взаимодействия.
///
/// Переиспользуемый (не знает про конвейер и объекты). На каждый кадр рендера (120 Гц):
///
///     cursor.update(target: точка-остриё, direction: куда смотрит рука, pinch: 0…1, state: .hover, dt: dt,
///                   viewer: положение камеры, tableY: высота стола)
///
/// Плавность: положение — критически демпфированная пружина (без перелёта, пропуск кадра распознавания не даёт
/// скачка), поворот — экспоненциальный slerp. Стрелка смотрит остриём по направлению руки и разворачивается
/// лицом к камере, чтобы всегда читалась как курсор.
/// Состояния: .hover — чуть больше и светлее; щипок/.grab — «нажатие» (меньше, как клик) и синяя окантовка.
final class HandCursor {
    enum State { case idle, hover, grab }

    let node = SCNNode()
    /// Сглаженное положение острия (сцена).
    private(set) var position = SIMD3<Float>(0, 0, 0)
    private(set) var direction = SIMD3<Float>(0, 0, -1)
    private(set) var visible = false
    /// Мягкая тень-пятно на столе под остриём.
    let blob = BlobShadow(radius: 0.018)

    /// Частота пружины положения, Гц (больше — быстрее догоняет, меньше — мягче).
    var positionHz: Float = 9
    /// Постоянная времени поворота, с.
    var rotationTau: Float = 0.08
    /// Высота стрелки, м.
    static let size: Float = 0.065
    /// Режим «Скульпт»: стрелка меньше и полупрозрачная, чтобы не закрывать скульптуру (остриё — точка кисти).
    var sculptStyle = false
    static let sculptScale: Float = 0.55
    static let sculptOpacity: Float = 0.55

    private let arrow = SCNNode()
    private let bodyMat = SCNMaterial()
    private let rimMat = SCNMaterial()
    private var vel = SIMD3<Float>(0, 0, 0)
    private var rot = simd_quatf(angle: 0, axis: [1, 0, 0])
    private var press: Float = 0
    private var glow: Float = 0
    private let rimColor = UIColor(white: 0.08, alpha: 1)
    private let grabRim = UIColor(red: 0.10, green: 0.45, blue: 1.0, alpha: 1)

    /// Контур классической стрелки (единицы — «пиксели» курсора 12×19, остриё в 0,0, ось Y вверх).
    private static let outline: [CGPoint] = [
        CGPoint(x: 0, y: 0), CGPoint(x: 0, y: -16), CGPoint(x: 4, y: -12.5), CGPoint(x: 6.8, y: -18.6),
        CGPoint(x: 9.2, y: -17.5), CGPoint(x: 6.5, y: -11.6), CGPoint(x: 11.5, y: -11.6),
    ]
    /// Ось «хвост → остриё» в координатах стрелки.
    private static let localForward = simd_normalize(SIMD3<Float>(-5.2, 15.5, 0))

    init() {
        node.name = "hand-cursor"
        let k = CGFloat(HandCursor.size / 19)

        bodyMat.lightingModel = .physicallyBased
        bodyMat.diffuse.contents = UIColor(white: 0.97, alpha: 1)
        bodyMat.roughness.contents = 0.28
        bodyMat.metalness.contents = 0.0
        bodyMat.emission.contents = UIColor(white: 1, alpha: 1)
        bodyMat.emission.intensity = 0.12
        rimMat.lightingModel = .physicallyBased
        rimMat.diffuse.contents = rimColor
        rimMat.roughness.contents = 0.35
        rimMat.metalness.contents = 0.0

        // Белое тело: экструзия контура со скруглёнными фасками; фаски и бока — тёмные (окантовка в объёме).
        let path = UIBezierPath()
        for (i, p) in HandCursor.outline.enumerated() {
            let q = CGPoint(x: p.x * k, y: p.y * k)
            if i == 0 { path.move(to: q) } else { path.addLine(to: q) }
        }
        path.close()
        path.flatness = 0.0005
        let body = SCNShape(path: path, extrusionDepth: 0.006 )
        body.chamferRadius = 0.0012
        body.chamferMode = .both
        // Элементы SCNShape: лицо, зад, бока, фаска спереди, фаска сзади.
        body.materials = [bodyMat, rimMat, rimMat, rimMat, rimMat]
        let bodyNode = SCNNode(geometry: body)

        // Тёмная обводка по контуру (как у системного курсора): кольцо шириной ~1,1 «пикселя» чуть тоньше тела.
        let ring = UIBezierPath(cgPath: path.cgPath.copy(strokingWithWidth: 1.1 * k * 2, lineCap: .round, lineJoin: .round, miterLimit: 4))
        let rim = SCNShape(path: ring, extrusionDepth: 0.0048)
        rim.chamferRadius = 0.0008
        rim.materials = [rimMat]
        let rimNode = SCNNode(geometry: rim)
        rimNode.simdPosition = SIMD3(0, 0, -0.0004)

        arrow.addChildNode(rimNode)
        arrow.addChildNode(bodyNode)
        arrow.castsShadow = false
        // Курсор всегда поверх сцены, как системный указатель (не прячется в объекте, к которому тянешься).
        for m in [bodyMat, rimMat] { m.readsFromDepthBuffer = false }
        bodyNode.renderingOrder = 101
        rimNode.renderingOrder = 100
        bodyNode.castsShadow = false
        rimNode.castsShadow = false
        node.addChildNode(arrow)
        node.isHidden = true
    }

    func attach(to parent: SCNNode) {
        parent.addChildNode(node)
        parent.addChildNode(blob.node)
    }

    func hide() {
        visible = false
        node.isHidden = true
        blob.node.isHidden = true
    }

    /// Поворот, при котором остриё смотрит по dir, а лицо стрелки — как можно больше к камере.
    private static func orientation(dir: SIMD3<Float>, toViewer: SIMD3<Float>) -> simd_quatf {
        let f = dir
        var n = toViewer - simd_dot(toViewer, f) * f
        if simd_length(n) < 1e-4 { n = abs(f.y) < 0.9 ? SIMD3(0, 1, 0) - f.y * f : SIMD3(1, 0, 0) - f.x * f }
        n = simd_normalize(n)
        let r = simd_cross(f, n)
        let lf = localForward, ln = SIMD3<Float>(0, 0, 1), lr = simd_cross(lf, ln)
        let world = simd_float3x3(columns: (r, f, n))
        let local = simd_float3x3(columns: (lr, lf, ln))
        return simd_quatf(world * local.transpose).normalized
    }

    /// target — точка острия, direction — куда смотрит рука; pinch — сила щипка 0…1; viewer — положение камеры.
    func update(target: SIMD3<Float>, direction dirIn: SIMD3<Float>, pinch: Float, state: State, dt: Float, opacity: Float = 1,
                viewer: SIMD3<Float> = SIMD3(0, 0.3, 0.3), tableY: Float? = nil) {
        let dir = simd_length(dirIn) > 1e-5 ? simd_normalize(dirIn) : direction
        if !visible || sculptStyle {
            // В рисовании без пружины: остриё совпадает с точкой кисти кадр в кадр.
            if !visible { rot = HandCursor.orientation(dir: dir, toViewer: simd_normalize(viewer - target)) }
            else { rot = simd_slerp(rot, HandCursor.orientation(dir: dir, toViewer: simd_normalize(viewer - target)), 1 - exp(-dt / max(rotationTau, 1e-3))).normalized }
            position = target; vel = .zero; direction = dir
            visible = true
        } else {
            // Критически демпфированная пружина (точное решение на шаге dt).
            let w = 2 * Float.pi * positionHz
            let e0 = position - target
            let c = vel + w * e0
            let ex = exp(-w * dt)
            position = target + (e0 + c * dt) * ex
            vel = (vel - w * c * dt) * ex
            let goal = HandCursor.orientation(dir: dir, toViewer: simd_normalize(viewer - position))
            rot = simd_slerp(rot, goal, 1 - exp(-dt / max(rotationTau, 1e-3))).normalized
            direction = dir
        }

        // Нажатие (щипок/хват) и подсветка — плавно.
        let pr: Float = state == .grab ? 1 : min(max(pinch, 0), 1) * 0.5
        press += (pr - press) * (1 - exp(-dt / 0.04))
        let gl: Float = state == .idle ? 0 : 1
        glow += (gl - glow) * (1 - exp(-dt / 0.08))

        node.isHidden = opacity <= 0.01
        node.opacity = CGFloat(opacity * (sculptStyle ? HandCursor.sculptOpacity : 1))
        node.simdPosition = position
        node.simdOrientation = rot
        // Остриё в начале координат стрелки — масштаб вокруг острия, точка взаимодействия не сдвигается.
        let s = (1 + 0.12 * glow - 0.18 * press) * (sculptStyle ? HandCursor.sculptScale : 1)
        arrow.simdScale = SIMD3(s, s, s * (1 - 0.4 * press))
        bodyMat.emission.intensity = CGFloat(0.12 + 0.25 * glow)
        rimMat.diffuse.contents = HandCursor.mix(rimColor, grabRim, CGFloat(min(1, press * 1.4)))

        if let ty = tableY { blob.update(at: position, tableY: ty, strength: opacity) } else { blob.node.isHidden = true }
    }

    private static func mix(_ a: UIColor, _ b: UIColor, _ t: CGFloat) -> UIColor {
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        a.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        b.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        return UIColor(red: r1 + (r2 - r1) * t, green: g1 + (g2 - g1) * t, blue: b1 + (b2 - b1) * t, alpha: 1)
    }
}
