import Foundation
import simd

/// Жёсткий скелет: фиксированные длины костей и зажимы углов сгиба.
enum HandSkeletonSolver {
    /// Средние длины костей взрослой руки (м), индекс = дочерний сустав − 1. Масштаб для s = 0.082 м.
    static let referenceScale: Float = 0.082
    static let defaultLengths: [Float] = [
        0.030, 0.045, 0.032, 0.028,   // большой: запястье→CMC→MP→IP→кончик
        0.085, 0.040, 0.023, 0.020,   // указательный
        0.082, 0.044, 0.027, 0.022,   // средний
        0.078, 0.041, 0.026, 0.022,   // безымянный
        0.072, 0.033, 0.019, 0.019,   // мизинец
    ]

    /// Максимальный угол сгиба (рад) по позиции в цепочке: [ -, кость ладони, MCP, PIP, DIP ].
    private static let fingerMax: [Float] = [0, .pi, 90 * .pi / 180, 110 * .pi / 180, 80 * .pi / 180]
    private static let thumbMax: [Float] = [0, .pi, 70 * .pi / 180, 90 * .pi / 180, 90 * .pi / 180]

    static func lengths(config: TrackingConfig, scale: Float) -> [Float] {
        if let cal = config.boneLengths, cal.count == HandJoint.boneCount { return cal }
        let k = scale / referenceScale
        return defaultLengths.map { $0 * k }
    }

    /// Перестраивает скелет от запястья к кончикам: ребёнок = родитель + направление · L.
    static func solve(_ j: inout [SIMD3<Float>], lengths: [Float]) {
        let meas = j
        for (ci, chain) in HandJoint.chains.enumerated() {
            let maxAngles = ci == 0 ? thumbMax : fingerMax
            for k in 1..<chain.count {
                let p = chain[k - 1], c = chain[k]
                var dir = meas[c] - j[p]
                let len = simd_length(dir)
                if len < 1e-6 {
                    dir = k >= 2 ? simd_normalize(j[p] - j[chain[k - 2]]) : SIMD3<Float>(0, 1, 0)
                } else {
                    dir /= len
                }
                if k >= 2 {
                    let prevVec = j[p] - j[chain[k - 2]]
                    let pl = simd_length(prevVec)
                    if pl > 1e-6 {
                        let prevDir = prevVec / pl
                        let cosA = clampf(simd_dot(prevDir, dir), -1, 1)
                        let angle = acos(cosA)
                        let maxA = maxAngles[k]
                        if angle > maxA {
                            let axisRaw = simd_cross(prevDir, dir)
                            let al = simd_length(axisRaw)
                            if al > 1e-6 {
                                let axis = axisRaw / al
                                // Поворот prevDir на maxA вокруг оси, перпендикулярной prevDir.
                                dir = prevDir * cos(maxA) + simd_cross(axis, prevDir) * sin(maxA)
                            }
                        }
                    }
                }
                j[c] = j[p] + dir * lengths[c - 1]
            }
        }
    }
}
