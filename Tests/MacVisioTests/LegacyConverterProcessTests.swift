import MacVisioInfrastructure
import XCTest
@testable import MacVisio

final class LegacyConverterProcessTests: XCTestCase {
    func testOutputFailureAndByteLimitsAreStructured() throws {
        let shell = URL(fileURLWithPath: "/bin/sh")
        XCTAssertEqual(try LegacyConverterProcess.run(executable: shell, arguments: ["-c", "printf output"]), Data("output".utf8))
        XCTAssertThrowsError(try LegacyConverterProcess.run(executable: shell, arguments: ["-c", "exit 7"])) {
            XCTAssertEqual($0 as? LegacyConverterError, .failed(7))
        }
        XCTAssertThrowsError(try LegacyConverterProcess.run(executable: shell, arguments: ["-c", "printf 'too much output'"], maximumOutputBytes: 3)) {
            XCTAssertEqual($0 as? LegacyConverterError, .outputLimit)
        }
    }

    func testTimeoutTerminatesAHelperThatIgnoresSIGTERM() {
        let start = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try LegacyConverterProcess.run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "trap '' TERM; while :; do :; done"], timeout: 0.1)) {
            XCTAssertEqual($0 as? LegacyConverterError, .timedOut)
        }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 3)
    }

    func testCancellationInterruptsBlockedReaderWithoutWaitingForTimeout() {
        let cancellation = LifecycleJobCancellation()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { cancellation.cancel() }
        let start = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try LegacyConverterProcess.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"], cancellation: cancellation)) {
            XCTAssertEqual($0 as? LifecycleJobError, .cancelled)
        }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 3)
    }
}
