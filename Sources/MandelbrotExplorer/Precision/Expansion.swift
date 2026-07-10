import Foundation

/// Error-free floating point primitives (Knuth / Dekker / Shewchuk).
@inline(__always) func twoSum(_ a: Double, _ b: Double) -> (Double, Double) {
    let s = a + b
    let bb = s - a
    let err = (a - (s - bb)) + (b - bb)
    return (s, err)
}

@inline(__always) func twoProd(_ a: Double, _ b: Double) -> (Double, Double) {
    let p = a * b
    let err = fma(a, b, -p)
    return (p, err)
}

/// Arbitrary-precision (bounded) real number represented as a non-overlapping
/// "expansion" of IEEE-754 doubles, ascending magnitude (terms[0] least
/// significant). Built from Shewchuk-style error-free grow/merge primitives.
///
/// This gives us as many decimal digits as needed (roughly 15.9 digits per
/// extra term) to represent Mandelbrot reference-orbit coordinates at
/// arbitrary zoom depth, without pulling in a full bignum dependency.
struct Expansion: Equatable {
    var terms: [Double]

    static let zero = Expansion(terms: [0.0])

    init(terms: [Double]) {
        self.terms = terms.isEmpty ? [0.0] : terms
    }

    init(_ value: Double) {
        self.terms = [value]
    }

    var approximateValue: Double {
        terms.reduce(0, +)
    }

    var isZero: Bool {
        terms.allSatisfy { $0 == 0 }
    }

    /// Fold one extra double into an ascending, non-overlapping expansion.
    private static func grow(_ e: [Double], _ b: Double) -> [Double] {
        guard b != 0 else { return e }
        var q = b
        var result: [Double] = []
        result.reserveCapacity(e.count + 1)
        for ei in e {
            let (s, err) = twoSum(q, ei)
            if err != 0 { result.append(err) }
            q = s
        }
        result.append(q)
        return result.isEmpty ? [0.0] : result
    }

    /// Keep only the `precision` most-significant (largest magnitude) terms.
    private static func compress(_ terms: [Double], precision: Int) -> [Double] {
        if terms.count <= precision { return terms.isEmpty ? [0.0] : terms }
        return Array(terms.suffix(precision))
    }

    func negated() -> Expansion {
        Expansion(terms: terms.map { -$0 })
    }

    func adding(_ other: Expansion, precision: Int) -> Expansion {
        var acc = terms
        for t in other.terms {
            acc = Expansion.grow(acc, t)
        }
        return Expansion(terms: Expansion.compress(acc, precision: precision))
    }

    func subtracting(_ other: Expansion, precision: Int) -> Expansion {
        adding(other.negated(), precision: precision)
    }

    func multiplied(by other: Expansion, precision: Int) -> Expansion {
        var products: [Double] = []
        products.reserveCapacity(terms.count * other.terms.count * 2)
        for x in terms where x != 0 {
            for y in other.terms where y != 0 {
                let (p, e) = twoProd(x, y)
                products.append(p)
                if e != 0 { products.append(e) }
            }
        }
        if products.isEmpty { return .zero }
        var acc: [Double] = [0.0]
        for p in products {
            acc = Expansion.grow(acc, p)
        }
        return Expansion(terms: Expansion.compress(acc, precision: precision))
    }

    func scaledByPowerOfTwo(_ k: Int) -> Expansion {
        Expansion(terms: terms.map { Foundation.scalbn($0, k) })
    }

    func reciprocal(precision: Int) -> Expansion {
        let approx = approximateValue
        guard approx != 0 else { return .zero }
        var x = Expansion(1.0 / approx)
        var currentPrecision = 2
        let two = Expansion(2.0)
        while currentPrecision < precision {
            currentPrecision = min(precision, currentPrecision * 2)
            let sx = multiplied(by: x, precision: currentPrecision)
            let twoMinusSX = two.subtracting(sx, precision: currentPrecision)
            x = x.multiplied(by: twoMinusSX, precision: currentPrecision)
        }
        return x
    }

    func divided(by other: Expansion, precision: Int) -> Expansion {
        multiplied(by: other.reciprocal(precision: precision), precision: precision)
    }

    func power(_ n: Int, precision: Int) -> Expansion {
        guard n > 0 else { return Expansion(1.0) }
        var result = Expansion(1.0)
        var base = self
        var e = n
        while e > 0 {
            if e & 1 == 1 { result = result.multiplied(by: base, precision: precision) }
            e >>= 1
            if e > 0 { base = base.multiplied(by: base, precision: precision) }
        }
        return result
    }

    /// Parse an arbitrary-precision decimal literal, e.g. "-0.7453983606667815".
    init(decimalString raw: String, precision: Int) {
        var s = Substring(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        var negative = false
        if s.first == "-" { negative = true; s.removeFirst() }
        else if s.first == "+" { s.removeFirst() }

        let parts = s.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let intPart = parts.first ?? ""
        let fracPart = parts.count > 1 ? parts[1] : ""

        var acc = Expansion(0.0)
        let ten = Expansion(10.0)
        for ch in intPart {
            guard let d = ch.wholeNumberValue else { continue }
            acc = acc.multiplied(by: ten, precision: precision).adding(Expansion(Double(d)), precision: precision)
        }
        for ch in fracPart {
            guard let d = ch.wholeNumberValue else { continue }
            acc = acc.multiplied(by: ten, precision: precision).adding(Expansion(Double(d)), precision: precision)
        }
        if !fracPart.isEmpty {
            let divisor = ten.power(fracPart.count, precision: precision)
            acc = acc.divided(by: divisor, precision: precision)
        }
        self = negative ? acc.negated() : acc
    }
}

/// Precision budget (number of `Double` terms) needed to safely represent
/// coordinates at a given zoom factor, plus guard digits for iteration error.
func requiredPrecisionTerms(forZoom zoom: Double) -> Int {
    let decimalDigits = max(0, log10(max(zoom, 1))) + 20
    let doublesNeeded = Int(ceil(decimalDigits / 15.5)) + 1
    return min(max(doublesNeeded, 2), 20)
}

struct ComplexExpansion {
    var re: Expansion
    var im: Expansion

    static let zero = ComplexExpansion(re: .zero, im: .zero)

    func adding(_ o: ComplexExpansion, precision: Int) -> ComplexExpansion {
        ComplexExpansion(re: re.adding(o.re, precision: precision), im: im.adding(o.im, precision: precision))
    }

    func subtracting(_ o: ComplexExpansion, precision: Int) -> ComplexExpansion {
        ComplexExpansion(re: re.subtracting(o.re, precision: precision), im: im.subtracting(o.im, precision: precision))
    }

    /// (re + im*i)^2 = (re^2 - im^2) + (2*re*im)*i
    func squared(precision: Int) -> ComplexExpansion {
        let rr = re.multiplied(by: re, precision: precision)
        let ii = im.multiplied(by: im, precision: precision)
        let ri = re.multiplied(by: im, precision: precision)
        return ComplexExpansion(
            re: rr.subtracting(ii, precision: precision),
            im: ri.adding(ri, precision: precision)
        )
    }

    var approximateValue: SIMD2<Double> {
        SIMD2(re.approximateValue, im.approximateValue)
    }
}
