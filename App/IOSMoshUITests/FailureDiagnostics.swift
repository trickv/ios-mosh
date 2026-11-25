import XCTest

/// A UI test that failed keeps the evidence while the app is still as the failure left it
/// (scripts/sim-test.sh): the spawner copies the app's debug.log, its session records and the
/// marks it received into ~/ios-mosh-out/diagnostics/<Class>.<test>-<time>/ (`/diagnostics`),
/// and the result bundle gets the app's state and an outline of its element tree. Nothing
/// here changes what a test checks: it runs in `tearDown`, after the test has passed or failed.
///
/// The outline has each element's type, identifier and frame, and only the lengths of its
/// label and value: a value can be screen text, pasted text or a field the test typed into,
/// and kept evidence never holds a key, a password or pasted text.
extension XCTestCase {
    func keepDiagnosticsIfFailed() {
        guard let run = testRun, run.failureCount + run.unexpectedExceptionCount > 0 else { return }
        let app = XCUIApplication()
        let tree = XCTAttachment(string: "app state: \(app.state.rawValue)\n\n\(Self.outline(of: app))")
        tree.name = "failure-app-tree"
        tree.lifetime = .keepAlways
        add(tree)
        guard let spawner = try? MoshSpawner.fromEnvironment() else { return }
        let marks = XCTAttachment(string: "marks: \((try? spawner.marks()) ?? [])")
        marks.name = "failure-marks"
        marks.lifetime = .keepAlways
        add(marks)
        // "-[IOSMoshUITests.ResumeUITests testX]" -> "ResumeUITests.testX-<UTC time>"
        let words = name.trimmingCharacters(in: CharacterSet(charactersIn: "-[]")).split(separator: " ")
        let test = words.map { $0.split(separator: ".").last.map(String.init) ?? "" }.joined(separator: ".")
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "").replacingOccurrences(of: "-", with: "")
        let saved = (try? spawner.saveDiagnostics(name: "\(test)-\(stamp)")) ?? "not saved"
        let note = XCTAttachment(string: "diagnostics: \(saved)")
        note.name = "failure-diagnostics"
        note.lifetime = .keepAlways
        add(note)
    }
}

extension XCTestCase {
    /// "type <raw> id=<identifier> {{x, y}, {w, h}} label <n> chars value <n> chars", indented by
    /// depth; no label or value text.
    static func outline(of app: XCUIApplication) -> String {
        guard let root = try? app.snapshot() else { return "no snapshot (app state \(app.state.rawValue))" }
        var lines: [String] = []
        func walk(_ element: XCUIElementSnapshot, _ depth: Int) {
            let id = element.identifier.isEmpty ? "" : " id=\(element.identifier)"
            let value = (element.value as? String).map { " value \($0.count) chars" } ?? ""
            let f = element.frame
            lines.append(String(repeating: "  ", count: depth)
                + "type \(element.elementType.rawValue)\(id) {{\(Int(f.minX)), \(Int(f.minY))}, "
                + "{\(Int(f.width)), \(Int(f.height))}} label \(element.label.count) chars\(value)")
            for child in element.children { walk(child, depth + 1) }
        }
        walk(root, 0)
        return lines.joined(separator: "\n")
    }
}

extension MoshSpawner {
    /// Asks the spawner to keep the app's debug.log, records and marks; returns where.
    func saveDiagnostics(name: String) throws -> String {
        struct Saved: Decodable { let saved: String }
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        return try JSONDecoder().decode(Saved.self, from: get("/diagnostics?name=\(encoded)")).saved
    }
}
