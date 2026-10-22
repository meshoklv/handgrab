import Foundation
import AVFoundation
import simd
import os
import QuartzCore

struct TimedDepth {
    let data: AVDepthData
    let time: Double
}

/// Кадр видео + последние карты глубины.
struct CaptureFrame {
    let pixelBuffer: CVPixelBuffer
    /// Последние карты глубины (до 3, по возрастанию времени) — для точного сопоставления по времени.
    let depths: [TimedDepth]
    let captureHostTime: Double
    let videoIntrinsics: matrix_float3x3?
    let videoSize: CGSize
    var arrivalTime: Double = CACurrentMediaTime()
}

enum CaptureError: Error, LocalizedError {
    case noTrueDepth, noFormat, cannotAdd(String)
    var errorDescription: String? {
        switch self {
        case .noTrueDepth: return "Нет фронтальной камеры TrueDepth"
        case .noFormat: return "Нет видеоформата с глубиной"
        case .cannotAdd(let s): return "Не удалось добавить \(s)"
        }
    }
}

/// Захват TrueDepth: видео 420f + глубина, синхронизированные.
final class TrueDepthCapture: NSObject, AVCaptureDataOutputSynchronizerDelegate,
    AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureDepthDataOutputDelegate {
    let session = AVCaptureSession()
    private let videoOut = AVCaptureVideoDataOutput()
    private let depthOut = AVCaptureDepthDataOutput()
    private var sync: AVCaptureDataOutputSynchronizer?
    let queue = DispatchQueue(label: "capture", qos: .userInteractive)
    private(set) var device: AVCaptureDevice?
    private(set) var selection: FormatSelection?
    private var thermalObserver: NSObjectProtocol?
    private var throttled = false
    private var depthLowRes = true
    private var withDepth = true

    /// Кольцо последних карт глубины (синхронизатор пишет на очереди capture).
    private var syncRing: [TimedDepth] = []
    /// Для раздельного режима: глубина приходит на своей очереди.
    private let depthQueue = DispatchQueue(label: "depth", qos: .userInteractive)
    private struct DepthState { var ring: [TimedDepth] = []; var newCount = 0; var dropCount = 0 }
    private let depthLock = OSAllocatedUnfairLock<DepthState>(uncheckedState: DepthState())
    static let ringSize = 3
    private(set) var synchronized = false

    var onFrame: ((CaptureFrame) -> Void)?

    func configure(depthFiltering: Bool, useSynchronizer: Bool, depthLowRes: Bool = true, withDepth: Bool = true) throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .inputPriority

        guard let dev = AVCaptureDevice.default(.builtInTrueDepthCamera, for: .video, position: .front) else {
            throw CaptureError.noTrueDepth
        }
        device = dev
        let input = try AVCaptureDeviceInput(device: dev)
        guard session.canAddInput(input) else { throw CaptureError.cannotAdd("вход камеры") }
        session.addInput(input)

        videoOut.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        videoOut.alwaysDiscardsLateVideoFrames = true
        guard session.canAddOutput(videoOut) else { throw CaptureError.cannotAdd("видеовыход") }
        session.addOutput(videoOut)

        self.depthLowRes = depthLowRes
        self.withDepth = withDepth
        if withDepth {
            depthOut.isFilteringEnabled = depthFiltering
            depthOut.alwaysDiscardsLateDepthData = true
            guard session.canAddOutput(depthOut) else { throw CaptureError.cannotAdd("выход глубины") }
            session.addOutput(depthOut)
        }

        // Буферы в нативной ориентации сенсора: без поворота и зеркала, чтобы видео и глубина совпадали.
        if let c = videoOut.connection(with: .video) {
            if c.isVideoMirroringSupported { c.automaticallyAdjustsVideoMirroring = false; c.isVideoMirrored = false }
            if c.isCameraIntrinsicMatrixDeliverySupported { c.isCameraIntrinsicMatrixDeliveryEnabled = true }
        }
        if let c = depthOut.connection(with: .depthData) {
            c.isEnabled = true
            if c.isVideoMirroringSupported { c.automaticallyAdjustsVideoMirroring = false; c.isVideoMirrored = false }
        }

        guard let sel = FormatSelector.select(device: dev, depthLowRes: depthLowRes) else { throw CaptureError.noFormat }
        try apply(sel, to: dev)

        synchronized = useSynchronizer && withDepth
        if synchronized {
            let s = AVCaptureDataOutputSynchronizer(dataOutputs: [videoOut, depthOut])
            s.setDelegate(self, queue: queue)
            sync = s
        } else {
            videoOut.setSampleBufferDelegate(self, queue: queue)
            depthOut.setDelegate(self, callbackQueue: depthQueue)
        }

        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: nil) { [weak self] _ in
            self?.handleThermal()
        }
    }

    private func apply(_ sel: FormatSelection, to dev: AVCaptureDevice) throws {
        try dev.lockForConfiguration()
        dev.activeFormat = sel.format
        dev.activeDepthDataFormat = withDepth ? sel.depthFormat : nil
        dev.activeVideoMinFrameDuration = sel.videoMinDuration
        dev.activeVideoMaxFrameDuration = sel.videoMinDuration
        if withDepth { dev.activeDepthDataMinFrameDuration = sel.depthMinDuration }
        dev.unlockForConfiguration()
        selection = sel
        let accuracy = "?"
        Metrics.shared.updateInfo {
            $0.videoFormat = "\(sel.videoSize.width)×\(sel.videoSize.height)@\(Int(sel.videoFps.rounded()))"
            $0.depthFormat = "\(sel.depthSize.width)×\(sel.depthSize.height) \(fourCC(CMFormatDescriptionGetMediaSubType(sel.depthFormat.formatDescription)))"
            if $0.depthAccuracy == "—" { $0.depthAccuracy = accuracy }
        }
    }

    /// При перегреве (.serious и выше) — видео 30 fps; при остывании — обратно максимум.
    private func handleThermal() {
        let st = ProcessInfo.processInfo.thermalState
        let hot = st == .serious || st == .critical
        guard hot != throttled, let dev = device else { return }
        throttled = hot
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        if let sel = FormatSelector.select(device: dev, capFps: hot ? 30 : nil, depthLowRes: depthLowRes) {
            try? apply(sel, to: dev)
        }
    }

    func setDepthFiltering(_ on: Bool) {
        queue.async { [weak self] in self?.depthOut.isFilteringEnabled = on }
    }

    func start() {
        queue.async { [weak self] in
            guard let self, !self.session.isRunning else { return }
            self.session.startRunning()
        }
    }

    func stop() {
        queue.async { [weak self] in self?.session.stopRunning() }
    }

    private func hostTime(_ pts: CMTime) -> Double {
        if let clock = session.synchronizationClock {
            let t = CMSyncConvertTime(pts, from: clock, to: CMClockGetHostTimeClock())
            return CMTimeGetSeconds(t)
        }
        return CMTimeGetSeconds(pts)
    }

    // MARK: AVCaptureDataOutputSynchronizerDelegate

    func dataOutputSynchronizer(_ synchronizer: AVCaptureDataOutputSynchronizer,
                                didOutput collection: AVCaptureSynchronizedDataCollection) {
        guard let v = collection.synchronizedData(for: videoOut) as? AVCaptureSynchronizedSampleBufferData,
              !v.sampleBufferWasDropped,
              let pb = CMSampleBufferGetImageBuffer(v.sampleBuffer) else { return }
        let t = hostTime(CMSampleBufferGetPresentationTimeStamp(v.sampleBuffer))

        var delivered = false, dropped = false
        if let d = collection.synchronizedData(for: depthOut) as? AVCaptureSynchronizedDepthData {
            if d.depthDataWasDropped {
                dropped = true
            } else {
                syncRing.append(TimedDepth(data: d.depthData, time: hostTime(d.timestamp)))
                if syncRing.count > Self.ringSize { syncRing.removeFirst() }
                delivered = true
            }
        }
        Metrics.shared.camFrame(depthDelivered: delivered, depthDropped: dropped)

        var intr: matrix_float3x3?
        if let data = CMGetAttachment(v.sampleBuffer, key: kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix,
                                      attachmentModeOut: nil) as? Data, data.count >= MemoryLayout<matrix_float3x3>.size {
            intr = data.withUnsafeBytes { $0.loadUnaligned(as: matrix_float3x3.self) }
        }
        let frame = CaptureFrame(pixelBuffer: pb, depths: syncRing,
                                 captureHostTime: t, videoIntrinsics: intr,
                                 videoSize: CGSize(width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb)))
        onFrame?(frame)
    }

    // MARK: Раздельные выходы

    func depthDataOutput(_ output: AVCaptureDepthDataOutput, didOutput depthData: AVDepthData,
                         timestamp: CMTime, connection: AVCaptureConnection) {
        let t = hostTime(timestamp)
        depthLock.withLockUnchecked { s in
            s.ring.append(TimedDepth(data: depthData, time: t))
            if s.ring.count > Self.ringSize { s.ring.removeFirst() }
            s.newCount += 1
        }
    }

    func depthDataOutput(_ output: AVCaptureDepthDataOutput, didDrop depthData: AVDepthData,
                         timestamp: CMTime, connection: AVCaptureConnection, reason: AVCaptureOutput.DataDroppedReason) {
        depthLock.withLockUnchecked { $0.dropCount += 1 }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let t = hostTime(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        let (ring, newCount, dropCount) = depthLock.withLockUnchecked { s -> ([TimedDepth], Int, Int) in
            let r = (s.ring, s.newCount, s.dropCount); s.newCount = 0; s.dropCount = 0; return r
        }
        Metrics.shared.camFrame(depthDelivered: newCount > 0, depthDropped: dropCount > 0)
        var intr: matrix_float3x3?
        if let data = CMGetAttachment(sampleBuffer, key: kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix,
                                      attachmentModeOut: nil) as? Data, data.count >= MemoryLayout<matrix_float3x3>.size {
            intr = data.withUnsafeBytes { $0.loadUnaligned(as: matrix_float3x3.self) }
        }
        // Глубина (30 Гц) приходит позже видео (60 Гц): конвейер сам сопоставит карту с кадром по времени.
        onFrame?(CaptureFrame(pixelBuffer: pb, depths: ring, captureHostTime: t,
                              videoIntrinsics: intr,
                              videoSize: CGSize(width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb))))
    }
}
