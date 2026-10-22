import Foundation
import SwiftUI
import Combine
import os
import simd

/// Настройки режима, которые читает поток рендера (копия под замком).
struct SculptSnap {
    var active = false
    var brush: BrushKind = .plasticine
    var color: SIMD3<Float> = Palette.defaultColor(.plasticine)
    var thickness: Float = 1
    /// «Плавность»: радиус поводка, м (0 / 6 / 12 мм).
    var leash: Float = 0.006
    var mirror = false
    /// Отмена коротким щипком (любой руки).
    var undoGesture = false
}

enum SculptCommand { case undo, redo, clear, save }

enum SculptPanel: String { case color, width }

/// Счётчики для HUD (пишет рендер ~4 раза в секунду).
struct SculptStats: Equatable {
    var strokes = 0
    var triangles = 0
    var fullness: Float = 0
    var cpuMs: Float = 0
    var canUndo = false
    var canRedo = false
    var mode = "—"
}

/// Аргументы запуска режима: `-sculpt`, `-preset <id|имя>`, `-sculptdemo [all|bench|art|<траектория>]`, `-replay sculpt-<траектория>`.
struct SculptLaunch {
    var autoActive = false
    var preset: BrushKind?
    var demo: String?
    var replayTrajectory: String?
    var noisy = false

    static let current: SculptLaunch = {
        let a = ProcessInfo.processInfo.arguments
        var l = SculptLaunch()
        if a.contains("-sculpt") { l.autoActive = true }
        if let i = a.firstIndex(of: "-preset"), i + 1 < a.count { l.preset = BrushKind.parse(a[i + 1]) }
        if let i = a.firstIndex(of: "-sculptdemo") {
            l.demo = i + 1 < a.count && !a[i + 1].hasPrefix("-") ? a[i + 1] : "all"
            l.autoActive = true
        }
        if let i = a.firstIndex(of: "-replay"), i + 1 < a.count, a[i + 1].hasPrefix("sculpt-") {
            var name = String(a[i + 1].dropFirst("sculpt-".count))
            if name.hasSuffix("-noise") { name = String(name.dropLast("-noise".count)); l.noisy = true }
            l.replayTrajectory = name
            l.autoActive = true
        }
        return l
    }()
}

/// Состояние режима: SwiftUI-сторона (@Published) и копия для рендера под замком + очередь команд.
final class SculptState: ObservableObject {
    static let shared = SculptState()

    @Published var active = false { didSet { push() } }
    @Published var brush: BrushKind = .plasticine { didSet { push() } }
    @Published var color: SIMD3<Float> = Palette.defaultColor(.plasticine) { didSet { push() } }
    @Published var thickness: Float = 1 { didSet { push() } }
    @Published var leashMM: Int = 6 { didSet { push() } }
    @Published var mirror = false { didSet { push() } }
    @Published var undoGesture = false { didSet { push() } }

    @Published var stats = SculptStats()
    @Published var exported: [URL] = []
    @Published var toast: String?
    @Published var previews: [BrushKind: UIImage] = [:]
    /// Раскрытая капсула инструментов (только UI). `-uipanel color|width` — раскрыть при запуске (скриншоты).
    @Published var panel: SculptPanel? = {
        let a = ProcessInfo.processInfo.arguments
        guard let i = a.firstIndex(of: "-uipanel"), i + 1 < a.count else { return nil }
        return SculptPanel(rawValue: a[i + 1])
    }()

    private let lock = OSAllocatedUnfairLock<(SculptSnap, [SculptCommand])>(uncheckedState: (SculptSnap(), []))

    let launch = SculptLaunch.current

    private init() {
        if let p = launch.preset { brush = p; color = Palette.defaultColor(p) }
        if launch.autoActive { active = true }
        push()
    }

    /// Выбор кисти: цвет переключается на цвет кисти по умолчанию, если пользователь не выбирал свой.
    func select(_ k: BrushKind) {
        let wasDefault = color == Palette.defaultColor(brush)
        brush = k
        if wasDefault { color = Palette.defaultColor(k) }
    }

    private func push() {
        let s = SculptSnap(active: active, brush: brush, color: color, thickness: thickness,
                           leash: Float(leashMM) / 1000, mirror: mirror, undoGesture: undoGesture)
        lock.withLockUnchecked { $0.0 = s }
    }

    func send(_ c: SculptCommand) { lock.withLockUnchecked { $0.1.append(c) } }

    /// Поток рендера: текущие настройки и накопленные команды.
    func take() -> (SculptSnap, [SculptCommand]) {
        lock.withLockUnchecked { v in
            let r = v
            v.1.removeAll()
            return r
        }
    }

    /// Поток рендера → главный: обновить счётчики/тост.
    func publish(stats s: SculptStats) {
        DispatchQueue.main.async { if self.stats != s { self.stats = s } }
    }

    func showToast(_ s: String) {
        DispatchQueue.main.async {
            self.toast = s
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { if self.toast == s { self.toast = nil } }
        }
    }
}
