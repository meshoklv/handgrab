import Foundation
import simd

/// Назначение распознанных рук слотам 0/1 между кадрами.
///
/// С 20.10 (вечер): рука держит свой слот по близости к прогнозу своей ладони в кадре, метка «левая/правая»
/// распознавателя почти не участвует. Метки шумят и у MediaPipe были сопоставлены наоборот: в записях автора
/// 508 из 524 кадров с двумя руками метка противоречила положению руки в кадре. Слот теперь не означает «правая»
/// или «левая» — обе руки равноправны (рисуют обе), слот — просто «эта же рука, что в прошлом кадре».
struct SlotAssigner {
    struct Slot {
        var palm: SIMD2<Float>?
        var vel = SIMD2<Float>(0, 0)
        var t: Double = -10
    }
    private(set) var slots = [Slot(), Slot()]
    /// Слот «живой», если рука в нём была не дольше этого времени назад.
    var keep: Double = 0.5
    /// Дальше этого (доля кадра) от прогноза — это другая рука, не продолжение.
    var gate: Float = 0.30

    static func palm(_ h: Hand2D) -> SIMD2<Float> {
        var c = SIMD2<Float>(0, 0)
        for i in HandJoint.palmIndices { c += h.points[i] }
        return c / Float(HandJoint.palmIndices.count)
    }

    private func predicted(_ s: Int, t: Double) -> SIMD2<Float>? {
        guard let p = slots[s].palm, t - slots[s].t < keep else { return nil }
        let dt = Float(min(max(t - slots[s].t, 0), 0.1))
        return p + slots[s].vel * dt
    }

    /// Свободный слот для новой руки: по метке (левая → 0), без метки — по стороне кадра (экран слева → 0).
    private func freshSlot(_ h: Hand2D) -> Int {
        switch h.chirality {
        case .left: return 0
        case .right: return 1
        case .unknown: return SlotAssigner.palm(h).y < 0.5 ? 0 : 1   // экран x = сенсор y
        }
    }

    /// Вернуть пары (индекс руки, слот).
    mutating func assign(_ hands: [Hand2D], t: Double) -> [(Int, Int)] {
        if hands.isEmpty { return [] }
        let palms = hands.map(SlotAssigner.palm)
        let pred = [predicted(0, t: t), predicted(1, t: t)]
        func cost(_ i: Int, _ s: Int) -> Float? {
            guard let p = pred[s] else { return nil }
            let d = simd_distance(p, palms[i])
            return d < gate ? d : nil
        }
        var out: [(Int, Int)] = []
        if hands.count == 1 {
            let c0 = cost(0, 0), c1 = cost(0, 1)
            if let a = c0, let b = c1 { out = [(0, a <= b ? 0 : 1)] }
            else if c0 != nil { out = [(0, 0)] }
            else if c1 != nil { out = [(0, 1)] }
            else {
                // Новая рука: в свободный слот; если свободны оба — по метке/стороне.
                let free = [pred[0] == nil, pred[1] == nil]
                if free[0] && free[1] { out = [(0, freshSlot(hands[0]))] }
                else if free[0] { out = [(0, 0)] }
                else if free[1] { out = [(0, 1)] }
                else {
                    // Оба слота живы, но рука далеко от обоих: продолжение того, кого дольше не видели.
                    out = [(0, slots[0].t <= slots[1].t ? 0 : 1)]
                }
            }
        } else {
            // Две руки: перебор двух вариантов; непродолжение стоит 0.5 (дороже любого допустимого сдвига).
            let miss: Float = 0.5
            func c(_ i: Int, _ s: Int) -> Float { cost(i, s) ?? miss }
            let a = c(0, 0) + c(1, 1), b = c(0, 1) + c(1, 0)
            if abs(a - b) < 1e-4 {
                // Оба слота пусты (или одинаково): левая по кадру — в слот 0.
                let left = palms[0].y <= palms[1].y ? 0 : 1
                out = [(left, 0), (1 - left, 1)]
            } else {
                out = a < b ? [(0, 0), (1, 1)] : [(0, 1), (1, 0)]
            }
        }
        for (i, s) in out {
            let p = palms[i]
            if let old = slots[s].palm, t - slots[s].t < 0.2, t > slots[s].t {
                let v = (p - old) / Float(t - slots[s].t)
                slots[s].vel += (v - slots[s].vel) * 0.5
            } else {
                slots[s].vel = .zero
            }
            slots[s].palm = p
            slots[s].t = t
        }
        return out
    }

    /// Старое правило (до 20.10, вечер) — только для сравнения в оценке реплеев:
    /// расстояние до прошлого запястья + штраф 0.15 за несовпадение метки (левая → слот 0, правая → слот 1).
    struct Legacy {
        var lastWrist: [SIMD2<Float>?] = [nil, nil]
        var lastSeen: [Double] = [-1, -1]
        mutating func assign(_ hands: [Hand2D], t: Double) -> [(Int, Int)] {
            if hands.isEmpty { return [] }
            func preferred(_ h: Hand2D) -> Int? {
                switch h.chirality { case .left: return 0; case .right: return 1; case .unknown: return nil }
            }
            func cost(_ h: Hand2D, _ s: Int) -> Float {
                var v: Float = 0
                if let w = lastWrist[s], t - lastSeen[s] < 0.3 { v += simd_distance(w, h.points[0]) } else { v += 0.25 }
                if let p = preferred(h), p != s { v += 0.15 }
                return v
            }
            let out: [(Int, Int)]
            if hands.count == 1 {
                out = cost(hands[0], 0) <= cost(hands[0], 1) ? [(0, 0)] : [(0, 1)]
            } else {
                let a = cost(hands[0], 0) + cost(hands[1], 1)
                let b = cost(hands[0], 1) + cost(hands[1], 0)
                out = a <= b ? [(0, 0), (1, 1)] : [(0, 1), (1, 0)]
            }
            for (i, s) in out { lastWrist[s] = hands[i].points[0]; lastSeen[s] = t }
            return out
        }
    }
}
