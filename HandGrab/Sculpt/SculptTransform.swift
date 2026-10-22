import Foundation
import SceneKit
import simd

/// Поворот, перенос и масштаб скульптуры. Мир = центр + T + R·s·(локальная − центр).
struct SculptTransform {
    let center: SIMD3<Float>
    var yaw: Float = 0
    var pitch: Float = 0
    var translation: SIMD3<Float> = .zero
    var scale: Float = 1
    /// Инерция поворота после отпускания кулака, рад/с.
    var yawVel: Float = 0
    var pitchVel: Float = 0
    /// Затухание инерции: ~0,8 с до 5%.
    let inertiaTau: Float = 0.27
    /// 1 см хода кулака = 6°.
    let degPerMeter: Float = 600

    init(center: SIMD3<Float>) { self.center = center }

    var rotation: simd_quatf {
        simd_quatf(angle: yaw, axis: [0, 1, 0]) * simd_quatf(angle: pitch, axis: [1, 0, 0])
    }

    func toLocal(_ w: SIMD3<Float>) -> SIMD3<Float> {
        center + rotation.inverse.act((w - center - translation) / scale)
    }

    func toWorld(_ l: SIMD3<Float>) -> SIMD3<Float> {
        center + translation + rotation.act((l - center) * scale)
    }

    /// Применить к узлам: pivot стоит в центре, content сдвинут на −центр.
    func apply(pivot: SCNNode, content: SCNNode) {
        pivot.simdPosition = center + translation
        pivot.simdOrientation = rotation
        pivot.simdScale = SIMD3(repeating: scale)
        content.simdPosition = -center
    }

    /// Поворот кулаком: смещение ладони за кадр (мир).
    mutating func rotateBy(delta d: SIMD3<Float>, dt: Float) {
        let k = degPerMeter * .pi / 180
        let dy = d.x * k, dp = -d.y * k
        yaw += dy
        pitch = clampf(pitch + dp, -1.4, 1.4)
        if dt > 0 {
            let a = 1 - exp(-dt / 0.05)
            yawVel += (dy / dt - yawVel) * a
            pitchVel += (dp / dt - pitchVel) * a
        }
    }

    /// Инерция после отпускания.
    mutating func coast(dt: Float) -> Bool {
        guard abs(yawVel) > 0.01 || abs(pitchVel) > 0.01 else { yawVel = 0; pitchVel = 0; return false }
        yaw += yawVel * dt
        pitch = clampf(pitch + pitchVel * dt, -1.4, 1.4)
        let k = exp(-dt / inertiaTau)
        yawVel *= k; pitchVel *= k
        return true
    }

    mutating func stop() { yawVel = 0; pitchVel = 0 }
}

/// Два кулака: середина двигает, расстояние масштабирует (×0,25…×4), поворот вектора между ними вращает вокруг вертикали.
struct TwoHandTransform {
    let start: SculptTransform
    let mid0: SIMD3<Float>
    let dist0: Float
    let angle0: Float

    init(start: SculptTransform, a: SIMD3<Float>, b: SIMD3<Float>) {
        self.start = start
        mid0 = (a + b) / 2
        dist0 = max(simd_distance(a, b), 0.02)
        angle0 = atan2(b.z - a.z, b.x - a.x)
    }

    func apply(a: SIMD3<Float>, b: SIMD3<Float>) -> SculptTransform {
        var t = start
        t.stop()
        let mid = (a + b) / 2
        t.translation = start.translation + (mid - mid0)
        t.scale = clampf(start.scale * simd_distance(a, b) / dist0, 0.25, 4)
        var da = atan2(b.z - a.z, b.x - a.x) - angle0
        if da > .pi { da -= 2 * .pi }
        if da < -.pi { da += 2 * .pi }
        t.yaw = start.yaw - da
        return t
    }
}
