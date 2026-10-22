import Foundation
import AVFoundation
import CoreImage
import UIKit
import os
import simd

/// Конвейер: capture → Vision (1–2 распознавателя параллельно, лишние кадры выбрасываются)
/// → последовательная очередь слияния (глубина по времени + жёсткая модель) → LatestHandState.
final class TrackingPipeline {
    let latest = LatestHandState()
    private final class Worker {
        let queue: DispatchQueue
        var detector: HandDetector?
        var kind = (-1, -1)
        let busy = OSAllocatedUnfairLock(initialState: false)
        init(_ i: Int) { queue = DispatchQueue(label: "detect\(i)", qos: .userInteractive) }
        /// Распознаватель создаётся на своей очереди и пересоздаётся при смене настройки.
        func detector(for c: TrackingConfig) -> HandDetector {
            if let d = detector, kind == (c.detector, c.visionDevice) { return d }
            let d = HandDetectorFactory.makeChecked(kind: c.detector, visionDevice: c.visionDevice, maxHands: c.maxHands)
            detector = d; kind = (c.detector, c.visionDevice)
            Metrics.shared.updateInfo { $0.detector = d.name }
            SessionRecorder.detectorName = d.name
            return d
        }
    }
    private let workers: [Worker] = (0..<2).map { Worker($0) }
    /// Запись сессии (точки + глубина ладони) для реплея.
    let recorder = SessionRecorder()
    /// Слияние строго по одному кадру за раз и по возрастанию времени.
    private let fusionQueue = DispatchQueue(label: "fusion", qos: .userInteractive)
    private let fusion = HandFusion()
    private let slots = [HandSlotState(slot: 0), HandSlotState(slot: 1)]
    /// Руки ↔ слоты по близости ладони в кадре (только на очереди слияния).
    private var assigner = SlotAssigner()
    private let calibration = CalibrationCollector()
    private let calibRequest = OSAllocatedUnfairLock(initialState: false)
    private var frameIndex = 0
    private var lastPreview: Double = 0
    private var lastFusedT: Double = 0
    private var lastIngestedDepthT: Double = 0
    private var intr = Intrinsics.fallback
    private var intrKnown = false
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    /// Превью рисуется на своей очереди, чтобы не задерживать Vision.
    private let previewQueue = DispatchQueue(label: "preview", qos: .utility)
    private let previewBusy = OSAllocatedUnfairLock(initialState: false)

    /// Вызывается на главном потоке, когда калибровка закончилась.
    var onCalibrated: ((_ bones: [Float], _ scale: Float, _ distance: Float) -> Void)?
    /// Превью (RGB и глубина с точками) ≤ 15 Гц, на главном потоке.
    var onPreview: ((CGImage?, CGImage?) -> Void)?

    func requestCalibration() { calibRequest.withLock { $0 = true } }

    /// Вызывается на очереди capture.
    func handle(_ frame: CaptureFrame) {
        let cfg = ConfigStore.shared.snapshot
        let count = cfg.parallelVision ? workers.count : 1
        var chosen: Worker?
        for w in workers.prefix(count) {
            let ok = w.busy.withLock { b -> Bool in if b { return false }; b = true; return true }
            if ok { chosen = w; break }
        }
        guard let w = chosen else { Metrics.shared.visionSkipped(); return }
        w.queue.async { [weak self] in
            guard let self else { return }
            let orientation = CGImagePropertyOrientation(rawValue: cfg.visionOrientation) ?? .right
            let det = w.detector(for: cfg)
            let t0 = CACurrentMediaTime()
            let hands = det.detect(pixelBuffer: frame.pixelBuffer, orientation: orientation, maxHands: cfg.maxHands,
                                   time: frame.captureHostTime)
            let t1 = CACurrentMediaTime()
            Metrics.shared.visionDone(ms: (t1 - t0) * 1000)
            w.busy.withLock { $0 = false }
            self.fusionQueue.async { self.fuse(frame, hands: hands, visionStart: t0) }
        }
    }

