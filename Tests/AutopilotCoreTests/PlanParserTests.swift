import Testing
import Foundation
@testable import AutopilotCore

@Suite struct PlanDecodingTests {
    @Test func decodesMinimalPlan() throws {
        let json = """
        {
          "schemaVersion": "1.0",
          "name": "smoke",
          "target": { "bundleId": "com.example.app" },
          "steps": [
            { "id": "c1", "action": "click",
              "target": { "role": "AXButton", "identifier": "ok" } }
          ]
        }
        """.data(using: .utf8)!
        let plan = try JSONDecoder().decode(Plan.self, from: json)
        #expect(plan.name == "smoke")
        #expect(plan.schemaVersion == "1.0")
        #expect(plan.target.bundleId == "com.example.app")
        #expect(plan.steps.count == 1)
        #expect(plan.steps[0].id == "c1")
        #expect(plan.steps[0].action == .click)
        #expect(plan.steps[0].target?.identifier == "ok")
    }
}

@Suite struct PlanValidationTests {
    @Test func rejectsUnsupportedSchemaVersion() throws {
        let json = """
        {"schemaVersion":"2.0","name":"x","target":{"bundleId":"a"},"steps":[]}
        """.data(using: .utf8)!
        #expect(throws: PlanError.self) {
            _ = try PlanParser().parse(data: json, baseDirectory: URL(fileURLWithPath: "/tmp"))
        }
    }

    @Test func rejectsTargetWithNeitherBundleIdNorPath() throws {
        let json = """
        {"schemaVersion":"1.0","name":"x","target":{},"steps":[]}
        """.data(using: .utf8)!
        #expect(throws: PlanError.self) {
            _ = try PlanParser().parse(data: json, baseDirectory: URL(fileURLWithPath: "/tmp"))
        }
    }

    @Test func rejectsDuplicateStepIds() throws {
        let json = """
        {"schemaVersion":"1.0","name":"x","target":{"bundleId":"a"},
         "steps":[{"id":"s","action":"screenshot"},{"id":"s","action":"screenshot"}]}
        """.data(using: .utf8)!
        #expect(throws: PlanError.self) {
            _ = try PlanParser().parse(data: json, baseDirectory: URL(fileURLWithPath: "/tmp"))
        }
    }

    @Test func rejectsActionRequiringTargetWithoutOne() throws {
        // click requires a target
        let json = """
        {"schemaVersion":"1.0","name":"x","target":{"bundleId":"a"},
         "steps":[{"id":"s","action":"click"}]}
        """.data(using: .utf8)!
        #expect(throws: PlanError.self) {
            _ = try PlanParser().parse(data: json, baseDirectory: URL(fileURLWithPath: "/tmp"))
        }
    }

    @Test func acceptsValidPlan() throws {
        let json = """
        {"schemaVersion":"1.0","name":"x","target":{"bundleId":"a"},
         "steps":[{"id":"s","action":"click","target":{"identifier":"ok"}}]}
        """.data(using: .utf8)!
        let plan = try PlanParser().parse(data: json, baseDirectory: URL(fileURLWithPath: "/tmp"))
        #expect(plan.steps.count == 1)
    }

    @Test func dragNeedsToOrToFiles() throws {
        let json = """
        {"schemaVersion":"1.0","name":"x","target":{"bundleId":"a"},
         "steps":[{"id":"d","action":"drag","target":{"identifier":"src"}}]}
        """.data(using: .utf8)!
        #expect(throws: PlanError.self) {
            _ = try PlanParser().parse(data: json, baseDirectory: URL(fileURLWithPath: "/tmp"))
        }
    }

    @Test func dragWithDestinationIsValid() throws {
        let json = """
        {"schemaVersion":"1.0","name":"x","target":{"bundleId":"a"},
         "steps":[{"id":"d","action":"drag","target":{"identifier":"src"},
                   "args":{"to":{"identifier":"dst"}}}]}
        """.data(using: .utf8)!
        let plan = try PlanParser().parse(data: json, baseDirectory: URL(fileURLWithPath: "/tmp"))
        #expect(plan.steps[0].args?.to?.identifier == "dst")
    }

    @Test func menuNeedsMenuPath() throws {
        let json = """
        {"schemaVersion":"1.0","name":"x","target":{"bundleId":"a"},
         "steps":[{"id":"m","action":"menu"}]}
        """.data(using: .utf8)!
        #expect(throws: PlanError.self) {
            _ = try PlanParser().parse(data: json, baseDirectory: URL(fileURLWithPath: "/tmp"))
        }
    }

    @Test func selectorIndexAndWithinDecode() throws {
        let json = """
        {"schemaVersion":"1.0","name":"x","target":{"bundleId":"a"},
         "steps":[{"id":"s","action":"click",
           "target":{"role":"AXButton","index":2,
                     "within":{"role":"AXRow","index":0}}}]}
        """.data(using: .utf8)!
        let plan = try PlanParser().parse(data: json, baseDirectory: URL(fileURLWithPath: "/tmp"))
        let sel = plan.steps[0].target!
        #expect(sel.index == 2)
        #expect(sel.withinSelector?.role == "AXRow")
        #expect(sel.withinSelector?.index == 0)
    }

    @Test func assertPixelNeedsColor() throws {
        // assertPixel doesn't require a target, but runtime needs args.color;
        // parser accepts it (color is checked at run time), so this parses fine.
        let json = """
        {"schemaVersion":"1.0","name":"x","target":{"bundleId":"a"},
         "steps":[{"id":"p","action":"assertPixel","args":{"atX":10,"atY":10,"color":"#FF0000"}}]}
        """.data(using: .utf8)!
        let plan = try PlanParser().parse(data: json, baseDirectory: URL(fileURLWithPath: "/tmp"))
        #expect(plan.steps[0].args?.color == "#FF0000")
    }
}
