import Testing
import Foundation
@testable import AutopilotCore

@Suite struct SelectorSuggesterTests {
    @Test func prefersIdentifier() {
        let s = SelectorSuggester.suggest(from: [
            ["role": "AXButton", "identifier": "okButton", "title": "OK"],
        ])
        #expect(s.count == 1)
        #expect(s[0].selector.identifier == "okButton")
        #expect(s[0].note.contains("stable"))
    }

    @Test func fallsBackToTitle() {
        let s = SelectorSuggester.suggest(from: [
            ["role": "AXButton", "title": "Save"],
        ])
        #expect(s[0].selector.role == "AXButton")
        #expect(s[0].selector.title == "Save")
    }

    @Test func fallsBackToRoleIndexWhenAmbiguous() {
        let s = SelectorSuggester.suggest(from: [
            ["role": "AXButton"],
            ["role": "AXButton"],
        ])
        #expect(s[0].selector.index == 0)
        #expect(s[1].selector.index == 1)
        #expect(s[1].note.contains("fragile"))
    }

    @Test func skipsNonInteractiveNodes() {
        let s = SelectorSuggester.suggest(from: [
            ["role": "AXStaticText", "value": "hello"],
            ["role": "AXGroup"],
        ])
        #expect(s.isEmpty)
    }
}