    private func updateIntrinsics(_ frame: CaptureFrame, depth: DepthMap?) {
        if let m = frame.videoIntrinsics, frame.videoSize.width > 0 {
            let w = Float(frame.videoSize.width), h = Float(frame.videoSize.height)
            intr = Intrinsics(fx: m.columns.0.x / w, fy: m.columns.1.y / h, cx: m.columns.2.x / w, cy: m.columns.2.y / h)
            intrKnown = true
        } else if !intrKnown, let d = depth {
            let w = Float(d.width), h = Float(d.height)
            intr = Intrinsics(fx: d.fx / w, fy: d.fy / h, cx: d.cx / w, cy: d.cy / h)
            intrKnown = true
        }
    }

    /// Карты глубины, которые ещё не учтены: сопоставить с позой руки в момент их съёмки.
    private func ingestDepths(_ frame: CaptureFrame, upTo t: Double) -> DepthMap? {
        var newest: DepthMap?
        for td in frame.depths where td.time > lastIngestedDepthT {
            // Поза на момент карты ещё не распознана — подождём следующего кадра (если карта не слишком старая).
            if td.time > t + 0.012 { continue }
            guard let map = DepthMap.make(from: td.data, time: td.time, videoIntrinsics: nil, videoSize: .zero) else {
                lastIngestedDepthT = td.time; continue
            }
            newest = map
            lastIngestedDepthT = td.time
            for st in slots where !st.history.isEmpty {
                guard let e = st.history.min(by: { abs($0.t - td.time) < abs($1.t - td.time) }),
                      abs(e.t - td.time) <= 0.012 else { continue }
                let ok = fusion.ingest(depth: map, points: e.points, conf: e.conf, state: st)
                Metrics.shared.depthIngest(hole: !ok)
            }
        }
        if let last = frame.depths.last {
            Metrics.shared.depthAge(ms: (t - last.time) * 1000)
        }
        return newest
    }

