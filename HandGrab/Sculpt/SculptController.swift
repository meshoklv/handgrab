import Foundation
import SceneKit
import UIKit
import simd

/// Режим «Рисование и скульпт»: вход — позы рук на каждом кадре рендера, выход — мазки в `root`.
/// Всё, кроме HUD, работает на потоке рендера SceneKit.
final class SculptController {
    /// Скульптура висит в центре рабочего объёма.
    static var center: SIMD3<Float> { SIMD3(0, SceneObjects.tableY + 0.15, Workspace.zMid) }

    let root = SCNNode()
    private let pivot = SCNNode()
    private let content = SCNNode()
    private let studioLights = SCNNode()
    /// Курсор-шарик кисти и подсветка «что возьмётся» — по одному на руку (рисуют обе).
    private let cursors = [SCNNode(), SCNNode()]
    private let hoverNodes = [SCNNode(), SCNNode()]
    private let stage = SCNNode()
    private let shadow = SCNNode()
    private let catcher = SCNNode()
    private let keyNode = SCNNode()

    /// Режим включён (применённое на потоке рендера состояние).
    private(set) var active = false
    private var snap = SculptSnap()

    private var strokes: [StrokeData] = []
    private var views: [Int: StrokeView] = [:]
    private var nextID = 1
    private var undo = SculptUndo()
    private var xf = SculptTransform(center: SculptController.center)
    private var two: TwoHandTransform?
    private var gestures = SculptGestures()
    private var lastRotPalm: SIMD3<Float>?

    private struct Draw {
        var id: Int
        var mirrorID: Int?
        var builder: StrokeBuilder
        var stab = StrokeStabilizer()
        var t0: Double
        var p: Float
        var normal: SIMD3<Float>
        var extendedFrom: Float?
        /// Узел стыка при продолжении линии (последний узел старой части).
        var junction: Int?
        /// Мазок до продолжения (для отмены); nil — новый мазок.
        var before: StrokeData?
    }
    /// Мазок / тяга каждой руки (слот 0 и 1) — руки рисуют одновременно и независимо.
    private var draws: [Draw?] = [nil, nil]
    private var pulls: [PlasticinePull?] = [nil, nil]
    private var pullStabs = [StrokeStabilizer(), StrokeStabilizer()]
    private var pullBefore: [StrokeData?] = [nil, nil]
    private var settles: [SettleAnim] = []

    private struct Drip { let id: Int; let start: Double; let base: [StrokeNode]; let down: SIMD3<Float> }
    private var drips: [Drip] = []

    private struct Saved {
        var background: Any?
        var env: Any?
        var envIntensity: CGFloat
        var lights: [(SCNLight, CGFloat, Bool)]
        var objectsHidden: Bool
        var physicsSpeed: CGFloat
        var camOrientation: simd_quatf
        var hdr: Bool, bloom: CGFloat, vignette: CGFloat, exposureAdapt: Bool
        var ssao: CGFloat
        /// Чужие узлы, отбрасывавшие тень (рука и пр.): в режиме тень на подиум даёт только скульптура.
        var casters: [SCNNode]
    }
    private var saved: Saved?
    private weak var camera: SCNNode?
    private var bloomOn = false

    private var demo: SculptDemo?
    private var demoHands = DemoHands()
    private var bench: SculptBench?

    // Счётчики
    private var cpuAcc: Double = 0, cpuMax: Double = 0, cpuN = 0
    private var dtAcc: Float = 0, dtN = 0
    private var lastStats: Double = 0, lastLog: Double = 0

