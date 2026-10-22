import Foundation
import CoreGraphics
import ImageIO
import simd

/// Все переводы систем координат в одном месте.
///
/// Системы:
/// * Vision — нормированные точки в ПОВЁРНУТОМ (по orientation) изображении, начало внизу слева.
/// * Сенсор — нормированные координаты нативного буфера камеры, начало сверху слева (x по строке, y вниз).
///   Видео и карта глубины в ней совпадают (поворот/зеркало на соединениях выключены).
/// * Камера — метры, оси сенсора: X вдоль строки, Y вниз, Z от камеры к человеку.
/// * Сцена — метры, X вправо по экрану, Y вверх, камера в начале координат смотрит в −Z.
enum CoordinateMapper {

    /// Точка Vision → нормированные координаты сенсора.
    /// Таблица — обратная к правилу отображения EXIF-ориентации: показанный(x,y) = сохранённый(f(x,y)).
    static func visionToSensor(_ p: CGPoint, orientation: CGImagePropertyOrientation) -> SIMD2<Float> {
        let x = Float(p.x)
        let y = 1 - Float(p.y) // в показанном изображении, начало сверху слева
        switch orientation {
        case .up: return SIMD2(x, y)
        case .upMirrored: return SIMD2(1 - x, y)
        case .down: return SIMD2(1 - x, 1 - y)
        case .downMirrored: return SIMD2(x, 1 - y)
        case .leftMirrored: return SIMD2(y, x)
        case .right: return SIMD2(y, 1 - x)
        case .rightMirrored: return SIMD2(1 - y, 1 - x)
        case .left: return SIMD2(1 - y, x)
        @unknown default: return SIMD2(x, y)
        }
    }

    /// Направление в осях камеры → направление в сцене (без переноса).
    ///
    /// Буфер фронталки в портрете показывается без зеркала ориентацией `.right`
    /// (проверено: Apple-пример «Tracking the User's Face in Real Time» даёт `.leftMirrored` для зеркального
    /// портрета, это `.right` + отражение). Значит в неотражённом кадре: вправо = −Yc, вверх = −Xc.
    ///
    /// * Вид от первого лица (по умолчанию): зритель стоит за рукой (у глаз пользователя) и смотрит на телефон.
    ///   Его «вправо» = +Yc, «вверх» = −Xc, «к себе» (+z сцены) = +Zc. Это поворот, не отражение:
    ///   правая рука остаётся правой, при ладони к телефону видна тыльная сторона.
    /// * Зеркало: то же, но z = −Zc (отражение в плоскости экрана, как в зеркале/селфи).
    @inline(__always)
    static func cameraDirToScene(_ c: SIMD3<Float>, rotate180: Bool, mirror: Bool) -> SIMD3<Float> {
        var x = c.y, y = -c.x
        if rotate180 { x = -x; y = -y }
        return SIMD3(x, y, mirror ? -c.z : c.z)
    }

    /// Нормированная точка сенсора → нормированная точка на экране (начало сверху слева),
    /// согласовано с cameraToScene. Используется для превью.
    @inline(__always)
    static func sensorToScreen(_ s: SIMD2<Float>, rotate180: Bool, mirrorX: Bool = true) -> SIMD2<Float> {
        var sx = s.y, sy = s.x
        if rotate180 { sx = 1 - sx; sy = 1 - sy }
        if !mirrorX { sx = 1 - sx }
        return SIMD2(sx, sy)
    }

    /// EXIF-ориентация, которая показывает буфер сенсора так же, как sensorToScreen.
    static func previewOrientation(rotate180: Bool, mirrorX: Bool = true) -> CGImagePropertyOrientation {
        switch (rotate180, mirrorX) {
        case (false, true): return .leftMirrored
        case (true, true): return .rightMirrored
        case (false, false): return .right
        case (true, false): return .left
        }
    }

    /// Горизонтальный (по экрану в портрете) угол обзора камеры в градусах.
    /// По экрану горизонталь = ось Y сенсора = высота карты глубины.
    static func horizontalFOVDegrees(fy: Float, height: Float) -> Float {
        2 * atan((height * 0.5) / fy) * 180 / .pi
    }
}
