import SwiftUI
import SceneKit
import UIKit
import simd

/// SceneKit-вид 120 Гц. Каждый кадр рендера читает последний HandFrame, предсказывает на момент кадра,
/// сглаживает (плавно догоняет новую позу, без рывков между кадрами распознавания), рисует руки, ведёт захват.
struct HandSceneView: UIViewRepresentable {
    let model: AppModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeUIView(context: Context) -> SCNView {
        let v = SCNView(frame: .zero, options: nil)
        v.scene = context.coordinator.scene
        v.pointOfView = context.coordinator.cameraNode
        v.delegate = context.coordinator
        v.preferredFramesPerSecond = 120
        v.antialiasingMode = .multisampling2X
        v.rendersContinuously = true
        v.isPlaying = true
        v.backgroundColor = UIColor(white: 0.06, alpha: 1)
        v.allowsCameraControl = false
        Telemetry.shared.sceneView = v
        Telemetry.shared.start()
        return v
    }

    func updateUIView(_ uiView: SCNView, context: Context) {}

    final class Coordinator: NSObject, SCNSceneRendererDelegate {
        let model: AppModel
        let scene = SCNScene()
        let cameraNode = SCNNode()
        let objects = SceneObjects()
        let rigs = [HandRig(color: UIColor(red: 0.35, green: 0.72, blue: 1.0, alpha: 1), name: "hand-left"),
                    HandRig(color: UIColor(red: 1.0, green: 0.66, blue: 0.36, alpha: 1), name: "hand-right")]
        let grab = GrabController()
        /// 3D-курсоры рук (по умолчанию вместо модели кисти).
        let cursors = [HandCursor(), HandCursor()]
        let sculpt = SculptController()
        private var lastTime: Double = 0
        /// Поза на экране по слотам (сглаженная на 120 Гц).
        private var display: [[SIMD3<Float>]?] = [nil, nil]
        /// Смещение щепоти от ладони, сглаженное как поза (точка кисти и острие курсора).
        private var pinchOff: [SIMD3<Float>?] = [nil, nil]
        private var lastObjLog: Double = 0
        private let sun = SCNLight()
        /// Замер плавности: вторая разность положения ладони по кадрам рендера (до и после сглаживания), мм.
        private var hist: [[[SIMD3<Float>]]] = [[[], []], [[], []]]   // [слот][сырая/курсор]
        private var jerk: [Float] = [0, 0]
        private var jerkN = 0

        init(model: AppModel) {
            self.model = model
            super.init()
            buildScene()
        }

        private func buildScene() {
            scene.background.contents = UIColor(white: 0.06, alpha: 1)
            scene.physicsWorld.gravity = SCNVector3(0, -9.8, 0)
            scene.physicsWorld.timeStep = 1.0 / 120.0

            // Глаз над ближним краем стола, смотрит вниз-вперёд: стол во весь экран, рука крупно.
            let cam = SCNCamera()
            cam.zNear = 0.01
            cam.zFar = 5
            // Портретный экран: угол задаётся по вертикали, стол и стена занимают весь экран.
            cam.projectionDirection = .vertical
            cam.fieldOfView = 72
            cameraNode.camera = cam
            cameraNode.simdPosition = SIMD3(0, SceneObjects.tableY + 0.34, 0.01)
            cameraNode.look(at: SCNVector3(0, SceneObjects.tableY, Workspace.zMid + 0.03))
            scene.rootNode.addChildNode(cameraNode)

            sun.type = .directional
            sun.intensity = 900
            // Динамические тени выключены (рендер 54 fps на телефоне): под предметами и курсором — мягкие пятна.
            sun.castsShadow = false
            sun.shadowMode = .forward   // deferred считает тень по буферу глубины и «высвечивает» стол сквозь растворённое запястье
            sun.shadowMapSize = CGSize(width: 1024, height: 1024)
            sun.orthographicScale = 0.45
            sun.shadowColor = UIColor(white: 0, alpha: 0.5)
            sun.shadowRadius = 4
            sun.shadowSampleCount = 8   // мягкий край тени
            let sunNode = SCNNode()
            sunNode.light = sun
            // Солнце почти сверху: тень руки падает прямо под неё — видно, над чем рука.
            sunNode.simdPosition = SIMD3(0.05, 0.6, Workspace.zMid + 0.08)
            sunNode.look(at: SCNVector3(0, SceneObjects.tableY, Workspace.zMid))
            scene.rootNode.addChildNode(sunNode)

            let amb = SCNLight()
            amb.type = .ambient
            amb.intensity = 380
            let ambNode = SCNNode()
            ambNode.light = amb
            scene.rootNode.addChildNode(ambNode)

            scene.rootNode.addChildNode(objects.root)
            scene.rootNode.addChildNode(sculpt.root)
            for r in rigs {
                scene.rootNode.addChildNode(r.root)
                r.attachColliders(to: scene.rootNode)
            }
            for c in cursors { c.attach(to: scene.rootNode) }
        }

