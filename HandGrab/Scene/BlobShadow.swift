import Foundation
import SceneKit
import UIKit
import simd

/// Мягкая тень-пятно на столе (запечённая радиальная текстура) — вместо динамических теней: дёшево и всегда мягко.
/// Чем выше предмет над столом, тем пятно больше и бледнее.
final class BlobShadow {
    let node = SCNNode()
    private let baseRadius: Float

    init(radius: Float) {
        baseRadius = radius
        let plane = SCNPlane(width: CGFloat(radius * 2.4), height: CGFloat(radius * 2.4))
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = BlobShadow.image
        m.blendMode = .alpha
        m.writesToDepthBuffer = false
        plane.materials = [m]
        node.geometry = plane
        node.simdOrientation = simd_quatf(angle: -.pi / 2, axis: SIMD3(1, 0, 0))
        node.castsShadow = false
        node.renderingOrder = 5
    }

    /// p — центр предмета, bottom — расстояние от центра до низа (у шара/куба — половина высоты).
    func update(at p: SIMD3<Float>, tableY: Float, bottom: Float = 0, strength: Float = 1) {
        let h = max(0, p.y - bottom - tableY)
        node.isHidden = strength <= 0.01
        node.simdPosition = SIMD3(p.x, tableY + 0.0008, p.z)
        let k = 1 + min(h, 0.35) * 2.6
        node.simdScale = SIMD3(k, k, 1)
        node.opacity = CGFloat(strength * max(0.18, 0.8 - h * 2.2))
    }

    /// Чёрное радиальное пятно с мягким краем (один раз на приложение).
    static let image: UIImage = {
        let size = CGSize(width: 128, height: 128)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let colors = [UIColor(white: 0, alpha: 0.55).cgColor, UIColor(white: 0, alpha: 0.28).cgColor, UIColor(white: 0, alpha: 0).cgColor]
            let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 0.45, 1])!
            ctx.cgContext.drawRadialGradient(g, startCenter: CGPoint(x: 64, y: 64), startRadius: 0,
                                             endCenter: CGPoint(x: 64, y: 64), endRadius: 64, options: [])
        }
    }()
}
