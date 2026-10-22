import SwiftUI
import SceneKit
import UIKit
import simd

/// Инструменты режима «Рисование и скульпт» — стеклянные капсулы над нижней панелью (её рисует GlassChrome).
/// Кисти — живые превью в кружках; цвет и толщина раскрываются отдельной капсулой; редкое — в меню «…».
struct SculptTools: View {
    @ObservedObject var st = SculptState.shared
    @State private var clearing = false
    private var panel: SculptPanel? { st.panel }

    private func color(_ c: SIMD3<Float>) -> Color { Color(red: Double(c.x), green: Double(c.y), blue: Double(c.z)) }

    var body: some View {
        GlassGroup(spacing: 8) {
            VStack(spacing: 8) {
                if panel == .color { colorPanel.transition(.scale(scale: 0.9, anchor: .bottom).combined(with: .opacity)) }
                if panel == .width { widthPanel.transition(.scale(scale: 0.9, anchor: .bottom).combined(with: .opacity)) }
                brushes
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.82), value: panel)
        .animation(.spring(response: 0.25, dampingFraction: 0.75), value: st.brush)
        .onAppear { SculptPreviews.renderIfNeeded() }
    }

    /// Правая капсула нижней панели: цвет, толщина, отмена, очистка (удержание 1 с), меню.
    var actions: some View {
        HStack(spacing: 2) {
            ToolButton(active: panel == .color, label: "Цвет") { toggle(.color) } content: {
                Circle().fill(st.color == Palette.colors[9] ? AnyShapeStyle(chrome) : AnyShapeStyle(color(st.color)))
                    .frame(width: 20, height: 20)
                    .overlay(Circle().stroke(.white.opacity(0.8), lineWidth: 1.5))
            }
            ToolButton(active: panel == .width, label: "Толщина") { toggle(.width) } content: {
                Image(systemName: "lineweight")
            }
            ToolButton(label: "Отменить") { st.send(.undo) } content: {
                Image(systemName: "arrow.uturn.backward")
            }
            .disabled(!st.stats.canUndo).opacity(st.stats.canUndo ? 1 : 0.35)
            ZStack {
                Circle().trim(from: 0, to: clearing ? 1 : 0)
                    .stroke(Color.red, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 34, height: 34)
                    .animation(clearing ? .linear(duration: 1) : .easeOut(duration: 0.15), value: clearing)
                Image(systemName: "trash").font(.system(size: 17, weight: .medium))
            }
            .frame(width: 44, height: 44)
            .contentShape(Circle())
            .onLongPressGesture(minimumDuration: 1, pressing: { clearing = $0 }) {
                clearing = false
                st.send(.clear)
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
            }
            .accessibilityLabel("Очистить (удерживать)")
            more
        }
        .padding(.horizontal, 4)
        .glass(Capsule())
    }

    private func toggle(_ p: SculptPanel) { st.panel = st.panel == p ? nil : p }

