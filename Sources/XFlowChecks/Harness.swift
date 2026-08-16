import Foundation

/// Minimal check harness. Collects failures instead of trapping on the first one,
/// so a single run reports everything that broke.
enum Checks {
    private(set) static var failures: [String] = []
    private(set) static var passed = 0

    static func check(
        _ condition: Bool,
        _ message: String,
        file: StaticString = #fileID,
        line: UInt = #line
    ) {
        if condition {
            passed += 1
        } else {
            failures.append("\(file):\(line) — \(message)")
        }
    }

    static func equal<T: Equatable>(
        _ actual: T,
        _ expected: T,
        _ message: String,
        file: StaticString = #fileID,
        line: UInt = #line
    ) {
        check(
            actual == expected,
            "\(message)\n    expected: \(expected)\n    actual:   \(actual)",
            file: file,
            line: line
        )
    }

    /// Asserts that `body` throws the given error.
    static func throwsError<E: Error & Equatable>(
        _ expected: E,
        _ message: String,
        file: StaticString = #fileID,
        line: UInt = #line,
        _ body: () throws -> Void
    ) {
        do {
            try body()
            check(false, "\(message) — nothing was thrown", file: file, line: line)
        } catch let error as E where error == expected {
            passed += 1
        } catch {
            check(false, "\(message) — threw \(error), expected \(expected)", file: file, line: line)
        }
    }

    static func report() -> Never {
        if failures.isEmpty {
            print("✅ \(passed) checks passed")
            exit(0)
        }
        print("❌ \(failures.count) failed, \(passed) passed\n")
        failures.forEach { print("  \($0)") }
        exit(1)
    }
}
