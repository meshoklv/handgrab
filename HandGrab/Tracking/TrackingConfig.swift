import Foundation
import Combine
import os

/// Все параметры трекинга. Стартовые значения — версия, подбираются на руке.
struct TrackingConfig: Codable, Equatable {
    // Захват
    var appleDepthFilter: Bool = false
    /// true = AVCaptureDataOutputSynchronizer (ждёт глубину 30 Гц), false = раздельные выходы.
    /// Применяется при запуске.
    var useSynchronizer: Bool = false
    /// Глубина 160×120 вместо 640×480: нужна только глубина ладони, меньше работы камере (после перезапуска).
    var depthLowRes: Bool = false   // бенч 20.10: доставка кадра 640 → 34.8 мс, 160 → 38.4 мс — выигрыша нет
    var maxHands: Int = 2
    /// Два параллельных распознавателя (больше кадров в секунду, но вдвое больше нагрев).
    var parallelVision: Bool = false
    /// Распознаватель: 0 = Vision, 1 = MediaPipe GPU (по умолчанию, бенч 20.10: 3–9 мс против 9–13 у Vision), 2 = MediaPipe CPU.
    var detector: Int = 1
    /// Устройство Vision: 0 = авто, 1 = нейроядро, 2 = GPU, 3 = CPU.
    var visionDevice: Int = 0
    /// Ориентация, которую получает Vision (CGImagePropertyOrientation.rawValue).
    /// 6 = right: портрет без зеркала, тогда «левая/правая» у Vision совпадает с настоящей рукой.
    var visionOrientation: UInt32 = 6
    /// Поворот осей сенсора на 180° (если рука на экране «вверх ногами»).
    var rotate180: Bool = false
    /// false = вид от первого лица (рука как своя, правая справа), true = как в зеркале.
    var mirrorView: Bool = false
    var swapChirality: Bool = false

    // Предсказание и плавность
    var predictionEnabled: Bool = true
    var manualPrediction: Bool = false
    var predictionMs: Float = 40
    /// Постоянная времени сглаживания позы на 120 Гц между кадрами распознавания, мс.
    var displaySmoothMs: Float = 18

    // Сглаживание: 2D-точки (нормированные единицы кадра) и жёсткая модель
    var jointMinCutoff: Float = 1.6
    var jointBeta: Float = 4
    var dCutoff: Float = 1.0
    /// Сглаживание положения ладони в сцене (One-Euro, м).
    var wristMinCutoff: Float = 2.0
    var wristBeta: Float = 8
    /// Сглаживание дистанции ладони до телефона (One-Euro, м; 0 — выкл.). Глубина TrueDepth шумит сильнее кадра,
    /// а рабочий объём растягивает её ×1,5 — по записям автора это вторая по величине дрожь кисти.
    var depthMinCutoff: Float = 0.5
    var depthBeta: Float = 2
    /// Точка рисования — по плоской модели (кончики в кадре на глубине ладони), а не по 3D-пальцам жёсткой модели.
    var stablePinchPoint: Bool = true

    // Жесты
    var pinchOn: Float = 0.35
    var pinchOff: Float = 0.55
    var fistOn: Float = 0.62
    var fistOff: Float = 0.85
    /// Магнит: при щипке/кулаке берётся ближайший объект в этом радиусе от поверхности, м.
    var magnetRadius: Float = 0.10

    // Рабочий объём: кадр камеры и дистанция ±zSpan вокруг ладони → весь стол
    /// Доля кадра по горизонтали (по экрану), которая растягивается на ширину стола.
    var wsXMin: Float = 0.15
    var wsXMax: Float = 0.85
    /// Доля кадра по вертикали: верх → рука высоко над столом, низ → рука у стола.
    var wsYTop: Float = 0.20
    var wsYBottom: Float = 0.75
    /// Ход руки к телефону/от телефона (± м от точки появления), который растягивается на глубину стола.
    var zSpan: Float = 0.15
    /// Размер виртуальной руки относительно настоящей.
    var handScale: Float = 1.0
    /// Наклон руки вперёд (пальцы к столу), градусы.
    var handTilt: Float = 70

    /// Опорная дистанция ладони до телефона, м (из калибровки; запасная, если нет глубины).
    var zCenter: Float = 0.35

    // Сцена
    var handColliders: Bool = false
    var showPreview: Bool = false
    /// Модель кисти (по умолчанию выключена — вместо неё 3D-курсор).
    var showHandModel: Bool = false
    /// Динамические тени солнца (дорого: 54 fps на телефоне). По умолчанию — запечённые пятна.
    var dynamicShadows: Bool = false
    /// Записывать сессию (21 точка + глубина ладони по времени) в Documents/sessions для реплея.
    var recordSession: Bool = true

    // Калибровка
    var boneLengths: [Float]? = nil
    var calibratedScale: Float? = nil
}

/// Хранилище конфигурации: UI работает с @Published, горячий путь читает снимок под замком.
final class ConfigStore: ObservableObject {
    static let shared = ConfigStore()
    private static let key = "TrackingConfig.v4"

    @Published var config: TrackingConfig {
        didSet {
            let c = config
            lock.withLockUnchecked { $0 = c }
            save()
        }
    }

    private let lock: OSAllocatedUnfairLock<TrackingConfig>

    var snapshot: TrackingConfig { lock.withLockUnchecked { $0 } }

    private init() {
        let c = ConfigStore.load()
        lock = OSAllocatedUnfairLock(uncheckedState: c)
        config = c
    }

    func resetToDefaults() { config = TrackingConfig() }

    private func save() {
        if let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: ConfigStore.key)
        }
    }

    private static func load() -> TrackingConfig {
        guard let data = UserDefaults.standard.data(forKey: key) else { return TrackingConfig() }
        if let c = try? JSONDecoder().decode(TrackingConfig.self, from: data) { return c }
        // Новые поля в версии приложения: накрыть умолчания сохранёнными ключами.
        guard let defData = try? JSONEncoder().encode(TrackingConfig()),
              var base = (try? JSONSerialization.jsonObject(with: defData)) as? [String: Any],
              let saved = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return TrackingConfig() }
        for (k, v) in saved where base[k] != nil { base[k] = v }
        guard let merged = try? JSONSerialization.data(withJSONObject: base),
              let c = try? JSONDecoder().decode(TrackingConfig.self, from: merged) else { return TrackingConfig() }
        return c
    }
}
