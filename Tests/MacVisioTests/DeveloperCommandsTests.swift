import MacVisioInfrastructure
import AppKit
import XCTest

@testable import MacVisio

final class DeveloperCommandsTests: XCTestCase {
    func testRecognizedIncompleteCommandsProduceUsageInsteadOfNormalLaunch() {
        for flag in [
            "--convert", "--render-document", "--export-all-pdf", "--benchmark-sample", "--profile-open",
        ] {
            XCTAssertNotNil(DeveloperCommands.usageError(arguments: ["MacVisio", flag]))
            XCTAssertNotNil(DeveloperCommands.usageError(arguments: ["MacVisio", flag, "input.vsdx"]))
            XCTAssertNil(
                DeveloperCommands.usageError(arguments: ["MacVisio", flag, "input.vsdx", "output.json"]))
        }
        XCTAssertNotNil(DeveloperCommands.usageError(arguments: ["MacVisio", "--generate-examples"]))
        XCTAssertNotNil(DeveloperCommands.usageError(arguments: ["MacVisio", "--render-ui", "--compact-ui"]))
        XCTAssertNil(DeveloperCommands.usageError(arguments: ["MacVisio", "--launch-check", "--compact-ui"]))
    }

    func testAtomicConversionPreservesInputAndReplacesDestinationOnlyWithCompleteArtifact() throws {
        try withFixture { directory, input, original in
            let output = directory.appendingPathComponent("complete.vsdx")
            try Data("old destination".utf8).write(to: output)
            _ = try DeveloperCommands.processDocument(.convert, input: input, output: output)
            XCTAssertEqual(try Data(contentsOf: input), original)
            let reopened = try VisioFormat.read(from: output)
            XCTAssertEqual(reopened.diagram.page.nodes.first?.text, "Synthetic CLI")
            XCTAssertFalse(
                try FileManager.default.contentsOfDirectory(atPath: directory.path).contains {
                    $0.hasPrefix(".MacVisio-")
                })
        }
    }

    func testFailedOutputKeepsDestinationAndLeavesNoStagingFile() throws {
        try withFixture { directory, input, original in
            let output = directory.appendingPathComponent("protected.unsupported")
            let prior = Data("existing destination".utf8)
            try prior.write(to: output)
            XCTAssertThrowsError(
                try DeveloperCommands.processDocument(.convert, input: input, output: output))
            XCTAssertEqual(try Data(contentsOf: output), prior)
            XCTAssertEqual(try Data(contentsOf: input), original)
            XCTAssertFalse(
                try FileManager.default.contentsOfDirectory(atPath: directory.path).contains {
                    $0.hasPrefix(".MacVisio-")
                })
        }
    }

    func testSourceAsDestinationAndPreCancelledCommandAreRejected() throws {
        try withFixture { directory, input, original in
            XCTAssertThrowsError(try DeveloperCommands.processDocument(.render, input: input, output: input))
            {
                XCTAssertEqual($0 as? LifecycleJobError, .inputIsDestination)
            }
            XCTAssertEqual(try Data(contentsOf: input), original)
            let cancellation = LifecycleJobCancellation()
            cancellation.cancel()
            let output = directory.appendingPathComponent("cancelled.pdf")
            XCTAssertThrowsError(
                try DeveloperCommands.processDocument(
                    .exportAllPDF, input: input, output: output, cancellation: cancellation)
            ) {
                XCTAssertEqual($0 as? LifecycleJobError, .cancelled)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        }
    }

    private func withFixture(_ body: @escaping (URL, URL, Data) throws -> Void) throws {
        func run() throws {
            _ = NSApplication.shared
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                "MacVisio-cli-test-\(UUID())")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: directory) }
            var diagram = Diagram()
            diagram.page.nodes = [DiagramNode(text: "Synthetic CLI")]
            let data = try JSONEncoder().encode(diagram)
            let input = directory.appendingPathComponent("input.macvisio")
            try data.write(to: input)
            try body(directory, input, data)
        }
        if Thread.isMainThread { try run() } else { try DispatchQueue.main.sync(execute: run) }
    }
}
