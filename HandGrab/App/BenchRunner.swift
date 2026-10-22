import Foundation
import AVFoundation
import CoreImage
import CoreVideo
import QuartzCore
import UIKit
import simd

/// Бенчмарк без человека: распознавание рук по встроенным картинкам (Vision разных устройств/разрешений,
/// MediaPipe GPU/CPU) и задержка доставки кадра камерой в разных режимах. Пишет Documents/bench.log.
/// Запуск: xcrun devicectl device process launch --device <id> <your bundle id> -- -bench
final class BenchRunner {
    private let q = DispatchQueue(label: "bench", qos: .userInteractive)
    private var lines: [String] = []
    private let ci = CIContext(options: [.cacheIntermediates: false])
    private var url: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("bench.log") }

    private func log(_ s: String) {
        let th: String
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: th = "норма"; case .fair: th = "тёплый"; case .serious: th = "ГОРЯЧИЙ"; case .critical: th = "КРИТ"
        @unknown default: th = "?"
        }
        lines.append(s + " therm=" + th)
        try? (lines.joined(separator: "\n") + "\n").data(using: .utf8)?.write(to: url, options: .atomic)
        NSLog("BENCH %@", s)
    }

    /// Секции: vision, mp, cam (по умолчанию все). Лог дописывается — секции можно гонять по одной.
    func run(sections: Set<String>) {
        if let old = try? String(contentsOf: url, encoding: .utf8) { lines = old.split(separator: "\n").map(String.init) }
        // Если пользователь переключился на другое приложение — даём досчитать (~30 с).
        let bg = UIApplication.shared.beginBackgroundTask(withName: "bench")
        q.async {
            self.runAll(sections)
            DispatchQueue.main.async { UIApplication.shared.endBackgroundTask(bg) }
        }
    }

    // MARK: Картинки → пиксельные буферы

    private func images(prefix: String) -> [CIImage] {
        let urls = (Bundle.main.urls(forResourcesWithExtension: "jpg", subdirectory: nil) ?? [])
            .filter { $0.lastPathComponent.hasPrefix(prefix) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return urls.compactMap { CIImage(contentsOf: $0) }
    }

    /// Буфер 420f (как у камеры) размером w×h; картинка вписывается с сохранением пропорций.
    /// rotateToSensor: положить портретную картинку в альбомный буфер (как сенсор), показывать ориентацией .right.
    private func buffer(_ img: CIImage, w: Int, h: Int, format: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                        rotateToSensor: Bool = false) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        CVPixelBufferCreate(nil, w, h, format, attrs as CFDictionary, &pb)
        guard let pb else { return nil }
        var src = img
        // .right = «повернуть сохранённое на 90° по часовой для показа» → сохраняем повёрнутым против часовой.
        if rotateToSensor { src = src.oriented(.left) }
        src = src.transformed(by: CGAffineTransform(translationX: -src.extent.minX, y: -src.extent.minY))
        let s = min(CGFloat(w) / src.extent.width, CGFloat(h) / src.extent.height)
        src = src.transformed(by: CGAffineTransform(scaleX: s, y: s))
        let dx = (CGFloat(w) - src.extent.width) / 2, dy = (CGFloat(h) - src.extent.height) / 2
        src = src.transformed(by: CGAffineTransform(translationX: dx, y: dy))
        let bg = CIImage(color: CIColor(red: 0.8, green: 0.78, blue: 0.75)).cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
        ci.render(src.composited(over: bg), to: pb)
        return pb
    }

    // MARK: Замер распознавателя

    private struct Stat { var ms: [Double] = []; var found = 0; var n = 0 }

    private func stats(_ a: [Double]) -> (Double, Double, Double) {
        guard !a.isEmpty else { return (.nan, .nan, .nan) }
        let s = a.sorted()
        return (a.reduce(0, +) / Double(a.count), s[s.count / 2], s[min(s.count - 1, Int(Double(s.count) * 0.95))])
    }

    private func measure(_ name: String, det: HandDetector, bufs: [CVPixelBuffer], orientation: CGImagePropertyOrientation,
                         maxHands: Int, perImage: Int = 25, warmup: Int = 5, label: String) {
        var st = Stat()
        var t = CACurrentMediaTime()
        for pb in bufs {
            for k in 0..<(warmup + perImage) {
                t += 1.0 / 60
                let t0 = CACurrentMediaTime()
                let hands = det.detect(pixelBuffer: pb, orientation: orientation, maxHands: maxHands, time: t)
                let ms = (CACurrentMediaTime() - t0) * 1000
                if k >= warmup { st.ms.append(ms); st.found += hands.count; st.n += 1 }
            }
        }
        let (mean, p50, p95) = stats(st.ms)
        log(String(format: "DET %@ %@ maxHands=%d imgs=%d n=%d mean=%.1f p50=%.1f p95=%.1f hands/кадр=%.2f",
                   name, label, maxHands, bufs.count, st.n, mean, p50, p95, Double(st.found) / Double(max(st.n, 1))))
    }

    /// Средняя разница точек двух распознавателей на одной картинке (проверка перевода координат).
    private func agreement(_ a: HandDetector, _ b: HandDetector, bufs: [CVPixelBuffer],
                           orientation: CGImagePropertyOrientation, orientB: CGImagePropertyOrientation? = nil, label: String) {
        var diffs: [Double] = []
        var missA = 0, missB = 0
        var t = CACurrentMediaTime()
        for pb in bufs {
            var hb: Hand2D?
            for _ in 0..<5 { t += 0.033; hb = b.detect(pixelBuffer: pb, orientation: orientB ?? orientation, maxHands: 1, time: t).first }
            let ha = a.detect(pixelBuffer: pb, orientation: orientation, maxHands: 1, time: t).first
            if ha == nil { missA += 1 }
            if hb == nil { missB += 1 }
            guard let ha, let hb else { continue }
            var d: Float = 0
            for i in 0..<HandJoint.count { d += simd_distance(ha.points[i], hb.points[i]) }
            diffs.append(Double(d / Float(HandJoint.count)))
        }
        log(String(format: "AGREE %@ vs %@ %@ imgs=%d (без руки: %d / %d) mean_dist=%.3f (доля кадра)", a.name, b.name, label, diffs.count, missA, missB,
                   diffs.isEmpty ? Double.nan : diffs.reduce(0, +) / Double(diffs.count)))
    }

    private func runAll(_ sections: Set<String>) {
        log("BENCH START \(sections.sorted().joined(separator: ",")) iOS \(UIDevice.current.systemVersion)")
        if sections.contains("vision") { visionBench() }
        if sections.contains("mp") { mediaPipeBench() }
        if sections.contains("live") { liveBench() }
        if sections.contains("cam") { cameraBench() }
        if sections.contains("chir") { chiralityBench() }
        log("BENCH DONE")
    }

    private func visionBench() {
        let one = images(prefix: "one_"), two = images(prefix: "two_")
        log("картинок: одна рука \(one.count), две руки \(two.count)")

        // 1. Vision авто: разрешения, 1 рука.
        let vAuto = VisionHandDetector(device: 0)
        for (w, h) in [(480, 640), (360, 480), (240, 320), (192, 256)] {
            let bufs = one.compactMap { buffer($0, w: w, h: h) }
            measure(vAuto.name, det: vAuto, bufs: bufs, orientation: .up, maxHands: 1, label: "\(w)x\(h) одна")
        }
        // Как с камеры: альбомный 640×480 и ориентация .right.
        let camBufs = one.compactMap { buffer($0, w: 640, h: 480, rotateToSensor: true) }
        measure(vAuto.name, det: vAuto, bufs: camBufs, orientation: .right, maxHands: 1, label: "640x480 .right одна")
        measure(vAuto.name, det: vAuto, bufs: camBufs, orientation: .right, maxHands: 2, label: "640x480 .right одна")
        // 2. Две руки.
        let two480 = two.compactMap { buffer($0, w: 480, h: 640) }
        let one480 = one.compactMap { buffer($0, w: 480, h: 640) }
        measure(vAuto.name, det: vAuto, bufs: two480, orientation: .up, maxHands: 2, label: "480x640 две")
        measure(vAuto.name, det: vAuto, bufs: one480, orientation: .up, maxHands: 2, label: "480x640 одна")
        // 3. Устройства Vision.
        for dev in [1, 2, 3] {
            let d = VisionHandDetector(device: dev)
            measure(d.name, det: d, bufs: one480, orientation: .up, maxHands: 1, label: "480x640 одна")
            measure(d.name, det: d, bufs: two480, orientation: .up, maxHands: 2, label: "480x640 две")
        }
    }

    /// Как в приложении: кадр 640×480 420f с сенсора, ищем до двух рук. Варианты чередуются по кругу 3 раза,
    /// чтобы нагрев и частота процессора не подыгрывали ни одному из них.
    private func liveBench() {
        let one = images(prefix: "one_").compactMap { buffer($0, w: 640, h: 480, rotateToSensor: true) }
        let two = images(prefix: "two_").compactMap { buffer($0, w: 640, h: 480, rotateToSensor: true) }
        var dets: [HandDetector] = [VisionHandDetector(device: 0)]
        #if canImport(MediaPipeTasksVision)
        #if !targetEnvironment(simulator)
        if let g = MediaPipeHandDetector(gpu: true, maxHands: 2) { dets.append(g) }
        #endif
        if let c = MediaPipeHandDetector(gpu: false, maxHands: 2) { dets.append(c) }
        #endif
        for round in 1...3 {
            for d in dets {
                measure(d.name, det: d, bufs: one, orientation: .right, maxHands: 2, perImage: 15, warmup: 3, label: "круг \(round) 640x480 одна")
                measure(d.name, det: d, bufs: two, orientation: .right, maxHands: 2, perImage: 15, warmup: 3, label: "круг \(round) 640x480 две")
            }
        }
    }

    private func mediaPipeBench() {
        let one = images(prefix: "one_"), two = images(prefix: "two_")
        let one480 = one.compactMap { buffer($0, w: 480, h: 640) }
        let two480 = two.compactMap { buffer($0, w: 480, h: 640) }
        let camBufs = one.compactMap { buffer($0, w: 640, h: 480, rotateToSensor: true) }
        let vAuto = VisionHandDetector(device: 0)
        // MediaPipe (видео-режим: рука ведётся между кадрами).
        #if canImport(MediaPipeTasksVision)
        #if targetEnvironment(simulator)
        let gpus = [false]   // GPU-делегат MediaPipe в Симуляторе не работает — только проверка точек на CPU
        #else
        let gpus = [true, false]
        #endif
        for gpu in gpus {
            guard let m1 = MediaPipeHandDetector(gpu: gpu, maxHands: 1) else { log("MediaPipe \(gpu ? "GPU" : "CPU"): не создался"); continue }
            m1.feedUp = false
            measure(m1.name, det: m1, bufs: one480, orientation: .up, maxHands: 1, label: "480x640 одна")
            measure(m1.name, det: m1, bufs: two480, orientation: .up, maxHands: 2, label: "480x640 две")
            // Одна рука в кадре, но ищем до двух (так в приложении по умолчанию): поиск второй ладони на каждом кадре.
            measure(m1.name, det: m1, bufs: one480, orientation: .up, maxHands: 2, label: "480x640 одна")
            measure(m1.name, det: m1, bufs: camBufs, orientation: .right, maxHands: 1, label: "640x480 .right одна")
            if let e = m1.lastError { log("MediaPipe ошибка: \(e)") }
            // Альбомный буфер как с сенсора, но без поворота (.up): MediaPipe сам ведёт повёрнутую руку.
            m1.feedUp = true
            measure(m1.name, det: m1, bufs: camBufs, orientation: .up, maxHands: 1, label: "640x480 .up одна")
            measure(m1.name, det: m1, bufs: two.compactMap { buffer($0, w: 640, h: 480, rotateToSensor: true) },
                    orientation: .up, maxHands: 2, label: "640x480 .up две")
            if let m2 = MediaPipeHandDetector(gpu: gpu, maxHands: 1) {
                m2.feedUp = false
                agreement(vAuto, m2, bufs: one480, orientation: .up, label: "480x640 .up")
            }
            if let m3 = MediaPipeHandDetector(gpu: gpu, maxHands: 1) {
                m3.feedUp = false
                agreement(vAuto, m3, bufs: camBufs, orientation: .right, label: "640x480 .right")
            }
            if let r = MediaPipeHandDetector(gpu: gpu, maxHands: 1), let u = MediaPipeHandDetector(gpu: gpu, maxHands: 1) {
                r.feedUp = false; u.feedUp = true
                agreement(r, u, bufs: camBufs, orientation: .right, label: "MP .right vs MP .up (один и тот же кадр)")
            }
            if let m4 = MediaPipeHandDetector(gpu: gpu, maxHands: 1) {
                m4.feedUp = true
                agreement(vAuto, m4, bufs: camBufs, orientation: .right, orientB: .up, label: "640x480 Vision .right / MP .up")
            }
        }
        #else
        log("MediaPipe: не собран в приложение")
        #endif
    }

    // MARK: Левая/правая: Vision и MediaPipe на одном и том же буфере

    /// Картинки рук (и их зеркальные копии) кладутся в буфер как с сенсора (альбомный, показ ориентацией .right).
    /// Vision получает .right (как в приложении), MediaPipe — буфер как есть (.up, как в приложении).
    /// В журнал: метки обоих по рукам слева направо (x — как картинка видна без зеркала).
    private func chiralityBench() {
        let urls = (Bundle.main.urls(forResourcesWithExtension: "jpg", subdirectory: nil) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("one_") || $0.lastPathComponent.hasPrefix("two_") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let v = VisionHandDetector(device: 0)
        var agree = 0, disagree = 0
        func x(_ h: Hand2D) -> Float {
            var c = SIMD2<Float>(0, 0)
            for i in HandJoint.palmIndices { c += h.points[i] }
            return CoordinateMapper.sensorToScreen(c / 5, rotate180: false, mirrorX: false).x
        }
        func tag(_ c: Chirality) -> String { c == .left ? "L" : c == .right ? "R" : "?" }
        for u in urls {
            guard let img0 = CIImage(contentsOf: u) else { continue }
            for flip in [false, true] {
                var img = img0
                if flip { img = img.transformed(by: CGAffineTransform(scaleX: -1, y: 1)) }
                guard let pb = buffer(img, w: 640, h: 480, rotateToSensor: true) else { continue }
                let vh = v.detect(pixelBuffer: pb, orientation: .right, maxHands: 2, time: 0).sorted { x($0) < x($1) }
                var line = String(format: "CHIR %@%@ Vision:", u.deletingPathExtension().lastPathComponent, flip ? " (зеркало)" : "")
                for h in vh { line += String(format: " %@@%.2f", tag(h.chirality), x(h)) }
                #if canImport(MediaPipeTasksVision)
                #if targetEnvironment(simulator)
                let gpu = false
                #else
                let gpu = true
                #endif
                if let m = MediaPipeHandDetector(gpu: gpu, maxHands: 2) {
                    m.feedUp = true
                    var mh: [Hand2D] = []
                    var raw: [String] = []
                    var t = CACurrentMediaTime()
                    for _ in 0..<5 { t += 0.033; mh = m.detect(pixelBuffer: pb, orientation: .up, maxHands: 2, time: t); raw = m.lastRawLabels }
                    let order = mh.indices.sorted { x(mh[$0]) < x(mh[$1]) }
                    line += " | MediaPipe как выдал:"
                    for i in order { line += String(format: " %@@%.2f", i < raw.count ? raw[i] : "?", x(mh[i])) }
                    // Сопоставление по положению: ближайшая рука Vision.
                    for i in order {
                        guard let w = vh.min(by: { abs(x($0) - x(mh[i])) < abs(x($1) - x(mh[i])) }), abs(x(w) - x(mh[i])) < 0.1,
                              w.chirality != .unknown, i < raw.count else { continue }
                        let mpLeft = raw[i] == "Left"
                        if mpLeft == (w.chirality == .left) { agree += 1 } else { disagree += 1 }
                    }
                }
                #endif
                log(line)
            }
        }
        log("CHIR ИТОГ: метка MediaPipe как есть совпала с Vision \(agree), противоположна \(disagree)")
    }

    // MARK: Камера

    private final class Probe: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
        var ages: [Double] = []
        var count = 0
        let session: AVCaptureSession
        /// Если задан — на каждый кадр (кроме занятого) распознаётся картинка руки того же размера, что кадр:
        /// задержка «съёмка → поза готова» с настоящей камерой и настоящим распознавателем (содержимое — не из камеры).
        var detector: HandDetector?
        var handBuf: CVPixelBuffer?
        var ready: [Double] = []
        var detMs: [Double] = []
        var skipped = 0
        private var busy = false
        private let work = DispatchQueue(label: "bench-det", qos: .userInteractive)
        init(session: AVCaptureSession) { self.session = session }
        func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
            let pts = CMSampleBufferGetPresentationTimeStamp(sb)
            var t = CMTimeGetSeconds(pts)
            if let clock = session.synchronizationClock {
                t = CMTimeGetSeconds(CMSyncConvertTime(pts, from: clock, to: CMClockGetHostTimeClock()))
            }
            ages.append((CACurrentMediaTime() - t) * 1000)
            count += 1
            guard let det = detector, let hb = handBuf else { return }
            if busy { skipped += 1; return }
            busy = true
            work.async {
                let t0 = CACurrentMediaTime()
                _ = det.detect(pixelBuffer: hb, orientation: .right, maxHands: 2, time: t)
                let t1 = CACurrentMediaTime()
                DispatchQueue.main.async { self.detMs.append((t1 - t0) * 1000); self.ready.append((t1 - t) * 1000); self.busy = false }
            }
        }
    }

    private func cameraBench() {
        let granted = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        if !granted {
            let sem = DispatchSemaphore(value: 0)
            AVCaptureDevice.requestAccess(for: .video) { _ in sem.signal() }
            sem.wait()
        }
        let hand = images(prefix: "one_").first.flatMap { buffer($0, w: 640, h: 480, rotateToSensor: true) }
        var runs: [(String, Bool, Bool, Int)] = [("видео+глубина 640", true, false, -1), ("видео+глубина 160", true, true, -1)]
        // Как в приложении: камера + распознаватель на каждом кадре (v2: Vision; v3: MediaPipe GPU).
        runs += [("v2-как: глубина 640 + Vision", true, false, 0), ("v3: глубина 160 + Vision", true, true, 0)]
        if HandDetectorFactory.mediaPipeAvailable {
            runs.append(("v3: глубина 640 + MediaPipe GPU", true, false, 1))
            runs.append(("v3: глубина 640 + MediaPipe CPU", true, false, 2))
        }
        for (label, depth, low, detKind) in runs {
            let cap = TrueDepthCapture()
            do {
                try cap.configure(depthFiltering: false, useSynchronizer: false, depthLowRes: low, withDepth: depth)
            } catch { log("CAM \(label): ошибка \(error.localizedDescription)"); continue }
            // Свой делегат видео поверх: замер возраста кадра в момент доставки.
            let probe = Probe(session: cap.session)
            if detKind >= 0 {
                probe.detector = HandDetectorFactory.make(kind: detKind, visionDevice: 0, maxHands: 2)
                probe.handBuf = hand
            }
            if let out = cap.session.outputs.compactMap({ $0 as? AVCaptureVideoDataOutput }).first {
                out.setSampleBufferDelegate(probe, queue: DispatchQueue(label: "bench-cam", qos: .userInteractive))
            }
            cap.session.startRunning()
            Thread.sleep(forTimeInterval: 1.0)
            probe.ages.removeAll(); probe.count = 0
            DispatchQueue.main.sync { probe.ready.removeAll(); probe.detMs.removeAll(); probe.skipped = 0 }
            let cpu0 = Metrics.cpuSeconds()
            let t0 = CACurrentMediaTime()
            Thread.sleep(forTimeInterval: 4.0)
            let dt = CACurrentMediaTime() - t0
            cap.session.stopRunning()
            let cpu = 100 * (Metrics.cpuSeconds() - cpu0) / dt
            let (mean, p50, p95) = stats(probe.ages)
            log(String(format: "CAM %@ fps=%.1f доставка mean=%.1f p50=%.1f p95=%.1f мс CPU=%.0f%% (%@)", label, Double(probe.count) / dt,
                       mean, p50, p95, cpu, cap.selection?.summary ?? "?"))
            let (rd, dm) = DispatchQueue.main.sync { (probe.ready, probe.detMs) }
            if detKind >= 0 {
                let (rm, r50, r95) = stats(rd), (dmm, _, d95) = stats(dm)
                log(String(format: "CAM+DET %@ поза готова через mean=%.1f p50=%.1f p95=%.1f мс после съёмки; распознавание %.1f/%.1f мс; %.0f поз/с",
                           label, rm, r50, r95, dmm, d95, Double(rd.count) / dt))
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
    }
}

/// Распознаватель на картинках рук 60 раз в секунду рядом с работающей сценой: сколько он стоит под нагрузкой рендера.
/// Раз в 2 с — строка DETLOAD в events.log (средн/p95 мс, поз/с).
final class DetLoad {
    static let shared = DetLoad()
    private let q = DispatchQueue(label: "detload", qos: .userInteractive)
    func start(kind: Int) {
        q.async {
            let ci = CIContext()
            var bufs: [CVPixelBuffer] = []
            for u in (Bundle.main.urls(forResourcesWithExtension: "jpg", subdirectory: nil) ?? []) where u.lastPathComponent.hasPrefix("two_") {
                guard var img = CIImage(contentsOf: u) else { continue }
                var pb: CVPixelBuffer?
                CVPixelBufferCreate(nil, 640, 480, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                                    [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &pb)
                guard let pb else { continue }
                img = img.oriented(.left)
                img = img.transformed(by: CGAffineTransform(translationX: -img.extent.minX, y: -img.extent.minY))
                let s = min(640 / img.extent.width, 480 / img.extent.height)
                ci.render(img.transformed(by: CGAffineTransform(scaleX: s, y: s)), to: pb)
                bufs.append(pb)
            }
            guard !bufs.isEmpty else { return }
            let det = HandDetectorFactory.make(kind: kind, visionDevice: 0, maxHands: 2)
            var ms: [Double] = [], n = 0, t0 = CACurrentMediaTime(), k = 0
            while true {
                let t = CACurrentMediaTime()
                _ = det.detect(pixelBuffer: bufs[(k / 30) % bufs.count], orientation: .right, maxHands: 2, time: t)
                let d = CACurrentMediaTime() - t
                ms.append(d * 1000); n += 1; k += 1
                if t - t0 > 2 {
                    let s = ms.sorted()
                    EventLog.shared.write(String(format: "DETLOAD %@ средн %.1f p95 %.1f мс, %.0f поз/с", det.name,
                                                 s.reduce(0, +) / Double(s.count), s[min(s.count - 1, s.count * 95 / 100)], Double(n) / (t - t0)))
                    ms.removeAll(); n = 0; t0 = t
                }
                let wait = 1.0 / 60 - (CACurrentMediaTime() - t)
                if wait > 0 { Thread.sleep(forTimeInterval: wait) }
            }
        }
    }
}
