import Foundation
import Vision
import CoreML
import CoreVideo
import ImageIO
import UIKit
import CoreImage
import QuartzCore
import simd
#if canImport(MediaPipeTasksVision)
import MediaPipeTasksVision
import VideoToolbox
#endif

/// Распознаватель 2D-скелета руки (21 точка в координатах сенсора).
protocol HandDetector: AnyObject {
    var name: String { get }
    /// time — время кадра (с), нужно видео-режиму MediaPipe (монотонно растёт).
    func detect(pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation, maxHands: Int, time: Double) -> [Hand2D]
}

enum HandDetectorFactory {
    /// kind: 0 = Vision, 1 = MediaPipe GPU, 2 = MediaPipe CPU. visionDevice: 0 авто, 1 ANE, 2 GPU, 3 CPU.
    static func make(kind: Int, visionDevice: Int, maxHands: Int = 2) -> HandDetector {
        #if canImport(MediaPipeTasksVision)
        if kind == 1 || kind == 2, let d = MediaPipeHandDetector(gpu: kind == 1, maxHands: maxHands) { return d }
        #endif
        return VisionHandDetector(device: visionDevice)
    }

    /// Самопроверка MediaPipe при запуске: на встроенной картинке руки (буфер как с сенсора, .right) точки MediaPipe
    /// должны совпасть с Vision (в среднем < 4% кадра). Иначе — откат на Vision (в журнал событий).
    static func makeChecked(kind: Int, visionDevice: Int, maxHands: Int) -> HandDetector {
        let d = make(kind: kind, visionDevice: visionDevice, maxHands: maxHands)
        guard kind != 0, !(d is VisionHandDetector) else { return d }
        guard let url = Bundle.main.url(forResource: "one_victory", withExtension: "jpg"), let img = CIImage(contentsOf: url) else { return d }
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, 640, 480, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                            [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &pb)
        guard let pb else { return d }
        var src = img.oriented(.left)
        src = src.transformed(by: CGAffineTransform(translationX: -src.extent.minX, y: -src.extent.minY))
        let sc = min(640 / src.extent.width, 480 / src.extent.height)
        src = src.transformed(by: CGAffineTransform(scaleX: sc, y: sc))
        CIContext().render(src, to: pb)
        let v = VisionHandDetector(device: 0)
        var t = CACurrentMediaTime()
        var mh: Hand2D?
        for _ in 0..<5 { t += 0.033; mh = d.detect(pixelBuffer: pb, orientation: .right, maxHands: 1, time: t).first }
        guard let vh = v.detect(pixelBuffer: pb, orientation: .right, maxHands: 1, time: t).first else { return d }
        guard let mh else {
            EventLog.shared.write("SELFTEST \(d.name): руки не нашёл → Vision")
            return v
        }
        var dist: Float = 0
        for i in 0..<HandJoint.count { dist += simd_distance(vh.points[i], mh.points[i]) }
        dist /= Float(HandJoint.count)
        EventLog.shared.write(String(format: "SELFTEST %@ vs Vision: %.3f кадра", d.name, dist))
        return dist < 0.04 ? d : v
    }

    static var mediaPipeAvailable: Bool {
        #if canImport(MediaPipeTasksVision)
        return Bundle.main.path(forResource: "hand_landmarker", ofType: "task") != nil
        #else
        return false
        #endif
    }
}

/// Отбор точек одинаковый для всех распознавателей.
enum HandFilter {
    static let minPointConfidence: Float = 0.3
    static let goodConfidence: Float = 0.5
    static let minGoodJoints = 12
}

/// Vision: запрос переиспользуется, обработчик — новый на каждый кадр.
final class VisionHandDetector: HandDetector {
    private let request = VNDetectHumanHandPoseRequest()
    let name: String

    init(device: Int) {
        var label = "авто"
        if device != 0, #available(iOS 17.0, *) {
            if let devs = try? request.supportedComputeStageDevices[.main] {
                let pick = devs.first { d in
                    switch d {
                    case .neuralEngine: return device == 1
                    case .gpu: return device == 2
                    case .cpu: return device == 3
                    @unknown default: return false
                    }
                }
                if let pick {
                    request.setComputeDevice(pick, for: .main)
                    label = device == 1 ? "ANE" : device == 2 ? "GPU" : "CPU"
                } else {
                    label = "нет устройства \(device)"
                }
            }
        }
        name = "Vision/" + label
    }

    func detect(pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation, maxHands: Int, time: Double) -> [Hand2D] {
        request.maximumHandCount = max(1, min(2, maxHands))
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])
        do { try handler.perform([request]) } catch { return [] }
        guard let results = request.results else { return [] }
        var hands: [Hand2D] = []
        for obs in results {
            guard let pts = try? obs.recognizedPoints(.all) else { continue }
            var points = [SIMD2<Float>](repeating: .zero, count: HandJoint.count)
            var conf = [Float](repeating: 0, count: HandJoint.count)
            var good = 0
            for (i, jn) in HandJoint.vnNames.enumerated() {
                guard let p = pts[jn] else { continue }
                let c = Float(p.confidence)
                if c < HandFilter.minPointConfidence { continue }
                points[i] = CoordinateMapper.visionToSensor(p.location, orientation: orientation)
                conf[i] = c
                if c > HandFilter.goodConfidence { good += 1 }
            }
            if good < HandFilter.minGoodJoints { continue }
            let ch: Chirality
            switch obs.chirality {
            case .left: ch = .left
            case .right: ch = .right
            default: ch = .unknown
            }
            hands.append(Hand2D(points: points, conf: conf, chirality: ch, goodCount: good))
        }
        return hands
    }
}

