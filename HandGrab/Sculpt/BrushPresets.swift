import Foundation
import UIKit
import simd

/// Кисти режима «Рисование и скульпт».
enum BrushKind: Int, CaseIterable, Codable, Identifiable {
    case plasticine, neon, silk, stardust, chrome, plasma

    var id: Int { rawValue }
    var title: String { ["Пластилин", "Неон", "Шёлк", "Пыль", "Хром", "Плазма"][rawValue] }
    var key: String { ["plasticine", "neon", "silk", "stardust", "chrome", "plasma"][rawValue] }
    /// Светящиеся кисти включают bloom.
    var emissive: Bool { self == .neon || self == .stardust || self == .plasma }
    /// Можно тянуть щипком за середину (сохранение объёма, оседание).
    var canPull: Bool { self == .plasticine || self == .chrome }

    static func parse(_ s: String) -> BrushKind? {
        if let i = Int(s) { return BrushKind(rawValue: i) }
        return allCases.first { $0.key == s.lowercased() }
    }
}

/// Параметры кисти (начальные, версия — подбираются глазами и на руке).
struct BrushPreset {
    /// Сторон у трубки.
    var sides: Int
    /// Шаг колец по длине дуги, м.
    var ringStep: Float
    /// Базовый радиус (полуширина ленты, разброс пыли), м — до множителя толщины.
    var baseRadius: Float
    /// r = base · (pMin + (1 − pMin) · сила щипка).
    var pMin: Float
    /// Колец в полусфере на конце (0 — плавное сужение на 5 мм).
    var capRings: Int

    static func of(_ k: BrushKind) -> BrushPreset {
        switch k {
        case .plasticine: return BrushPreset(sides: 24, ringStep: 0.0015, baseRadius: 0.006, pMin: 0.5, capRings: 8)
        case .neon: return BrushPreset(sides: 16, ringStep: 0.0015, baseRadius: 0.0025, pMin: 0.7, capRings: 4)
        case .silk: return BrushPreset(sides: 2, ringStep: 0.0015, baseRadius: 0.007, pMin: 0.4, capRings: 0)
        case .stardust: return BrushPreset(sides: 6, ringStep: 0.002, baseRadius: 0.005, pMin: 0.5, capRings: 0)
        case .chrome: return BrushPreset(sides: 24, ringStep: 0.0015, baseRadius: 0.005, pMin: 0.6, capRings: 8)
        case .plasma: return BrushPreset(sides: 6, ringStep: 0.002, baseRadius: 0.0008, pMin: 0.6, capRings: 0)
        }
    }
}

/// Палитра HUD: 10 подобранных цветов (sRGB 0…1).
enum Palette {
    static let colors: [SIMD3<Float>] = [
        [0.80, 0.42, 0.30],   // глина-терракота
        [0.52, 0.88, 0.74],   // мята
        [0.96, 0.90, 0.77],   // сливочный
        [0.16, 0.34, 0.90],   // кобальт
        [1.00, 0.46, 0.42],   // коралл
        [0.98, 0.86, 0.28],   // лимон
        [0.70, 0.60, 0.96],   // лаванда
        [0.22, 0.23, 0.26],   // графит
        [0.97, 0.97, 0.97],   // белый
        [0.78, 0.80, 0.84],   // хром
    ]
    static let names = ["терракота", "мята", "сливочный", "кобальт", "коралл", "лимон", "лаванда", "графит", "белый", "хром"]

    /// Цвет кисти по умолчанию.
    static func defaultColor(_ k: BrushKind) -> SIMD3<Float> {
        switch k {
        case .plasticine: return colors[0]
        case .neon: return [0.20, 0.85, 1.00]
        case .silk: return colors[4]
        case .stardust: return colors[6]
        case .chrome: return colors[9]
        case .plasma: return [0.62, 0.42, 1.00]
        }
    }

    static func ui(_ c: SIMD3<Float>, _ a: CGFloat = 1) -> UIColor {
        UIColor(red: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: a)
    }
}

// MARK: Шум и цвет

/// Детерминированный хеш → 0…1.
@inline(__always) func hgHash(_ x: Int32, _ seed: UInt32) -> Float {
    var h = UInt32(bitPattern: x) &* 374_761_393 &+ seed &* 668_265_263
    h = (h ^ (h >> 13)) &* 1_274_126_177
    h ^= h >> 16
    return Float(h & 0xFFFFFF) / Float(0xFFFFFF)
}

/// Гладкий шум по одной оси → −1…1.
@inline(__always) func hgNoise1(_ x: Float, _ seed: UInt32) -> Float {
    let i = floor(x), f = x - i
    let u = f * f * (3 - 2 * f)
    let ii = Int32(clamping: Int(i))
    let a = hgHash(ii, seed), b = hgHash(ii &+ 1, seed)
    return (a + (b - a) * u) * 2 - 1
}

@inline(__always) func hgSmoothstep(_ e0: Float, _ e1: Float, _ x: Float) -> Float {
    let t = clampf((x - e0) / (e1 - e0), 0, 1)
    return t * t * (3 - 2 * t)
}

/// Сдвиг оттенка (градусы) в пространстве RGB (поворот вокруг серой оси).
func hgHueShift(_ c: SIMD3<Float>, degrees: Float) -> SIMD3<Float> {
    let a = degrees * .pi / 180
    let k = simd_normalize(SIMD3<Float>(1, 1, 1))
    let cosA = cos(a), sinA = sin(a)
    let r = c * cosA + simd_cross(k, c) * sinA + k * simd_dot(k, c) * (1 - cosA)
    return simd_clamp(r, SIMD3(repeating: 0), SIMD3(repeating: 1))
}

/// sRGB → линейный (вершинные цвета SceneKit читает как линейные).
@inline(__always) func hgLinear(_ c: SIMD3<Float>) -> SIMD3<Float> {
    SIMD3(pow(max(c.x, 0), 2.2), pow(max(c.y, 0), 2.2), pow(max(c.z, 0), 2.2))
}