    init() {
        root.name = "sculpt-root"
        root.isHidden = true
        root.addChildNode(pivot)
        pivot.addChildNode(content)
        xf.apply(pivot: pivot, content: content)
        let M = SculptMaterials.shared
        // Прогреть ленивые материалы на главном потоке (дальше их читает рендер).
        _ = [M.clay, M.chrome, M.silk, M.dust, M.dustSpine, M.cursor, M.highlight]
        _ = M.studioCube; _ = M.background; _ = M.shadowBlob; _ = M.stageGlow

        // Студийный свет: тёплый ключевой сверху-спереди (он же даёт мягкую тень на пол), холодный контровой сзади,
        // слабый заполняющий снизу-сбоку — объём читается, тени в складках не проваливаются в черноту.
        let key = SCNLight(); key.type = .directional; key.intensity = 950
        key.color = UIColor(red: 1, green: 0.95, blue: 0.88, alpha: 1)
        key.castsShadow = true
        key.shadowMode = .forward
        key.shadowMapSize = SculptController.lite ? CGSize(width: 1024, height: 1024) : CGSize(width: 2048, height: 2048)
        key.shadowSampleCount = SculptController.lite ? 4 : 16
        key.shadowRadius = 14
        key.shadowColor = UIColor(white: 0, alpha: 0.55)
        key.orthographicScale = 0.3
        key.zNear = 0.05; key.zFar = 2
        key.shadowBias = 2
        keyNode.light = key
        keyNode.simdPosition = SculptController.center + SIMD3(-0.18, 0.6, 0.30)
        keyNode.look(at: SCNVector3(SculptController.center))
        let rim = SCNLight(); rim.type = .directional; rim.intensity = 650; rim.color = UIColor(red: 0.72, green: 0.84, blue: 1, alpha: 1)
        let rn = SCNNode(); rn.light = rim
        rn.simdPosition = SculptController.center + SIMD3(0.35, 0.3, -0.5)
        rn.look(at: SCNVector3(SculptController.center))
        let fill = SCNLight(); fill.type = .directional; fill.intensity = 180; fill.color = UIColor(red: 1, green: 0.85, blue: 0.78, alpha: 1)
        let fn = SCNNode(); fn.light = fill
        fn.simdPosition = SculptController.center + SIMD3(0.4, -0.2, 0.3)
        fn.look(at: SCNVector3(SculptController.center))
        studioLights.addChildNode(keyNode); studioLights.addChildNode(rn); studioLights.addChildNode(fn)
        root.addChildNode(studioLights)

        // Сцена-«подиум»: светлое пятно, настоящая мягкая тень скульптуры (пол-ловец теней) и лёгкое пятно-подложка.
        let st = SCNPlane(width: 0.9, height: 0.9)
        let sm = SCNMaterial(); sm.lightingModel = .constant; sm.diffuse.contents = M.stageGlow; sm.writesToDepthBuffer = false
        st.materials = [sm]
        stage.geometry = st
        stage.simdEulerAngles = SIMD3(-.pi / 2, 0, 0)
        stage.simdPosition = SIMD3(0, SceneObjects.tableY - 0.002, SculptController.center.z)
        stage.renderingOrder = -10
        stage.castsShadow = false
        root.addChildNode(stage)
        let cp = SCNPlane(width: 0.9, height: 0.9)
        cp.materials = [M.shadowCatcher]
        catcher.geometry = cp
        catcher.simdEulerAngles = SIMD3(-.pi / 2, 0, 0)
        catcher.simdPosition = SIMD3(0, SceneObjects.tableY - 0.0015, SculptController.center.z)
        catcher.renderingOrder = -8
        catcher.castsShadow = false
        root.addChildNode(catcher)
        let sh = SCNPlane(width: 0.22, height: 0.22)
        let shm = SCNMaterial(); shm.lightingModel = .constant; shm.diffuse.contents = M.shadowBlob; shm.writesToDepthBuffer = false
        sh.materials = [shm]
        shadow.geometry = sh
        shadow.simdEulerAngles = SIMD3(-.pi / 2, 0, 0)
        shadow.renderingOrder = -9
        shadow.castsShadow = false
        root.addChildNode(shadow)

        for k in 0..<2 {
            // Свой материал у каждого курсора: цвет кисти ставится на материал.
            let cs = SCNSphere(radius: 1); cs.segmentCount = 16; cs.materials = [M.cursor.copy() as! SCNMaterial]
            cursors[k].geometry = cs
            cursors[k].isHidden = true
            cursors[k].castsShadow = false
            cursors[k].renderingOrder = 20
            root.addChildNode(cursors[k])
            let hs = SCNSphere(radius: 1); hs.segmentCount = 16; hs.materials = [M.highlight]
            hoverNodes[k].geometry = hs
            hoverNodes[k].isHidden = true
            hoverNodes[k].castsShadow = false
            hoverNodes[k].renderingOrder = 21
            content.addChildNode(hoverNodes[k])
        }

        let launch = SculptState.shared.launch
        if let d = launch.demo { demo = SculptDemo(name: d) }
        if let t = launch.replayTrajectory { replayTrajectory = SculptTrajectory(rawValue: t) }
    }

    private var replayTrajectory: SculptTrajectory?
    /// Рука считается в кадре (для рисования), если её поза свежее этого: короткие провалы распознавания не рвут мазок.
    static var holdS: Double = 0.3
    /// Облегчённый рендер студии (без SSAO, тень 1024/4): рендер делит GPU с распознавателем рук.
    /// `-sculptheavy` — прежний вариант (для замера), `-sculptlite` — облегчённый.
    static var lite: Bool = !ProcessInfo.processInfo.arguments.contains("-sculptheavy")

    // MARK: Кадр

