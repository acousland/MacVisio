import MacVisioInfrastructure
import XCTest
@testable import MacVisio

final class AtomicJobOutputTests: XCTestCase {
    func testFailureAndCancellationKeepValidDestinationAndRemoveStagingFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("output.svg")
        let valid = Data("valid destination".utf8)
        try valid.write(to: output)
        XCTAssertThrowsError(try AtomicJobOutput.write(to: output) { staging in
            try Data("partial".utf8).write(to: staging)
            throw ProbeError.failed
        })
        XCTAssertEqual(try Data(contentsOf: output), valid)
        let cancellation = LifecycleJobCancellation()
        XCTAssertThrowsError(try AtomicJobOutput.write(to: output, cancellation: cancellation) { staging in
            try Data("complete but cancelled".utf8).write(to: staging)
            cancellation.cancel()
        }) { XCTAssertEqual($0 as? LifecycleJobError, .cancelled) }
        XCTAssertEqual(try Data(contentsOf: output), valid)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["output.svg"])
    }

    func testSuccessfulArtifactReplacesDestinationAndInputAliasIsRejectedBeforeWork() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("output.vsdx")
        try Data("before".utf8).write(to: output)
        try AtomicJobOutput.write(to: output) { try Data("after".utf8).write(to: $0) }
        XCTAssertEqual(try Data(contentsOf: output), Data("after".utf8))
        let alias = directory.appendingPathComponent("alias.vsdx")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: output)
        XCTAssertThrowsError(try AtomicJobOutput.write(to: alias, input: output) { _ in
            XCTFail("Input/output identity must be checked before serialization")
        }) { XCTAssertEqual($0 as? LifecycleJobError, .inputIsDestination) }
        XCTAssertEqual(try Data(contentsOf: output), Data("after".utf8))
    }

    private enum ProbeError: Error { case failed }
}
