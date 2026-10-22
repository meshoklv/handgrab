import Foundation
import SceneKit
import UIKit
import simd

/// Захват объектов щипком или кулаком, перенос критически затухающей пружиной, бросок.
final class GrabController {
    enum Mode { case pinch, fist }

    private struct Held {
        let object: GrabObject
        let mode: Mode
        let offsetPos: SIMD3<Float>
        let offsetRot: simd_quatf
        var pos: SIMD3<Float>
        var vel: SIMD3<Float>
        var rot: simd_quatf
    }

    private var held: [Held?] = [nil, nil]
    private var prevGesture = [false, false]
    private var prevFrameID: [UInt64] = [0, 0]
    private var history: [[(Double, SIMD3<Float>)]] = [[], []]

    let springHz: Float = 10
    let maxThrow: Float = 2.0
    let lostHold: Double = 0.15

    private let impactGrab = UIImpactFeedbackGenerator(style: .light)
    private let impactRelease = UIImpactFeedbackGenerator(style: .soft)

    func isHolding(_ slot: Int) -> Bool { held[slot] != nil }

    /// Поза руки для удержания: начало — точка хвата, базис — ладонь.
    static func handRotation(_ j: [SIMD3<Float>]) -> simd_quatf {
        let aRaw = j[9] - j[0]                               // запястье → средний MCP
        guard simd_length(aRaw) > 1e-4 else { return simd_quatf(angle: 0, axis: SIMD3(0, 1, 0)) }
        let a = simd_normalize(aRaw)
        var b = j[5] - j[17]                                 // мизинец → указательный
        b = b - simd_dot(b, a) * a
        guard simd_length(b) > 1e-4 else { return simd_quatf(angle: 0, axis: SIMD3(0, 1, 0)) }
        b = simd_normalize(b)
        let n = simd_cross(b, a)
        return simd_quatf(simd_float3x3(columns: (b, a, n)))
    }

    static func grabPoint(_ j: [SIMD3<Float>], mode: Mode) -> SIMD3<Float> {
        switch mode {
        case .pinch: return (j[HandJoint.thumbTip.rawValue] + j[HandJoint.indexTip.rawValue]) * 0.5
        case .fist: return PinchDetector.palmCenter(j)
        }
    }

    /// Объект, на который сейчас «наведена» рука (подсвечивается), по слотам.
    private(set) var hovered: [GrabObject?] = [nil, nil]
    /// Время начала жеста без захвата: 0,35 с после начала можно «дотянуться» до объекта.
    private var gestureStart: [Double] = [0, 0]
    /// После жеста дистанции захват ждёт, пока жест отпустят.
    private var suppressed = [false, false]
    let lateGrabWindow: Double = 0.35
    let releaseGrace: Double = 0.12
    private var offSince: [Double?] = [nil, nil]

    func suppressUntilRelease() { suppressed = [true, true] }

    /// Магнит: ближайший свободный объект к щепотке или к центру ладони (расстояние до поверхности < radius).
    private func candidate(_ j: [SIMD3<Float>], objects: [GrabObject], radius: Float) -> (GrabObject, Mode)? {
        var best: (GrabObject, Mode, Float)?
        for mode in [Mode.pinch, Mode.fist] {
            let gp = GrabController.grabPoint(j, mode: mode)
            for o in objects where o.heldBy == nil {
                let d = simd_distance(o.position, gp) - o.radius
                if d < radius, d < (best?.2 ?? .greatestFiniteMagnitude) { best = (o, mode, d) }
            }
        }
        return best.map { ($0.0, $0.1) }
    }