    func update(display: [[SIMD3<Float>]?], pinchOffsets: [SIMD3<Float>?] = [nil, nil], frames: [HandFrame?], ages: [Double], now: Double, dt: Float,
                camera: SCNNode, scene: SCNScene, objects: SceneObjects) {
        let tStart = CACurrentMediaTime()
        let (s, cmds) = SculptState.shared.take()
        if s.active != active {
            if s.active { enter(camera: camera, scene: scene, objects: objects) } else { exit(camera: camera, scene: scene, objects: objects) }
        }
        snap = s
        guard active else { return }
        dtAcc += dt; dtN += 1

        for c in cmds { handle(c, now: now) }

        var hands = [SculptHand(), SculptHand()]
        for slot in 0..<2 {
            if let j = display[slot], let f = frames[slot], ages[slot] < SculptController.holdS { hands[slot] = SculptHand(joints: j, frame: f, pinchOffset: pinchOffsets[slot]) }
        }
        if let d = demo {
            // Часы демо: подвисание кадра (компиляция шейдера, снимок) не превращается в прыжок руки и прямой отрезок.
            demoClock += min(Double(dt), 1.0 / 30)
            switch d.step(now: demoClock, hands: &demoHands) {
            case .none: break
            case .clear: endAll(now: now); setStrokes([]); xf = SculptTransform(center: SculptController.center)
            case .brush(let k, let c):
                snap.brush = k
                demoBrush = k; demoColor = c ?? Palette.defaultColor(k)
            case .thickness(let v): demoThickness = v
            case .yaw(let a, let p): xf.yaw = a; xf.pitch = p; xf.stop()
            case .snap(let name): DispatchQueue.main.async { Telemetry.shared.saveSnapshot(name: name) }
            case .bench: bench = SculptBench(start: now)
            case .log(let m): EventLog.shared.write(m)
            }
            hands = demoHands.hands
            if let k = demoBrush { snap.brush = k; snap.color = demoColor }
            snap.thickness = demoThickness
        }
        if let b = bench {
            if b.step(now: now, dt: dt, controller: self) { bench = nil }
        }

        let ev = gestures.update(hands: hands, now: now, undoGesture: snap.undoGesture)
        let rotHand = hands[ev.rotateHand]

        // Поворот, перенос, масштаб.
        if ev.twoBegin { two = TwoHandTransform(start: xf, a: hands[0].palm, b: hands[1].palm); EventLog.shared.write("SCULPT два кулака") }
        if gestures.twoFists, let tw = two {
            xf = tw.apply(a: hands[0].palm, b: hands[1].palm)
            lastRotPalm = nil
        } else if ev.rotating {
            if ev.rotateBegin { xf.stop(); EventLog.shared.write("SCULPT поворот кулаком") }
            if let lp = lastRotPalm { xf.rotateBy(delta: rotHand.palm - lp, dt: dt) }
            lastRotPalm = rotHand.palm
        } else {
            if lastRotPalm != nil {
                lastRotPalm = nil
                EventLog.shared.write(String(format: "ROTATE yaw=%.1f° pitch=%.1f° инерция %.2f рад/с", xf.yaw * 180 / .pi, xf.pitch * 180 / .pi, xf.yawVel))
            }
            _ = xf.coast(dt: dt)
        }
        if ev.twoEnd { two = nil; EventLog.shared.write(String(format: "SCULPT масштаб %.2f", xf.scale)) }
        xf.apply(pivot: pivot, content: content)

        // Рисование / тяга — каждая рука своё.
        for s in 0..<2 {
            if ev.drawBegin[s] { begin(s, hands[s], now: now) }
            if gestures.drawing[s] {
                if draws[s] != nil { continueDraw(s, hands[s], now: now, dt: dt) } else if pulls[s] != nil { continuePull(s, hands[s], now: now) }
            }
            if ev.drawEnd[s] { end(s, now: now) }
        }
        if ev.undoTap { handle(.undo, now: now) }

        if !warm.isHidden && now > warmUntil { warm.isHidden = true; warm.childNodes.forEach { $0.removeFromParentNode() } }
        animate(now: now)
        for s in 0..<2 { updateCursor(s, hands[s], now: now) }
        updateLook()

        let cpu = CACurrentMediaTime() - tStart
        cpuAcc += cpu; cpuN += 1; cpuMax = max(cpuMax, cpu)
        if now - lastStats > 0.25 { publishStats(now: now) }
    }

    private var demoClock: Double = 0
    private var demoBrush: BrushKind?
    private var demoColor = SIMD3<Float>(1, 1, 1)
    private var demoThickness: Float = 1

    // MARK: Вход/выход из режима

    private func enter(camera: SCNNode, scene: SCNScene, objects: SceneObjects) {
        active = true
        self.camera = camera
        var lights: [(SCNLight, CGFloat, Bool)] = []
        var casters: [SCNNode] = []
        scene.rootNode.enumerateChildNodes { n, _ in
            if SculptController.isDescendant(n, of: self.root) { return }
            if let l = n.light { lights.append((l, l.intensity, l.castsShadow)) }
            if n.castsShadow && n.geometry != nil { casters.append(n) }
        }
        for n in casters { n.castsShadow = false }
        let c = camera.camera
        saved = Saved(background: scene.background.contents, env: scene.lightingEnvironment.contents,
                      envIntensity: scene.lightingEnvironment.intensity, lights: lights,
                      objectsHidden: objects.root.isHidden, physicsSpeed: scene.physicsWorld.speed,
                      camOrientation: camera.simdOrientation,
                      hdr: c?.wantsHDR ?? false, bloom: c?.bloomIntensity ?? 0, vignette: c?.vignettingIntensity ?? 0,
                      exposureAdapt: c?.wantsExposureAdaptation ?? false,
                      ssao: c?.screenSpaceAmbientOcclusionIntensity ?? 0, casters: casters)
        for (l, _, _) in lights {
            l.intensity = l.type == .ambient ? 80 : 0
            l.castsShadow = false
        }
        objects.root.isHidden = true
        scene.physicsWorld.speed = 0
        let M = SculptMaterials.shared
        scene.background.contents = M.background
        scene.lightingEnvironment.contents = M.studioCube
        scene.lightingEnvironment.intensity = 1.25
        if let c {
            c.wantsHDR = true
            c.wantsExposureAdaptation = false
            c.exposureOffset = 0
            c.vignettingIntensity = 0.4
            c.vignettingPower = 0.7
            c.bloomThreshold = 0.85
            c.bloomBlurRadius = 14
            // Мягкое затенение там, где мазки близко друг к другу (узлы, переплетения) — объём «как в Medium».
            c.screenSpaceAmbientOcclusionIntensity = SculptController.lite ? 0 : 1.1
            c.screenSpaceAmbientOcclusionRadius = 0.012
            c.screenSpaceAmbientOcclusionNormalThreshold = 0.3
            c.screenSpaceAmbientOcclusionDepthThreshold = 0.03
            c.screenSpaceAmbientOcclusionBias = 0.0005
            c.bloomIntensity = 0
            bloomOn = false
        }
        // Взгляд — на центр скульптуры (рука по-прежнему в своём месте сцены).
        camera.look(at: SCNVector3(SculptController.center + SIMD3(0, -0.015, 0)))
        root.isHidden = false
        warmShaders()
        EventLog.shared.write("SCULPT вход")
    }

