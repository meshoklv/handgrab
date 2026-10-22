import Foundation
import QuartzCore
import simd

/// Оценка трекинга по записанным сессиям без экрана и без реального времени (`-trackeval [файл.jsonl …]`).
///
/// Каждая сессия прогоняется через тот же код, что в приложении: назначение слотов → жёсткая модель → фильтры →
/// щипок/кулак → предсказание и сглаживание позы на 120 Гц (как HandSceneView) → жесты рисования → стабилизатор кисти.
/// Одна и та же сессия считается в вариантах «было» (правила до 20.10, вечер) и «стало» — числа до/после на одних данных.
/// Пишет Documents/trackeval.log, в конце строка «TRACKEVAL DONE».
final class TrackEval {
    struct Variant {
        var name: String
        /// Старое назначение слотов (метка + запястье) и метки MediaPipe перевёрнутые, как писались до 20.10.
        var legacyAssign = false
        var legacyLabels = false
        /// Рисует только «ведущая» рука (слот 1), как до 20.10.
        var legacyDraw = false
        var legacyPinch = false
        var hold: Double = 0.15
        var stabMinCutoff: Float = 1.2
        var stabBeta: Float = 0.04
        var leash: Float = 0.006
        /// Писать покадровый CSV (Documents/trackdump-<сессия>.csv) — для разбора.
        var dump = false
        var stablePinch = true
        var predShift: Float = HandPredictor.maxWristShift
        var prediction = true
        var smoothOffset = true
        var depthMinCutoff: Float = TrackingConfig().depthMinCutoff
        var depthBeta: Float = TrackingConfig().depthBeta
    }

    struct Stats {
        var dur: Double = 0
        var frames = 0
        var expected = 0, missing = 0
        var slotJumps = 0
        var teleports = 0
        var rawJerk: Double = 0, rawJerkN = 0
        var cursorJerk: Double = 0, cursorJerkN = 0
        var brushJerk: Double = 0, brushJerkN = 0
        var lagDist: Double = 0, lagSpeed: Double = 0, lagN = 0
        var pinchEpisodes = 0, pinchShort = 0, pinchRegrab = 0
        var strokes = [0, 0]        // по стороне кадра: 0 — левая рука пользователя, 1 — правая
        var strokesTiny = 0, strokeBreaks = 0
        var pinchNoStroke = [0, 0]  // щипок ≥150 мс, а мазка нет (по стороне)
        var bothDrawingS: Double = 0

        mutating func add(_ o: Stats) {
            dur += o.dur; frames += o.frames; expected += o.expected; missing += o.missing; slotJumps += o.slotJumps
            teleports += o.teleports
            rawJerk += o.rawJerk; rawJerkN += o.rawJerkN; cursorJerk += o.cursorJerk; cursorJerkN += o.cursorJerkN
            brushJerk += o.brushJerk; brushJerkN += o.brushJerkN
            lagDist += o.lagDist; lagSpeed += o.lagSpeed; lagN += o.lagN
            pinchEpisodes += o.pinchEpisodes; pinchShort += o.pinchShort; pinchRegrab += o.pinchRegrab
            for k in 0..<2 { strokes[k] += o.strokes[k]; pinchNoStroke[k] += o.pinchNoStroke[k] }
            strokesTiny += o.strokesTiny; strokeBreaks += o.strokeBreaks; bothDrawingS += o.bothDrawingS
        }

        var line: String {
            String(format: "без руки %.1f%% · перескоков слота %d · телепортов курсора %d · дрожь: кончик %.2f мм/кадр распозн., курсор %.3f мм/кадр 120Гц, кисть %.3f мм/кадр 120Гц · отставание кисти %.1f мм (%.0f мс) · щипков %d (коротких<100мс %d, перехватов<150мс %d) · мазков левой %d правой %d (сорванных %d, разрывов %d) · щипков без мазка: левой %d правой %d · обе рисуют %.1f с",
                   expected > 0 ? 100 * Double(missing) / Double(expected) : 0, slotJumps, teleports,
                   rawJerkN > 0 ? rawJerk / Double(rawJerkN) : 0, cursorJerkN > 0 ? cursorJerk / Double(cursorJerkN) : 0,
                   brushJerkN > 0 ? brushJerk / Double(brushJerkN) : 0,
                   lagN > 0 ? lagDist / Double(lagN) : 0, lagSpeed > 0 ? 1000 * lagDist / lagSpeed : 0,
                   pinchEpisodes, pinchShort, pinchRegrab, strokes[0], strokes[1], strokesTiny, strokeBreaks,
                   pinchNoStroke[0], pinchNoStroke[1], bothDrawingS)
        }
    }