#if canImport(MediaPipeTasksVision)
/// MediaPipe Hand Landmarker (видео-режим: между кадрами следит за рукой без повторного поиска ладони).
final class MediaPipeHandDetector: HandDetector {
    private var landmarkers: [Int: HandLandmarker] = [:]
    private let gpu: Bool
    private let modelPath: String
    private var lastMs: Int = -1
    let name: String
    /// MediaPipe принимает только 32BGRA: 420f с камеры переводится аппаратно (VTPixelTransferSession).
    private var transfer: VTPixelTransferSession?
    private var bgra: CVPixelBuffer?
    private(set) var lastError: String?
    /// Метки рук из последнего кадра как их выдал MediaPipe («Left»/«Right») — для бенча сверки с Vision.
    private(set) var lastRawLabels: [String] = []

    private func toBGRA(_ pb: CVPixelBuffer) -> CVPixelBuffer? {
        if CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_32BGRA { return pb }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        if bgra == nil || CVPixelBufferGetWidth(bgra!) != w || CVPixelBufferGetHeight(bgra!) != h {
            var out: CVPixelBuffer?
            let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:],
                                        kCVPixelBufferMetalCompatibilityKey as String: true]
            CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &out)
            bgra = out
        }
        if transfer == nil { VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &transfer) }
        guard let t = transfer, let dst = bgra else { return nil }
        return VTPixelTransferSessionTransferImage(t, from: pb, to: dst) == noErr ? dst : nil
    }

    init?(gpu: Bool, maxHands: Int) {
        guard let path = Bundle.main.path(forResource: "hand_landmarker", ofType: "task") else { return nil }
        self.gpu = gpu
        self.modelPath = path
        self.name = "MediaPipe/" + (gpu ? "GPU" : "CPU")
        guard landmarker(maxHands) != nil else { return nil }
    }

    private func landmarker(_ n: Int) -> HandLandmarker? {
        if let l = landmarkers[n] { return l }
        let o = HandLandmarkerOptions()
        o.baseOptions.modelAssetPath = modelPath
        o.baseOptions.delegate = gpu ? .GPU : .CPU
        o.runningMode = .video
        o.numHands = n
        o.minHandDetectionConfidence = 0.5
        o.minHandPresenceConfidence = 0.5
        o.minTrackingConfidence = 0.5
        guard let l = try? HandLandmarker(options: o) else { return nil }
        landmarkers[n] = l
        return l
    }

    /// Подавать буфер сенсора как есть (.up): MediaPipe сам ведёт повёрнутую руку, поворот кадра не нужен.
    var feedUp = true

    func detect(pixelBuffer: CVPixelBuffer, orientation requested: CGImagePropertyOrientation, maxHands: Int, time: Double) -> [Hand2D] {
        guard let l = landmarker(max(1, min(2, maxHands))) else { return [] }
        let orientation: CGImagePropertyOrientation = feedUp ? .up : requested
        let uiOrient: UIImage.Orientation
        switch orientation {
        case .up: uiOrient = .up
        case .down: uiOrient = .down
        case .left: uiOrient = .left
        case .right: uiOrient = .right
        case .upMirrored: uiOrient = .upMirrored
        case .downMirrored: uiOrient = .downMirrored
        case .leftMirrored: uiOrient = .leftMirrored
        case .rightMirrored: uiOrient = .rightMirrored
        @unknown default: uiOrient = .up
        }
        guard let src = toBGRA(pixelBuffer) else { lastError = "BGRA"; return [] }
        let img: MPImage
        do { img = try MPImage(pixelBuffer: src, orientation: uiOrient) } catch { lastError = "MPImage: \(error)"; return [] }
        var ms = Int(time * 1000)
        if ms <= lastMs { ms = lastMs + 1 }
        lastMs = ms
        let r: HandLandmarkerResult
        do { r = try l.detect(videoFrame: img, timestampInMilliseconds: ms) } catch { lastError = "detect: \(error)"; return [] }
        var hands: [Hand2D] = []
        var raw: [String] = []
        defer { lastRawLabels = raw }
        for (k, lm) in r.landmarks.enumerated() where lm.count == HandJoint.count {
            let score = Float(r.handedness.indices.contains(k) ? (r.handedness[k].first?.score ?? 0.9) : 0.9)
            var points = [SIMD2<Float>](repeating: .zero, count: HandJoint.count)
            // Порядок 21 точки у MediaPipe совпадает с Vision (запястье, большой CMC…кончик, указательный…).
            for i in 0..<HandJoint.count {
                // Начало координат MediaPipe — сверху слева, у Vision — снизу слева.
                let p = CGPoint(x: CGFloat(lm[i].x), y: 1 - CGFloat(lm[i].y))
                points[i] = CoordinateMapper.visionToSensor(p, orientation: orientation)
            }
            // Метка MediaPipe берётся как есть. До 20.10 (вечер) она переворачивалась «наугад» (кадр без зеркала,
            // а MediaPipe будто бы ждёт селфи) — и это было неверно: в записях автора 508 из 524 кадров с двумя руками
            // перевёрнутая метка противоречила положению руки в кадре, а рисовала только его левая рука
            // (её метили «правой» = ведущей). Сверка с Vision на одном и том же буфере — бенч `-bench chir`.
            var ch = Chirality.unknown
            let cat = r.handedness.indices.contains(k) ? r.handedness[k].first?.categoryName : nil
            if let cat { ch = cat == "Left" ? .left : (cat == "Right" ? .right : .unknown) }
            raw.append(cat ?? "?")
            hands.append(Hand2D(points: points, conf: [Float](repeating: max(score, 0.6), count: HandJoint.count),
                                chirality: ch, goodCount: HandJoint.count))
        }
        return hands
    }
}
#endif
