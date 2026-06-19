import Foundation

public enum AssertProperty: String, Codable, Sendable {
    case value, title, enabled, focused, position, size
    case marked   // menu-item checkmark state: "true"/"false" from AXMenuItemMarkChar
    case count    // number of elements matching the selector (for collections);
                  // evaluated via the resolver's count, relaxing single-match rules
}

public enum AssertOp: String, Codable, Sendable {
    case equals, notEquals, contains, matches
    case exists, notExists, greaterThan, lessThan
}

public struct Assertion: Codable, Equatable, Sendable {
    public var property: AssertProperty
    public var op: AssertOp
    /// Expected value as a string; numeric ops parse it as Double.
    public var expected: String?
    public init(property: AssertProperty, op: AssertOp, expected: String? = nil) {
        self.property = property; self.op = op; self.expected = expected
    }
}
