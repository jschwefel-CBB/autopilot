import Testing
import Foundation
@testable import MacOSDriver

@Suite struct KeyMapTests {
    @Test func lowercaseLetterNoShift() {
        let r = KeyMap.keyCode(for: "a")
        #expect(r?.code == 0)
        #expect(r?.shift == false)
    }

    @Test func uppercaseLetterNeedsShift() {
        let r = KeyMap.keyCode(for: "A")
        #expect(r?.code == 0)     // same base key as 'a'
        #expect(r?.shift == true)
    }

    @Test func digitNoShift() {
        #expect(KeyMap.keyCode(for: "5")?.code == 23)
        #expect(KeyMap.keyCode(for: "5")?.shift == false)
    }

    @Test func shiftedSymbolUsesBaseKey() {
        // '%' is Shift+5 → keycode 23 with shift.
        let r = KeyMap.keyCode(for: "%")
        #expect(r?.code == 23)
        #expect(r?.shift == true)
    }

    @Test func spaceAndPunctuation() {
        #expect(KeyMap.keyCode(for: " ")?.code == 49)
        #expect(KeyMap.keyCode(for: ",")?.code == 43)
        #expect(KeyMap.keyCode(for: ",")?.shift == false)
    }

    @Test func nonAnsiFallsBackToNil() {
        #expect(KeyMap.keyCode(for: "é") == nil)
        #expect(KeyMap.keyCode(for: "λ") == nil)
    }
}
