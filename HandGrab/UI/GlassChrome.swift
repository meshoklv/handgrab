import SwiftUI

// Интерфейс поверх сцены в стиле iOS 26 «жидкое стекло»: на экране только нижняя панель и маленькая кнопка отладки.
// На iOS 26 — настоящее Liquid Glass (glassEffect / GlassEffectContainer), на iOS 18 — тонкий материал.

extension View {
    /// Стеклянная подложка заданной формы.
    @ViewBuilder func glass<S: Shape>(_ shape: S, interactive: Bool = false) -> some View {
        if #available(iOS 26, *) {
            self.glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
                .overlay(shape.stroke(.white.opacity(0.16), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.25), radius: 10, y: 3)
        }
    }
}

/// Группа стеклянных элементов (на iOS 26 стекло соседних капсул сливается и перетекает).
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 10
    @ViewBuilder var content: Content
    var body: some View {
        if #available(iOS 26, *) { GlassEffectContainer(spacing: spacing) { content } } else { content }
    }
}

/// Круглая отдельная стеклянная кнопка.
struct GlassIconButton: View {
    let icon: String
    var size: CGFloat = 44
    let label: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: size * 0.38, weight: .semibold))
                .frame(width: size, height: size).contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glass(Circle(), interactive: true)
        .accessibilityLabel(label)
    }
}

/// Весь интерфейс над сценой.
struct GlassChrome: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var store: ConfigStore
    @ObservedObject var st = SculptState.shared
    @Binding var showDebug: Bool
    @AppStorage("hg.showStats") private var showStats = false
    @Namespace private var ns

    var body: some View {
        VStack(spacing: 8) {
            top
            if let t = st.toast, st.active {
                Text(t).font(.footnote.weight(.medium))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .glass(Capsule())
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            Spacer()
            notices
            if st.active { SculptTools().transition(.move(edge: .bottom).combined(with: .opacity)) }
            bottomBar
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 6)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: st.active)
        .animation(.easeOut(duration: 0.2), value: st.toast)
    }

    // MARK: Верх: строка fps (по желанию), превью камеры (отладка), кнопка отладки.

    private var top: some View {
        HStack(alignment: .top, spacing: 8) {
            if showStats {
                VStack(alignment: .leading, spacing: 4) {
                    MiniHUD()
                    if st.active { sculptStats }
                }
            }
            Spacer(minLength: 4)
            if store.config.showPreview { DebugPreviewView(pipeline: model.pipeline) }
            GlassIconButton(icon: "slider.horizontal.3", size: 36, label: "Отладка") { showDebug = true }
        }
    }

    private var sculptStats: some View {
        let s = st.stats
        return Text(String(format: "%d мазк · %.0fк треуг%@", s.strokes, Float(s.triangles) / 1000,
                           s.fullness >= 0.8 ? String(format: " · %.0f%%", s.fullness * 100) : ""))
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(s.fullness >= 0.8 ? Color.yellow : Color.white.opacity(0.6))
    }

    @ViewBuilder private var notices: some View {
        if let s = model.lastCalibration {
            Text(s).font(.caption).padding(.horizontal, 12).padding(.vertical, 6).glass(Capsule())
        }
        if !model.status.isEmpty, model.statusIsError {
            Label(model.status, systemImage: "exclamationmark.triangle.fill")
                .font(.caption).padding(.horizontal, 12).padding(.vertical, 6)
                .glass(Capsule())
                .foregroundStyle(.red)
        }
    }

    // MARK: Низ: переключатель режима + действия режима.

    private var bottomBar: some View {
        GlassGroup(spacing: 10) {
            HStack(spacing: 10) {
                modeSwitch
                Spacer(minLength: 0)
                if st.active {
                    SculptTools().actions
                } else {
                    GlassIconButton(icon: "arrow.counterclockwise", label: "Вернуть предметы") { model.requestReset() }
                }
            }
        }
    }

    private var modeSwitch: some View {
        HStack(spacing: 2) {
            modeButton(icon: "cube", on: !st.active, label: "Предметы") { st.active = false }
            modeButton(icon: "paintbrush.pointed", on: st.active, label: "Рисование") { st.active = true }
        }
        .padding(3)
        .glass(Capsule())
    }

    private func modeButton(icon: String, on: Bool, label: String, _ action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { action() }
            UISelectionFeedbackGenerator().selectionChanged()
        } label: {
            Image(systemName: on ? icon + ".fill" : icon)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 50, height: 40)
                .background {
                    if on { Capsule().fill(.white.opacity(0.24)).matchedGeometryEffect(id: "mode", in: ns) }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