    private var lines: [String] = []
    private var url: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("trackeval.log") }

    private func log(_ s: String) {
        lines.append(s)
        try? (lines.joined(separator: "\n") + "\n").data(using: .utf8)?.write(to: url, options: .atomic)
        NSLog("TRACKEVAL %@", s)
    }

    static func variants() -> [Variant] {
        var old = Variant(name: "было")
        old.legacyAssign = true; old.legacyLabels = true; old.legacyDraw = true; old.legacyPinch = true
        old.stablePinch = false; old.depthMinCutoff = 0; old.predShift = 0.05; old.smoothOffset = false
        var new = Variant(name: "стало")
        new.hold = SculptController.holdS
        new.stabMinCutoff = StrokeStabilizer.defaultMinCutoff; new.stabBeta = StrokeStabilizer.defaultBeta
        new.dump = ProcessInfo.processInfo.arguments.contains("-dump")
        guard ProcessInfo.processInfo.arguments.contains("-sweep") else { return [old, new] }
        // Подбор: «стало» с одним изменённым параметром.
        var out = [old, new]
        func vary(_ n: String, _ f: (inout Variant) -> Void) { var v = new; v.name = n; v.dump = false; f(&v); out.append(v) }
        vary("без плоской щепоти") { $0.stablePinch = false }
        vary("без сглаживания щепоти") { $0.smoothOffset = false }
        vary("прогноз выкл") { $0.prediction = false }
        vary("прогноз ≤5 см") { $0.predShift = 0.05 }
        vary("прогноз ≤1 см") { $0.predShift = 0.01 }
        vary("прогноз ≤3 см") { $0.predShift = 0.03 }
        vary("глубина 1/2") { $0.depthBeta = 2 }
        vary("глубина 0.5/2") { $0.depthMinCutoff = 0.5; $0.depthBeta = 2 }
        vary("без фильтра глубины") { $0.depthMinCutoff = 0 }
        vary("глубина 0.5/10") { $0.depthMinCutoff = 0.5 }
        vary("глубина 2/10") { $0.depthMinCutoff = 2 }
        vary("глубина 1/30") { $0.depthBeta = 30 }
        vary("удержание 0.15") { $0.hold = 0.15 }
        vary("удержание 0.45") { $0.hold = 0.45 }
        vary("кисть 1€ 0.6/0.04") { $0.stabMinCutoff = 0.6 }
        vary("кисть 1€ 2.4/0.04") { $0.stabMinCutoff = 2.4 }
        vary("кисть 1€ 1.2/0.1") { $0.stabBeta = 0.1 }
        vary("кисть 1€ 1.2/0.02") { $0.stabBeta = 0.02 }
        vary("поводок 0") { $0.leash = 0 }
        vary("поводок 3 мм") { $0.leash = 0.003 }
        vary("поводок 10 мм") { $0.leash = 0.010 }
        return out
    }

    func run(files: [URL], variants: [Variant] = TrackEval.variants()) {
        DispatchQueue.global(qos: .userInitiated).async {
            self.log("TRACKEVAL START файлов \(files.count)")
            var totals = [Stats](repeating: Stats(), count: variants.count)
            for f in files {
                guard let src = FileReplay(url: f) else { self.log("нет \(f.lastPathComponent)"); continue }
                for (k, v) in variants.enumerated() {
                    self.dumpName = f.deletingPathExtension().lastPathComponent
                    let s = self.simulate(src, v)
                    totals[k].add(s)
                    self.log(String(format: "%@ [%@] %.1f с: ", f.lastPathComponent, v.name, s.dur) + s.line)
                }
            }
            for (k, v) in variants.enumerated() { self.log("ИТОГО [\(v.name)] " + String(format: "%.1f с: ", totals[k].dur) + totals[k].line) }
            self.log("TRACKEVAL DONE")
        }
    }

    private var dumpName = ""

    // MARK: Прогон одной сессии

    private func simulate(_ src: FileReplay, _ v: Variant) -> Stats {
        var st = Stats()
        var cfg = TrackingConfig()
        cfg.stablePinchPoint = v.stablePinch
        cfg.depthMinCutoff = v.depthMinCutoff
        cfg.depthBeta = v.depthBeta
        cfg.predictionEnabled = v.prediction
        let savedShift = HandPredictor.maxWristShift
        HandPredictor.maxWristShift = v.predShift
        defer { HandPredictor.maxWristShift = savedShift }
        var offS: [SIMD3<Float>?] = [nil, nil]
        let fusion = HandFusion()
        let slots = [HandSlotState(slot: 0), HandSlotState(slot: 1)]
        var assigner = SlotAssigner()
        var legacy = SlotAssigner.Legacy()
        PinchDetector.legacy = v.legacyPinch
        defer { PinchDetector.legacy = false }
        let items = src.items
        guard let first = items.first, let last = items.last else { return st }
        st.dur = last.0 - first.0
        st.frames = items.count
        // Поза готова через ~45 мс после съёмки (замер hud.log без нагрузки скульпта).
        let delay = 0.045
        var latest: [HandFrame?] = [nil, nil]
        var seen: [Double] = [-10, -10]
        var slotPalm: [(Double, SIMD2<Float>)?] = [nil, nil]
        var rawHist: [[SIMD3<Float>]] = [[], []]
        var display: [[SIMD3<Float>]?] = [nil, nil]
        var prevCursor: [SIMD3<Float>?] = [nil, nil]
        var curHist: [[SIMD3<Float>]] = [[], []]
        var brushHist: [[SIMD3<Float>]] = [[], []]
        var gest = SculptGestures()
        var oldGest = LegacyGestures()
        var stabs = [StrokeStabilizer(), StrokeStabilizer()]
        var drawing = [false, false]
        var drawStart: [Double] = [0, 0], drawEndT: [Double] = [-10, -10]
        var drawLen: [Float] = [0, 0]
        var lastBrush: [SIMD3<Float>?] = [nil, nil]
        var drawSide = [0, 0]
        var pinchOn: [Double?] = [nil, nil], pinchOffT: [Double] = [-10, -10]
        var sPinch: [Double?] = [nil, nil]
        var sPinchDrew = [false, false]
        var sPinchSide = [0, 0]
        var idx = 0
        let dt = 1.0 / 120
        var dump = "t,slot,px,py,z,fresh,sx,sy,sz,gx,gy,gz,pinchD,fistD,pinch,fist,ch\n"
        defer {
            if v.dump {
                let u = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("trackdump-\(dumpName).csv")
                try? dump.data(using: .utf8)?.write(to: u)
            }
        }
        var now = first.0 + delay
        while now <= last.0 + delay + 0.5 {
            // Кадры распознавания, готовые к этому кадру рендера.
            while idx < items.count, items[idx].0 + delay <= now {
                let (t, hs0, zs) = items[idx]; idx += 1
                var hs = hs0
                if v.legacyLabels {
                    for i in hs.indices { hs[i].chirality = hs[i].chirality == .left ? .right : hs[i].chirality == .right ? .left : .unknown }
                }
                let asg = v.legacyAssign ? legacy.assign(hs, t: t) : assigner.assign(hs, t: t)
                for (hi, s) in asg {
                    let ss = slots[s]
                    if t - ss.lastSeen > 0.5 { ss.reset() }
                    if hi < zs.count, let z = zs[hi] { ss.depth.update(t: t, z: z) }
                    guard let fused = fusion.fuse(hs[hi], t: t, intr: src.intrinsics, state: ss, config: cfg) else { continue }
                    let f = fusion.filter(fused, hand: hs[hi], state: ss, t: t, config: cfg)
                    ss.lastWrist2D = hs[hi].points[0]
                    latest[s] = f; seen[s] = t
                    if v.dump {
                        let pc = PinchDetector.palmCenter(f.joints)
                        let g = f.pinchOffset.map { pc + $0 } ?? GrabController.grabPoint(f.joints, mode: .pinch)
                        let p2 = SlotAssigner.palm(hs[hi])
                        dump += String(format: "%.4f,%d,%.4f,%.4f,%.4f,%d,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.3f,%.3f,%d,%d,%d\n", t, s, p2.x, p2.y,
                                       fused.palmCameraZ, fused.depthFresh ? 1 : 0, pc.x, pc.y, pc.z, g.x, g.y, g.z, f.pinchD, f.fistD,
                                       f.pinching ? 1 : 0, f.fist ? 1 : 0, hs[hi].chirality.rawValue)
                    }
                    // Перескок: ладонь слота прыгнула больше чем на 20% кадра за ≤ 0,25 с — в слоте другая рука.
                    let palm = SlotAssigner.palm(hs[hi])
                    if let (pt, pp) = slotPalm[s], t - pt < 0.25, simd_distance(pp, palm) > 0.2 { st.slotJumps += 1 }
                    slotPalm[s] = (t, palm)
                    // Дрожь кончика по кадрам распознавания.
                    let g = f.pinchOffset.map { PinchDetector.palmCenter(f.joints) + $0 } ?? GrabController.grabPoint(f.joints, mode: .pinch)
                    rawHist[s].append(g); if rawHist[s].count > 3 { rawHist[s].removeFirst() }
                    if rawHist[s].count == 3 {
                        let j = simd_length(rawHist[s][2] - 2 * rawHist[s][1] + rawHist[s][0]) * 1000
                        if j < 30 { st.rawJerk += Double(j); st.rawJerkN += 1 }
                    }
                    // Эпизоды щипка (как его видит детектор).
                    if f.pinching && !f.fist {
                        if pinchOn[s] == nil {
                            pinchOn[s] = t; st.pinchEpisodes += 1
                            if t - pinchOffT[s] < 0.15 { st.pinchRegrab += 1 }
                        }
                    } else if let on = pinchOn[s] {
                        if t - on < 0.1 { st.pinchShort += 1 }
                        pinchOn[s] = nil; pinchOffT[s] = t
                    }
                }
            }
            // Кадр рендера: поза на экране как в HandSceneView.
            var hands = [SculptHand(), SculptHand()]
            for s in 0..<2 {
                guard let f = latest[s] else { display[s] = nil; continue }
                let age = now - seen[s]
                if age > 0.35 { display[s] = nil; offS[s] = nil; curHist[s].removeAll(); continue }
                var target = f.joints
                if cfg.predictionEnabled && age < 0.15 { target = HandPredictor.predict(frame: f, now: now, config: cfg) }
                let lengths = HandSkeletonSolver.lengths(config: cfg, scale: f.scale / max(cfg.handScale, 0.1)).map { $0 * cfg.handScale }
                HandSkeletonSolver.solve(&target, lengths: lengths)
                var joints = target
                if var d = display[s], simd_distance(d[0], target[0]) < 0.25 {
                    let a = Float(1 - exp(-dt / max(Double(cfg.displaySmoothMs) / 1000, 0.001)))
                    for i in 0..<HandJoint.count { d[i] += (target[i] - d[i]) * a }
                    HandSkeletonSolver.solve(&d, lengths: lengths)
                    joints = d
                }
                display[s] = joints
                if let o = f.pinchOffset {
                    if v.smoothOffset, let p = offS[s] {
                        let a = Float(1 - exp(-dt / max(Double(cfg.displaySmoothMs) / 1000, 0.001)))
                        offS[s] = p + (o - p) * a
                    } else { offS[s] = o }
                }
                if age < v.hold {
                    var h = SculptHand(joints: joints, frame: f, pinchOffset: offS[s])
                    if v.legacyDraw { h.pinching = f.pinching }
                    hands[s] = h
                }
            }
            // Ожидаемое число рук: максимум рук в записи в окне ±0,3 с.
            var expect = 0
            var k = max(0, idx - 40)
            while k < items.count, items[k].0 + delay <= now + 0.3 {
                if items[k].0 + delay >= now - 0.3 { expect = max(expect, items[k].1.count) }
                k += 1
            }
            let visible = hands.filter(\.visible).count
            st.expected += expect
            st.missing += max(0, expect - visible)

            for s in 0..<2 where hands[s].visible {
                let p = hands[s].pinchPoint
                if let q = prevCursor[s], simd_distance(p, q) > 0.03 {
                    st.teleports += 1; curHist[s].removeAll()
                    if v.dump, let f = latest[s] {
                        let d = p - q
                        let pal = PinchDetector.palmCenter(display[s] ?? f.joints)
                        log(String(format: "  TELEPORT t=%.3f слот %d сдвиг (%.0f,%.0f,%.0f) мм возраст %.0f мс скорость ладони %.2f м/с ладонь→щепоть %.0f мм",
                                   now - delay, s, d.x * 1000, d.y * 1000, d.z * 1000, (now - seen[s]) * 1000,
                                   simd_length(f.jointVel[0]), simd_distance(pal, p) * 1000))
                    }
                }
                prevCursor[s] = p
                curHist[s].append(p); if curHist[s].count > 3 { curHist[s].removeFirst() }
                if curHist[s].count == 3 {
                    st.cursorJerk += Double(simd_length(curHist[s][2] - 2 * curHist[s][1] + curHist[s][0]) * 1000); st.cursorJerkN += 1
                }
            }
            for s in 0..<2 where !hands[s].visible { prevCursor[s] = nil; curHist[s].removeAll() }

            // Жесты.
            var begin = [false, false], end = [false, false], drawNow = [false, false]
            if v.legacyDraw {
                let e = oldGest.update(hands: hands, dominant: 1, now: now)
                begin[1] = e.drawBegin; end[1] = e.drawEnd; drawNow[1] = oldGest.drawing
            } else {
                let e = gest.update(hands: hands, now: now, undoGesture: false)
                begin = e.drawBegin; end = e.drawEnd; drawNow = gest.drawing
            }
            for s in 0..<2 {
                let side = hands[s].visible ? (sideOf(latest[s]) ?? 0) : 0
                // Щипок глазами пользователя: держит щепоть ≥150 мс — ждёт, что рисует.
                if hands[s].visible && hands[s].pinching {
                    if sPinch[s] == nil { sPinch[s] = now; sPinchDrew[s] = false; sPinchSide[s] = side }
                    if drawNow[s] { sPinchDrew[s] = true }
                } else if let on = sPinch[s] {
                    if now - on >= 0.15 && !sPinchDrew[s] { st.pinchNoStroke[sPinchSide[s]] += 1 }
                    sPinch[s] = nil
                }
                if begin[s] {
                    drawing[s] = true; drawStart[s] = now; drawLen[s] = 0
                    if now - drawEndT[s] < 0.3 { st.strokeBreaks += 1 }
                    stabs[s] = StrokeStabilizer(); stabs[s].euro.minCutoff = v.stabMinCutoff; stabs[s].euro.beta = v.stabBeta
                    stabs[s].leash = v.leash; stabs[s].begin(at: hands[s].pinchPoint)
                    lastBrush[s] = hands[s].pinchPoint; brushHist[s] = []
                    drawSide[s] = side
                }
                if drawing[s] && drawNow[s] && hands[s].visible {
                    let raw = hands[s].pinchPoint
                    let b = stabs[s].feed(raw, t: now)
                    if let lb = lastBrush[s] { drawLen[s] += simd_distance(lb, b) }
                    lastBrush[s] = b
                    brushHist[s].append(b); if brushHist[s].count > 3 { brushHist[s].removeFirst() }
                    if brushHist[s].count == 3 {
                        st.brushJerk += Double(simd_length(brushHist[s][2] - 2 * brushHist[s][1] + brushHist[s][0]) * 1000); st.brushJerkN += 1
                    }
                    if curHist[s].count >= 2 {
                        st.lagDist += Double(simd_distance(b, raw) * 1000) / 1
                        st.lagSpeed += Double(simd_distance(curHist[s][curHist[s].count - 1], curHist[s][curHist[s].count - 2]) * 1000) / dt
                        st.lagN += 1
                    }
                }
                if end[s] && drawing[s] {
                    drawing[s] = false; drawEndT[s] = now
                    if drawLen[s] < 0.008 { st.strokesTiny += 1 } else { st.strokes[drawSide[s]] += 1 }
                }
            }
            if drawing[0] && drawing[1] { st.bothDrawingS += dt }
            now += dt
        }
        return st
    }

    /// Сторона руки глазами пользователя по положению ладони в кадре (селфи: экран слева — левая рука).
    private func sideOf(_ f: HandFrame?) -> Int? {
        guard let f else { return nil }
        // Сцена: x вправо по экрану (вид от первого лица = как своя рука). Центр стола x = 0.
        return PinchDetector.palmCenter(f.joints).x < 0 ? 0 : 1
    }
}

