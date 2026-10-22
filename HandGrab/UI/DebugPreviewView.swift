import SwiftUI
import UIKit

/// Превью в углу: RGB и псевдоцвет глубины с 21 точкой, переведённой в координаты сенсора.
/// Отрисовка — через contents у CALayer, не чаще 15 Гц (кадры готовит конвейер).
struct DebugPreviewView: UIViewRepresentable {
    let pipeline: TrackingPipeline

    func makeUIView(context: Context) -> PreviewHost {
        let v = PreviewHost()
        pipeline.onPreview = { [weak v] rgb, depth in v?.set(rgb: rgb, depth: depth) }
        return v
    }

    func updateUIView(_ uiView: PreviewHost, context: Context) {}

    static func dismantleUIView(_ uiView: PreviewHost, coordinator: ()) {}

    final class PreviewHost: UIView {
        private let rgbLayer = CALayer()
        private let depthLayer = CALayer()

        override init(frame: CGRect) {
            super.init(frame: frame)
            for l in [rgbLayer, depthLayer] {
                l.contentsGravity = .resizeAspect
                l.backgroundColor = UIColor(white: 0, alpha: 0.5).cgColor
                l.cornerRadius = 4
                l.masksToBounds = true
                layer.addSublayer(l)
            }
        }

        required init?(coder: NSCoder) { fatalError() }

        override var intrinsicContentSize: CGSize { CGSize(width: 120 * 2 + 4, height: 160) }

        override func layoutSubviews() {
            super.layoutSubviews()
            let w = (bounds.width - 4) / 2
            rgbLayer.frame = CGRect(x: 0, y: 0, width: w, height: bounds.height)
            depthLayer.frame = CGRect(x: w + 4, y: 0, width: w, height: bounds.height)
        }

        func set(rgb: CGImage?, depth: CGImage?) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            rgbLayer.contents = rgb
            depthLayer.contents = depth
            CATransaction.commit()
        }
    }
}

extension DebugPreviewView {
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: PreviewHost, context: Context) -> CGSize? {
        CGSize(width: 164, height: 110)
    }
}
