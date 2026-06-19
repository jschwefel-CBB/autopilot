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

    @Test func decodesAttachMode() throws {
        let json = """
        {
          "schemaVersion": "1.0",
          "name": "attach-test",
          "target": { "bundleId": "com.example.app", "attach": true },
          "steps": [ { "id": "q", "action": "terminate" } ]
        }
        """.data(using: .utf8)!
        let plan = try JSONDecoder().decode(Plan.self, from: json)
        #expect(plan.target.attach == true)
        #expect(plan.target.bundleId == "com.example.app")
    }

    @Test func attachDefaultsToNil() throws {
        let json = """
        {
          "schemaVersion": "1.0",
          "name": "normal",
          "target": { "bundleId": "com.example.app" },
          "steps": [ { "id": "q", "action": "terminate" } ]
        }
        """.data(using: .utf8)!
        let plan = try JSONDecoder().decode(Plan.self, from: json)
        #expect(plan.target.attach == nil)
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

    @Test func assertPixelNeedsColorAtParse() throws {
        let json = """
        {"schemaVersion":"1.0","name":"x","target":{"bundleId":"a"},
         "steps":[{"id":"p","action":"assertPixel","args":{"atX":1,"atY":1}}]}
        """.data(using: .utf8)!
        #expect(throws: PlanError.self) {
            _ = try PlanParser().parse(data: json, baseDirectory: URL(fileURLWithPath: "/tmp"))
        }
    }

    @Test func assertRegionNeedsColorAtParse() throws {
        let json = """
        {"schemaVersion":"1.0","name":"x","target":{"bundleId":"a"},
         "steps":[{"id":"r","action":"assertRegion","args":{"atX":1,"atY":1,"width":4,"height":4}}]}
        """.data(using: .utf8)!
        #expect(throws: PlanError.self) {
            _ = try PlanParser().parse(data: json, baseDirectory: URL(fileURLWithPath: "/tmp"))
        }
    }

    @Test func snapshotNeedsReferenceAtParse() throws {
        let json = """
        {"schemaVersion":"1.0","name":"x","target":{"bundleId":"a"},
         "steps":[{"id":"s","action":"snapshot","args":{"atX":1,"atY":1}}]}
        """.data(using: .utf8)!
        #expect(throws: PlanError.self) {
            _ = try PlanParser().parse(data: json, baseDirectory: URL(fileURLWithPath: "/tmp"))
        }
    }

    @Test func labelAndPathSelectorsRejectedAtParse() throws {
        for field in ["\"label\":\"OK\"", "\"path\":[\"w[0]\"]"] {
            let json = """
            {"schemaVersion":"1.0","name":"x","target":{"bundleId":"a"},
             "steps":[{"id":"c","action":"click","target":{\(field)}}]}
            """.data(using: .utf8)!
            #expect(throws: PlanError.self) {
                _ = try PlanParser().parse(data: json, baseDirectory: URL(fileURLWithPath: "/tmp"))
            }
        }
    }

    @Test func keyPressBadChordRejectedAtParse() throws {
        let json = """
        {"schemaVersion":"1.0","name":"x","target":{"bundleId":"a"},
         "steps":[{"id":"k","action":"keyPress","target":{"identifier":"e"},"args":{"keys":"cmd+frobnicate"}}]}
        """.data(using: .utf8)!
        #expect(throws: PlanError.self) {
            _ = try PlanParser().parse(data: json, baseDirectory: URL(fileURLWithPath: "/tmp"))
        }
    }

    @Test func scrollNeedsADelta() throws {
        let json = """
        {"schemaVersion":"1.0","name":"x","target":{"bundleId":"a"},
         "steps":[{"id":"s","action":"scroll","target":{"identifier":"e"}}]}
        """.data(using: .utf8)!
        #expect(throws: PlanError.self) {
            _ = try PlanParser().parse(data: json, baseDirectory: URL(fileURLWithPath: "/tmp"))
        }
    }

    @Test func numericAssertNeedsNumericExpected() throws {
        let json = """
        {"schemaVersion":"1.0","name":"x","target":{"bundleId":"a"},
         "steps":[{"id":"a","action":"assert","target":{"identifier":"e"},
                   "assert":{"property":"value","op":"greaterThan","expected":"notanumber"}}]}
        """.data(using: .utf8)!
        #expect(throws: PlanError.self) {
            _ = try PlanParser().parse(data: json, baseDirectory: URL(fileURLWithPath: "/tmp"))
        }
    }

    @Test func matchesAssertNeedsValidRegex() throws {
        let json = """
        {"schemaVersion":"1.0","name":"x","target":{"bundleId":"a"},
         "steps":[{"id":"a","action":"assert","target":{"identifier":"e"},
                   "assert":{"property":"value","op":"matches","expected":"[unterminated"}}]}
        """.data(using: .utf8)!
        #expect(throws: PlanError.self) {
            _ = try PlanParser().parse(data: json, baseDirectory: URL(fileURLWithPath: "/tmp"))
        }
    }

    @Test func validAssertionsAndChordsParse() throws {
        let json = """
        {"schemaVersion":"1.0","name":"x","target":{"bundleId":"a"},
         "steps":[
           {"id":"k","action":"keyPress","target":{"identifier":"e"},"args":{"keys":"cmd+s"}},
           {"id":"sc","action":"scroll","target":{"identifier":"e"},"args":{"deltaY":-100}},
           {"id":"g","action":"assert","target":{"identifier":"e"},"assert":{"property":"value","op":"greaterThan","expected":"5"}},
           {"id":"m","action":"assert","target":{"identifier":"e"},"assert":{"property":"value","op":"matches","expected":"\\\\d+"}}
         ]}
        """.data(using: .utf8)!
        let plan = try PlanParser().parse(data: json, baseDirectory: URL(fileURLWithPath: "/tmp"))
        #expect(plan.steps.count == 4)
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

    @Test func assertPixelWithColorAndPointIsValid() throws {
        // A complete assertPixel (color + absolute point) parses fine.
        let json = """
        {"schemaVersion":"1.0","name":"x","target":{"bundleId":"a"},
         "steps":[{"id":"p","action":"assertPixel","args":{"atX":10,"atY":10,"color":"#FF0000"}}]}
        """.data(using: .utf8)!
        let plan = try PlanParser().parse(data: json, baseDirectory: URL(fileURLWithPath: "/tmp"))
        #expect(plan.steps[0].args?.color == "#FF0000")
    }

    @Test func screenshotActionDecodesAllModes() throws {
        // Full display, element-scoped, absolute region, and captureTarget all parse.
        let json = """
        {"schemaVersion":"1.0","name":"x","target":{"bundleId":"a"},
         "steps":[
           {"id":"full","action":"screenshot"},
           {"id":"el","action":"screenshot",
            "target":{"identifier":"toolbar"},"args":{"padding":16}},
           {"id":"region","action":"screenshot",
            "args":{"atX":0,"atY":0,"width":400,"height":50}},
           {"id":"ct","action":"assert","target":{"identifier":"label"},
            "assert":{"property":"value","op":"equals","expected":"OK"},
            "captureTarget":true,"args":{"padding":8}}
         ]}
        """.data(using: .utf8)!
        let plan = try PlanParser().parse(data: json, baseDirectory: URL(fileURLWithPath: "/tmp"))
        #expect(plan.steps.count == 4)
        #expect(plan.steps[1].target?.identifier == "toolbar")
        #expect(plan.steps[1].args?.padding == 16)
        #expect(plan.steps[2].args?.atX == 0)
        #expect(plan.steps[2].args?.width == 400)
        #expect(plan.steps[3].captureTarget == true)
        #expect(plan.steps[3].args?.padding == 8)
    }
}

