import Foundation
import simd

/// Предсказание позы руки на момент кадра дисплея.
enum HandPredictor {
    /// Вынос ладони не дальше этого (м). Было 5 см: на записях автора скачок скорости при новом кадре давал прыжок курсора 3–5 см.
    static var maxWristShift: Float = 0.01
    static let maxLocalShift: Float = 0.02

    /// Время выноса T, с.
    static func horizon(frame: HandFrame, now: Double, config: TrackingConfig) -> Float {
        if config.manualPrediction { return clampf(config.predictionMs, 0, 100) / 1000 }
        return clampf(Float(now - frame.captureTime), 0, 0.05)
    }

    /// x_pred = x + v·T·exp(−T/0.12), вынос запястья ≤ 3 см, локальный вынос пальцев ≤ 1.5 см.
    static func predict(frame: HandFrame, now: Double, config: TrackingConfig) -> [SIMD3<Float>] {
        let T = horizon(frame: frame, now: now, config: config)
        if T <= 0 { return frame.joints }
        let k = T * exp(-T / 0.12)
        let wristDelta = clampLength(frame.jointVel[0] * k, maxWristShift)
        var out = frame.joints
        out[0] += wristDelta
        for i in 1..<HandJoint.count {
            let local = clampLength((frame.jointVel[i] - frame.jointVel[0]) * k, maxLocalShift)
            out[i] += wristDelta + local
        }
        return out
    }
}