    /// Прогрев шейдеров: крошечный мазок каждой кистью на 0,3 с (иначе первый мазок кисти дёргается на компиляции).
    private let warm = SCNNode()
    private var warmUntil: Double = 0
    private func warmShaders() {
        warm.childNodes.forEach { $0.removeFromParentNode() }
        for k in BrushKind.allCases {
            let pr = BrushPreset.of(k)
            var nodes: [StrokeNode] = []
            for i in 0..<8 { nodes.append(StrokeNode(p: SculptController.center + SIMD3(Float(i) * 0.002, 0, 0), r: pr.baseRadius, n: [0, 0, 1], t: Float(i) * 0.01)) }
            let v = StrokeView(kind: k)
            v.rebuildAll(StrokeData(id: -1, kind: k, color: Palette.defaultColor(k), seed: 1, nodes: nodes, finished: true))
            warm.addChildNode(v.node)
        }
        warm.simdScale = SIMD3(repeating: 0.05)
        warm.simdPosition = SculptController.center * 0.95
        if warm.parent == nil { root.addChildNode(warm) }
        warm.isHidden = false
        warmUntil = CACurrentMediaTime() + 0.3
    }

    private static func isDescendant(_ n: SCNNode, of r: SCNNode) -> Bool {
        var p: SCNNode? = n
        while let q = p { if q === r { return true }; p = q.parent }
        return false
    }

    private func exit(camera: SCNNode, scene: SCNScene, objects: SceneObjects) {
        endAll(now: CACurrentMediaTime())
        active = false
        root.isHidden = true
        guard let s = saved else { return }
        scene.background.contents = s.background
        scene.lightingEnvironment.contents = s.env
        scene.lightingEnvironment.intensity = s.envIntensity
        for (l, i, sh) in s.lights { l.intensity = i; l.castsShadow = sh }
        for n in s.casters { n.castsShadow = true }
        objects.root.isHidden = s.objectsHidden
        scene.physicsWorld.speed = s.physicsSpeed
        camera.simdOrientation = s.camOrientation
        if let c = camera.camera {
            c.wantsHDR = s.hdr; c.bloomIntensity = s.bloom; c.vignettingIntensity = s.vignette; c.wantsExposureAdaptation = s.exposureAdapt
            c.screenSpaceAmbientOcclusionIntensity = s.ssao
        }
        saved = nil
        EventLog.shared.write("SCULPT выход")
    }

    private func updateLook() {
        let want = snap.brush.emissive || strokes.contains { $0.kind.emissive }
        if want != bloomOn, let c = camera?.camera {
            bloomOn = want
            c.bloomIntensity = want ? 1.2 : 0
        }
        let base = xf.toWorld(SculptController.center)
        shadow.simdPosition = SIMD3(base.x, SceneObjects.tableY - 0.001, base.z)
        shadow.simdScale = SIMD3(repeating: max(0.5, xf.scale))
    }

    // MARK: Команды HUD

    private func handle(_ c: SculptCommand, now: Double) {
        switch c {
        case .undo:
            endAll(now: now)
            if let (op, s) = undo.undo(current: strokes) {
                setStrokes(s); SculptState.shared.showToast("Отменено: \(op.rawValue)")
                EventLog.shared.write("SCULPT отмена \(op.rawValue)")
            }
        case .redo:
            endAll(now: now)
            if let (op, s) = undo.redo(current: strokes) { setStrokes(s); SculptState.shared.showToast("Возвращено: \(op.rawValue)") }
        case .clear:
            endAll(now: now)
            guard !strokes.isEmpty else { return }
            undo.push(.clear, before: strokes)
            setStrokes([])
            SculptState.shared.showToast("Очищено — можно отменить ↶")
            EventLog.shared.write("SCULPT очистка")
        case .save:
            endAll(now: now)
            SculptExport.save(strokes: strokes, transform: xf)
        }
    }

    private func setStrokes(_ s: [StrokeData]) {
        for v in views.values { v.node.removeFromParentNode() }
        views.removeAll()
        strokes = s
        for sd in strokes {
            let v = StrokeView(kind: sd.kind)
            v.setChunkSize(StrokeView.frozenChunk)
            content.addChildNode(v.node)
            views[sd.id] = v
            v.rebuildAll(sd)
            nextID = max(nextID, sd.id + 1)
        }
    }

    private func index(_ id: Int) -> Int? { strokes.firstIndex { $0.id == id } }

    // MARK: Мазок

    private func pressure(_ d: Float) -> Float { hgSmoothstep(0.55, 0.15, d) }

    private func radius(_ k: BrushKind, p: Float) -> Float {
        let pr = BrushPreset.of(k)
        return pr.baseRadius * snap.thickness * (pr.pMin + (1 - pr.pMin) * p) / xf.scale
    }

    private func ringStep(_ k: BrushKind) -> Float {
        let pr = BrushPreset.of(k)
        return max(pr.ringStep, 0.12 * 2 * pr.baseRadius * snap.thickness) / xf.scale
    }

    /// Ближайшее кольцо к точке (локально): мазок, кольцо, расстояние до поверхности.
    private func nearestRing(_ g: SIMD3<Float>, filter: (StrokeData) -> Bool) -> (Int, Int, Float)? {
        var best: (Int, Int, Float)?
        for (si, s) in strokes.enumerated() where filter(s) {
            for (i, n) in s.nodes.enumerated() {
                let d = simd_distance(n.p, g) - n.r
                if d < (best?.2 ?? .greatestFiniteMagnitude) { best = (si, i, d) }
            }
        }
        return best
    }

