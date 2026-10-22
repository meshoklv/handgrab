import SwiftUI

/// Оверлей калибровки (2 с раскрытой ладони).
struct CalibrationView: View {
    @State private var progress: Double = 0
    private let timer = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "hand.raised.fill").font(.system(size: 44))
            Text("Держи раскрытую ладонь\nна удобной дистанции").multilineTextAlignment(.center).font(.headline)
            ProgressView(value: min(progress, 1)).frame(width: 180)
        }
        .padding(24)
        .glass(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .onReceive(timer) { _ in progress += 0.05 / 2.0 }
    }
}

/// Отладочные переключатели. Всё хранится в TrackingConfig → UserDefaults.
struct DebugSettingsView: View {
    @EnvironmentObject var store: ConfigStore
    @EnvironmentObject var model: AppModel
    @AppStorage("hg.showStats") private var showStats = false

    private func row(_ title: String, _ value: Binding<Float>, _ range: ClosedRange<Float>, _ fmt: String = "%.2f") -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack { Text(title); Spacer(); Text(String(format: fmt, value.wrappedValue)).monospacedDigit() }
            Slider(value: value, in: range)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HUDView().listRowInsets(EdgeInsets()).listRowBackground(Color.black)
                    Toggle("Строка fps на экране", isOn: $showStats)
                    HStack {
                        Button("Калибровать ладонь") { model.startCalibration() }
                        Spacer()
                        NavigationLink("Зонд") { ProbeView() }
                    }
                }
                Section("Распознавание (после перезапуска приложения)") {
                    Picker("Распознаватель", selection: $store.config.detector) {
                        Text("Vision").tag(0)
                        if HandDetectorFactory.mediaPipeAvailable {
                            Text("MediaPipe GPU").tag(1); Text("MediaPipe CPU").tag(2)
                        }
                    }
                    Picker("Vision на", selection: $store.config.visionDevice) {
                        Text("авто").tag(0); Text("ANE").tag(1); Text("GPU").tag(2); Text("CPU").tag(3)
                    }.pickerStyle(.segmented)
                    Picker("Рук максимум", selection: $store.config.maxHands) {
                        Text("1").tag(1); Text("2").tag(2)
                    }.pickerStyle(.segmented)
                    Toggle("Два распознавателя параллельно (греет)", isOn: $store.config.parallelVision)
                    Toggle("Глубина 160×120", isOn: $store.config.depthLowRes)
                    Toggle("Фильтр глубины Apple", isOn: $store.config.appleDepthFilter)
                    Toggle("Синхронизатор", isOn: $store.config.useSynchronizer)
                    Toggle("Превью RGB/глубины", isOn: $store.config.showPreview)
                    Toggle("Записывать сессию для реплея", isOn: $store.config.recordSession)
                }
                Section("Плавность") {
                    Toggle("Предсказание", isOn: $store.config.predictionEnabled)
                    Toggle("T вручную", isOn: $store.config.manualPrediction)
                    row("T, мс", $store.config.predictionMs, 0...100, "%.0f")
                    row("Сглаживание на экране, мс", $store.config.displaySmoothMs, 0...60, "%.0f")
                }
                Section("Рабочий объём") {
                    Toggle("Показывать модель кисти", isOn: $store.config.showHandModel)
                    Toggle("Динамические тени (дорого)", isOn: $store.config.dynamicShadows)
                    Toggle("Зеркало (рука как в зеркале)", isOn: $store.config.mirrorView)
                    row("Размер руки ×", $store.config.handScale, 0.8...2.5)
                    row("Наклон руки, °", $store.config.handTilt, 0...70, "%.0f")
                    row("Ход к телефону ±, см", Binding(get: { store.config.zSpan * 100 },
                                                        set: { store.config.zSpan = $0 / 100 }), 5...30, "%.0f")
                    row("Кадр слева", $store.config.wsXMin, 0...0.45)
                    row("Кадр справа", $store.config.wsXMax, 0.55...1)
                    row("Кадр верх", $store.config.wsYTop, 0...0.45)
                    row("Кадр низ (у стола)", $store.config.wsYBottom, 0.55...1)
                    row("Магнит захвата, см", Binding(get: { store.config.magnetRadius * 100 },
                                                      set: { store.config.magnetRadius = $0 / 100 }), 2...20, "%.0f")
                }
                Section("Сглаживание") {
                    row("Точки mincutoff", $store.config.jointMinCutoff, 0.1...6)
                    row("Точки beta", $store.config.jointBeta, 0...20, "%.1f")
                    row("Запястье mincutoff", $store.config.wristMinCutoff, 0.1...6)
                    row("Запястье beta", $store.config.wristBeta, 0...40, "%.1f")
                }
                Section("Жесты") {
                    row("Щипок вкл <", $store.config.pinchOn, 0.05...0.6)
                    row("Щипок выкл >", $store.config.pinchOff, 0.1...0.9)
                    row("Кулак вкл <", $store.config.fistOn, 0.4...1.5)
                    row("Кулак выкл >", $store.config.fistOff, 0.6...2.0)
                }
                Section("Глубина") {
                    row("Центр Z (запасной), м", $store.config.zCenter, 0.15...0.8)
                }
                Section("Оси (если руки не совпадают)") {
                    Picker("Ориентация Vision", selection: $store.config.visionOrientation) {
                        Text("up").tag(UInt32(1)); Text("upMirrored").tag(UInt32(2))
                        Text("down").tag(UInt32(3)); Text("downMirrored").tag(UInt32(4))
                        Text("leftMirrored").tag(UInt32(5)); Text("right").tag(UInt32(6))
                        Text("rightMirrored").tag(UInt32(7)); Text("left").tag(UInt32(8))
                    }
                    Toggle("Повернуть оси на 180°", isOn: $store.config.rotate180)
                    Toggle("Поменять левую/правую", isOn: $store.config.swapChirality)
                }
                Section("Сцена") {
                    Toggle("Руки толкают объекты", isOn: $store.config.handColliders)
                }
                Section {
                    Button("Сбросить калибровку") { model.clearCalibration() }
                    Button("Все настройки по умолчанию", role: .destructive) { store.resetToDefaults() }
                }
            }
            .navigationTitle("Отладка")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

/// Экран зонда: перечень форматов и живые замеры на дистанциях.
struct ProbeView: View {
    @State private var text = DeviceProbe.shared.text
    @State private var hud = Metrics.HUDData()
    private let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Зонд TrueDepth").font(.headline)
            Text("Держи ладонь на отмеренной дистанции и жми кнопку. Файл: Файлы → HandGrab → probe.txt")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                ForEach([15, 20, 30, 50, 70], id: \.self) { cm in
                    Button("\(cm) см") {
                        DeviceProbe.shared.recordSample(label: "\(cm)см", hud: Metrics.shared.lastHUD)
                        text = DeviceProbe.shared.text
                    }.buttonStyle(.bordered)
                }
            }
            ScrollView {
                Text(text).font(.system(size: 9, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding()
        .onReceive(timer) { _ in text = DeviceProbe.shared.text }
    }
}
