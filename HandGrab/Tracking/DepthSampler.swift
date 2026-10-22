import Foundation
import AVFoundation
import CoreVideo
import simd

/// Карта глубины (метры) + intrinsics, пересчитанные под её разрешение.
struct DepthMap {
    let buffer: CVPixelBuffer
    let width: Int
    let height: Int
    let fx: Float, fy: Float, cx: Float, cy: Float
    let time: Double
    let accuracy: AVDepthData.Accuracy
    let quality: AVDepthData.Quality
    let depthData: AVDepthData

    var hfovDegrees: Float { CoordinateMapper.horizontalFOVDegrees(fy: fy, height: Float(height)) }

    /// Собрать карту из AVDepthData. Диспаритет переводится в глубину Float32.
    /// videoIntrinsics — матрица из сэмпла видео (опорные размеры = размеры видео).
    static func make(from raw: AVDepthData, time: Double,
                     videoIntrinsics: matrix_float3x3?, videoSize: CGSize) -> DepthMap? {
        var data = raw
        let t = data.depthDataType
        if t == kCVPixelFormatType_DisparityFloat16 || t == kCVPixelFormatType_DisparityFloat32 {
            data = data.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
        }
        let dt = data.depthDataType
        guard dt == kCVPixelFormatType_DepthFloat16 || dt == kCVPixelFormatType_DepthFloat32 else { return nil }
        let buf = data.depthDataMap
        let w = CVPixelBufferGetWidth(buf), h = CVPixelBufferGetHeight(buf)
        var fx: Float, fy: Float, cx: Float, cy: Float
        if let cal = data.cameraCalibrationData {
            let m = cal.intrinsicMatrix
            let ref = cal.intrinsicMatrixReferenceDimensions
            let sx = Float(w) / Float(ref.width), sy = Float(h) / Float(ref.height)
            fx = m.columns.0.x * sx; fy = m.columns.1.y * sy
            cx = m.columns.2.x * sx; cy = m.columns.2.y * sy
        } else if let m = videoIntrinsics, videoSize.width > 0 {
            let sx = Float(w) / Float(videoSize.width), sy = Float(h) / Float(videoSize.height)
            fx = m.columns.0.x * sx; fy = m.columns.1.y * sy
            cx = m.columns.2.x * sx; cy = m.columns.2.y * sy
        } else {
            // Запасной вариант (версия): горизонтальный по сенсору FOV ≈ 70°.
            let f = Float(w) / (2 * tan(35 * Float.pi / 180))
            fx = f; fy = f; cx = Float(w) / 2; cy = Float(h) / 2
        }
        return DepthMap(buffer: buf, width: w, height: h, fx: fx, fy: fy, cx: cx, cy: cy,
                        time: time, accuracy: data.depthDataAccuracy, quality: data.depthDataQuality,
                        depthData: data)
    }
}

/// Чтение карты глубины. Буфер блокируется на время работы с ним (withLocked).
final class DepthSampler {
    let minZ: Float = 0.12
    let maxZ: Float = 1.2

    struct Accessor {
        let base: UnsafeRawPointer
        let rowBytes: Int
        let width: Int
        let height: Int
        let half: Bool

        @inline(__always) func raw(_ x: Int, _ y: Int) -> Float {
            let row = base.advanced(by: y * rowBytes)
            if half {
                return Float(row.assumingMemoryBound(to: Float16.self)[x])
            } else {
                return row.assumingMemoryBound(to: Float.self)[x]
            }
        }
    }

    func withLocked<T>(_ map: DepthMap, _ body: (Accessor) -> T) -> T? {
        let buf = map.buffer
        guard CVPixelBufferLockBaseAddress(buf, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buf, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buf) else { return nil }
        let acc = Accessor(base: UnsafeRawPointer(base), rowBytes: CVPixelBufferGetBytesPerRow(buf),
                           width: map.width, height: map.height,
                           half: CVPixelBufferGetPixelFormatType(buf) == kCVPixelFormatType_DepthFloat16)
        return body(acc)
    }

    /// Медиана валидных значений в окне (2r+1)×(2r+1) вокруг пикселя (u,v) карты глубины.
    func median(_ a: Accessor, u: Float, v: Float, radius: Int = 2) -> Float? {
        let cx = Int(u.rounded()), cy = Int(v.rounded())
        guard cx >= 0, cy >= 0, cx < a.width, cy < a.height else { return nil }
        var vals = [Float](); vals.reserveCapacity((2 * radius + 1) * (2 * radius + 1))
        let x0 = max(0, cx - radius), x1 = min(a.width - 1, cx + radius)
        let y0 = max(0, cy - radius), y1 = min(a.height - 1, cy + radius)
        for y in y0...y1 {
            for x in x0...x1 {
                let d = a.raw(x, y)
                if d.isFinite && d >= minZ && d <= maxZ { vals.append(d) }
            }
        }
        // Меньше трети окна валидно — край пальца, не доверяем.
        if vals.count < max(3, (x1 - x0 + 1) * (y1 - y0 + 1) / 3) { return nil }
        return medianOf(vals)
    }

    /// Доля невалидных пикселей (NaN, 0, отрицательные) в прямоугольнике (пиксели карты).
    func invalidFraction(_ a: Accessor, minX: Int, minY: Int, maxX: Int, maxY: Int, step: Int = 2) -> Float {
        let x0 = max(0, minX), x1 = min(a.width - 1, maxX)
        let y0 = max(0, minY), y1 = min(a.height - 1, maxY)
        guard x1 > x0, y1 > y0 else { return .nan }
        var bad = 0, total = 0
        var y = y0
        while y <= y1 {
            var x = x0
            while x <= x1 {
                let d = a.raw(x, y)
                if !d.isFinite || d <= 0 { bad += 1 }
                total += 1
                x += step
            }
            y += step
        }
        return total > 0 ? Float(bad) / Float(total) : .nan
    }
}