    /// Мазки, которые сейчас рисует/тянет рука s (с зеркальными копиями).
    private func busyIDs(_ s: Int) -> Set<Int> {
        var ids = Set<Int>()
        if let d = draws[s] { ids.insert(d.id); if let m = d.mirrorID { ids.insert(m) } }
        if let p = pulls[s] { ids.insert(p.strokeID) }
        return ids
    }

    private func begin(_ hand: Int, _ h: SculptHand, now: Double) {
        let brush = snap.brush
        let g = xf.toLocal(h.pinchPoint)
        let reach = 0.02 / xf.scale
        // Мазок, который сейчас ведёт другая рука, не трогаем (ни продолжить, ни тянуть).
        let busy = busyIDs(1 - hand)
        if demo?.allowEdit ?? true, let (si, ring, dist) = nearestRing(g, filter: { !busy.contains($0.id) && ($0.kind == brush || ($0.kind.canPull && brush.canPull)) }) {
            let s = strokes[si]
            let n = s.nodes.count
            // Конец: щепоть у торца (ближе 2 см и не дальше 1 см сверх расстояния до ближайшего кольца) — продолжить линию.
            let dStart = simd_distance(g, s.nodes[0].p) - s.nodes[0].r
            let dEnd = simd_distance(g, s.nodes[n - 1].p) - s.nodes[n - 1].r
            let dEdge = min(dStart, dEnd)
            let endReach = brush.canPull ? reach : s.nodes[ring].r + 0.004 / xf.scale
            // …или ближайшее кольцо в последних 2,5 см линии (на руке в торец точно не попасть).
            var arcStart: Float = 0, arcEnd: Float = 0
            for k in stride(from: 1, to: n, by: 1) {
                let d = simd_distance(s.nodes[k].p, s.nodes[k - 1].p)
                if k <= ring { arcStart += d } else { arcEnd += d }
            }
            let nearTip = min(arcStart, arcEnd) < 0.025 / xf.scale && dist < reach
            if s.kind == brush && n >= 3 && ((dEdge < endReach && dEdge < dist + 0.01 / xf.scale) || nearTip) {
                extend(si, hand: hand, fromStart: nearTip ? arcStart < arcEnd : dStart < dEnd, h: h, now: now)
                return
            }
            if brush.canPull && s.kind.canPull && dist < reach {
                pullBefore[hand] = s
                pulls[hand] = PlasticinePull(stroke: s, ring: ring, grab: g)
                pullStabs[hand] = StrokeStabilizer(); pullStabs[hand].leash = 0; pullStabs[hand].begin(at: g)
                views[s.id]?.setChunkSize(StrokeView.hotChunk)
                views[s.id]?.rebuildAll(s)
                haptic(.rigid)
                EventLog.shared.write(String(format: "PULL start рука=\(hand) кольцо %d из %d, d=%.1f мм", ring, n, dist * 1000))
                return
            }
        }
        let id = nextID; nextID += 1
        var sd = StrokeData(id: id, kind: brush, color: snap.color, seed: UInt32.random(in: 0...UInt32.max), nodes: [], finished: false)
        var b = StrokeBuilder(ringStep: ringStep(brush))
        var d = Draw(id: id, mirrorID: nil, builder: b, t0: now, p: pressure(h.pinchD), normal: localDir(h.palmNormal))
        d.stab.leash = snap.leash / xf.scale
        d.stab.begin(at: g)
        b.start(StrokeNode(p: g, r: radius(brush, p: d.p), n: d.normal, t: 0), nodes: &sd.nodes)
        d.builder = b
        strokes.append(sd)
        let v = StrokeView(kind: brush)
        content.addChildNode(v.node)
        views[id] = v
        v.rebuild(sd, from: 0)
        if snap.mirror {
            let mid = nextID; nextID += 1
            let m = sd.mirrored(id: mid)
            strokes.append(m)
            let mv = StrokeView(kind: brush)
            content.addChildNode(mv.node)
            views[mid] = mv
            mv.rebuild(m, from: 0)
            d.mirrorID = mid
        }
        if brush == .plasma { v.flash(now: now) }
        draws[hand] = d
        haptic(.light)
    }

    private func extend(_ si: Int, hand: Int, fromStart: Bool, h: SculptHand, now: Double) {
        let before = strokes[si]
        if fromStart { strokes[si].nodes.reverse() }
        strokes[si].finished = false
        let s = strokes[si]
        let last = s.nodes[s.nodes.count - 1]
        var b = StrokeBuilder(ringStep: ringStep(s.kind))
        b.resume(nodes: s.nodes)
        let pr = BrushPreset.of(s.kind)
        let p0 = clampf((last.r * xf.scale / (pr.baseRadius * snap.thickness) - pr.pMin) / max(1 - pr.pMin, 0.01), 0, 1)
        var d = Draw(id: s.id, mirrorID: nil, builder: b, t0: now - Double(last.t), p: p0, normal: last.n, extendedFrom: s.length,
                     junction: s.nodes.count - 1, before: before)
        d.stab.leash = snap.leash / xf.scale
        d.stab.begin(at: last.p)
        draws[hand] = d
        views[s.id]?.setChunkSize(StrokeView.hotChunk)
        views[s.id]?.rebuildAll(s)
        haptic(.rigid)
        EventLog.shared.write(String(format: "EXTEND мазок %d с %@, длина %.1f см", s.id, fromStart ? "начала" : "конца", s.length * 100))
    }

