import Foundation
import simd

/// Внутренние параметры камеры в нормированных координатах кадра (0…1 по ширине/высоте буфера).
/// Видео и карта глубины TrueDepth зарегистрированы в одно поле зрения, поэтому одна матрица на оба.
struct Intrinsics {
    var fx: Float, fy: Float, cx: Float, cy: Float

    /// Луч с z = 1 через нормированную точку кадра.
    @inline(__always) func ray(_ p: SIMD2<Float>) -> SIMD3<Float> {
        SIMD3((p.x - cx) / fx, (p.y - cy) / fy, 1)
    }

    /// Горизонтальный (по экрану в портрете) угол обзора = по высоте буфера.
    var hfovDegrees: Float { 2 * atan(0.5 / fy) * 180 / .pi }

    /// Запасной вариант (версия): горизонталь сенсора 70°, пиксели квадратные, кадр 4:3.
    static let fallback = Intrinsics(fx: 0.714, fy: 0.952, cx: 0.5, cy: 0.5)
}

/// Глубина ладони во времени: альфа-бета фильтр по измерениям, привязанным к моменту съёмки карты.
struct PalmDepthTrack {
    private(set) var z: Float?
    private(set) var v: Float = 0
    private(set) var t: Double = 0
    private var rejects = 0

    mutating func reset() { z = nil; v = 0; rejects = 0 }

    mutating func update(t tm: Double, z zm: Float) {
        guard let z0 = z else { z = zm; v = 0; t = tm; return }
        let dt = Float(max(tm - t, 1e-3))
        let zp = z0 + v * dt
        let r = zm - zp
        // Выброс (край пальца, фон): отбрасываем до 2 подряд, третий принимаем как новую правду.
        if abs(r) > 0.06 && rejects < 2 { rejects += 1; return }
        rejects = 0
        z = zp + 0.6 * r
        v = clampf(v + 0.25 * r / dt, -1.5, 1.5)
        t = tm
    }

    /// Прогноз глубины на момент кадра tq (экстраполяция ≤ 100 мс).
    func at(_ tq: Double) -> Float? {
        guard let z else { return nil }
        return z + v * Float(clampf(Float(tq - t), 0, 0.1))
    }

    func age(_ tq: Double) -> Double { z == nil ? .infinity : tq - t }
}

/// Состояние одного «слота» руки (0 = голубая, 1 = оранжевая) между кадрами.
final class HandSlotState {
    let slot: Int
    var f2d = [OneEuroFilterV<SIMD2<Float>>](repeating: OneEuroFilterV(minCutoff: 1.6, beta: 4), count: HandJoint.count)
    var wrist = OneEuroFilterV<SIMD3<Float>>(minCutoff: 2, beta: 8)
    var depthF = OneEuroFilter(minCutoff: 0.5, beta: 2)
    var depth = PalmDepthTrack()
    /// Смещение глубины каждого сустава от ладони по последней карте (подсказка для выбора решения).
    var jointDev = [Float?](repeating: nil, count: HandJoint.count)
    var jointDevT: Double = -1
    /// Сырые 2D-точки последних кадров — чтобы сопоставить карту глубины с позой в момент её съёмки.
    var history: [(t: Double, points: [SIMD2<Float>], conf: [Float])] = []
    var prevDirs = [SIMD3<Float>?](repeating: nil, count: HandJoint.boneCount)
    var prevChoice = [Int](repeating: -1, count: HandJoint.boneCount)
    /// > 0 — правая рука, < 0 — левая (голосуют Vision и глубина).
    var handBelief: Float = 0
    var scaleWindow: [Float] = []
    var scale: Float?
    var prevScene: [SIMD3<Float>]?
    var vel = [SIMD3<Float>](repeating: .zero, count: HandJoint.count)
    var lastWrist2D: SIMD2<Float>?
    var lastT: Double = 0
    var lastSeen: Double = -1
    var pinch = PinchDetector()
    var frameCounter: UInt64 = 0
    /// Якорь глубины (середина стола) — переживает короткие потери руки.
    var anchor = DepthAnchor()

    init(slot: Int) { self.slot = slot }