    private func fuse(_ frame: CaptureFrame, hands: [Hand2D], visionStart t0: Double) {
        let cfg = ConfigStore.shared.snapshot
        let t = frame.captureHostTime
        // Два распознавателя могут закончить не по порядку — старый кадр после нового только навредит.
        guard t > lastFusedT else { return }
        lastFusedT = t
        frameIndex += 1
        let deliverAge = (frame.arrivalTime - frame.captureHostTime) * 1000
        let queueWait = (t0 - frame.arrivalTime) * 1000

        if calibRequest.withLock({ v -> Bool in let r = v; v = false; return r }) {
            calibration.start(now: t)
        }

        // Сопоставление рук со слотами; сначала история 2D, потом глубина (ей нужна история).
        let assignment = assigner.assign(hands, t: t)
        for (hi, slotIndex) in assignment {
            let st = slots[slotIndex]
            if t - st.lastSeen > 0.5 { st.reset() }
            st.history.append((t, hands[hi].points, hands[hi].conf))
            st.history.removeAll { t - $0.t > 0.25 }
        }
        var depthMap = ingestDepths(frame, upTo: t)
        updateIntrinsics(frame, depth: depthMap)

        var frames: [HandFrame] = []
        var meanConf: Float = 0
        var fused0: FusedHand?
        for (hi, slotIndex) in assignment {
            let h = hands[hi]
            let st = slots[slotIndex]
            guard let fused = fusion.fuse(h, t: t, intr: intr, state: st, config: cfg) else { continue }
            if fused0 == nil { fused0 = fused }
            if calibration.active, let res = calibration.add(fused: fused, now: t) {
                DispatchQueue.main.async { [weak self] in self?.onCalibrated?(res.bones, res.scale, res.distance) }
            }
            let f = fusion.filter(fused, hand: h, state: st, t: t, config: cfg)
            st.lastWrist2D = h.points[0]
            frames.append(f)
            meanConf += h.conf.reduce(0, +) / Float(HandJoint.count)
        }
        // Глубина, только что сопоставленная с этим кадром, сразу попала в решение (карта той же позы).
        // Если карт в этом кадре не было — свежая карта для превью/метрик берётся последняя из кольца.
        if depthMap == nil, let last = frame.depths.last {
            depthMap = DepthMap.make(from: last.data, time: last.time, videoIntrinsics: nil, videoSize: .zero)
        }
        _ = calibration.cancelIfExpired(now: t)
        latest.publish(frames, hfov: intr.hfovDegrees)
        if cfg.recordSession {
            recorder.add(t: t, hands: assignment.map { hands[$0.0] }, depths: assignment.map { a -> Float? in
                let st = slots[a.1]
                return st.depth.age(t) < 0.4 ? st.depth.at(t) : nil
            }, intr: intr, orientation: cfg.visionOrientation)
        }
        let doneAge = (CACurrentMediaTime() - frame.captureHostTime) * 1000
        Metrics.shared.stages(deliver: deliverAge, wait: queueWait, done: doneAge)

        let first = frames.first
        Metrics.shared.updateInfo { i in
            i.hands = frames.count
            i.meanConf = frames.isEmpty ? 0 : meanConf / Float(frames.count)
            i.palmCm = first.map { $0.palmDistance * 100 } ?? .nan
            i.depthFresh = fused0?.depthFresh ?? false
            i.pinchD = first?.pinchD ?? .nan
            i.fistD = first?.fistD ?? .nan
            i.pinch = frames.map { ($0.chirality == .right ? "П:" : "Л:") + ($0.pinching ? "щипок" : $0.fist ? "кулак" : "—") }.joined(separator: " ")
            if i.pinch.isEmpty { i.pinch = "—" }
            i.scaleCm = first.map { $0.scale * 100 } ?? .nan
            i.hfov = intr.hfovDegrees
            if let d = depthMap {
                i.depthAccuracy = d.accuracy == .absolute ? "абсолютная" : "относительная"
                i.depthQuality = d.quality == .high ? "high" : "low"
            }
        }

        // Превью ≤ 15 Гц.
        if cfg.showPreview, t - lastPreview >= 1.0 / 15.0, onPreview != nil {
            let free = previewBusy.withLock { b -> Bool in if b { return false }; b = true; return true }
            if free {
                lastPreview = t
                let dm = depthMap
                previewQueue.async { [weak self] in
                    guard let self else { return }
                    self.makePreview(frame: frame, depth: dm, hands: hands, config: cfg)
                    self.previewBusy.withLock { $0 = false }
                }
            }
        }
    }

    // MARK: Реплей — тот же конвейер без камеры

    static let recordInjected = ProcessInfo.processInfo.arguments.contains("-record")

    /// Подать распознанные руки и глубину ладони (м, по руке) как будто с камеры. Вызывать с любого потока.
    func inject(hands: [Hand2D], palmDepths: [Float?], t: Double, intrinsics: Intrinsics) {
        fusionQueue.async { [weak self] in
            guard let self else { return }
            let cfg = ConfigStore.shared.snapshot
            guard t > self.lastFusedT else { return }
            self.lastFusedT = t
            self.intr = intrinsics; self.intrKnown = true
            let assignment = self.assigner.assign(hands, t: t)
            var frames: [HandFrame] = []
            for (hi, slotIndex) in assignment {
                let st = self.slots[slotIndex]
                if t - st.lastSeen > 0.5 { st.reset() }
                if hi < palmDepths.count, let z = palmDepths[hi] { st.depth.update(t: t, z: z) }
                guard let fused = self.fusion.fuse(hands[hi], t: t, intr: intrinsics, state: st, config: cfg) else { continue }
                let f = self.fusion.filter(fused, hand: hands[hi], state: st, t: t, config: cfg)
                st.lastWrist2D = hands[hi].points[0]
                frames.append(f)
            }
            self.latest.publish(frames, hfov: intrinsics.hfovDegrees)
            // Проверка записи/реплея файла: синтетику можно записать как сессию (-replay synth -record).
            if TrackingPipeline.recordInjected {
                self.recorder.add(t: t, hands: assignment.map { hands[$0.0] },
                                  depths: assignment.map { $0.0 < palmDepths.count ? palmDepths[$0.0] : nil },
                                  intr: intrinsics, orientation: cfg.visionOrientation)
            }
            Metrics.shared.visionDone(ms: 0)
            Metrics.shared.updateInfo { i in
                i.hands = frames.count
                i.palmCm = frames.first.map { $0.palmDistance * 100 } ?? .nan
                i.pinch = frames.map { ($0.chirality == .right ? "П:" : "Л:") + ($0.pinching ? "щипок" : $0.fist ? "кулак" : "—") }.joined(separator: " ")
                i.pinchD = frames.first?.pinchD ?? .nan
                i.fistD = frames.first?.fistD ?? .nan
            }
        }
    }

