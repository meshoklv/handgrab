import Foundation
import SceneKit
import UIKit
import simd

/// Материалы, шейдер-модификаторы и процедурные текстуры режима «Скульпт».
/// Всё генерируется один раз при первом обращении (около 30–60 мс, версия).
final class SculptMaterials {
    static let shared = SculptMaterials()

    // MARK: Текстуры

    lazy var studioCube: [UIImage] = SculptMaterials.makeStudioCube(size: 512)
    lazy var background: UIImage = SculptMaterials.makeBackdrop(w: 600, h: 1300)
    lazy var clayNormal: UIImage = SculptMaterials.makeClayNormal(size: 256)
    lazy var sprite: UIImage = SculptMaterials.makeSprite(size: 64)
    lazy var silkTexture: UIImage = SculptMaterials.makeSilk(size: 128)
    lazy var shadowBlob: UIImage = SculptMaterials.radialGradient(size: CGSize(width: 256, height: 256),
                                                                   inner: UIColor(white: 0, alpha: 0.32), outer: UIColor(white: 0, alpha: 0),
                                                                   center: CGPoint(x: 0.5, y: 0.5), radius: 0.5)
    lazy var stageGlow: UIImage = SculptMaterials.radialGradient(size: CGSize(width: 256, height: 256),
                                                                  inner: UIColor(red: 0.16, green: 0.18, blue: 0.23, alpha: 0.9),
                                                                  outer: UIColor(red: 0.16, green: 0.18, blue: 0.23, alpha: 0),
                                                                  center: CGPoint(x: 0.5, y: 0.5), radius: 0.5)

    // MARK: Шейдеры

    /// Множитель яркости в HDR (для bloom и вспышки отпускания).
    static let boostFragment = """
    #pragma arguments
    float boost;
    #pragma body
    _output.color.rgb *= boost;
    """

    /// Ореол неона: прозрачность по углу к взгляду (мягкий край), сложение цветов.
    static let haloSurface = """
    #pragma body
    float ndv = abs(dot(normalize(_surface.normal), normalize(_surface.view)));
    float a = pow(ndv, 2.2);
    _surface.diffuse.rgb *= a;
    """

    /// Пластилин: мягкий «подповерхностный» тёплый край (свет просвечивает воск) и чуть темнее в глубине складок.
    static let claySurface = """
    #pragma body
    float ndv = clamp(dot(normalize(_surface.normal), normalize(_surface.view)), 0.0, 1.0);
    float rim = pow(1.0 - ndv, 2.6);
    _surface.emission.rgb += _surface.diffuse.rgb * _surface.diffuse.rgb * rim * 0.35;
    """

    /// Шёлк: складка поперёк ленты и скользящий блик по краю.
    static let silkSurface = """
    #pragma body
    float ndv = abs(dot(normalize(_surface.normal), normalize(_surface.view)));
    float fold = 0.86 + 0.14 * sin(_surface.diffuseTexcoord.x * 3.14159);
    _surface.diffuse.rgb *= fold;
    float sheen = pow(1.0 - ndv, 3.0);
    _surface.emission.rgb += mix(_surface.diffuse.rgb, float3(1.0), 0.35) * sheen * 0.6 + _surface.diffuse.rgb * 0.06;
    """

    /// Шёлк: лёгкая волна 0,6 мм, 0,5 Гц.
    static let silkGeometry = """
    #pragma body
    float v = _geometry.texcoords[0].y;
    _geometry.position.xyz += _geometry.normal * (0.0006 * sin(scn_frame.time * 3.14159 + v * 1.3));
    """

    /// Пыль: билборд к камере, мерцание размером, медленный дрейф.
    static let dustGeometry = """
    #pragma body
    float2 corner = _geometry.texcoords[0] * 2.0 - 1.0;
    float sd = _geometry.texcoords[1].x;
    float size = _geometry.texcoords[1].y;
    float tm = scn_frame.time;
    float tw = 0.55 + 0.45 * sin(tm * (1.5 + sd * 5.0) + sd * 40.0);
    float3 drift = float3(sin(tm * 0.7 + sd * 13.0), cos(tm * 0.5 + sd * 7.0), sin(tm * 0.6 + sd * 3.0)) * 0.002;
    float4 vp = scn_node.modelViewTransform * float4(_geometry.position.xyz + drift, 1.0);
    vp.xy += corner * size * tw;
    _geometry.position = scn_node.inverseModelViewTransform * vp;
    """

