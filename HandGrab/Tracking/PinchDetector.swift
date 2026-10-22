import Foundation
import simd

/// Щипок и кулак с гистерезисом и дебаунсом (по кадрам Vision).
struct PinchDetector {
    /// Правила до 20.10 (вечер) — только для сравнения в оценке реплеев (TrackEval).
    static var legacy = false
    private(set) var pinching = false
    private(set) var fist = false
    private(set) var d: Float = 9
    private(set) var fistMetric: Float = 9
    private var pinchOnCount = 0, pinchOffCount = 0
    private var fistOnCount = 0, fistOffCount = 0

    mutating func reset() { self = PinchDetector() }

    static func palmCenter(_ j: [SIMD3<Float>]) -> SIMD3<Float> {
        (j[0] + j[5] + j[9] + j[13] + j[17]) / 5
    }

    /// pinch2D — расстояние «большой–указательный» в кадре, делённое на длину ладони в кадре. В 3D глубина кончиков
    /// неоднозначна (решение «ближе/дальше» может перескочить), в кадре — нет: берём меньшее из двух.
    mutating func update(joints j: [SIMD3<Float>], conf: [Float], scale s: Float, config c: TrackingConfig, pinch2D: Float? = nil) {
        guard s > 1e-4 else { return }
        d = simd_distance(j[HandJoint.thumbTip.rawValue], j[HandJoint.indexTip.rawValue]) / s
        if let d2 = pinch2D { d = min(d, d2) }
        let pc = PinchDetector.palmCenter(j)
        var sum: Float = 0
        for t in [8, 12, 16, 20] { sum += simd_distance(j[t], pc) }
        fistMetric = sum / 4 / s

        let tipsReliable = conf[HandJoint.thumbTip.rawValue] > 0.35 && conf[HandJoint.indexTip.rawValue] > 0.35

        if !pinching {
            pinchOnCount = (d < c.pinchOn && tipsReliable) ? pinchOnCount + 1 : 0
            if pinchOnCount >= 2 { pinching = true; pinchOffCount = 0 }
        } else {
            pinchOffCount = d > c.pinchOff ? pinchOffCount + 1 : 0
            if pinchOffCount >= 3 { pinching = false; pinchOnCount = 0 }
        }

        if !fist {
            fistOnCount = fistMetric < c.fistOn ? fistOnCount + 1 : 0
            if fistOnCount >= 2 { fist = true; fistOffCount = 0 }
        } else {
            fistOffCount = fistMetric > c.fistOff ? fistOffCount + 1 : 0
            if fistOffCount >= 3 { fist = false; fistOnCount = 0 }
        }
    }
}
