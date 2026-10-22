import Foundation
import UIKit
import SceneKit
import os

/// Телеметрия для удалённой проверки без экрана: строка HUD каждые 2 с в Documents/hud.log
/// и снимок сцены каждые 5 с в Documents/snap.jpg. Забирать: devicectl device copy from …
final class Telemetry {
    static let shared = Telemetry()
    weak var sceneView: SCNView?
    private var timer: Timer?
    private var tick = 0
    private let io = DispatchQueue(label: "telemetry", qos: .utility)
    private var lines: [String] = []
    /// Последний кадр превью (селфи-ориентация с точками) — пишется в cam.jpg для удалённой проверки осей.
    let lastPreview = OSAllocatedUnfairLock<CGImage?>(uncheckedState: nil)

    /// Идёт реплей (камера выключена) — помечается в hud.log.
    var replayMode = false

    /// Снимок сцены в Documents/<name>.jpg (главный поток).
    func saveSnapshot(name: String) {
        guard let v = sceneView else { return }
        let img = v.snapshot()
        let url = docs.appendingPathComponent(name + ".jpg")
        io.async { try? img.jpegData(compressionQuality: 0.75)?.write(to: url, options: .atomic) }
        EventLog.shared.write("SNAP \(name)")
    }

    private var docs: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.fire() }
    }

    private func fire() {
        tick += 1
        // Единственное место, где снимаются счётчики (HUD-виды читают lastHUD).
        let h = Metrics.shared.snapshot()
        let i = h.info
        let cfg = ConfigStore.shared.snapshot
        if tick % 4 == 0 {
            let line = String(format: "%@ render=%.0f cam=%.0f depth=%.0f vision=%.0f %.1f/%.1fms skip=%.0f%% lat=%.1f/%.1fms [доставка %.1f очередь %.1f готово %.1f] pred=%.0f cpu=%.0f%% det=%@ hands=%d conf=%.2f palm=%.1fcm fresh=%@ s=%.1fcm %@ d=%.2f fist=%.2f depthDrop=%.0f%% palmHole=%.0f%% depthAge=%.0fms acc=%@ hfov=%.1f therm=%@ mirror=%@ par=%@ replay=%@",
                              ISO8601DateFormatter().string(from: Date()), h.renderFps, h.camFps, h.depthFps, h.visionFps,
                              h.visionMean, h.visionP95, h.visionSkipPct, h.latMean, h.latP95, h.deliverMs, h.waitMs, h.doneMs,
                              i.predictionMs, h.cpuPct, i.detector, i.hands, i.meanConf, i.palmCm, i.depthFresh ? "да" : "нет", i.scaleCm,
                              i.pinch, i.pinchD, i.fistD, h.depthDropPct, h.palmHolePct, h.depthAgeMs,
                              i.depthAccuracy, i.hfov, h.thermal,
                              cfg.mirrorView ? "да" : "нет", cfg.parallelVision ? "да" : "нет", replayMode ? "да" : "нет")
            lines.append(line)
            if lines.count > 600 { lines.removeFirst(lines.count - 600) }
            let text = lines.joined(separator: "\n") + "\n"
            let url = docs.appendingPathComponent("hud.log")
            io.async { try? text.data(using: .utf8)?.write(to: url, options: .atomic) }
        }
        if tick % 30 == 0, !replayMode, let v = sceneView {  // snapshot() рендерит на главном потоке — редко, чтобы не было рывков
            let img = v.snapshot()
            let url = docs.appendingPathComponent("snap.jpg")
            io.async { try? img.jpegData(compressionQuality: 0.6)?.write(to: url, options: .atomic) }
            if let cg = lastPreview.withLockUnchecked({ $0 }) {
                let camURL = docs.appendingPathComponent("cam.jpg")
                io.async { try? UIImage(cgImage: cg).jpegData(compressionQuality: 0.7)?.write(to: camURL, options: .atomic) }
            }
        }
    }
}