/// Жесты рисования до 20.10 (вечер): рисует только ведущая рука — для сравнения в оценке.
struct LegacyGestures {
    struct Events { var drawBegin = false; var drawEnd = false }
    private(set) var drawing = false
    private var offSince: Double?
    private var fistSince: [Double?] = [nil, nil]
    let releaseGrace: Double = 0.12
    let fistHold: Double = 0.15

    mutating func update(hands h: [SculptHand], dominant: Int, now: Double) -> Events {
        var e = Events()
        let dom = h[dominant]
        for s in 0..<2 {
            if h[s].visible && h[s].fist && !(s == dominant && h[s].pinching) { if fistSince[s] == nil { fistSince[s] = now } } else { fistSince[s] = nil }
        }
        func held(_ s: Int) -> Bool { fistSince[s].map { now - $0 >= fistHold } ?? false }
        let two = held(0) && held(1)
        if two { if drawing { drawing = false; e.drawEnd = true }; return e }
        let on = dom.visible && dom.pinching
        if drawing {
            if !dom.visible { drawing = false; e.drawEnd = true; offSince = nil }
            else if on { offSince = nil }
            else {
                if offSince == nil { offSince = now }
                if let o = offSince, now - o >= releaseGrace { drawing = false; e.drawEnd = true; offSince = nil }
            }
        } else if on && !held(dominant) {
            drawing = true; e.drawBegin = true; offSince = nil
        }
        return e
    }
}