    /// Вызывается на каждом кадре дисплея для каждого слота.
    /// joints — предсказанная и перестроенная поза (nil — руки нет), age — сколько секунд руку не видели.
    /// enabled = false — захват выключен (жест дистанции), удержание при этом отпускается штатно.
    func update(slot: Int, frame: HandFrame?, joints: [SIMD3<Float>]?, age: Double, now: Double, dt: Float,
                objects: [GrabObject], magnet: Float, enabled: Bool = true) {
        guard let f = frame, let j = joints else {
            if let h = held[slot], age > lostHold { release(slot, h, velocity: .zero) }
            prevGesture[slot] = false
            hovered[slot] = nil
            return
        }
        // Рука потеряна, а объект в руке: держим 150 мс, потом отпускаем со скоростью 0.
        if age > lostHold {
            if let h = held[slot] { release(slot, h, velocity: .zero) }
            prevGesture[slot] = false
            hovered[slot] = nil
            history[slot].removeAll()
            return
        }

        let gesture = f.pinching || f.fist
        let newFrame = f.frameID != prevFrameID[slot]
        prevFrameID[slot] = f.frameID
        if newFrame && gesture && !prevGesture[slot] {
            gestureStart[slot] = now
            let c = candidate(j, objects: objects, radius: 1)
            EventLog.shared.write(String(format: "GESTURE on slot=%d %@ d=%.2f кул=%.2f ближайший=%@", slot, f.pinching ? "щипок" : "кулак",
                                         f.pinchD, f.fistD, c.map { $0.0.name } ?? "—"))
        }
        if newFrame && !gesture && prevGesture[slot] { EventLog.shared.write("GESTURE off slot=\(slot)") }
        if !gesture { suppressed[slot] = false }

        // Подсветка: что возьмётся, если сейчас сжать.
        hovered[slot] = (held[slot] == nil && enabled && !suppressed[slot])
            ? candidate(j, objects: objects, radius: magnet)?.0 : nil

        // Захват без прицеливания: пока жест держится и рядом (в радиусе магнита) есть объект — он прилетает в руку.
        if enabled, !suppressed[slot], gesture, held[slot] == nil,
           let (o, mode) = candidate(j, objects: objects, radius: magnet) {
            // Режим — по реальному жесту; если оба, ближайшая точка.
            let m: Mode = f.pinching && f.fist ? mode : (f.pinching ? .pinch : .fist)
            grab(slot, o, mode: m, joints: j)
            hovered[slot] = nil
        }
        if newFrame { prevGesture[slot] = gesture }

        guard var h = held[slot] else {
            history[slot].removeAll()
            return
        }

        let gp = GrabController.grabPoint(j, mode: h.mode)
        history[slot].append((now, gp))
        history[slot].removeAll { now - $0.0 > 0.15 }

        // Спад жеста держится ≥ 120 мс — отпускание с медианной скоростью точки хвата за 100 мс
        // (короткий сбой распознавания щипка не роняет объект).
        if gesture { offSince[slot] = nil } else if offSince[slot] == nil { offSince[slot] = now }
        if let off = offSince[slot], now - off >= releaseGrace {
            offSince[slot] = nil
            release(slot, h, velocity: releaseVelocity(slot, now: now))
            return
        }

        // Цель = поза руки × смещение; к цели — критически затухающая пружина f = 10 Гц, ζ = 1.
        let hr = GrabController.handRotation(j)
        let targetPos = gp + hr.act(h.offsetPos)
        let targetRot = hr * h.offsetRot
        let w = 2 * Float.pi * springHz
        let e0 = h.pos - targetPos
        let v0 = h.vel
        let ex = exp(-w * dt)
        let c = v0 + w * e0
        h.pos = targetPos + (e0 + c * dt) * ex
        h.vel = (v0 - w * c * dt) * ex
        h.rot = simd_slerp(h.rot, targetRot, 1 - ex)
        held[slot] = h

        h.object.node.simdPosition = h.pos
        h.object.node.simdOrientation = h.rot
    }

    private func grab(_ slot: Int, _ o: GrabObject, mode: Mode, joints j: [SIMD3<Float>]) {
        guard let body = o.node.physicsBody else { return }
        let pres = o.node.presentation
        let pos = pres.simdWorldPosition
        let rot = pres.simdWorldOrientation
        body.type = .kinematic
        body.velocity = SCNVector3Zero
        body.angularVelocity = SCNVector4Zero
        o.node.simdPosition = pos
        o.node.simdOrientation = rot
        let hr = GrabController.handRotation(j)
        let inv = hr.inverse
        // Магнит: объект прилетает центром в точку хвата (щепотка) или под ладонь (кулак), пружина делает перелёт.
        // Объект держится перед курсором по направлению руки: острие курсора касается его поверхности.
        var local = SIMD3<Float>(0, 0, 0)
        let aim = (j[9] - j[0]) + 0.5 * (j[8] - j[5])
        if simd_length(aim) > 1e-4 { local = inv.act(simd_normalize(aim) * (o.radius + 0.006)) }
        held[slot] = Held(object: o, mode: mode, offsetPos: local, offsetRot: inv * rot,
                          pos: pos, vel: .zero, rot: rot)
        o.heldBy = slot
        EventLog.shared.write(String(format: "GRAB slot=%d %@ mode=%@ obj=(%.3f,%.3f,%.3f)", slot, o.name,
                                     mode == .pinch ? "щипок" : "кулак", pos.x, pos.y, pos.z))
        history[slot].removeAll()
        DispatchQueue.main.async { [impactGrab] in impactGrab.impactOccurred() }
    }

    private func release(_ slot: Int, _ h: Held, velocity: SIMD3<Float>) {
        held[slot] = nil
        let p = h.pos
        EventLog.shared.write(String(format: "RELEASE slot=%d %@ at=(%.3f,%.3f,%.3f) v=%.2f", slot, h.object.name,
                                     p.x, p.y, p.z, simd_length(velocity)))
        h.object.heldBy = nil
        guard let body = h.object.node.physicsBody else { return }
        body.type = .dynamic
        body.resetTransform()
        body.velocity = SCNVector3(velocity.x, velocity.y, velocity.z)
        body.angularVelocity = SCNVector4Zero
        history[slot].removeAll()
        DispatchQueue.main.async { [impactRelease] in impactRelease.impactOccurred() }
    }

    private func releaseVelocity(_ slot: Int, now: Double) -> SIMD3<Float> {
        let hist = history[slot].filter { now - $0.0 <= 0.1 }
        guard hist.count >= 3 else { return .zero }
        var vx: [Float] = [], vy: [Float] = [], vz: [Float] = []
        for k in 1..<hist.count {
            let dt = Float(hist[k].0 - hist[k - 1].0)
            if dt < 1e-4 { continue }
            let v = (hist[k].1 - hist[k - 1].1) / dt
            vx.append(v.x); vy.append(v.y); vz.append(v.z)
        }
        guard let mx = medianOf(vx), let my = medianOf(vy), let mz = medianOf(vz) else { return .zero }
        return clampLength(SIMD3(mx, my, mz), maxThrow)
    }

    /// Сбросить всё удержание (кнопка «Сброс объектов»).
    func dropAll() {
        held = [nil, nil]
        hovered = [nil, nil]
        prevGesture = [false, false]
        history = [[], []]
    }
}
