import Darwin
import Foundation
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

    func testTimeoutTerminatesAHelperThatIgnoresSIGTERM() throws {
        let fixture = try ProcessFixture()
        defer { fixture.cleanUp() }
        let start = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try LegacyConverterProcess.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "trap '' TERM; printf '%s' \"$$\" > \"$1/helper.pid\"; while :; do :; done", "fixture", fixture.directory.path],
            timeout: 0.1)) {
            XCTAssertEqual($0 as? LegacyConverterError, .timedOut)
        }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 3)
        XCTAssertNotNil(fixture.pid("helper"))
        XCTAssertTrue(fixture.waitForExit("helper"), "The owned helper must receive the SIGKILL escalation.")
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

    func testDeadlineReturnsAfterParentExitsWhileDescendantRetainsStdout() throws {
        let fixture = try ProcessFixture()
        defer { fixture.cleanUp() }
        let start = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try LegacyConverterProcess.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: fixture.stdoutHolderArguments,
            timeout: 0.3)) {
            XCTAssertEqual($0 as? LegacyConverterError, .timedOut)
        }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 3)
        XCTAssertNotNil(fixture.pid("parent"))
        XCTAssertFalse(fixture.isRunning("parent"), "The deadline must remain active after the direct parent exits.")
        XCTAssertTrue(fixture.isRunning("child"), "The fixture must actually retain stdout in a live descendant.")
    }

    func testCancellationReturnsAfterParentExitsWhileDescendantRetainsStdout() throws {
        let fixture = try ProcessFixture()
        defer { fixture.cleanUp() }
        let cancellation = LifecycleJobCancellation()
        let observedExit = expectation(description: "Parent exited with its child's stdout still open")
        DispatchQueue.global(qos: .utility).async {
            let deadline = ProcessInfo.processInfo.systemUptime + 2
            while ProcessInfo.processInfo.systemUptime < deadline {
                if fixture.pid("parent") != nil, !fixture.isRunning("parent"), fixture.isRunning("child") {
                    observedExit.fulfill()
                    cancellation.cancel()
                    return
                }
                usleep(1000)
            }
            cancellation.cancel()
        }
        let start = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try LegacyConverterProcess.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: fixture.stdoutHolderArguments,
            cancellation: cancellation, timeout: 5)) {
            XCTAssertEqual($0 as? LifecycleJobError, .cancelled)
        }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 3)
        wait(for: [observedExit], timeout: 0.1)
        XCTAssertFalse(fixture.isRunning("parent"))
        XCTAssertTrue(fixture.isRunning("child"))
    }

    func testOutputLimitEscalatesForOwnedHelperIgnoringTERMAndPIPE() throws {
        let fixture = try ProcessFixture()
        defer { fixture.cleanUp() }
        let start = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try LegacyConverterProcess.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: [
                "-c",
                "trap '' TERM PIPE; printf '%s' \"$$\" > \"$1/helper.pid\"; while :; do printf 'too much output'; done",
                "fixture", fixture.directory.path,
            ],
            maximumOutputBytes: 3)) {
            XCTAssertEqual($0 as? LegacyConverterError, .outputLimit)
        }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 3)
        XCTAssertNotNil(fixture.pid("helper"))
        XCTAssertTrue(fixture.waitForExit("helper"), "Output refusal must still stop the owned helper.")
    }

    private struct ProcessFixture {
        let directory: URL

        init() throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("MacVisioConverter-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        var stdoutHolderArguments: [String] {
            [
                "-c",
                """
                printf '%s' "$$" > "$1/parent.pid"
                /bin/sh -c 'printf "%s" "$$" > "$1/child.pid"; exec /bin/sleep 10' fixture-child "$1" &
                while [ ! -s "$1/child.pid" ]; do :; done
                exit 0
                """,
                "fixture-parent", directory.path,
            ]
        }

        func pid(_ name: String) -> pid_t? {
            guard let value = try? String(contentsOf: directory.appendingPathComponent("\(name).pid"), encoding: .utf8),
                  let pid = Int32(value), pid > 0
            else { return nil }
            return pid
        }

        func isRunning(_ name: String) -> Bool {
            guard let pid = pid(name) else { return false }
            return kill(pid, 0) == 0 || errno == EPERM
        }

        func waitForExit(_ name: String) -> Bool {
            let deadline = ProcessInfo.processInfo.systemUptime + 2
            while isRunning(name), ProcessInfo.processInfo.systemUptime < deadline { usleep(1000) }
            return !isRunning(name)
        }

        func cleanUp() {
            // Only PIDs recorded by this fixture's literal scripts are signalled.
            // The production wrapper deliberately does not kill descendants.
            for name in ["child", "helper", "parent"] {
                if let pid = pid(name), isRunning(name) { _ = kill(pid, SIGKILL) }
            }
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
