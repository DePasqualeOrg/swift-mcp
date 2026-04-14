// Copyright © Anthony DePasquale
// Copyright © Matt Zmuda

import class Foundation.JSONDecoder
import class Foundation.JSONEncoder
@testable import MCP
import Testing

struct UnitIntervalTests {
    @Test
    func `Valid literal initialization`() {
        let zero: UnitInterval = 0.0
        #expect(zero.doubleValue == 0.0)

        let half: UnitInterval = 0.5
        #expect(half.doubleValue == 0.5)

        let one: UnitInterval = 1.0
        #expect(one.doubleValue == 1.0)

        let quarter: UnitInterval = 0.25
        #expect(quarter.doubleValue == 0.25)
    }

    @Test
    func `Valid failable initialization with runtime values`() {
        // Test with runtime computed values to force use of failable initializer
        let values = [0.0, 0.5, 1.0, 0.25]

        for value in values {
            let computed = value * 1.0 // Force runtime computation
            let interval = UnitInterval(computed)
            #expect(interval != nil)
            #expect(interval?.doubleValue == value)
        }
    }

    @Test
    func `Invalid failable initialization`() {
        // Test with runtime computed values to force use of failable initializer
        let invalidValues = [-0.1, 1.1, 100.0, -100.0]

        for value in invalidValues {
            let computed = value * 1.0 // Force runtime computation
            let interval = UnitInterval(computed)
            #expect(interval == nil)
        }
    }

    @Test
    func `Boundary and edge case values`() {
        // Test exact boundary values
        let exactZero = 0.0 * 1.0
        let zero = UnitInterval(exactZero)
        #expect(zero != nil)

        let exactOne = 1.0 * 1.0
        let one = UnitInterval(exactOne)
        #expect(one != nil)

        // Test machine precision boundaries
        let justAboveZero = Double.ulpOfOne * 1.0
        let aboveZero = UnitInterval(justAboveZero)
        #expect(aboveZero != nil)

        let justBelowOne = (1.0 - Double.ulpOfOne) * 1.0
        let belowOne = UnitInterval(justBelowOne)
        #expect(belowOne != nil)

        // Test very small positive value
        let tinyValue = 1e-10 * 1.0
        let tiny = UnitInterval(tinyValue)
        #expect(tiny != nil)
        #expect(tiny?.doubleValue == 1e-10)

        // Test value very close to 1
        let almostOneValue = 0.9999999999 * 1.0
        let almostOne = UnitInterval(almostOneValue)
        #expect(almostOne != nil)
        #expect(almostOne?.doubleValue == 0.9999999999)
    }

    @Test
    func `Float literal initialization`() {
        let zero: UnitInterval = 0.0
        #expect(zero.doubleValue == 0.0)

        let half: UnitInterval = 0.5
        #expect(half.doubleValue == 0.5)

        let one: UnitInterval = 1.0
        #expect(one.doubleValue == 1.0)

        let quarter: UnitInterval = 0.25
        #expect(quarter.doubleValue == 0.25)
    }

    @Test
    func `Integer literal initialization`() {
        let zero: UnitInterval = 0
        #expect(zero.doubleValue == 0.0)

        let one: UnitInterval = 1
        #expect(one.doubleValue == 1.0)
    }

    @Test
    func `Comparable conformance`() {
        let zero: UnitInterval = 0.0
        let quarter: UnitInterval = 0.25
        let half: UnitInterval = 0.5
        let one: UnitInterval = 1.0

        #expect(zero < quarter)
        #expect(quarter < half)
        #expect(half < one)
        #expect(zero < one)

        #expect(!(quarter < zero))
        #expect(!(half < quarter))
        #expect(!(one < half))

        #expect(zero <= quarter)
        #expect(quarter <= half)
        #expect(half <= one)
        #expect(zero <= zero)

        #expect(quarter > zero)
        #expect(half > quarter)
        #expect(one > half)

        #expect(quarter >= zero)
        #expect(half >= quarter)
        #expect(one >= half)
        #expect(one >= one)
    }

    @Test
    func `Equality and hashing`() {
        let half1: UnitInterval = 0.5
        let half2: UnitInterval = 0.5
        let quarter: UnitInterval = 0.25

        #expect(half1 == half2)
        #expect(half1 != quarter)
        #expect(half1.hashValue == half2.hashValue)
    }

    @Test
    func `String description`() {
        let zero: UnitInterval = 0.0
        #expect(zero.description == "0.0")

        let half: UnitInterval = 0.5
        #expect(half.description == "0.5")

        let one: UnitInterval = 1.0
        #expect(one.description == "1.0")

        let quarter: UnitInterval = 0.25
        #expect(quarter.description == "0.25")
    }

    @Test
    func `JSON encoding and decoding`() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let original: UnitInterval = 0.75

        let data = try encoder.encode(original)
        let decoded = try decoder.decode(UnitInterval.self, from: data)

        #expect(decoded == original)
        #expect(decoded.doubleValue == 0.75)
    }

    @Test
    func `JSON decoding with invalid values`() throws {
        let decoder = JSONDecoder()

        // Test negative value
        let negativeJSON = "-0.5".data(using: .utf8)!
        #expect(throws: DecodingError.self) {
            try decoder.decode(UnitInterval.self, from: negativeJSON)
        }

        // Test value greater than 1
        let tooLargeJSON = "1.5".data(using: .utf8)!
        #expect(throws: DecodingError.self) {
            try decoder.decode(UnitInterval.self, from: tooLargeJSON)
        }
    }

    @Test
    func `JSON encoding produces expected format`() throws {
        let encoder = JSONEncoder()

        let half: UnitInterval = 0.5
        let data = try encoder.encode(half)
        let jsonString = String(data: data, encoding: .utf8)

        #expect(jsonString == "0.5")
    }

    @Test
    func `Double value property`() {
        let values = [0.0, 0.1, 0.25, 0.5, 0.75, 0.9, 1.0]

        for value in values {
            let computed = value * 1.0 // Force runtime computation
            if let interval = UnitInterval(computed) {
                #expect(interval.doubleValue == value)
            } else {
                #expect(Bool(false), "UnitInterval(\(value)) should succeed")
            }
        }
    }
}
