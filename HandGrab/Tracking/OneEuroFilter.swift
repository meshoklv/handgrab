import Foundation
import simd

@inline(__always) private func oneEuroAlpha(_ cutoff: Float, _ dt: Float) -> Float {
    let tau = 1 / (2 * Float.pi * max(cutoff, 1e-3))
    return 1 / (1 + tau / dt)
}

/// One-Euro фильтр для скаляра (Casiez et al. 2012).
struct OneEuroFilter {
    var minCutoff: Float
    var beta: Float
    var dCutoff: Float
    private(set) var value: Float?
    private(set) var derivative: Float = 0
    private var lastT: Double = 0

    init(minCutoff: Float, beta: Float, dCutoff: Float = 1) {
        self.minCutoff = minCutoff; self.beta = beta; self.dCutoff = dCutoff
    }

    mutating func reset() { value = nil; derivative = 0 }

    mutating func filter(_ x: Float, t: Double) -> Float {
        guard let prev = value else { value = x; derivative = 0; lastT = t; return x }
        let dt = Float(max(t - lastT, 1e-4)); lastT = t
        let dx = (x - prev) / dt
        derivative += (dx - derivative) * oneEuroAlpha(dCutoff, dt)
        let a = oneEuroAlpha(minCutoff + beta * abs(derivative), dt)
        let out = prev + (x - prev) * a
        value = out
        return out
    }
}

/// One-Euro фильтр для векторов (SIMD2/SIMD3). Порог по модулю скорости.
struct OneEuroFilterV<V: SIMD> where V.Scalar == Float {
    var minCutoff: Float
    var beta: Float
    var dCutoff: Float
    private(set) var value: V?
    private(set) var derivative: V = V()
    private var lastT: Double = 0

    init(minCutoff: Float, beta: Float, dCutoff: Float = 1) {
        self.minCutoff = minCutoff; self.beta = beta; self.dCutoff = dCutoff
    }

    mutating func reset() { value = nil; derivative = V() }

    mutating func filter(_ x: V, t: Double) -> V {
        guard let prev = value else { value = x; derivative = V(); lastT = t; return x }
        let dt = Float(max(t - lastT, 1e-4)); lastT = t
        let dx = (x - prev) / dt
        derivative = derivative + (dx - derivative) * oneEuroAlpha(dCutoff, dt)
        let speed = (derivative * derivative).sum().squareRoot()
        let a = oneEuroAlpha(minCutoff + beta * speed, dt)
        let out = prev + (x - prev) * a
        value = out
        return out
    }
}