    /// Плазма: изломы молнии — 3 октавы шума по длине дуги, новый узор 60 раз в секунду.
    static let plasmaGeometry = """
    float hg_h(float n) { return fract(sin(n) * 43758.5453); }
    float hg_n(float x, float k) {
        float i = floor(x); float f = fract(x); float u = f * f * (3.0 - 2.0 * f);
        return mix(hg_h(i + k * 57.31), hg_h(i + 1.0 + k * 57.31), u) * 2.0 - 1.0;
    }
    float3 hg_n3(float x, float k) { return float3(hg_n(x, k), hg_n(x, k + 17.0), hg_n(x, k + 31.0)); }
    #pragma body
    float s = _geometry.texcoords[1].x;
    float sd = _geometry.texcoords[1].y;
    float env = _geometry.texcoords[0].y;
    float fr = fmod(floor(scn_frame.time * 60.0), 997.0);
    float k = sd * 13.0 + fr * 0.71;
    float3 d = hg_n3(s * 70.0, k) * 0.0035 + hg_n3(s * 220.0, k + 3.3) * 0.0012 + hg_n3(s * 600.0, k + 7.7) * 0.0005;
    _geometry.position.xyz += d * env;
    """

    // MARK: Материалы

    lazy var clay: SCNMaterial = {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = UIColor.white
        m.roughness.contents = NSNumber(value: 0.56)
        m.metalness.contents = NSNumber(value: 0.0)
        // Восковой блеск пластилина: мягкий лак поверх матовой основы.
        m.clearCoat.contents = NSNumber(value: 0.2)
        m.clearCoatRoughness.contents = NSNumber(value: 0.38)
        m.normal.contents = clayNormal
        m.normal.intensity = 0.22
        m.shaderModifiers = [.surface: SculptMaterials.claySurface]
        m.normal.wrapS = .repeat; m.normal.wrapT = .repeat
        m.normal.mipFilter = .linear
        return m
    }()

    lazy var chrome: SCNMaterial = {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = UIColor.white
        m.metalness.contents = NSNumber(value: 1.0)
        m.roughness.contents = NSNumber(value: 0.07)
        return m
    }()

    lazy var silk: SCNMaterial = {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = silkTexture
        m.diffuse.wrapS = .repeat; m.diffuse.wrapT = .repeat
        m.roughness.contents = NSNumber(value: 0.42)
        m.metalness.contents = NSNumber(value: 0.0)
        m.shaderModifiers = [.geometry: SculptMaterials.silkGeometry, .surface: SculptMaterials.silkSurface]
        return m
    }()

