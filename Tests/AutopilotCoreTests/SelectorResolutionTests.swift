import Testing
import Foundation
@testable import AutopilotCore

@Suite struct SelectorMatcherTests {
    // A snapshot node is a [String:String] as produced by AXTree.snapshot.
    @Test func matchesByIdentifier() {
        let node = ["role": "AXButton", "identifier": "okButton", "title": "OK"]
        #expect(AXResolver.matches(node: node, selector: Selector(identifier: "okButton")))
        #expect(!AXResolver.matches(node: node, selector: Selector(identifier: "cancel")))
    }

    @Test func matchesByRoleAndTitle() {
        let node = ["role": "AXButton", "title": "OK"]
        #expect(AXResolver.matches(node: node, selector: Selector(role: "AXButton", title: "OK")))
        #expect(!AXResolver.matches(node: node, selector: Selector(role: "AXButton", title: "No")))
    }

    @Test func andsAllPredicates() {
        let node = ["role": "AXButton", "identifier": "okButton", "title": "OK"]
        // identifier matches but role does not -> no match
        #expect(!AXResolver.matches(node: node,
            selector: Selector(role: "AXTextField", identifier: "okButton")))
    }

    @Test func emptySelectorMatchesNothing() {
        let node = ["role": "AXButton"]
        #expect(!AXResolver.matches(node: node, selector: Selector()))
    }
}

@Suite struct KeyChordParseTests {
    @Test func parsesCmdS() throws {
        let chord = try ActionEngine.parseChord("cmd+s")
        #expect(chord.flags.contains(.maskCommand))
        #expect(chord.virtualKey == 1) // ANSI 's'
    }

    @Test func parsesShiftCmdLeftLetter() throws {
        let chord = try ActionEngine.parseChord("shift+cmd+a")
        #expect(chord.flags.contains(.maskShift))
        #expect(chord.flags.contains(.maskCommand))
        #expect(chord.virtualKey == 0) // ANSI 'a'
    }

    @Test func unknownKeyThrows() {
        #expect(throws: Error.self) { _ = try ActionEngine.parseChord("cmd+£") }
    }
}

@Suite struct VisionMatchTests {
    /// A 4x4 needle with internal structure (a 2x2 bright block in the top-left
    /// quadrant). NCC is undefined for a uniform template, so the pattern must
    /// have variance — as any real template image does.
    let needle: [[Double]] = [
        [1, 1, 0, 0],
        [1, 1, 0, 0],
        [0, 0, 0, 0],
        [0, 0, 0, 0],
    ]

    /// Build a 20x20 zero buffer, optionally stamping the needle at (px, py).
    func haystack(stampAt: (x: Int, y: Int)?) -> [[Double]] {
        var rows = Array(repeating: Array(repeating: 0.0, count: 20), count: 20)
        if let p = stampAt {
            for y in 0..<4 { for x in 0..<4 { rows[p.y + y][p.x + x] = needle[y][x] } }
        }
        return rows
    }

    @Test func findsTemplateLocation() {
        let match = VisionResolver.bestMatch(haystack: haystack(stampAt: (x: 5, y: 7)), needle: needle)
        #expect(match != nil)
        #expect(match!.x == 5)
        #expect(match!.y == 7)
        #expect(match!.score > 0.99)
    }

    @Test func reportsLowScoreWhenAbsent() {
        // Haystack has no copy of the pattern (all zero) => no positive correlation.
        let match = VisionResolver.bestMatch(haystack: haystack(stampAt: nil), needle: needle)
        #expect(match == nil || match!.score < 0.5)
    }

    @Test func uniformNeedleIsUndefined() {
        // A flat template has zero variance: NCC is undefined, must return nil.
        let flat = Array(repeating: Array(repeating: 1.0, count: 4), count: 4)
        #expect(VisionResolver.bestMatch(haystack: haystack(stampAt: (x: 5, y: 7)), needle: flat) == nil)
    }
}