    func reset() {
        for i in f2d.indices { f2d[i].reset() }
        wrist.reset()
        depthF.reset()
        depth.reset()
        jointDev = [Float?](repeating: nil, count: HandJoint.count)
        jointDevT = -1
        history.removeAll()
        prevDirs = [SIMD3<Float>?](repeating: nil, count: HandJoint.boneCount)
        prevChoice = [Int](repeating: -1, count: HandJoint.boneCount)
        handBelief = 0
        prevScene = nil
        vel = [SIMD3<Float>](repeating: .zero, count: HandJoint.count)
        lastWrist2D = nil
        pinch.reset()
        // scale и окно масштаба не сбрасываем: рука того же человека.
    }

    func apply(config c: TrackingConfig) {
        for i in f2d.indices {
            f2d[i].minCutoff = c.jointMinCutoff; f2d[i].beta = c.jointBeta; f2d[i].dCutoff = c.dCutoff
        }
        wrist.minCutoff = c.wristMinCutoff; wrist.beta = c.wristBeta; wrist.dCutoff = c.dCutoff
        depthF.minCutoff = c.depthMinCutoff; depthF.beta = c.depthBeta
    }
}

/// Результат решения жёсткой модели в осях камеры.
struct FusedHand {
    var camera: [SIMD3<Float>]
    var palmCameraZ: Float
    var depthFresh: Bool
    /// Точки на плоскости ладони (все на глубине ладони) — для калибровки длин по раскрытой ладони.
    var planar: [SIMD3<Float>]
    var scaleMeas: Float?
    /// Центр ладони в нормированных координатах сенсора (сглаженный).
    var palm2D: SIMD2<Float>
}

/// 2D (Vision) + глубина ладони (TrueDepth) → жёсткая 3D-модель руки.
///
/// Идея: глубина TrueDepth на суставах пальцев шумит и рвётся (края, тонкие пальцы), а на ладони стабильна.
/// Поэтому из карты берётся только глубина ладони (робастная медиана по внутренним точкам),
/// а каждый сустав ставится на свой луч камеры так, чтобы кость имела фиксированную длину:
/// |C − P| = L, C = t·луч. Из двух решений (ближе/дальше) выбираем по подсказке глубины,
/// анатомии (палец не выгибается назад), прошлому кадру и гистерезису.
final class HandFusion {
    let sampler = DepthSampler()

    // MARK: Глубина

    /// Измерить глубину ладони и смещения суставов по карте, снятой в момент, когда рука была в points.
    /// Возвращает false, если на ладони дыра.
    @discardableResult
    func ingest(depth: DepthMap, points p: [SIMD2<Float>], conf: [Float], state st: HandSlotState) -> Bool {
        let W = Float(depth.width), H = Float(depth.height)
        let palm = HandJoint.palmIndices.filter { conf[$0] > 0 }
        guard palm.count >= 3 else { return false }
        var c = SIMD2<Float>(0, 0)
        for i in palm { c += p[i] }
        c /= Float(palm.count)
        var zPalm: Float?
        var devs = [Float?](repeating: nil, count: HandJoint.count)
        _ = sampler.withLocked(depth) { acc in
            // Центр ладони и середины отрезков «центр → сустав ладони»: внутри ладони, не на краю.
            var samples: [Float] = []
            if let z = sampler.median(acc, u: c.x * W, v: c.y * H, radius: 3) { samples.append(z) }
            for i in palm {
                let q = (c + p[i]) * 0.5
                if let z = sampler.median(acc, u: q.x * W, v: q.y * H, radius: 2) { samples.append(z) }
            }
            guard samples.count >= 2, let zp = medianOf(samples) else { return }
            zPalm = zp
            for i in 0..<HandJoint.count where conf[i] > 0 {
                if let z = sampler.median(acc, u: p[i].x * W, v: p[i].y * H, radius: 1), abs(z - zp) < 0.10 {
                    devs[i] = z - zp
                }
            }
        }
        guard let zp = zPalm else { return false }
        st.depth.update(t: depth.time, z: zp)
        st.jointDev = devs
        st.jointDevT = depth.time
        return true
    }

    // MARK: Решение

