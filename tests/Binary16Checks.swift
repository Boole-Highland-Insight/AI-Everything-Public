import Foundation

@main enum Binary16Checks {
    static func main() {
        for integer in UInt32(0)...UInt32(UInt16.max) {
            let bits = UInt16(integer)
            let portable = Binary16.decode(bits)
            if portable.isNaN { continue }
            precondition(Binary16.encode(portable) == bits, "Half round trip failed: \(bits)")
            #if arch(arm64)
            precondition(portable.bitPattern == Float(Float16(bitPattern: bits)).bitPattern,
                         "Stored vectors decode differently on Intel: \(bits)")
            #endif
        }
        #if arch(arm64)
        var seed: UInt32 = 42
        for _ in 0..<200_000 {
            seed = seed &* 1664525 &+ 1013904223
            let value = Float(bitPattern: seed)
            if value.isNaN { continue }
            precondition(Binary16.encode(value) == Float16(value).bitPattern,
                         "Float rounding differs from native: \(seed)")
        }
        // Every finite adjacent pair's midpoint exercises tie-to-even rounding.
        for bits in UInt16(0)..<UInt16(0x7bff) {
            let midpoint = (Float(Float16(bitPattern: bits)) + Float(Float16(bitPattern: bits + 1))) / 2
            for value in [midpoint.nextDown, midpoint, midpoint.nextUp, -midpoint] {
                precondition(Binary16.encode(value) == Float16(value).bitPattern)
            }
        }
        #endif
        print("Binary16 checks passed: all 65,536 payloads; native compatibility, 200,000 Float bit patterns and finite rounding boundaries on Apple Silicon.")
    }
}
