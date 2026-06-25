import Testing
import Foundation
import AutopilotCore
@testable import MacOSDriver

@Suite struct SelectorMatcherTests {
    // A snapshot node is a [String:String] as produced by AXTree.snapshot.
    // Selector matching is pure and lives in AutopilotCore.AXResolver.
    @Test func matchesByIdentifier() {
        let node = ["role": "AXButton", "identifier": "okButton", "title": "OK"]
        #expect(AXResolver.matches(node: node, selector: AutopilotCore.Selector(identifier: "okButton")))
        #expect(!AXResolver.matches(node: node, selector: AutopilotCore.Selector(identifier: "cancel")))
    }

    @Test func matchesByRoleAndTitle() {
        let node = ["role": "AXButton", "title": "OK"]
        #expect(AXResolver.matches(node: node, selector: AutopilotCore.Selector(role: "AXButton", title: "OK")))
        #expect(!AXResolver.matches(node: node, selector: AutopilotCore.Selector(role: "AXButton", title: "No")))
    }

    @Test func andsAllPredicates() {
        let node = ["role": "AXButton", "identifier": "okButton", "title": "OK"]
        // identifier matches but role does not -> no match
        #expect(!AXResolver.matches(node: node,
            selector: AutopilotCore.Selector(role: "AXTextField", identifier: "okButton")))
    }

    @Test func emptySelectorMatchesNothing() {
        let node = ["role": "AXButton"]
        #expect(!AXResolver.matches(node: node, selector: AutopilotCore.Selector()))
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

    @Test func parsesCmdComma() throws {
        // The single most common macOS shortcut (Preferences) — previously rejected.
        let chord = try ActionEngine.parseChord("cmd+,")
        #expect(chord.flags.contains(.maskCommand))
        #expect(chord.virtualKey == 43) // ANSI comma
    }

    @Test func parsesPunctuationByNameAndSymbol() throws {
        #expect(try ActionEngine.parseChord(".").virtualKey == 47)
        #expect(try ActionEngine.parseChord("period").virtualKey == 47)
        #expect(try ActionEngine.parseChord("/").virtualKey == 44)
        #expect(try ActionEngine.parseChord("slash").virtualKey == 44)
    }

    @Test func escapeHasCorrectKeycode() throws {
        // Regression: escape was previously mis-mapped to 27 (the minus key).
        #expect(try ActionEngine.parseChord("escape").virtualKey == 53)
        #expect(try ActionEngine.parseChord("minus").virtualKey == 27)
        #expect(try ActionEngine.parseChord("-").virtualKey == 27)
    }

    @Test func parsesNavigationAndFunctionKeys() throws {
        #expect(try ActionEngine.parseChord("home").virtualKey == 115)
        #expect(try ActionEngine.parseChord("pagedown").virtualKey == 121)
        #expect(try ActionEngine.parseChord("f1").virtualKey == 122)
        #expect(try ActionEngine.parseChord("cmd+f12").flags.contains(.maskCommand))
    }

    @Test func parsesPlusKeyWithImplicitShift() throws {
        // The + key (Shift+=) is spelled `plus` since + is the chord separator.
        let chord = try ActionEngine.parseChord("cmd+plus")
        #expect(chord.virtualKey == 24)                  // '=' base key
        #expect(chord.flags.contains(.maskCommand))
        #expect(chord.flags.contains(.maskShift))        // implicit
    }
}

@Suite struct VisionPathTests {
    @Test func absolutePathUsedAsIs() {
        #expect(Targeting.resolveImagePath("/tmp/x.png", baseDir: URL(fileURLWithPath: "/plans"))
                == "/tmp/x.png")
    }
    @Test func relativePathResolvesAgainstPlanDir() {
        #expect(Targeting.resolveImagePath("templates/icon.png", baseDir: URL(fileURLWithPath: "/plans/sub"))
                == "/plans/sub/templates/icon.png")
    }
    @Test func relativeWithNoBaseStaysRelative() {
        #expect(Targeting.resolveImagePath("icon.png", baseDir: nil) == "icon.png")
    }
}

@Suite struct VisionMatchTests {
    /// A 4x4 needle with internal structure (a 2x2 bright block in the top-left
    /// quadrant). NCC is undefined for a uniform template, so the pattern must
    /// have variance — as any real template image does. bestMatch is pure (core).
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
