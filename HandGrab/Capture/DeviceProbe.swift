import Foundation
import AVFoundation
import os

/// Зонд устройства: все форматы TrueDepth + живые замеры. Пишет в os_log и Documents/probe.txt.
/// Забрать файл: «Файлы» → На iPhone → HandGrab, или
/// `xcrun devicectl device copy from --device <id> --domain-type appDataContainer --domain-identifier <your bundle id> --source Documents/probe.txt --destination probe.txt`.
final class DeviceProbe {
    static let shared = DeviceProbe()
    private let log = Logger(subsystem: "com.example.handgrab", category: "probe")
    private let lock = OSAllocatedUnfairLock<[String]>(uncheckedState: [])

    var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("probe.txt")
    }

    var text: String { lock.withLockUnchecked { $0.joined(separator: "\n") } }

    private func emit(_ s: String) {
        log.log("\(s, privacy: .public)")
        lock.withLockUnchecked { $0.append(s) }
    }

    private func flush() {
        let t = text + "\n"
        try? t.data(using: .utf8)?.write(to: fileURL, options: .atomic)
    }

    static func describe(_ r: [AVFrameRateRange]) -> String {
        r.map { String(format: "%.0f–%.0f", $0.minFrameRate, $0.maxFrameRate) }.joined(separator: ",")
    }

    /// Перечень всех форматов. Вызывать после конфигурации сессии.
    func dumpFormats(device: AVCaptureDevice, selection: FormatSelection?) {
        let df = ISO8601DateFormatter()
        emit("=== HandGrab probe \(df.string(from: Date())) ===")
        emit("device: \(device.localizedName) type=\(device.deviceType.rawValue) model=\(modelIdentifier()) iOS=\(UIDeviceSystemVersion())")
        for (i, f) in device.formats.enumerated() {
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            let sub = fourCC(CMFormatDescriptionGetMediaSubType(f.formatDescription))
            var line = "[\(i)] \(sub) \(d.width)×\(d.height) fps \(DeviceProbe.describe(f.videoSupportedFrameRateRanges)) fov \(String(format: "%.1f", f.videoFieldOfView))°"
            if f.isVideoBinned { line += " binned" }
            emit(line)
            for df in f.supportedDepthDataFormats {
                let dd = CMVideoFormatDescriptionGetDimensions(df.formatDescription)
                let ds = fourCC(CMFormatDescriptionGetMediaSubType(df.formatDescription))
                emit("     depth \(ds) \(dd.width)×\(dd.height) fps \(DeviceProbe.describe(df.videoSupportedFrameRateRanges))")
            }
        }
        emit("active: \(selection?.summary ?? "нет")")
        let a = device.activeFormat
        let ad = CMVideoFormatDescriptionGetDimensions(a.formatDescription)
        emit("activeFormat \(ad.width)×\(ad.height) min dur \(CMTimeGetSeconds(device.activeVideoMinFrameDuration)) " +
             "depth min dur \(CMTimeGetSeconds(device.activeDepthDataMinFrameDuration))")
        flush()
    }

    /// Живой замер: дистанция вводится рукой (кнопки 15/20/30/50/70 см).
    func recordSample(label: String, hud: Metrics.HUDData) {
        let i = hud.info
        emit(String(format: "sample[%@] palm=%.1fсм fresh=%@ palmHole=%.0f%% depthDrop=%.0f%% depthAge=%.0fмс acc=%@ q=%@ cam=%.0f depth=%.0f vision=%.0f(%.1f/%.1fмс) render=%.0f lat=%.1f/%.1fмс drop=%.0f%% hfov=%.1f",
                    label, i.palmCm, i.depthFresh ? "да" : "нет", hud.palmHolePct, hud.depthDropPct, hud.depthAgeMs,
                    i.depthAccuracy, i.depthQuality, hud.camFps, hud.depthFps, hud.visionFps,
                    hud.visionMean, hud.visionP95, hud.renderFps, hud.latMean, hud.latP95, hud.depthDropPct, i.hfov))
        flush()
    }

    private func modelIdentifier() -> String {
        var sys = utsname()
        uname(&sys)
        return withUnsafeBytes(of: &sys.machine) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }
}

import UIKit
private func UIDeviceSystemVersion() -> String {
    // UIDevice — главный поток; зонд вызывается с очереди захвата, версия ОС от ProcessInfo достаточна.
    let v = ProcessInfo.processInfo.operatingSystemVersion
    return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
}