    // MARK: Превью

    private func makePreview(frame: CaptureFrame, depth: DepthMap?, hands: [Hand2D], config c: TrackingConfig) {
        // Превью всегда как селфи (привычно глазу), точки — в той же ориентации.
        let orient = CoordinateMapper.previewOrientation(rotate180: c.rotate180, mirrorX: true)
        let pts: [[SIMD2<Float>]] = hands.map { h in
            h.points.enumerated().filter { h.conf[$0.offset] > 0 }.map {
                CoordinateMapper.sensorToScreen($0.element, rotate180: c.rotate180, mirrorX: true)
            }
        }
        let size = CGSize(width: 120, height: 160) // портрет
        let rgb = renderImage(CIImage(cvPixelBuffer: frame.pixelBuffer), orientation: orient, size: size, points: pts)
        var dimg: CGImage?
        if let depth, var ci = CIImage(depthData: depth.depthData) {
            // Глубина 0.15–1.0 м → 0…1 → псевдоцвет (близко — красный, далеко — синий).
            ci = ci.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 1 / 0.85, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 1 / 0.85, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 1 / 0.85, y: 0, z: 0, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: -0.176, y: -0.176, z: -0.176, w: 1),
            ]).applyingFilter("CIColorClamp").applyingFilter("CIFalseColor", parameters: [
                "inputColor0": CIColor(red: 1, green: 0.2, blue: 0.1),
                "inputColor1": CIColor(red: 0.1, green: 0.2, blue: 1),
            ])
            dimg = renderImage(ci, orientation: orient, size: size, points: pts)
        }
        Telemetry.shared.lastPreview.withLockUnchecked { $0 = rgb }
        DispatchQueue.main.async { [weak self] in self?.onPreview?(rgb, dimg) }
    }

    private func renderImage(_ src: CIImage, orientation: CGImagePropertyOrientation, size: CGSize,
                             points: [[SIMD2<Float>]]) -> CGImage? {
        let o = src.oriented(orientation)
        let sx = size.width / o.extent.width, sy = size.height / o.extent.height
        let scaled = o.transformed(by: CGAffineTransform(translationX: -o.extent.minX, y: -o.extent.minY))
            .transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        guard let base = ciContext.createCGImage(scaled, from: CGRect(origin: .zero, size: size)) else { return nil }
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 2
        let r = UIGraphicsImageRenderer(size: size, format: fmt)
        let img = r.image { ctx in
            UIImage(cgImage: base).draw(in: CGRect(origin: .zero, size: size))
            let colors = [UIColor.cyan, UIColor.orange]
            for (hi, hp) in points.enumerated() {
                ctx.cgContext.setFillColor(colors[hi % 2].cgColor)
                for p in hp {
                    let x = CGFloat(p.x) * size.width, y = CGFloat(p.y) * size.height
                    ctx.cgContext.fillEllipse(in: CGRect(x: x - 1.5, y: y - 1.5, width: 3, height: 3))
                }
            }
        }
        return img.cgImage
    }
}