    private var chrome: LinearGradient {
        LinearGradient(colors: [.white, Color(white: 0.55), .white], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private var more: some View {
        Menu {
            Button { st.send(.save) } label: { Label("Сохранить", systemImage: "square.and.arrow.down") }
            if !st.exported.isEmpty {
                ShareLink(items: st.exported) { Label("Поделиться", systemImage: "square.and.arrow.up") }
            }
            Button { st.send(.redo) } label: { Label("Вернуть", systemImage: "arrow.uturn.forward") }
                .disabled(!st.stats.canRedo)
            Divider()
            Picker(selection: $st.leashMM) {
                Text("Без сглаживания").tag(0); Text("Плавно 6 мм").tag(6); Text("Очень плавно 12 мм").tag(12)
            } label: { Label("Плавность", systemImage: "scribble.variable") }
            Toggle(isOn: $st.mirror) { Label("Зеркало", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right") }
            Toggle(isOn: $st.undoGesture) { Label("Отмена щипком", systemImage: "hand.pinch") }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 17, weight: .semibold))
                .frame(width: 44, height: 44).contentShape(Circle())
        }
        .accessibilityLabel("Ещё")
    }

    // MARK: Кисти

    private var brushes: some View {
        HStack(spacing: 6) {
            ForEach(BrushKind.allCases) { k in
                let sel = st.brush == k
                Button { st.select(k) } label: {
                    ZStack {
                        Circle().fill(Color.black.opacity(0.35))
                        if let img = st.previews[k] {
                            Image(uiImage: img).resizable().scaledToFill().clipShape(Circle())
                        } else {
                            Text(String(k.title.prefix(1))).font(.footnote.bold())
                        }
                    }
                    .frame(width: 40, height: 40)
                    .overlay(Circle().stroke(sel ? color(st.color) : .clear, lineWidth: 2.5).padding(-3))
                    .scaleEffect(sel ? 1 : 0.86)
                    .frame(width: 48, height: 48)
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(k.title)
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 2)
        .glass(Capsule())
    }

    // MARK: Раскрывающиеся капсулы

    private var colorPanel: some View {
        HStack(spacing: 3) {
            ForEach(0..<Palette.colors.count, id: \.self) { i in
                let c = Palette.colors[i]
                let sel = simd_distance(c, st.color) < 0.01
                Button { st.color = c } label: {
                    Circle().fill(i == 9 ? AnyShapeStyle(chrome) : AnyShapeStyle(color(c)))
                        .frame(width: 22, height: 22)
                        .overlay(Circle().stroke(.white, lineWidth: sel ? 2 : 0).padding(-3))
                        .frame(width: 28, height: 36)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Palette.names[i])
            }
            ColorPicker("", selection: Binding(get: { color(st.color) }, set: { c in
                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                UIColor(c).getRed(&r, green: &g, blue: &b, alpha: &a)
                st.color = SIMD3(Float(min(max(r, 0), 1)), Float(min(max(g, 0), 1)), Float(min(max(b, 0), 1)))
            }), supportsOpacity: false)
            .labelsHidden()
            .scaleEffect(0.85)
            .frame(width: 28, height: 36)
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .glass(Capsule())
    }

    private static let wMin: Float = 0.3, wMax: Float = 3
    private var widthPanel: some View {
        let mm = BrushPreset.of(st.brush).baseRadius * 2 * st.thickness * 1000
        let d = CGFloat(min(max(mm * 2.4, 4), 30))
        return HStack(spacing: 12) {
            Circle().fill(color(st.color)).frame(width: d, height: d).frame(width: 30, height: 30)
            Slider(value: Binding(
                get: { (log(st.thickness) - log(Self.wMin)) / (log(Self.wMax) - log(Self.wMin)) },
                set: { st.thickness = exp(log(Self.wMin) + $0 * (log(Self.wMax) - log(Self.wMin))) }), in: 0...1)
                .tint(.white)
            Text(String(format: "×%.1f", st.thickness)).font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .frame(maxWidth: 360)
        .glass(Capsule())
    }
}

/// Кнопка внутри стеклянной капсулы (сама без стекла); активная — мягкая светлая подложка.
struct ToolButton<Content: View>: View {
    var active = false
    var label: String
    let action: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        Button(action: action) {
            content
                .font(.system(size: 17, weight: .medium))
                .frame(width: 44, height: 44)
                .background(Circle().fill(.white.opacity(active ? 0.22 : 0)).padding(3))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// Живые превью кистей: короткая «S» каждой кистью, офскрин-рендер SceneKit при первом показе HUD.
enum SculptPreviews {
    private static var started = false

    static func renderIfNeeded() {
        guard !started else { return }
        started = true
        let M = SculptMaterials.shared
        _ = M.studioCube   // прогрето на главном потоке
        DispatchQueue.global(qos: .utility).async {
            guard let dev = MTLCreateSystemDefaultDevice() else { return }
            var out: [BrushKind: UIImage] = [:]
            for k in BrushKind.allCases {
                let scene = SCNScene()
                scene.background.contents = UIColor(red: 0.07, green: 0.08, blue: 0.1, alpha: 1)
                scene.lightingEnvironment.contents = M.studioCube
                scene.lightingEnvironment.intensity = 1.3
                let light = SCNNode(); light.light = SCNLight(); light.light?.type = .directional; light.light?.intensity = 700
                light.simdPosition = [-0.3, 0.5, 0.4]; light.look(at: SCNVector3Zero)
                scene.rootNode.addChildNode(light)
                let pr = BrushPreset.of(k)
                var nodes: [StrokeNode] = []
                let n = Int(0.09 / pr.ringStep)
                for i in 0...n {
                    let u = Float(i) / Float(n)
                    let p = SIMD3<Float>(-0.03 * sin(2 * .pi * u), 0.045 - 0.09 * u, 0)
                    let nn = simd_quatf(angle: u * .pi, axis: [0, 1, 0]).act(SIMD3<Float>(0, 0, 1))
                    nodes.append(StrokeNode(p: p, r: pr.baseRadius * (k == .stardust ? 2.2 : 1.5) * (0.6 + 0.4 * sin(.pi * u)), n: nn, t: u * 0.6))
                }
                let sd = StrokeData(id: 1, kind: k, color: Palette.defaultColor(k), seed: 42, nodes: nodes, finished: true)
                let v = StrokeView(kind: k)
                v.setChunkSize(StrokeView.frozenChunk)
                v.rebuildAll(sd)
                scene.rootNode.addChildNode(v.node)
                let cam = SCNCamera(); cam.zNear = 0.01; cam.fieldOfView = 40
                cam.wantsHDR = true
                if k.emissive { cam.bloomIntensity = 1.4; cam.bloomThreshold = 0.8; cam.bloomBlurRadius = 8 }
                let cn = SCNNode(); cn.camera = cam; cn.simdPosition = [0, 0, 0.16]
                scene.rootNode.addChildNode(cn)
                let r = SCNRenderer(device: dev, options: nil)
                r.scene = scene
                r.pointOfView = cn
                let img = r.snapshot(atTime: 1.3, with: CGSize(width: 128, height: 128), antialiasingMode: .multisampling4X)
                out[k] = img
            }
            DispatchQueue.main.async { SculptState.shared.previews = out }
        }
    }
}