    func fuse(_ h: Hand2D, t: Double, intr: Intrinsics, state st: HandSlotState, config c: TrackingConfig) -> FusedHand? {
        let n = HandJoint.count
        st.apply(config: c)

        // 1. Сглаженные 2D-точки. Пропавшая точка — прошлое значение фильтра, иначе родитель.
        var p = [SIMD2<Float>](repeating: .zero, count: n)
        var have = [Bool](repeating: false, count: n)
        for i in 0..<n {
            if h.conf[i] > 0 {
                p[i] = st.f2d[i].filter(h.points[i], t: t); have[i] = true
            } else if let v = st.f2d[i].value {
                p[i] = v; have[i] = true
            }
        }
        if !have[0] { return nil }
        for i in 1..<n where !have[i] {
            if let par = HandJoint(rawValue: i)?.parent?.rawValue { p[i] = p[par] }
        }
        let rays = p.map { intr.ray($0) }

        // 2. Глубина ладони: из карты (с прогнозом на момент кадра), иначе по размеру ладони в кадре.
        let refS = st.scale ?? c.calibratedScale ?? HandSkeletonSolver.referenceScale
        let palmSpan = simd_length(SIMD2(rays[9].x - rays[0].x, rays[9].y - rays[0].y))
        let zFromSize: Float? = palmSpan > 1e-3 ? clampf(refS / palmSpan, 0.12, 1.2) : nil
        var depthFresh = false
        var zPalm: Float
        if let zd = st.depth.at(t), st.depth.age(t) < 0.4 {
            zPalm = zd; depthFresh = true
        } else if let zs = zFromSize {
            zPalm = zs
        } else {
            zPalm = c.zCenter
        }

        // 3. Масштаб руки по плоскости ладони (только когда глубина настоящая).
        var sMeas: Float?
        if depthFresh, palmSpan > 1e-3 {
            let s = zPalm * palmSpan
            if s > 0.05 && s < 0.13 {
                sMeas = s
                st.scaleWindow.append(s)
                if st.scaleWindow.count > 90 { st.scaleWindow.removeFirst() }
                // 75-й перцентиль: наклон ладони только укорачивает проекцию.
                let sorted = st.scaleWindow.sorted()
                st.scale = clampf(sorted[min(sorted.count - 1, sorted.count * 3 / 4)], 0.065, 0.105)
            }
        }
        let s = c.calibratedScale ?? st.scale ?? HandSkeletonSolver.referenceScale
        let L = HandSkeletonSolver.lengths(config: c, scale: s)

        // 4. Голос Vision за «правая/левая».
        var vote: Float = 0
        switch h.chirality {
        case .right: vote = 1
        case .left: vote = -1
        case .unknown: vote = 0
        }
        if c.swapChirality { vote = -vote }
        st.handBelief = clampf(st.handBelief + 0.04 * vote, -1, 1)

        // 5. Жёсткая модель.
        let devFresh = t - st.jointDevT < 0.15
        func hintZ(_ i: Int) -> Float? {
            guard devFresh, let d = st.jointDev[i] else { return nil }
            return zPalm + d
        }
        var J = [SIMD3<Float>](repeating: .zero, count: n)
        // Запястье — на своём луче на глубине ладони (± подсказка, но не дальше 3 см: на запястье бывает рукав).
        let zw = zPalm + clampf(hintZ(0).map { $0 - zPalm } ?? 0, -0.03, 0.03)
        J[0] = rays[0] * zw

        // Суставы ладони: сфера вокруг запястья ∩ луч, решение ближе к плоскости ладони.
        for i in [1, 5, 9, 13, 17] {
            let prior = zPalm + clampf(hintZ(i).map { $0 - zPalm } ?? 0, -0.03, 0.03)
            let (cands, _) = sphereRay(parent: J[0], ray: rays[i], length: L[i - 1])
            J[i] = cands.min(by: { abs($0.z - prior) < abs($1.z - prior) }) ?? rays[i] * prior
            st.prevDirs[i - 1] = simd_normalize(J[i] - J[0])
        }

        // Нормаль ладони (в сторону ладони для правой руки — см. HandFusion.palmNormalSign).
        let nRaw = simd_cross(J[5] - J[0], J[17] - J[0])
        let nLen = simd_length(nRaw)
        let nUnit = nLen > 1e-6 ? nRaw / nLen : SIMD3<Float>(0, 0, -1)
        let handSign: Float = st.handBelief >= 0 ? 1 : -1
        let palmSide = nUnit * handSign

        for (ci, chain) in HandJoint.chains.enumerated() {
            for k in 2..<chain.count {
                let par = chain[k - 1], cj = chain[k], gp = chain[k - 2]
                let bone = cj - 1
                let (cands, ambiguous) = sphereRay(parent: J[par], ray: rays[cj], length: L[bone])
                let dParent = simd_normalize(J[par] - J[gp])
                if cands.count == 1 || !ambiguous {
                    J[cj] = cands[0]
                    st.prevChoice[bone] = -1
                } else {
                    var best = 0
                    var bestCost = Float.greatestFiniteMagnitude
                    var depthPick = -1
                    let hz = hintZ(cj)
                    if let hz {
                        let e0 = abs(cands[0].z - hz), e1 = abs(cands[1].z - hz)
                        if abs(cands[0].z - cands[1].z) > 0.02 && abs(e0 - e1) > 0.012 { depthPick = e0 < e1 ? 0 : 1 }
                    }
                    for (ki, cand) in cands.enumerated() {
                        let d = simd_normalize(cand - J[par])
                        var cost: Float = 0
                        if let hz { cost += min(9, pow((cand.z - hz) / 0.015, 2)) * 0.5 }
                        if ci != 0 {
                            // Переразгибание: кость уходит от ладони относительно родительской.
                            let hyper = simd_dot(dParent, palmSide) - simd_dot(d, palmSide)
                            cost += 30 * pow(max(0, hyper - 0.17), 2)
                        }
                        if let pd = st.prevDirs[bone] { cost += 3 * simd_length_squared(d - pd) }
                        if st.prevChoice[bone] == ki { cost -= 0.4 }
                        if cost < bestCost { bestCost = cost; best = ki }
                    }
                    J[cj] = cands[best]
                    st.prevChoice[bone] = best
                    // Глубина уверенно выбрала решение — это голос за «правая/левая».
                    if ci != 0, depthPick >= 0 {
                        let d = simd_normalize(cands[depthPick] - J[par])
                        let flex = simd_dot(d, nUnit) - simd_dot(dParent, nUnit)
                        if abs(flex) > 0.2 { st.handBelief = clampf(st.handBelief + 0.03 * (flex > 0 ? 1 : -1), -1, 1) }
                    }
                }
                st.prevDirs[bone] = simd_normalize(J[cj] - J[par])
            }
        }

        // 6. Ограничение углов (длины сохраняются).
        HandSkeletonSolver.solve(&J, lengths: L)

        let planar = rays.map { $0 * zPalm }
        var pc = SIMD2<Float>(0, 0)
        for i in HandJoint.palmIndices { pc += p[i] }
        pc /= Float(HandJoint.palmIndices.count)
        return FusedHand(camera: J, palmCameraZ: zPalm, depthFresh: depthFresh, planar: planar, scaleMeas: sMeas,
                         palm2D: pc)
    }

