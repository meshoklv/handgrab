import SwiftUI

/// Полный HUD (в «Отладке»): частоты, задержка, состояние руки. Читает последний снимок счётчиков.
struct HUDView: View {
    @State private var h = Metrics.HUDData()
    private let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    private func f(_ v: Double, _ d: Int = 0) -> String { v.isNaN ? "—" : String(format: "%.\(d)f", v) }
    private func f(_ v: Float, _ d: Int = 0) -> String { v.isNaN ? "—" : String(format: "%.\(d)f", v) }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("рендер \(f(h.renderFps)) · камера \(f(h.camFps)) · глуб \(f(h.depthFps)) · CPU \(f(h.cpuPct))%")
            Text("\(h.info.detector) \(f(h.visionFps)) fps \(f(h.visionMean, 1))/\(f(h.visionP95, 1)) мс · пропуск \(f(h.visionSkipPct))%")
            Text("кадр→рендер \(f(h.latMean, 1))/\(f(h.latP95, 1)) мс · прогноз \(f(h.info.predictionMs)) мс")
            Text("доставка \(f(h.deliverMs, 1)) · очередь \(f(h.waitMs, 1)) · готово \(f(h.doneMs, 1)) мс")
            Text("глуб: выброшено \(f(h.depthDropPct))% · дыра на ладони \(f(h.palmHolePct))% · возраст \(f(h.depthAgeMs)) мс")
            Text("рук \(h.info.hands) conf \(f(h.info.meanConf, 2)) · ладонь \(f(h.info.palmCm)) см \(h.info.depthFresh ? "(глуб)" : "(по размеру)") · s \(f(h.info.scaleCm, 1))")
            Text("\(h.info.pinch) d=\(f(h.info.pinchD, 2)) кул=\(f(h.info.fistD, 2)) · \(h.thermal)")
        }
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .padding(6)
        .background(.black.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .foregroundStyle(.white)
        .onAppear { h = Metrics.shared.lastHUD }
        .onReceive(timer) { _ in h = Metrics.shared.lastHUD }
    }
}

/// Маленькая строка на главном экране: fps распознавания и задержка.
struct MiniHUD: View {
    @State private var h = Metrics.HUDData()
    private let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        Text(String(format: "%.0f fps · %.0f мс%@", h.visionFps, h.latMean,
                    h.thermal == "ГОРЯЧИЙ" || h.thermal == "КРИТИЧНО" ? " · горячий" : ""))
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(.white.opacity(0.55))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(.black.opacity(0.3)).clipShape(Capsule())
            .onReceive(timer) { _ in h = Metrics.shared.lastHUD }
    }
}
