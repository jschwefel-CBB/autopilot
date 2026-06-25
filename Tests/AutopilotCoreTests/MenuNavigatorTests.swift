import Testing
import Foundation
@testable import MacOSDriver

@Suite struct MenuNavigatorTests {
    @Test func findsTitleIndex() {
        let titles: [String?] = ["File", "Edit", "View", nil, "Window"]
        #expect(MenuNavigator.indexOfTitle("View", in: titles) == 2)
        #expect(MenuNavigator.indexOfTitle("Window", in: titles) == 4)
    }

    @Test func missingTitleIsNil() {
        let titles: [String?] = ["File", "Edit"]
        #expect(MenuNavigator.indexOfTitle("Nope", in: titles) == nil)
    }

    @Test func nilTitlesDoNotMatch() {
        let titles: [String?] = [nil, nil, "Help"]
        #expect(MenuNavigator.indexOfTitle("Help", in: titles) == 2)
        #expect(MenuNavigator.indexOfTitle("", in: titles) == nil)
    }
}