    /// Пересечение луча (через начало координат) со сферой |C − P| = L.
    /// Возвращает 1–2 точки; ambiguous = решения различаются по глубине > 4 мм.
    private func sphereRay(parent P: SIMD3<Float>, ray r: SIMD3<Float>, length L: Float) -> ([SIMD3<Float>], Bool) {
        let d = simd_normalize(r)
        let b = simd_dot(d, P)
        let disc = b * b - (simd_length_squared(P) - L * L)
        if disc <= 0 {
            // Луч проходит дальше длины кости (шум/неточная длина): ближайшая точка, длина сохранена.
            let q = d * b
            var dir = q - P
            let l = simd_length(dir)
            dir = l > 1e-6 ? dir / l : simd_normalize(d)
            return ([P + dir * L], false)
        }
        let sq = disc.squareRoot()
        let t1 = b - sq, t2 = b + sq
        if t1 < 0.05 { return ([d * t2], false) }
        let c1 = d * t1, c2 = d * t2
        return ([c1, c2], abs(c1.z - c2.z) > 0.004)
    }

    // MARK: Сцена, скорости, жесты

    func filter(_ fused: FusedHand, hand h: Hand2D, state st: HandSlotState, t: Double, config c: TrackingConfig) -> HandFrame {
        let n = HandJoint.count
        let J = fused.camera
        // Положение — через рабочий объём (кадр + дистанция → весь стол), форма — жёсткая модель, увеличенная.
        let zPalm = c.depthMinCutoff > 0 ? st.depthF.filter(fused.palmCameraZ, t: t) : fused.palmCameraZ
        let anchor = st.anchor.update(z: zPalm, depthFresh: fused.depthFresh, t: t, span: c.zSpan)
        let scr = Workspace.screen(fused.palm2D, config: c)
        let palmScene = Workspace.palmScene(screen: scr, distance: zPalm, anchor: anchor, config: c)
        let pf = st.wrist.filter(palmScene, t: t)
        let palmCam = (J[0] + J[5] + J[9] + J[13] + J[17]) / 5
        let rot = Workspace.shapeRotation(config: c)
        var joints = [SIMD3<Float>](repeating: .zero, count: n)
        for i in 0..<n {
            joints[i] = pf + Workspace.shapeOffset(J[i] - palmCam, rot: rot, config: c)
        }
        if let prev = st.prevScene, t - st.lastT > 1e-3, t - st.lastT < 0.2 {
            let dt = Float(t - st.lastT)
            for i in 0..<n {
                let v = (joints[i] - prev[i]) / dt
                st.vel[i] += (v - st.vel[i]) * 0.5
            }
        } else {
            st.vel = [SIMD3<Float>](repeating: .zero, count: n)
        }
        st.prevScene = joints
        // Точка щепоти по плоской модели: кончики в кадре (сглаженные 2D) на глубине ладони, глубина кончиков
        // относительно ладони — постоянная (щепоть ближе к телефону, чем ладонь). Смещение — как у суставов.
        var pinchOffset: SIMD3<Float>?
        if c.stablePinchPoint {
            let P = fused.planar
            let palmPl = (P[0] + P[5] + P[9] + P[13] + P[17]) / 5
            var off = (P[4] + P[8]) * 0.5 - palmPl
            off.z = -0.03
            pinchOffset = Workspace.shapeOffset(off, rot: rot, config: c)
        }

        let s = c.calibratedScale ?? st.scale ?? HandSkeletonSolver.referenceScale
        func p2(_ i: Int) -> SIMD2<Float> { st.f2d[i].value ?? h.points[i] }
        let palmLen2D = simd_distance(p2(0), p2(9))
        let pinch2D: Float? = palmLen2D > 1e-3 ? simd_distance(p2(4), p2(8)) / palmLen2D : nil
        st.pinch.update(joints: joints, conf: h.conf, scale: s * c.handScale, config: c, pinch2D: pinch2D)
        st.frameCounter += 1
        st.lastT = t
        st.lastSeen = t
        return HandFrame(slot: st.slot, frameID: st.frameCounter, joints: joints, jointVel: st.vel, conf: h.conf,
                         chirality: st.handBelief >= 0 ? .right : .left, scale: s * c.handScale, captureTime: t, processedTime: t,
                         pinching: st.pinch.pinching, fist: st.pinch.fist, pinchD: st.pinch.d,
                         fistD: st.pinch.fistMetric, palmDistance: fused.palmCameraZ, pinchOffset: pinchOffset)
    }
}

