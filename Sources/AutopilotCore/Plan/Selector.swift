import Foundation

/// A deterministic locator for one UI element. Predicates are ANDed.
/// Resolution priority is fixed: identifier > role+attr > path > vision.
public struct Selector: Codable, Equatable, Sendable {
    public var role: String?
    public var identifier: String?
    public var title: String?
    public var label: String?
    public var value: String?
    /// Positional index path, e.g. ["window[0]", "group[2]", "button[0]"].
    public var path: [String]?
    public var vision: VisionSelector?
    /// When the predicates match multiple elements, pick the nth (0-based) in
    /// tree order instead of erroring on ambiguity. A disambiguator of last resort.
    public var index: Int?
    /// Scope the search to inside the subtree of this (separately-resolved)
    /// parent element, e.g. "the AXButton within the AXRow at index 0".
    /// `indirect` (via the boxed storage below) lets the struct recurse.
    public var within: Selector? {
        get { _within?.value }
        set { _within = newValue.map(Box.init) }
    }
    private var _within: Box?

    /// Reference box so a value-type Selector can recursively hold a Selector.
    public final class Box: Codable, Equatable, @unchecked Sendable {
        public let value: Selector
        public init(_ v: Selector) { value = v }
        public init(from decoder: Decoder) throws {
            value = try Selector(from: decoder)   // a Box encodes AS its Selector
        }
        public func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
        public static func == (l: Box, r: Box) -> Bool { l.value == r.value }
    }

    public init(role: String? = nil, identifier: String? = nil, title: String? = nil,
                label: String? = nil, value: String? = nil, path: [String]? = nil,
                vision: VisionSelector? = nil, index: Int? = nil, within: Selector? = nil) {
        self.role = role; self.identifier = identifier; self.title = title
        self.label = label; self.value = value; self.path = path
        self.vision = vision; self.index = index
        self._within = within.map(Box.init)
    }

    private enum CodingKeys: String, CodingKey {
        case role, identifier, title, label, value, path, vision, index, within
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        role = try c.decodeIfPresent(String.self, forKey: .role)
        identifier = try c.decodeIfPresent(String.self, forKey: .identifier)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        value = try c.decodeIfPresent(String.self, forKey: .value)
        path = try c.decodeIfPresent([String].self, forKey: .path)
        vision = try c.decodeIfPresent(VisionSelector.self, forKey: .vision)
        index = try c.decodeIfPresent(Int.self, forKey: .index)
        _within = try c.decodeIfPresent(Box.self, forKey: .within)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(role, forKey: .role)
        try c.encodeIfPresent(identifier, forKey: .identifier)
        try c.encodeIfPresent(title, forKey: .title)
        try c.encodeIfPresent(label, forKey: .label)
        try c.encodeIfPresent(value, forKey: .value)
        try c.encodeIfPresent(path, forKey: .path)
        try c.encodeIfPresent(vision, forKey: .vision)
        try c.encodeIfPresent(index, forKey: .index)
        try c.encodeIfPresent(_within, forKey: .within)
    }

    /// The parent selector to scope within, if any.
    public var withinSelector: Selector? { within }
}

/// Template-match fallback locator. Deterministic: fixed confidence threshold, no LLM.
public struct VisionSelector: Codable, Equatable, Sendable {
    public var image: String          // path to template PNG, relative to plan file
    public var confidence: Double     // 0...1, required match threshold
    public init(image: String, confidence: Double) {
        self.image = image; self.confidence = confidence
    }
}
