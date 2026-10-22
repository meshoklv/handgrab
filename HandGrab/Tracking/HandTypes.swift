import Foundation
import simd
import Vision

/// 21 сустав руки в порядке Vision. Индекс кости = индекс дочернего сустава − 1.
enum HandJoint: Int, CaseIterable {
    case wrist = 0
    case thumbCMC, thumbMP, thumbIP, thumbTip
    case indexMCP, indexPIP, indexDIP, indexTip
    case middleMCP, middlePIP, middleDIP, middleTip
    case ringMCP, ringPIP, ringDIP, ringTip
    case littleMCP, littlePIP, littleDIP, littleTip

    static let count = 21
    static let boneCount = 20

    var parent: HandJoint? {
        switch self {
        case .wrist: return nil
        case .thumbCMC, .indexMCP, .middleMCP, .ringMCP, .littleMCP: return .wrist
        default: return HandJoint(rawValue: rawValue - 1)
        }
    }

    var isTip: Bool {
        switch self {
        case .thumbTip, .indexTip, .middleTip, .ringTip, .littleTip: return true
        default: return false
        }
    }

    /// Цепочки от запястья к кончику.
    static let chains: [[Int]] = [
        [0, 1, 2, 3, 4],
        [0, 5, 6, 7, 8],
        [0, 9, 10, 11, 12],
        [0, 13, 14, 15, 16],
        [0, 17, 18, 19, 20],
    ]

    static let palmIndices: [Int] = [0, 5, 9, 13, 17]
    static let tipIndices: [Int] = [4, 8, 12, 16, 20]

    static let vnNames: [VNHumanHandPoseObservation.JointName] = [
        .wrist,
        .thumbCMC, .thumbMP, .thumbIP, .thumbTip,
        .indexMCP, .indexPIP, .indexDIP, .indexTip,
        .middleMCP, .middlePIP, .middleDIP, .middleTip,
        .ringMCP, .ringPIP, .ringDIP, .ringTip,
        .littleMCP, .littlePIP, .littleDIP, .littleTip,
    ]
}

enum Chirality: Int {
    case unknown, left, right
}

/// Рука в 2D: координаты сенсора, нормированные, начало сверху слева (x вправо по строке буфера, y вниз).
struct Hand2D {
    var points: [SIMD2<Float>]
    var conf: [Float]
    var chirality: Chirality
    var goodCount: Int
}

/// Отфильтрованная рука в координатах сцены (метры, Y вверх, камера смотрит в −Z).
struct HandFrame {
    var slot: Int
    var frameID: UInt64
    var joints: [SIMD3<Float>]
    var jointVel: [SIMD3<Float>]
    var conf: [Float]
    var chirality: Chirality
    var scale: Float
    var captureTime: Double
    var processedTime: Double
    var pinching: Bool
    var fist: Bool
    var pinchD: Float
    var fistD: Float
    var palmDistance: Float
    /// Точка щепоти относительно центра ладони (сцена, м) по плоской модели: середина кончиков большого и указательного
    /// в кадре, на глубине ладони. Без выбора «ближе/дальше» у суставов пальцев — не прыгает. nil — старое правило.
    var pinchOffset: SIMD3<Float>? = nil
}

@inline(__always) func clampLength(_ v: SIMD3<Float>, _ maxLen: Float) -> SIMD3<Float> {
    let l = simd_length(v)
    return l > maxLen && l > 0 ? v * (maxLen / l) : v
}

@inline(__always) func clampf(_ x: Float, _ lo: Float, _ hi: Float) -> Float { min(max(x, lo), hi) }

/// Медиана массива (копирует и сортирует; размеры маленькие).
func medianOf(_ a: [Float]) -> Float? {
    if a.isEmpty { return nil }
    let s = a.sorted()
    let n = s.count
    return n % 2 == 1 ? s[n / 2] : 0.5 * (s[n / 2 - 1] + s[n / 2])
}
