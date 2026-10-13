import Foundation

/// IEEE-754 binary16 conversion for Intel macOS, where Swift.Float16 is unavailable.
/// Round to nearest, ties to even, matching the native Apple Silicon representation.
enum Binary16 {
    static func encode(_ value: Float) -> UInt16 {
        let bits = value.bitPattern
        let sign = UInt16((bits >> 16) & 0x8000)
        let fraction = bits & 0x7fffff
        let exponent = Int((bits >> 23) & 0xff) - 127 + 15
        if exponent == 143 { return sign | 0x7c00 | (fraction == 0 ? 0 : 0x0200) }
        if exponent >= 31 { return sign | 0x7c00 }
        if exponent < -10 { return sign }
        let mantissa = exponent <= 0 ? fraction | 0x800000 : fraction
        let shift = UInt32(exponent <= 0 ? 14 - exponent : 13)
        var rounded = mantissa >> shift
        let remainder = mantissa & ((1 << shift) - 1)
        let midpoint: UInt32 = 1 << (shift - 1)
        if remainder > midpoint || (remainder == midpoint && rounded & 1 != 0) { rounded += 1 }
        let encodedExponent = exponent <= 0 ? 0 : UInt32(exponent) << 10
        return sign | UInt16(encodedExponent + rounded)
    }

    static func decode(_ bits: UInt16) -> Float {
        let sign = UInt32(bits & 0x8000) << 16
        let exponent = Int((bits >> 10) & 0x1f)
        var fraction = UInt32(bits & 0x03ff)
        if exponent == 0 {
            if fraction == 0 { return Float(bitPattern: sign) }
            var power = -14
            while fraction & 0x0400 == 0 { fraction <<= 1; power -= 1 }
            return Float(bitPattern: sign | UInt32(power + 127) << 23 | (fraction & 0x03ff) << 13)
        }
        return Float(bitPattern: sign | UInt32(exponent == 31 ? 255 : exponent + 112) << 23 | fraction << 13)
    }
}