        // MARK: SCNSceneRendererDelegate — каждый кадр дисплея.

        func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
            let now = CACurrentMediaTime()
            var dtD: Double = 1.0 / 120.0
            if lastTime > 0 { dtD = min(max(now - lastTime, 1.0 / 240.0), 1.0 / 30.0) }
            let dt = Float(dtD)
            lastTime = now
            Metrics.shared.renderFrame()

            let cfg = ConfigStore.shared.snapshot
            let snap = model.pipeline.latest.read()

            if sun.castsShadow != cfg.dynamicShadows { sun.castsShadow = cfg.dynamicShadows }
            if model.consumeResetRequest() {
                grab.dropAll()
                objects.resetAll()
            }

            var predMs: Float = 0
            for slot in 0..<2 {
                let rig = rigs[slot]
                rig.setCollidersEnabled(cfg.handColliders)
                rig.modelVisible = cfg.showHandModel
                // Скульпт: стрелка меньше и полупрозрачная (не закрывает работу), без пятна на полу.
                cursors[slot].sculptStyle = sculpt.active
                guard let f = snap.hands[slot] else {
                    rig.hide(); display[slot] = nil; pinchOff[slot] = nil; cursors[slot].hide()
                    grab.update(slot: slot, frame: nil, joints: nil, age: .infinity, now: now, dt: dt,
                                objects: objects.objects, magnet: cfg.magnetRadius)
                    continue
                }
                let age = now - snap.lastSeen[slot]
                // Потеря руки: 150 мс держим позу, затем 200 мс гасим.
                let opacity: Float = age < 0.15 ? 1 : max(0, 1 - Float(age - 0.15) / 0.2)
                if opacity <= 0 {
                    rig.hide(); display[slot] = nil; pinchOff[slot] = nil; cursors[slot].hide()
                    grab.update(slot: slot, frame: f, joints: nil, age: age, now: now, dt: dt,
                                objects: objects.objects, magnet: cfg.magnetRadius)
                    continue
                }
                var target = f.joints
                if cfg.predictionEnabled && age < 0.15 {
                    target = HandPredictor.predict(frame: f, now: now, config: cfg)
                    predMs = max(predMs, HandPredictor.horizon(frame: f, now: now, config: cfg) * 1000)
                }
                // Жёсткие длины (в масштабе виртуальной руки).
                let k = cfg.handScale
                let lengths = HandSkeletonSolver.lengths(config: cfg, scale: f.scale / max(k, 0.1)).map { $0 * k }
                HandSkeletonSolver.solve(&target, lengths: lengths)

                // Плавность: экспоненциально догоняем цель; при большом скачке (новое появление) — сразу.
                var joints = target
                if var d = display[slot], simd_distance(d[0], target[0]) < 0.25 {
                    let a = 1 - exp(-dt / max(cfg.displaySmoothMs / 1000, 0.001))
                    for i in 0..<HandJoint.count { d[i] += (target[i] - d[i]) * a }
                    HandSkeletonSolver.solve(&d, lengths: lengths)
                    joints = d
                }
                // Рука не проваливается в стол: самый нижний сустав — не ниже поверхности (вся рука приподнимается).
                let minY = joints.map(\.y).min() ?? 0
                let floorY = SceneObjects.tableY + 0.006
                if minY < floorY {
                    let lift = SIMD3<Float>(0, floorY - minY, 0)
                    for i in 0..<HandJoint.count { joints[i] += lift }
                }
                display[slot] = joints
                if let o = f.pinchOffset {
                    if let p = pinchOff[slot] {
                        let a = 1 - exp(-dt / max(cfg.displaySmoothMs / 1000, 0.001))
                        pinchOff[slot] = p + (o - p) * a
                    } else { pinchOff[slot] = o }
                }

                // Курсор: цель — точка хвата по предсказанной позе (своё сглаживание у курсора — пружина),
                // направление — запястье → середина пальцев с поправкой на указательный.
                let mode: GrabController.Mode = f.fist ? .fist : .pinch
                // В рисовании остриё — ровно точка кисти (щепоть сглаженной позы, по которой рисует скульпт).
                // В рисовании остриё — ровно точка кисти (та же, что берёт скульпт: ладонь сглаженной позы + щепоть по плоской модели).
                let aim = sculpt.active ? (pinchOff[slot].map { PinchDetector.palmCenter(joints) + $0 } ?? GrabController.grabPoint(joints, mode: .pinch))
                                        : GrabController.grabPoint(target, mode: mode)
                let dir = (target[9] - target[0]) + 0.5 * (target[8] - target[5])
                let cstate: HandCursor.State = grab.isHolding(slot) ? .grab : (grab.hovered[slot] != nil ? .hover : .idle)
                let pinchAmt = f.fist ? 1 : clampf(1 - (f.pinchD - cfg.pinchOn) / max(cfg.pinchOff, 0.1), 0, 1)
                cursors[slot].update(target: aim, direction: dir, pinch: pinchAmt, state: cstate, dt: dt, opacity: opacity,
                                     viewer: cameraNode.simdPosition, tableY: sculpt.active ? nil : SceneObjects.tableY)
                if Telemetry.shared.replayMode {
                    let pr = aim, pd = cursors[slot].position
                    for (k, p) in [pr, pd].enumerated() {
                        hist[slot][k].append(p); if hist[slot][k].count > 3 { hist[slot][k].removeFirst() }
                        let h = hist[slot][k]
                        if h.count == 3 { jerk[k] += simd_length(h[2] - 2 * h[1] + h[0]) * 1000 }
                    }
                    if hist[slot][0].count == 3 { jerkN += 1 }
                }
                // Хват — там, где виден курсор: поза сдвигается целиком так, чтобы точка хвата совпала с курсором.
                let shift = cursors[slot].position - GrabController.grabPoint(joints, mode: mode)
                for i in 0..<HandJoint.count { joints[i] += shift }
                grab.update(slot: slot, frame: f, joints: joints, age: age, now: now, dt: dt,
                            objects: objects.objects, magnet: cfg.magnetRadius, enabled: !sculpt.active)
                let gp = GrabController.grabPoint(joints, mode: mode)
                rig.update(joints: joints, opacity: opacity,
                           highlight: f.pinching || f.fist || grab.isHolding(slot) || grab.hovered[slot] != nil,
                           grabPoint: gp, chirality: f.chirality)
                if age < 0.15 { Metrics.shared.latency(ms: (now - f.captureTime) * 1000) }
            }
            sculpt.update(display: display, pinchOffsets: pinchOff, frames: snap.hands, ages: [now - snap.lastSeen[0], now - snap.lastSeen[1]],
                          now: now, dt: dt, camera: cameraNode, scene: scene, objects: objects)
            for o in objects.objects { o.setHighlight(grab.hovered.contains { $0 === o }) }
            if predMs > 0 { Metrics.shared.updateInfo { $0.predictionMs = predMs } }
            // Реплей: позиции объектов и руки в журнал дважды в секунду (проверка без экрана).
            if Telemetry.shared.replayMode, now - lastObjLog > 0.5 {
                lastObjLog = now
                var s = "OBJ"
                for o in objects.objects { let p = o.position; s += String(format: " %@=(%.2f,%.2f,%.2f)", o.name, p.x, p.y, p.z) }
                if let d = display[1] ?? display[0] {
                    let g = GrabController.grabPoint(d, mode: .pinch)
                    s += String(format: " щепоть=(%.2f,%.2f,%.2f)", g.x, g.y, g.z)
                }
                EventLog.shared.write(s)
                if jerkN > 0 {
                    EventLog.shared.write(String(format: "JITTER рывок точки руки за кадр 120 Гц: сырая поза %.2f мм, курсор %.2f мм (n=%d)",
                                                 jerk[0] / Float(jerkN), jerk[1] / Float(jerkN), jerkN))
                    jerk = [0, 0]; jerkN = 0
                }
            }
            objects.recoverLost()
            objects.updateBlobs()
        }
    }
}
