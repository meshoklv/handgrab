import Foundation
import simd

/// Вход жестов одной руки за кадр (мир, м).
struct SculptHand {
    var visible = false
    var pinching = false
    var fist = false
    var pinchD: Float = 9
    var pinchPoint = SIMD3<Float>.zero
    var palm = SIMD3<Float>.zero
    /// Нормаль ладони (для ориентации ленты).
    var palmNormal = SIMD3<Float>(0, 0, 1)

    init() {}

    /// pinchOffset — сглаженное на 120 Гц смещение щепоти от ладони (nil — из кадра как есть).
    init(joints j: [SIMD3<Float>], frame f: HandFrame, pinchOffset: SIMD3<Float>? = nil) {
        visible = true
        // Сжатый кулак часто проходит и как «щипок» (большой у указательного): кулак важнее.
        pinching = f.pinching && !f.fist
        fist = f.fist
        pinchD = f.pinchD
        palm = PinchDetector.palmCenter(j)
        pinchPoint = (pinchOffset ?? f.pinchOffset).map { palm + $0 } ?? GrabController.grabPoint(j, mode: .pinch)
        palmNormal = GrabController.handRotation(j).act(SIMD3(0, 0, 1))
    }
}

/// Машина состояний жестов. Обе руки равноправны (с 20.10, вечер): щипок любой руки — свой мазок/тяга,
/// кулак одной руки ≥150 мс — поворот, два кулака — перенос и масштаб. «Ведущей руки» больше нет.
struct SculptGestures {
    enum Mode: String { case idle, draw, rotate, transform2 }

    struct Events {
        var drawBegin = [false, false]
        var drawEnd = [false, false]
        var rotating = false
        var rotateBegin = false
        /// Рука, кулак которой вращает (когда rotating).
        var rotateHand = 0
        var twoBegin = false
        var twoEnd = false
        var undoTap = false
    }

    private(set) var drawing = [false, false]
    private(set) var twoFists = false
    private(set) var rotating = false
    private(set) var rotateHand = 0
    private var offSince: [Double?] = [nil, nil]
    private var fistSince: [Double?] = [nil, nil]
    private var tapStart: [(Double, SIMD3<Float>)?] = [nil, nil]
    private var tapMoved = [false, false]
    let releaseGrace: Double = 0.12
    let fistHold: Double = 0.15

    var anyDrawing: Bool { drawing[0] || drawing[1] }
    var mode: Mode { twoFists ? .transform2 : anyDrawing ? .draw : rotating ? .rotate : .idle }

    mutating func update(hands h: [SculptHand], now: Double, undoGesture: Bool) -> Events {
        var e = Events()
        for s in 0..<2 {
            // Кулак не считается, пока эта рука рисует (сжатая щепоть похожа на кулак).
            if h[s].visible && h[s].fist && !drawing[s] { if fistSince[s] == nil { fistSince[s] = now } } else { fistSince[s] = nil }
        }
        func held(_ s: Int) -> Bool { fistSince[s].map { now - $0 >= fistHold } ?? false }

        // Два кулака — перенос/масштаб, рисование заблокировано.
        let two = held(0) && held(1)
        if two && !twoFists {
            e.twoBegin = true
            for s in 0..<2 where drawing[s] { drawing[s] = false; e.drawEnd[s] = true; offSince[s] = nil }
        }
        if !two && twoFists { e.twoEnd = true }
        twoFists = two

        // Поворот: кулак одной руки ≥ 150 мс (вторая может в это время рисовать).
        var rot = false
        if !two {
            if held(rotateHand) { rot = true }
            else if held(1 - rotateHand) { rot = true; if !rotating || !held(rotateHand) { rotateHand = 1 - rotateHand } }
        }
        if rot && !rotating { e.rotateBegin = true }
        rotating = rot
        e.rotating = rot
        e.rotateHand = rotateHand

        // Рисование: щипок любой руки; конец — через 120 мс после снятия щипка или сразу при потере руки.
        if !two {
            for s in 0..<2 {
                let on = h[s].visible && h[s].pinching
                if drawing[s] {
                    if !h[s].visible {
                        drawing[s] = false; e.drawEnd[s] = true; offSince[s] = nil
                    } else if on {
                        offSince[s] = nil
                    } else {
                        if offSince[s] == nil { offSince[s] = now }
                        if let o = offSince[s], now - o >= releaseGrace { drawing[s] = false; e.drawEnd[s] = true; offSince[s] = nil }
                    }
                } else if on && !held(s) && !(rotating && rotateHand == s) {
                    drawing[s] = true; e.drawBegin[s] = true; offSince[s] = nil
                }
            }
        }

        // Отмена коротким щипком любой руки (< 250 мс, сдвиг < 1 см); сам случайный мазок отбрасывается как слишком короткий.
        for s in 0..<2 {
            if undoGesture && !two && h[s].visible && h[s].pinching {
                if tapStart[s] == nil { tapStart[s] = (now, h[s].pinchPoint); tapMoved[s] = false }
                if let t = tapStart[s], simd_distance(t.1, h[s].pinchPoint) > 0.01 { tapMoved[s] = true }
            } else if let t = tapStart[s] {
                if undoGesture && now - t.0 < 0.25 && !tapMoved[s] { e.undoTap = true }
                tapStart[s] = nil
            }
        }
        return e
    }

    mutating func cancelDraw(_ s: Int) { drawing[s] = false; offSince[s] = nil }
}