    /// Полуширина скругления стыка при продолжении линии, м (локально).
    private var junctionHalf: Float { 0.016 / xf.scale }

    private func localDir(_ w: SIMD3<Float>) -> SIMD3<Float> {
        let v = xf.rotation.inverse.act(w)
        return simd_length_squared(v) > 1e-8 ? simd_normalize(v) : [0, 0, 1]
    }

    private func continueDraw(_ hand: Int, _ h: SculptHand, now: Double, dt: Float) {
        guard var d = draws[hand], let i = index(d.id) else { return }
        let raw = xf.toLocal(h.pinchPoint)
        let b = d.stab.feed(raw, t: now)
        d.p += (pressure(h.pinchD) - d.p) * (1 - exp(-dt / 0.08))
        // Ориентация ленты: свой фильтр, τ = 60 мс.
        var nn = localDir(h.palmNormal)
        if simd_dot(nn, d.normal) < 0 { nn = -nn }
        d.normal = simd_normalize(d.normal + (nn - d.normal) * (1 - exp(-dt / 0.06)) + SIMD3(1e-6, 0, 0))
        let node = StrokeNode(p: b, r: radius(strokes[i].kind, p: d.p), n: d.normal, t: Float(now - d.t0))
        let dirty = d.builder.add(node, nodes: &strokes[i].nodes)
        if let j = d.junction {
            // Продолжение: показываем уже скруглённый стык (сам мазок скругляется при отпускании).
            var shown = strokes[i]
            StrokeSmoothing.roundCorner(&shown.nodes, at: j, half: junctionHalf)
            let back = Int(junctionHalf / max(d.builder.ringStep, 1e-5)) + 4
            views[d.id]?.rebuild(shown, from: min(dirty, max(0, j - back)))
        } else {
            views[d.id]?.rebuild(strokes[i], from: dirty)
        }
        if let mid = d.mirrorID, let mi = index(mid) {
            strokes[mi].nodes = strokes[i].mirrored(id: mid).nodes
            views[mid]?.rebuild(strokes[mi], from: dirty)
        }
        draws[hand] = d
    }

    private func continuePull(_ hand: Int, _ h: SculptHand, now: Double) {
        guard var p = pulls[hand], let i = index(p.strokeID) else { return }
        let g = pullStabs[hand].feed(xf.toLocal(h.pinchPoint), t: now)
        let before = p.window.lowerBound
        strokes[i].nodes = p.apply(grab: g)
        views[p.strokeID]?.rebuild(strokes[i], from: max(0, min(before, p.window.lowerBound) - 1))
        pulls[hand] = p
    }

    /// Закончить мазки/тяги обеих рук.
    private func endAll(now: Double) {
        for s in 0..<2 { end(s, now: now) }
    }

    /// Закончить мазок/тягу руки s.
    private func end(_ hand: Int, now: Double) {
        if var d = draws[hand], let i = index(d.id) {
            draws[hand] = nil
            let target = d.stab.filtered ?? strokes[i].nodes.last!.p
            let r = strokes[i].nodes.last?.r ?? radius(strokes[i].kind, p: d.p)
            d.builder.finish(at: StrokeNode(p: target, r: r, n: d.normal, t: Float(now - d.t0)), nodes: &strokes[i].nodes)
            if let j = d.junction { StrokeSmoothing.roundCorner(&strokes[i].nodes, at: j, half: junctionHalf) }
            if strokes[i].nodes.count < 3 && d.extendedFrom == nil {
                // Случайный щипок без движения — мазка нет.
                let ids = [d.id] + (d.mirrorID.map { [$0] } ?? [])
                for id in ids { views[id]?.node.removeFromParentNode(); views[id] = nil }
                strokes.removeAll { ids.contains($0.id) }
                gestures.cancelDraw(hand)
                return
            }
            undo.pushStrokes(d.before == nil ? .add : .edit, before: [(d.id, d.before)] + (d.mirrorID.map { [($0, nil)] } ?? []))
            var ids = [d.id]
            if let mid = d.mirrorID, let mi = index(mid) {
                strokes[mi].nodes = strokes[i].mirrored(id: mid).nodes
                ids.append(mid)
            }
            for id in ids {
                guard let k = index(id), let v = views[id] else { continue }
                strokes[k].finished = true
                v.setChunkSize(StrokeView.frozenChunk)
                v.rebuildAll(strokes[k])
                if strokes[k].kind == .neon || strokes[k].kind == .plasma { v.flash(now: now) }
                if strokes[k].kind == .chrome {
                    drips.append(Drip(id: id, start: now, base: strokes[k].nodes, down: localDir([0, -1, 0])))
                    v.setChunkSize(StrokeView.hotChunk); v.rebuildAll(strokes[k])
                }
            }
            logStroke(strokes[i], view: views[d.id], extendedFrom: d.extendedFrom, hand: hand)
            haptic(.soft)
        }
        if let p = pulls[hand] {
            pulls[hand] = nil
            undo.pushStrokes(.edit, before: [(p.strokeID, pullBefore[hand])])
            pullBefore[hand] = nil
            settles.append(SettleAnim(strokeID: p.strokeID, start: now, window: p.window))
            if let i = index(p.strokeID) {
                let s = strokes[i]
                let r0 = p.orig.map(\.r).max() ?? 0
                let rmin = s.nodes[p.window].map(\.r).min() ?? 0
                EventLog.shared.write(String(format: "PULL end рука=\(hand) сдвиг %.1f см, длина %.1f → %.1f см, колец %d → %d, мин. радиус %.2f·r0",
                                             p.maxShift * 100, StrokeData(id: 0, kind: s.kind, color: s.color, seed: 0, nodes: p.orig, finished: true).length * 100,
                                             s.length * 100, p.orig.count, s.nodes.count, r0 > 0 ? rmin / r0 : 0))
            }
            haptic(.soft)
        }
    }

