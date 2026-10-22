import SwiftUI
import AVFoundation
import Combine
import os

@main
struct HandGrabApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .environmentObject(ConfigStore.shared)
                .statusBarHidden(true)
                .persistentSystemOverlays(.hidden)
        }
    }
}

/// Режим запуска по аргументам: `-replay synth|<файл.jsonl> [-loop]`, `-bench`.
enum LaunchMode {
    case live
    case replay(String, loop: Bool)
    case bench(Set<String>)
    case trackeval([String])

    static let current: LaunchMode = {
        let a = ProcessInfo.processInfo.arguments
        if let i = a.firstIndex(of: "-trackeval") {
            return .trackeval(a[(i + 1)...].prefix { !$0.hasPrefix("-") }.map { String($0) })
        }
        if a.contains("-sculptdemo") { return .replay("sculptdemo", loop: false) }   // режим «Скульпт» без трекинга
        if let i = a.firstIndex(of: "-replay") {
            return .replay(i + 1 < a.count ? a[i + 1] : "synth", loop: a.contains("-loop"))
        }
        if let i = a.firstIndex(of: "-bench") {
            let all: Set<String> = ["vision", "mp", "cam", "live", "chir"]
            if i + 1 < a.count, all.contains(a[i + 1]) { return .bench([a[i + 1]]) }
            return .bench(all)
        }
        return .live
    }()
}

/// Связывает захват, конвейер и UI.
final class AppModel: ObservableObject {
    let capture = TrueDepthCapture()
    let pipeline = TrackingPipeline()
    @Published var status: String = ""
    @Published var statusIsError = false
    @Published var calibrating = false
    @Published var lastCalibration: String?
    private let resetFlag = OSAllocatedUnfairLock(initialState: false)
    private var cancellables = Set<AnyCancellable>()
    private var started = false
    private var replay: ReplayRunner?
    private var bench: BenchRunner?
    private var eval: TrackEval?

    init() {
        capture.onFrame = { [weak self] f in self?.pipeline.handle(f) }
        pipeline.onCalibrated = { [weak self] bones, scale, dist in
            guard let self else { return }
            var c = ConfigStore.shared.config
            c.boneLengths = bones
            c.calibratedScale = scale
            c.zCenter = dist
            ConfigStore.shared.config = c
            self.calibrating = false
            self.lastCalibration = String(format: "s = %.1f см, дистанция %.0f см", scale * 100, dist * 100)
        }
        ConfigStore.shared.$config
            .map(\.appleDepthFilter)
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] on in self?.capture.setDepthFiltering(on) }
            .store(in: &cancellables)
    }

    func start() {
        guard !started else { return }
        started = true
        UIApplication.shared.isIdleTimerDisabled = true
        // Замер A/B без касания экрана: -shadows включает старые динамические тени, -handmodel — кисть.
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-shadows") || args.contains("-handmodel") {
            var c = ConfigStore.shared.config
            if args.contains("-shadows") { c.dynamicShadows = true }
            if args.contains("-handmodel") { c.showHandModel = true }
            ConfigStore.shared.config = c
        }
        // Нагрузка распознавателем поверх любого режима (замер «рендер + распознавание» без человека): -detload gpu|cpu|vision
        if let i = args.firstIndex(of: "-detload") {
            let k = i + 1 < args.count ? args[i + 1] : "gpu"
            DetLoad.shared.start(kind: k == "cpu" ? 2 : k == "vision" ? 0 : 1)
        }
        switch LaunchMode.current {
        case .replay(let name, let loop):
            startReplay(name, loop: loop)
        case .bench(let sections):
            let b = BenchRunner()
            bench = b
            b.run(sections: sections)
        case .trackeval(let names):
            Telemetry.shared.replayMode = true
            let dir = SessionRecorder.dir
            let list = names.isEmpty
                ? ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".jsonl") }.sorted()
                : names
            let e = TrackEval()
            eval = e
            e.run(files: list.map { dir.appendingPathComponent($0) })
        case .live:
            startCamera()
        }
    }

    private func startReplay(_ name: String, loop: Bool) {
        Telemetry.shared.replayMode = true
        let src: ReplaySource?
        if name == "sculptdemo" { return }
        if name.hasPrefix("sculpt-") {
            let l = SculptState.shared.launch
            src = SculptReplay(name: l.replayTrajectory ?? "", config: ConfigStore.shared.snapshot, noisy: l.noisy, preset: SculptState.shared.brush)
        } else if name == "synth" || name == "synthnoise" {
            var s = SyntheticReplay(config: ConfigStore.shared.snapshot)
            s.noisy = name == "synthnoise"
            src = s
        } else {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let candidates = [SessionRecorder.dir.appendingPathComponent(name), docs.appendingPathComponent(name),
                              Bundle.main.url(forResource: name, withExtension: nil)].compactMap { $0 }
            src = candidates.lazy.compactMap { FileReplay(url: $0) }.first
        }
        guard let src else {
            status = "Реплей: не найден \(name)"; statusIsError = true
            EventLog.shared.write("REPLAY NOT FOUND \(name)")
            return
        }
        let r = ReplayRunner(pipeline: pipeline, source: src, loop: loop)
        replay = r
        r.start()
    }

    private func startCamera() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] ok in
            guard let self else { return }
            guard ok else {
                DispatchQueue.main.async { self.status = "Нет доступа к камере — включи в Настройках"; self.statusIsError = true }
                return
            }
            self.capture.queue.async {
                do {
                    let cfg = ConfigStore.shared.snapshot
                    try self.capture.configure(depthFiltering: cfg.appleDepthFilter,
                                               useSynchronizer: cfg.useSynchronizer, depthLowRes: cfg.depthLowRes)
                    if let d = self.capture.device {
                        DeviceProbe.shared.dumpFormats(device: d, selection: self.capture.selection)
                    }
                    self.capture.session.startRunning()
                    let s = (self.capture.selection?.summary ?? "") + (self.capture.synchronized ? " · синхронизатор" : " · раздельно")
                    EventLog.shared.write("CAMERA \(s)")
                } catch {
                    DispatchQueue.main.async { self.status = "Ошибка камеры: \(error.localizedDescription)"; self.statusIsError = true }
                }
            }
        }
    }

    func requestReset() { resetFlag.withLock { $0 = true } }
    func consumeResetRequest() -> Bool { resetFlag.withLock { v in let r = v; v = false; return r } }

    func startCalibration() {
        calibrating = true
        // Сбросить старую калибровку длин, чтобы мерить «сырые» кости.
        var c = ConfigStore.shared.config
        c.calibratedScale = nil
        ConfigStore.shared.config = c
        pipeline.requestCalibration()
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self, self.calibrating else { return }
            self.calibrating = false
            self.lastCalibration = "Калибровка не удалась: руку не видно"
        }
    }

    func clearCalibration() {
        var c = ConfigStore.shared.config
        c.boneLengths = nil
        c.calibratedScale = nil
        c.zCenter = 0.35
        ConfigStore.shared.config = c
        lastCalibration = "Калибровка сброшена"
    }
}
