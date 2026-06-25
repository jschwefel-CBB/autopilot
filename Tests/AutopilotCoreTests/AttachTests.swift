import Testing
import Foundation
@testable import MacOSDriver

@Suite struct AttachTests {
    struct FakeApp { let name: String; let active: Bool }

    @Test func prefersActiveInstance() {
        let apps = [FakeApp(name: "a", active: false),
                    FakeApp(name: "b", active: true),
                    FakeApp(name: "c", active: false)]
        let chosen = AppLauncher.chooseFrontmost(apps) { $0.active }
        #expect(chosen?.name == "b")
    }

    @Test func fallsBackToFirstWhenNoneActive() {
        let apps = [FakeApp(name: "a", active: false), FakeApp(name: "b", active: false)]
        let chosen = AppLauncher.chooseFrontmost(apps) { $0.active }
        #expect(chosen?.name == "a")
    }

    @Test func emptyListIsNil() {
        let apps: [FakeApp] = []
        #expect(AppLauncher.chooseFrontmost(apps) { $0.active } == nil)
    }
}