    // MARK: Анимации после отпускания

    private func animate(now: Double) {
        for v in views.values where v.flashing { v.updateFlash(now: now) }
        // Оседание пластилина.
        var k = 0
        while k < settles.count {
            let sa = settles[k]
            guard let i = index(sa.strokeID), let v = views[sa.strokeID] else { settles.remove(at: k); continue }
            let w = sa.window.clamped(to: 0...(strokes[i].nodes.count - 1))
            if let strength = settles[k].smoothingPass(now: now) { SettleAnim.smooth(&strokes[i].nodes, window: w, strength: strength) }
            if now - sa.start >= sa.duration {
                v.radiusScale = 1; v.radiusScaleRange = nil
                v.setChunkSize(StrokeView.frozenChunk)
                v.rebuildAll(strokes[i])
                settles.remove(at: k)
                continue
            }
            v.radiusScale = sa.radiusScale(now: now); v.radiusScaleRange = w
            v.rebuild(strokes[i], from: max(0, w.lowerBound - 1))
            k += 1
        }
        // Хром: «стекание» 1,5 с (провис середины), потом заморозка.
        k = 0
        while k < drips.count {
            let dr = drips[k]
            guard let i = index(dr.id), let v = views[dr.id], strokes[i].nodes.count == dr.base.count else { drips.remove(at: k); continue }
            let t = Float(now - dr.start)
            let L = max(StrokeData(id: 0, kind: .chrome, color: .zero, seed: 0, nodes: dr.base, finished: true).length, 1e-4)
            let sag = min(0.5 * 0.02 * t * t, 0.12 * L, 0.02)
            var acc: Float = 0
            for j in 0..<dr.base.count {
                if j > 0 { acc += simd_distance(dr.base[j].p, dr.base[j - 1].p) }
                let u = acc / L
                let w = pow(sin(Float.pi * u), 1.5)
                strokes[i].nodes[j].p = dr.base[j].p + dr.down * sag * w
            }
            v.rebuild(strokes[i], from: 0)
            if t >= 1.5 {
                v.setChunkSize(StrokeView.frozenChunk); v.rebuildAll(strokes[i])
                drips.remove(at: k); continue
            }
            k += 1
        }
    }

    // MARK: Курсор и подсветка

    private func updateCursor(_ hand: Int, _ h: SculptHand, now: Double) {
        let drawing = gestures.drawing[hand]
        let cursor = cursors[hand], hoverNode = hoverNodes[hand]
        if h.visible && !drawing && !gestures.twoFists {
            cursor.isHidden = false
            cursor.simdPosition = h.pinchPoint
            let r = radius(snap.brush, p: pressure(h.pinchD)) * xf.scale
            cursor.simdScale = SIMD3(repeating: max(r, 0.0015))
            (cursor.geometry?.firstMaterial)?.diffuse.contents = Palette.ui(snap.color)
        } else {
            cursor.isHidden = true
        }
        // Что возьмётся щипком: кольцо пластилина ближе 2 см.
        if h.visible && !drawing && snap.brush.canPull,
           let (si, ring, dist) = nearestRing(xf.toLocal(h.pinchPoint), filter: { $0.kind.canPull }), dist < 0.02 / xf.scale {
            let n = strokes[si].nodes[ring]
            hoverNode.isHidden = false
            hoverNode.simdPosition = n.p
            hoverNode.simdScale = SIMD3(repeating: n.r * 1.3)
        } else {
            hoverNode.isHidden = true
        hoverNode.castsShadow = false
        }
    }

    // MARK: Журнал и счётчики

    private func logStroke(_ s: StrokeData, view: StrokeView?, extendedFrom: Float?, hand: Int) {
        let m = StrokeMetrics.measure(s, frames: view?.frames ?? [])
        var line = String(format: "STROKE рука=%d %@ id=%d узлов=%d длина=%.1f см шаг(макс/ном)=%.2f перекрут=%.1f° дрожь=%.3f мм r_конец/r_ном=%.2f",
                          hand, s.kind.key, s.id, m.nodes, m.length * 100, m.maxStepRatio, m.maxTwistDeg, m.jitterMM,
                          (s.nodes.last?.r ?? 0) / max(BrushPreset.of(s.kind).baseRadius * snap.thickness / xf.scale, 1e-6))
        if let e = extendedFrom { line += String(format: " ТЯГА: %.1f → %.1f см (+%.1f)", e * 100, m.length * 100, (m.length - e) * 100) }
        let tr = demo?.currentTrajectory ?? replayTrajectory
        if let tr, tr != .pull, extendedFrom == nil, xf.yaw == 0, xf.scale == 1 {
            let dev = TrajectoryCheck.deviation(s.nodes.map(\.p), ref: tr.reference())
            line += String(format: " отклонение от эталона «%@»: макс %.1f мм, средн %.1f мм, форма %.1f мм", tr.rawValue, dev.max * 1000, dev.mean * 1000, dev.shapeMax * 1000)
        }
        let tris = view?.totalTriangles ?? 0
        line += " треуг=\(tris)"
        EventLog.shared.write(line)
    }