    func neonCore() -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = UIColor.white
        m.shaderModifiers = [.fragment: SculptMaterials.boostFragment]
        m.setValue(NSNumber(value: 3.0), forKey: "boost")
        return m
    }

    func neonHalo() -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = UIColor.white
        m.blendMode = .add
        m.writesToDepthBuffer = false
        m.shaderModifiers = [.surface: SculptMaterials.haloSurface, .fragment: SculptMaterials.boostFragment]
        m.setValue(NSNumber(value: 1.2), forKey: "boost")
        return m
    }

    lazy var dust: SCNMaterial = {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = sprite
        m.blendMode = .add
        m.writesToDepthBuffer = false
        m.isDoubleSided = true
        m.shaderModifiers = [.geometry: SculptMaterials.dustGeometry, .fragment: SculptMaterials.boostFragment]
        m.setValue(NSNumber(value: 3.2), forKey: "boost")
        return m
    }()

    lazy var dustSpine: SCNMaterial = {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = UIColor.white
        m.blendMode = .add
        m.writesToDepthBuffer = false
        m.transparency = 0.3
        return m
    }()

    func plasma() -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = UIColor.white
        m.blendMode = .add
        m.writesToDepthBuffer = false
        m.shaderModifiers = [.geometry: SculptMaterials.plasmaGeometry, .fragment: SculptMaterials.boostFragment]
        m.setValue(NSNumber(value: 2.6), forKey: "boost")
        return m
    }

    /// Пол-«ловец теней»: сам невидим, показывает только мягкую тень скульптуры.
    lazy var shadowCatcher: SCNMaterial = {
        let m = SCNMaterial()
        m.lightingModel = .shadowOnly
        m.diffuse.contents = UIColor.white
        m.writesToDepthBuffer = false
        return m
    }()

    lazy var cursor: SCNMaterial = {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = UIColor.white
        m.transparency = 0.35
        m.writesToDepthBuffer = false
        return m
    }()

    lazy var highlight: SCNMaterial = {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = UIColor(white: 1, alpha: 1)
        m.blendMode = .add
        m.writesToDepthBuffer = false
        m.transparency = 0.35
        return m
    }()

    // MARK: Генераторы картинок

    static func radialGradient(size: CGSize, inner: UIColor, outer: UIColor, center: CGPoint, radius: CGFloat) -> UIImage {
        let f = UIGraphicsImageRendererFormat(); f.scale = 1; f.opaque = false
        return UIGraphicsImageRenderer(size: size, format: f).image { ctx in
            let cs = CGColorSpaceCreateDeviceRGB()
            let g = CGGradient(colorsSpace: cs, colors: [inner.cgColor, outer.cgColor] as CFArray, locations: [0, 1])!
            let c = CGPoint(x: center.x * size.width, y: center.y * size.height)
            let r = radius * max(size.width, size.height)
            ctx.cgContext.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: r, options: [.drawsAfterEndLocation])
        }
    }

    /// Студийная кубмапа: тёмные стены с бликом горизонта, большие софтбоксы (сверху, спереди, сбоку), цветные контровые полосы.
    /// Порядок граней: +X, −X, +Y, −Y, +Z, −Z.
    static func makeStudioCube(size: Int) -> [UIImage] {
        let s = CGFloat(size)
        let f = UIGraphicsImageRendererFormat(); f.scale = 1; f.opaque = true
        let cs = CGColorSpaceCreateDeviceRGB()
        func wall(_ cg: CGContext) {
            // Стена: сверху темно, у горизонта светлая полоса (даёт хрому «линию горизонта»), низ — тёплый пол.
            let cols = [UIColor(red: 0.05, green: 0.055, blue: 0.07, alpha: 1), UIColor(red: 0.13, green: 0.14, blue: 0.17, alpha: 1),
                        UIColor(red: 0.42, green: 0.43, blue: 0.46, alpha: 1), UIColor(red: 0.10, green: 0.09, blue: 0.09, alpha: 1),
                        UIColor(red: 0.16, green: 0.14, blue: 0.13, alpha: 1)].map(\.cgColor)
            let g = CGGradient(colorsSpace: cs, colors: cols as CFArray, locations: [0, 0.38, 0.5, 0.53, 1])!
            cg.drawLinearGradient(g, start: .zero, end: CGPoint(x: 0, y: s), options: [])
        }
        func face(_ draw: @escaping (CGContext) -> Void, plain: UIColor? = nil) -> UIImage {
            UIGraphicsImageRenderer(size: CGSize(width: s, height: s), format: f).image { ctx in
                let cg = ctx.cgContext
                if let plain { cg.setFillColor(plain.cgColor); cg.fill(CGRect(x: 0, y: 0, width: s, height: s)) } else { wall(cg) }
                draw(cg)
            }
        }
        func box(_ cg: CGContext, _ r: CGRect, _ c: UIColor, blur: CGFloat = 0.05) {
            cg.saveGState()
            cg.setShadow(offset: .zero, blur: blur * s, color: c.cgColor)
            cg.setFillColor(c.cgColor)
            cg.addPath(UIBezierPath(roundedRect: r, cornerRadius: min(r.width, r.height) * 0.12).cgPath)
            cg.fillPath()
            cg.restoreGState()
        }
        func R(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect { CGRect(x: s * x, y: s * y, width: s * w, height: s * h) }
        let warm = UIColor(red: 1, green: 0.92, blue: 0.80, alpha: 1)
        let cool = UIColor(red: 0.66, green: 0.80, blue: 1, alpha: 1)
        let px = face { cg in box(cg, R(0.36, 0.10, 0.28, 0.70), warm) }
        let nx = face { cg in box(cg, R(0.22, 0.18, 0.56, 0.40), cool); box(cg, R(0.70, 0.12, 0.06, 0.6), .white, blur: 0.02) }
        let py = face({ cg in
            box(cg, R(0.16, 0.16, 0.68, 0.68), .white, blur: 0.09)
            box(cg, R(0.36, 0.36, 0.28, 0.28), UIColor(white: 1, alpha: 1), blur: 0.04)
        }, plain: UIColor(white: 0.16, alpha: 1))
        let ny = face({ _ in }, plain: UIColor(red: 0.17, green: 0.15, blue: 0.14, alpha: 1))
        let pz = face { cg in
            box(cg, R(0.10, 0.12, 0.80, 0.34), UIColor(white: 0.95, alpha: 1), blur: 0.07)
        }
        let nz = face { cg in
            box(cg, R(0.04, 0.26, 0.92, 0.06), UIColor(red: 1, green: 0.55, blue: 0.32, alpha: 1), blur: 0.03)
            box(cg, R(0.04, 0.42, 0.92, 0.035), UIColor(red: 0.45, green: 0.75, blue: 1, alpha: 1), blur: 0.025)
        }
        return [px, nx, py, ny, pz, nz]
    }

    /// Фон: студийная «циклорама» — светлее за скульптурой, тёплый отсвет пола внизу, тёмная виньетка;
    /// лёгкое зерно против полос градиента.
    static func makeBackdrop(w: Int, h: Int) -> UIImage {
        var px = [UInt8](repeating: 255, count: w * h * 4)
        let top = SIMD3<Float>(0.035, 0.040, 0.052), mid = SIMD3<Float>(0.150, 0.162, 0.200), floorC = SIMD3<Float>(0.118, 0.110, 0.115)
        for y in 0..<h {
            let v = Float(y) / Float(h - 1)
            // Вертикаль: верх тёмный → свет за скульптурой (v≈0.45) → «горизонт» → пол.
            var base: SIMD3<Float>
            if v < 0.45 { base = simd_mix(top, mid, SIMD3(repeating: hgSmoothstep(0, 0.45, v))) } else {
                base = simd_mix(mid, floorC, SIMD3(repeating: hgSmoothstep(0.45, 0.95, v)))
            }
            for x in 0..<w {
                let u = Float(x) / Float(w - 1)
                let dx = (u - 0.5) * 1.15, dy = (v - 0.46) * 0.62
                let d = (dx * dx + dy * dy).squareRoot()
                let glow = exp(-d * d * 7) * 0.07
                let vign = 1 - 0.55 * hgSmoothstep(0.25, 0.75, d)
                var c = (base + SIMD3(0.55, 0.60, 0.75) * glow) * vign
                let n = (hgHash(Int32(x + y * 4099), 77) - 0.5) / 255 * 1.6
                c += SIMD3(repeating: n)
                let o = (y * w + x) * 4
                // Цвета заданы прямо в sRGB.
                px[o] = UInt8(clampf(c.x * 255, 0, 255))
                px[o + 1] = UInt8(clampf(c.y * 255, 0, 255))
                px[o + 2] = UInt8(clampf(c.z * 255, 0, 255))
            }
        }
        return imageRGBA(px, w, h)
    }

    /// Карта нормалей «глины»: мелкий шум + концентрические дуги (отпечатки пальцев).
    static func makeClayNormal(size n: Int) -> UIImage {
        var h = [Float](repeating: 0, count: n * n)
        // Шум двух октав (значения на решётке, билинейно, по кругу — бесшовно).
        func lattice(_ x: Int, _ y: Int, _ cells: Int, _ seed: UInt32) -> Float {
            hgHash(Int32((x % cells) + (y % cells) * 1000), seed)
        }
        func noise(_ u: Float, _ v: Float, cells: Int, seed: UInt32) -> Float {
            let x = u * Float(cells), y = v * Float(cells)
            let xi = Int(floor(x)), yi = Int(floor(y))
            let fx = x - Float(xi), fy = y - Float(yi)
            let a = lattice(xi, yi, cells, seed), b = lattice(xi + 1, yi, cells, seed)
            let c = lattice(xi, yi + 1, cells, seed), d = lattice(xi + 1, yi + 1, cells, seed)
            let sx = fx * fx * (3 - 2 * fx), sy = fy * fy * (3 - 2 * fy)
            return (a + (b - a) * sx) * (1 - sy) + (c + (d - c) * sx) * sy
        }
        // Отпечатки: 3 центра, кольца с шагом ~1/40 текстуры, затухание к краю пятна.
        let prints: [(Float, Float, Float)] = [(0.3, 0.35, 0.22), (0.72, 0.68, 0.18), (0.8, 0.15, 0.14)]
        for y in 0..<n {
            for x in 0..<n {
                let u = Float(x) / Float(n), v = Float(y) / Float(n)
                var val = noise(u, v, cells: 12, seed: 3) * 0.6 + noise(u, v, cells: 40, seed: 9) * 0.14
                for (cx, cy, rad) in prints {
                    var dx = abs(u - cx), dy = abs(v - cy)
                    dx = min(dx, 1 - dx); dy = min(dy, 1 - dy)
                    let d = (dx * dx + dy * dy * 1.3).squareRoot()
                    if d < rad {
                        let fade = 1 - d / rad
                        val += sin(d * 2 * .pi * 34) * 0.10 * fade * fade
                    }
                }
                h[y * n + x] = val
            }
        }
        var px = [UInt8](repeating: 255, count: n * n * 4)
        let k: Float = 6
        for y in 0..<n {
            for x in 0..<n {
                let l = h[y * n + (x + n - 1) % n], r = h[y * n + (x + 1) % n]
                let u = h[((y + n - 1) % n) * n + x], d = h[((y + 1) % n) * n + x]
                let nv = simd_normalize(SIMD3<Float>((l - r) * k, (u - d) * k, 1))
                let o = (y * n + x) * 4
                px[o] = UInt8(clampf((nv.x * 0.5 + 0.5) * 255, 0, 255))
                px[o + 1] = UInt8(clampf((nv.y * 0.5 + 0.5) * 255, 0, 255))
                px[o + 2] = UInt8(clampf((nv.z * 0.5 + 0.5) * 255, 0, 255))
            }
        }
        return imageRGBA(px, n, n)
    }

    /// Мягкий круглый спрайт для пыли (гаусс + яркое ядро).
    static func makeSprite(size n: Int) -> UIImage {
        var px = [UInt8](repeating: 0, count: n * n * 4)
        for y in 0..<n {
            for x in 0..<n {
                let dx = (Float(x) + 0.5) / Float(n) * 2 - 1, dy = (Float(y) + 0.5) / Float(n) * 2 - 1
                let d2 = dx * dx + dy * dy
                let a = clampf(exp(-d2 * 5) + exp(-d2 * 40) * 0.8, 0, 1) * (d2 < 1 ? 1 : 0)
                let o = (y * n + x) * 4
                let v = UInt8(a * 255)
                px[o] = v; px[o + 1] = v; px[o + 2] = v; px[o + 3] = v
            }
        }
        return imageRGBA(px, n, n)
    }

    /// Шёлк: светлая основа с тонкими продольными нитями.
    static func makeSilk(size n: Int) -> UIImage {
        var px = [UInt8](repeating: 255, count: n * n * 4)
        for y in 0..<n {
            for x in 0..<n {
                let u = Float(x) / Float(n), v = Float(y) / Float(n)
                let thread = 0.5 + 0.5 * sin(u * 2 * .pi * 48 + hgNoise1(v * 6, 5) * 1.5)
                let val = 0.88 + 0.12 * thread + hgNoise1(u * 40 + v * 3, 8) * 0.03
                let o = (y * n + x) * 4
                let b = UInt8(clampf(val, 0, 1) * 255)
                px[o] = b; px[o + 1] = b; px[o + 2] = b
            }
        }
        return imageRGBA(px, n, n)
    }

    static func imageRGBA(_ px: [UInt8], _ w: Int, _ h: Int) -> UIImage {
        let data = Data(px) as CFData
        let provider = CGDataProvider(data: data)!
        let cg = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                         space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                         provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
        return UIImage(cgImage: cg)
    }
}
