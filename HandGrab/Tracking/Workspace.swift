import Foundation
import simd

/// Рабочий объём: естественная зона движения руки перед камерой → весь стол со всеми объектами.
///
/// * По экрану (кадр камеры в портрете, как селфи): горизонталь wsXMin…wsXMax → ширина стола,
///   вертикаль wsYTop…wsYBottom → высота над столом (верх кадра — рука высоко, низ — у самого стола).
/// * По дистанции до телефона: ±zSpan вокруг якоря → вся глубина стола. Якорь = дистанция ладони при появлении
///   руки (середина стола), дальше «едет» за рукой, если она вышла за ±zSpan.
/// * Форма руки — из жёсткой модели, увеличенная в handScale раз и наклонённая на handTilt (пальцы к столу).
enum Workspace {
    /// Высота центра ладони над столом: верх кадра / низ кадра.
    static let hoverTop: Float = 0.30
    static let hoverBottom: Float = 0.035

    static var zMid: Float { (SceneObjects.tableZNear + SceneObjects.tableZFar) / 2 }
    static var zHalf: Float { (SceneObjects.tableZNear - SceneObjects.tableZFar) / 2 }

    /// Мягкое ограничение: внутри [0,1] линейно, за краем — не дальше чем на 12% хода.
    @inline(__always) static func soft01(_ x: Float) -> Float { clampf(x, -0.12, 1.12) }

    /// Нормированная точка сенсора → точка экрана (селфи-портрет: x вправо = правая рука пользователя, y вниз).
    @inline(__always) static func screen(_ s: SIMD2<Float>, config c: TrackingConfig) -> SIMD2<Float> {
        CoordinateMapper.sensorToScreen(s, rotate180: c.rotate180, mirrorX: true)
    }

    /// Центр ладони в сцене по точке экрана и дистанции до телефона.
    static func palmScene(screen p: SIMD2<Float>, distance z: Float, anchor: Float, config c: TrackingConfig) -> SIMD3<Float> {
        let u = soft01((p.x - c.wsXMin) / max(c.wsXMax - c.wsXMin, 0.05))
        let v = soft01((p.y - c.wsYTop) / max(c.wsYBottom - c.wsYTop, 0.05))
        let x = (u * 2 - 1) * SceneObjects.halfWidth
        let y = SceneObjects.tableY + hoverTop + (hoverBottom - hoverTop) * v
        // w = +1: ладонь дальше от телефона (ближе к себе) → ближний край стола.
        let w = clampf((z - anchor) / max(c.zSpan, 0.03), -1.12, 1.12)
        let zs = zMid + (c.mirrorView ? -w : w) * zHalf
        return SIMD3(x, y, zs)
    }

    /// Обратное отображение (для синтетического реплея): центр ладони в сцене → точка экрана и дистанция.
    static func inverse(scene q: SIMD3<Float>, anchor: Float, config c: TrackingConfig) -> (SIMD2<Float>, Float) {
        let u = (q.x / SceneObjects.halfWidth + 1) / 2
        let v = (q.y - SceneObjects.tableY - hoverTop) / (hoverBottom - hoverTop)
        let sx = c.wsXMin + u * (c.wsXMax - c.wsXMin)
        let sy = c.wsYTop + v * (c.wsYBottom - c.wsYTop)
        var w = (q.z - zMid) / zHalf
        if c.mirrorView { w = -w }
        return (SIMD2(sx, sy), anchor + w * c.zSpan)
    }

    /// Поворот формы руки: оси камеры → сцена, затем наклон пальцами вперёд.
    static func shapeRotation(config c: TrackingConfig) -> simd_quatf {
        simd_quatf(angle: -c.handTilt * .pi / 180, axis: SIMD3(1, 0, 0))
    }

    /// Смещение сустава от центра ладони (оси камеры, м) → смещение в сцене.
    @inline(__always) static func shapeOffset(_ d: SIMD3<Float>, rot: simd_quatf, config c: TrackingConfig) -> SIMD3<Float> {
        rot.act(CoordinateMapper.cameraDirToScene(d, rotate180: c.rotate180, mirror: c.mirrorView) * c.handScale)
    }
}

/// Якорь глубины для одного слота руки.
struct DepthAnchor {
    private(set) var value: Float?
    private(set) var fromDepth = false
    private var lastSeen: Double = -10

    /// Обновить по текущей дистанции ладони; вернуть якорь.
    mutating func update(z: Float, depthFresh: Bool, t: Double, span: Float) -> Float {
        // Рука пропала больше чем на 1,5 с — следующая — новое появление, новый центр.
        if t - lastSeen > 1.5 { value = nil }
        lastSeen = t
        guard var a = value else {
            value = z; fromDepth = depthFresh
            return z
        }
        // Первая настоящая глубина после оценки по размеру — переякорить.
        if depthFresh && !fromDepth { a = z; fromDepth = true }
        if z - a > span { a = z - span }
        if a - z > span { a = z + span }
        value = a
        return a
    }

    mutating func reset() { value = nil }
}