@Suite struct PlanLinterCaptureTargetTests {
    func plan(steps: [[String: Any]]) throws -> Plan {
        let obj: [String: Any] = [
            "schemaVersion": "1.0", "name": "t",
            "target": ["bundleId": "a"],
            "steps": steps,
        ]
        let data = try JSONSerialization.data(withJSONObject: obj)
        return try PlanParser().parse(data: data, baseDirectory: URL(fileURLWithPath: "/tmp"))
    }

    @Test func captureTargetWithNoTargetIsWarning() throws {
        // captureTarget: true on a step with no target → linter warning
        let p = try plan(steps: [
            ["id": "s", "action": "screenshot", "captureTarget": true]
        ])
        let findings = PlanLinter().lint(p)
        #expect(findings.contains { $0.stepId == "s" && $0.severity == .warning
            && $0.message.contains("captureTarget") })
    }

    @Test func captureTargetWithTargetProducesNoWarning() throws {
        // captureTarget: true on a step WITH a target → no linter warning
        let p = try plan(steps: [
            ["id": "a", "action": "assert",
             "target": ["identifier": "btn"],
             "assert": ["property": "value", "op": "equals", "expected": "OK"],
             "captureTarget": true]
        ])
        let findings = PlanLinter().lint(p)
        #expect(!findings.contains { $0.message.contains("captureTarget") })
    }
}