/// Калибровка: 2 с раскрытой ладони к камере → масштаб, длины костей (по плоскости ладони) и рабочая дистанция.
final class CalibrationCollector {
    private var bones: [[Float]] = Array(repeating: [], count: HandJoint.boneCount)
    private var scales: [Float] = []
    private var dists: [Float] = []
    private(set) var active = false
    private var endTime: Double = 0

    func start(now: Double, duration: Double = 2.0) {
        bones = Array(repeating: [], count: HandJoint.boneCount); scales = []; dists = []
        endTime = now + duration; active = true
    }

    func add(fused: FusedHand, now: Double) -> (bones: [Float], scale: Float, distance: Float)? {
        guard active else { return nil }
        if fused.depthFresh, let s = fused.scaleMeas {
            let j = fused.planar
            for i in 1..<HandJoint.count {
                if let p = HandJoint(rawValue: i)?.parent?.rawValue { bones[i - 1].append(simd_distance(j[i], j[p])) }
            }
            scales.append(s)
            dists.append(fused.palmCameraZ)
        }
        if now < endTime { return nil }
        active = false
        guard scales.count >= 10, let d = medianOf(dists) else { return nil }
        let sorted = scales.sorted()
        let s = sorted[sorted.count * 3 / 4]
        let k = s / HandSkeletonSolver.referenceScale
        var out: [Float] = []
        for i in 0..<HandJoint.boneCount {
            let def = HandSkeletonSolver.defaultLengths[i] * k
            // Проекция только укорачивает кость: берём верхний квартиль, держим в пределах ±25% от пропорций.
            let b = bones[i].sorted()
            let m = b.isEmpty ? def : b[b.count * 3 / 4]
            out.append(clampf(m, def * 0.8, def * 1.25))
        }
        return (out, s, d)
    }

    func cancelIfExpired(now: Double) -> Bool {
        if active && now > endTime + 1 { active = false; return true }
        return false
    }
}