    private func publishStats(now: Double) {
        lastStats = now
        let tris = views.values.reduce(0) { $0 + $1.totalTriangles }
        let budget: Float = bloomOn ? 250_000 : 400_000
        let cpu = cpuN > 0 ? cpuAcc / Double(cpuN) * 1000 : 0
        var st = SculptStats()
        st.strokes = strokes.count
        st.triangles = tris
        st.fullness = Float(tris) / budget
        st.cpuMs = Float(cpu)
        st.canUndo = undo.canUndo
        st.canRedo = undo.canRedo
        let nDraw = draws.compactMap { $0 }.count
        st.mode = nDraw == 2 ? "рисую двумя" : nDraw == 1 ? "рисую" : pulls.contains { $0 != nil } ? "тяну" : gestures.twoFists ? "двигаю" : gestures.rotating ? "кручу" : "—"
        SculptState.shared.publish(stats: st)
        if (Telemetry.shared.replayMode || demo != nil), now - lastLog > 2 {
            lastLog = now
            let fps = dtN > 0 ? Float(dtN) / max(dtAcc, 1e-3) : 0
            EventLog.shared.write(String(format: "SCULPT fps=%.0f cpu=%.2f мс (макс %.2f) треуг=%d мазков=%d bloom=%@ yaw=%.1f° режим=%@",
                                         fps, cpu, cpuMax * 1000, tris, strokes.count, bloomOn ? "да" : "нет", xf.yaw * 180 / .pi, st.mode))
            cpuMax = 0
        }
        cpuAcc = 0; cpuN = 0; dtAcc = 0; dtN = 0
    }

    private func haptic(_ s: UIImpactFeedbackGenerator.FeedbackStyle) {
        DispatchQueue.main.async { UIImpactFeedbackGenerator(style: s).impactOccurred() }
    }

    // MARK: Для бенча

    /// Заполнить сцену статичными мазками (бенч).
    func benchFill(meters: Float, kind: BrushKind) {
        var list: [StrokeData] = []
        var left = meters
        var id = 1000
        let pr = BrushPreset.of(kind)
        while left > 0 {
            let len = min(left, 1)
            left -= len
            let n = Int(len / pr.ringStep)
            var nodes: [StrokeNode] = []
            let yOff = Float(id - 1000) * 0.012
            for k in 0...n {
                let u = Float(k) / Float(n)
                let a = u * len / 0.3 * 2 * .pi
                let p = SculptController.center + SIMD3(0.05 * cos(a), -0.06 + yOff * 0.5 + 0.01 * u, 0.05 * sin(a))
                nodes.append(StrokeNode(p: p, r: pr.baseRadius, n: [0, 0, 1], t: u))
            }
            list.append(StrokeData(id: id, kind: kind, color: Palette.defaultColor(kind), seed: UInt32(id), nodes: nodes, finished: true))
            id += 1
        }
        setStrokes(list)
    }

    func benchClear() { setStrokes([]) }
    var benchTriangles: Int { views.values.reduce(0) { $0 + $1.totalTriangles } }
    func benchBloom(_ on: Bool) { camera?.camera?.bloomIntensity = on ? 1.2 : 0; bloomOn = on }
}

/// Бенч сцены: 1 / 5 / 15 м пластилина и неона, bloom выкл/вкл; fps и время кадра — в журнал и Documents/sculpt-bench.log.
final class SculptBench {
    private var stage = 0
    private var stageStart: Double
    private var dts: [Float] = []
    private var lines: [String] = []
    private let cases: [(Float, BrushKind, Bool)] = [(1, .plasticine, false), (5, .plasticine, false), (15, .plasticine, false),
                                                     (15, .plasticine, true), (5, .neon, true), (15, .neon, true)]

    init(start: Double) { stageStart = start }

    /// true — закончен.
    func step(now: Double, dt: Float, controller c: SculptController) -> Bool {
        if stage >= cases.count * 2 { return true }
        let (m, k, bloom) = cases[stage / 2]
        if stage % 2 == 0 {
            c.benchFill(meters: m, kind: k)
            c.benchBloom(bloom)
            dts.removeAll()
            stage += 1; stageStart = now
            return false
        }
        if now - stageStart > 0.7 { dts.append(dt) }
        if now - stageStart > 3.7 {
            let s = dts.sorted()
            let mean = s.reduce(0, +) / Float(max(s.count, 1))
            let p95 = s.isEmpty ? 0 : s[min(s.count - 1, Int(Float(s.count) * 0.95))]
            let line = String(format: "BENCH sculpt %@ %.0f м bloom=%@ треуг=%d fps=%.0f кадр средн %.2f мс p95 %.2f мс",
                              k.key, m, bloom ? "да" : "нет", c.benchTriangles, 1 / max(mean, 1e-4), mean * 1000, p95 * 1000)
            EventLog.shared.write(line)
            lines.append(line)
            let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("sculpt-bench.log")
            try? (lines.joined(separator: "\n") + "\n").data(using: .utf8)?.write(to: url, options: .atomic)
            DispatchQueue.main.async { Telemetry.shared.saveSnapshot(name: String(format: "sculpt-bench-%@-%.0fm%@", k.key, m, bloom ? "-bloom" : "")) }
            stage += 1
            if stage >= cases.count * 2 { c.benchClear(); return true }
        }
        return false
    }
}
