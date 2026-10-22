import Foundation
import AVFoundation

/// Выбор видео- и depth-формата TrueDepth.
/// Приоритет: 1) макс. fps видео, у которого есть depth-формат; 2) видео ширины ≥ 640, чем меньше — тем лучше;
/// 3) глубина DepthFloat16 макс. разрешения, иначе DepthFloat32, иначе диспаритет (переводится в глубину).
struct FormatSelection {
    let format: AVCaptureDevice.Format
    let depthFormat: AVCaptureDevice.Format
    let videoFps: Double
    let videoMinDuration: CMTime
    let depthMinDuration: CMTime
    let videoSize: CMVideoDimensions
    let depthSize: CMVideoDimensions

    var summary: String {
        let dt = CMFormatDescriptionGetMediaSubType(depthFormat.formatDescription)
        return "видео \(videoSize.width)×\(videoSize.height)@\(Int(videoFps.rounded())) " +
            "глубина \(depthSize.width)×\(depthSize.height) \(fourCC(dt)) " +
            "@\(Int((1 / max(CMTimeGetSeconds(depthMinDuration), 1e-3)).rounded()))"
    }
}

func fourCC(_ c: FourCharCode) -> String {
    let b = [UInt8((c >> 24) & 0xff), UInt8((c >> 16) & 0xff), UInt8((c >> 8) & 0xff), UInt8(c & 0xff)]
    return String(bytes: b, encoding: .ascii) ?? "\(c)"
}

enum FormatSelector {
    static func depthRank(_ f: AVCaptureDevice.Format) -> Int {
        switch CMFormatDescriptionGetMediaSubType(f.formatDescription) {
        case kCVPixelFormatType_DepthFloat16: return 4
        case kCVPixelFormatType_DepthFloat32: return 3
        case kCVPixelFormatType_DisparityFloat16: return 2
        case kCVPixelFormatType_DisparityFloat32: return 1
        default: return 0
        }
    }

    static func maxFps(_ f: AVCaptureDevice.Format) -> Double {
        f.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
    }

    static func minDuration(_ f: AVCaptureDevice.Format) -> CMTime {
        let ranges = f.videoSupportedFrameRateRanges
        guard let best = ranges.max(by: { $0.maxFrameRate < $1.maxFrameRate }) else { return CMTime(value: 1, timescale: 30) }
        return best.minFrameDuration
    }

    static func select(device: AVCaptureDevice, capFps: Double? = nil, depthLowRes: Bool = false) -> FormatSelection? {
        var best: (AVCaptureDevice.Format, AVCaptureDevice.Format, Double, Int32)?
        for f in device.formats {
            let sub = CMFormatDescriptionGetMediaSubType(f.formatDescription)
            guard sub == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange else { continue }
            let dims = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            guard dims.width >= 640 else { continue }
            let depths = f.supportedDepthDataFormats.filter { depthRank($0) > 0 }
            guard let depth = depths.max(by: { a, b in
                let ra = depthRank(a), rb = depthRank(b)
                if ra != rb { return ra < rb }
                let da = CMVideoFormatDescriptionGetDimensions(a.formatDescription)
                let db = CMVideoFormatDescriptionGetDimensions(b.formatDescription)
                let aa = Int(da.width) * Int(da.height), ab = Int(db.width) * Int(db.height)
                return depthLowRes ? aa > ab : aa < ab
            }) else { continue }
            var fps = maxFps(f)
            if let cap = capFps { fps = min(fps, cap) }
            let area = dims.width * dims.height
            if let b = best {
                if fps > b.2 + 0.5 || (abs(fps - b.2) <= 0.5 && area < b.3) {
                    best = (f, depth, fps, area)
                }
            } else {
                best = (f, depth, fps, area)
            }
        }
        guard let (f, depth, fps, _) = best else { return nil }
        var vMin = minDuration(f)
        if let cap = capFps, 1 / CMTimeGetSeconds(vMin) > cap + 0.5 {
            vMin = CMTime(value: 1, timescale: CMTimeScale(cap))
        }
        var dMin = minDuration(depth)
        if CMTimeCompare(dMin, vMin) < 0 { dMin = vMin }
        return FormatSelection(format: f, depthFormat: depth, videoFps: fps,
                               videoMinDuration: vMin, depthMinDuration: dMin,
                               videoSize: CMVideoFormatDescriptionGetDimensions(f.formatDescription),
                               depthSize: CMVideoFormatDescriptionGetDimensions(depth.formatDescription))
    }
}
