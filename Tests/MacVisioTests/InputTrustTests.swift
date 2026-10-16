import Foundation
import Darwin
import XCTest
@testable import MacVisio

final class InputTrustTests: XCTestCase {
    func testXMLRejectsDTDExternalEntitiesInvalidEncodingAndOversizedParts() throws {
        let forbidden = [
            "<!DOCTYPE x [<!ENTITY secret SYSTEM 'file:///etc/passwd'>]><x>&secret;</x>",
            "<!doctype x SYSTEM 'https://127.0.0.1:1/private'><x/>",
            "<!ENTITY secret 'private'><x/>"
        ]
        for xml in forbidden {
            XCTAssertThrowsError(try VisioXML.document(Data(xml.utf8)))
        }
        XCTAssertThrowsError(try VisioXML.document(Data([0xFF, 0xFE, 0x00])))
        XCTAssertThrowsError(try VisioXML.document(Data(repeating: 0x20, count: VisioPackage.partLimit + 1)))
    }

    func testXMLStreamingPreflightEnforcesDepthAndNodeBudgets() throws {
        let allowed = String(repeating: "<x>", count: 100) + String(repeating: "</x>", count: 100)
        XCTAssertNotNil(try VisioXML.document(Data(allowed.utf8)).rootElement())
        let deep = "<x>" + allowed + "</x>"
        XCTAssertThrowsError(try VisioXML.document(Data(deep.utf8)))
        let wide = "<root>" + String(repeating: "<x/>", count: 500_000) + "</root>"
        XCTAssertThrowsError(try VisioXML.document(Data(wide.utf8)))
    }

    func testPreflightKeepsOrderedWhitespaceAndUnicodeTextRuns() throws {
        let xml = "<PageContents><Shapes><Shape><Text>א🙂<cp IX='2'/>  <cp IX='4'/>e\u{301}</Text></Shape></Shapes></PageContents>"
        let document = try VisioXML.document(Data(xml.utf8))
        let text = try XCTUnwrap(document.rootElement()?.firstLocal("Shapes")?.firstLocal("Shape")?.firstLocal("Text"))
        XCTAssertEqual(text.stringValue, "א🙂  e\u{301}")
        XCTAssertEqual(text.children?.count, 5)
        XCTAssertEqual(text.children?[2].stringValue, "  ")
    }

    func testPackageTargetsCannotEscapeOrBecomeExternalResources() throws {
        for target in ["../../../private.xml", "https://127.0.0.1:1/private.xml", "file:///etc/passwd", "..%2F..%2F..%2Fprivate.xml", "a%3Ab", "a\\b", "part.xml#secret", "part.xml?token=secret"] {
            XCTAssertThrowsError(try VisioFormat.resolve(target, relativeTo: "visio/pages/page1.xml"), target)
        }
        XCTAssertEqual(try VisioFormat.resolve("../media/image1.png", relativeTo: "visio/pages/page1.xml"), "visio/media/image1.png")
        for name in ["../escape", "/absolute", "a/./b", "a/../b", "a\\b", "a:b", "a\u{0}b"] {
            XCTAssertThrowsError(try VisioPackage.validatePath(name), name)
        }
    }

    func testCompoundCorruptionFailsWithoutFollowingAllocationCycles() throws {
        var data = try CompoundFile(streams: ["probe": Data(repeating: 1, count: 5000)]).encoded()
        // Header directory sector points beyond any sector in the document.
        data.set(UInt32.max - 5, at: 48)
        XCTAssertThrowsError(try CompoundFile.read(data))
        XCTAssertThrowsError(try CompoundFile.read(CompoundFile.signature))
    }

    func testActionFunctionsAndExcessiveFormulaNestingHaveNoExecutionPath() throws {
        for formula in ["RUNADDON(\"touch /tmp/MacVisio-untrusted\")", "SHELLEXEC(\"file:///private\")", "CALLTHIS(\"UntrustedMacro\")"] {
            XCTAssertThrowsError(try ShapeSheet.evaluate(formula, resolve: { _ in 0 }))
        }
        XCTAssertThrowsError(try ShapeSheet.parse(String(repeating: "(", count: 80) + "1" + String(repeating: ")", count: 80)))
    }

    func testSVGExternalResourcesAndScriptsDoNotContactLoopbackServer() throws {
        let server = try LoopbackTrustProbe()
        defer { server.stop() }
        try server.verifyObserver()
        let baseline = server.requests
        XCTAssertEqual(baseline, 1)
        let xml = """
        <svg xmlns="http://www.w3.org/2000/svg" width="200pt" height="100pt">
          <script href="\(server.url)/script.js">untrusted()</script>
          <image x="0" y="0" width="20" height="20" href="\(server.url)/private.png"/>
          <image x="20" y="0" width="20" height="20" href="file:///private/secret.png"/>
          <rect x="40" y="0" width="20" height="20" fill="#112233"/>
        </svg>
        """
        let result = try SVGImport.page(Data(xml.utf8), name: "External resources")
        XCTAssertEqual(result.page.nodes.count, 1)
        XCTAssertTrue(result.page.nodes.allSatisfy { $0.formatting.image == nil })
        XCTAssertTrue(result.warnings.contains { $0.contains("embedded data") })
        // Give any mistakenly scheduled asynchronous request time to arrive.
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertEqual(server.requests, baseline, "Import must not fetch external SVG scripts or images.")
    }

    func testOpeningImportedActionPreservesSourceWithoutLaunchingIt() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacVisio-trust-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("executed")
        let executable = directory.appendingPathComponent("untrusted.sh")
        try Data("#!/bin/sh\ntouch '\(marker.path)'\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        var diagram = Diagram()
        diagram.page.nodes = [DiagramNode(kind: .rectangle, x: 30, y: 40, text: "Safe cached label")]
        let source = directory.appendingPathComponent("action.vsdx")
        try VisioFormat.write(diagram, to: source)
        var parts = try VisioPackage.read(source)
        parts.removeValue(forKey: "macvisio/document.json")
        let pagePart = "visio/pages/page1.xml"
        var xml = String(decoding: try XCTUnwrap(parts[pagePart]), as: UTF8.self)
        let action = "<Section N=\"Actions\"><Row IX=\"0\"><Cell N=\"Action\" F=\"RUNADDON(&quot;\(executable.path)&quot;)\" V=\"0\"/></Row></Section>"
        xml = xml.replacingOccurrences(of: "</Shape>", with: action + "</Shape>")
        parts[pagePart] = Data(xml.utf8)
        try VisioPackage.write(parts, to: source)
        let original = try Data(contentsOf: source)
        let imported = try VisioFormat.read(from: source)
        XCTAssertEqual(imported.diagram.page.nodes.first?.text, "Safe cached label")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertEqual(imported.diagram.visioArchive?.parts[pagePart], parts[pagePart])
        XCTAssertEqual(try Data(contentsOf: source), original)
    }
}

/// A local-only observer that responds immediately if an import accidentally
/// fetches a resource, so the negative fixture cannot hang on a network read.
private final class LoopbackTrustProbe: @unchecked Sendable {
    private let descriptor: Int32
    private let lock = NSLock()
    private var requestCount = 0
    private var isStopped = false
    private let stopped = DispatchGroup()
    let url: String
    var requests: Int { lock.lock(); defer { lock.unlock() }; return requestCount }

    init() throws {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw DiagramError.invalid("Cannot create local trust probe.") }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, length) }
        }
        guard bound == 0, listen(descriptor, 4) == 0 else {
            Darwin.close(descriptor); throw DiagramError.invalid("Cannot bind local trust probe.")
        }
        let named = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        guard named == 0 else { Darwin.close(descriptor); throw DiagramError.invalid("Cannot identify local trust probe.") }
        _ = fcntl(descriptor, F_SETFL, O_NONBLOCK)
        self.descriptor = descriptor
        url = "http://127.0.0.1:\(UInt16(bigEndian: address.sin_port))"
        stopped.enter()
        DispatchQueue.global().async { [self] in
            defer { stopped.leave() }
            while true {
                lock.lock(); let shouldStop = isStopped; lock.unlock()
                if shouldStop { return }
                var watched = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
                guard poll(&watched, 1, 50) > 0 else { continue }
                let client = accept(descriptor, nil, nil)
                guard client >= 0 else { continue }
                lock.lock(); requestCount += 1; lock.unlock()
                var noPipe: Int32 = 1
                _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noPipe, socklen_t(MemoryLayout<Int32>.size))
                let response = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                response.withCString { pointer in _ = send(client, pointer, strlen(pointer), 0) }
                Darwin.close(client)
            }
        }
    }
    func verifyObserver() throws {
        let client = socket(AF_INET, SOCK_STREAM, 0)
        guard client >= 0 else { throw DiagramError.invalid("Cannot check local trust observer.") }
        defer { Darwin.close(client) }
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        _ = setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = UInt16(URL(string: url)!.port!).bigEndian
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(client, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 else { throw DiagramError.invalid("Local trust observer is not listening.") }
        var response = [UInt8](repeating: 0, count: 128)
        guard recv(client, &response, response.count, 0) > 0, requests == 1 else {
            throw DiagramError.invalid("Local trust observer did not observe its positive control.")
        }
    }
    func stop() {
        lock.lock(); isStopped = true; lock.unlock()
        _ = stopped.wait(timeout: .now() + 1)
        Darwin.close(descriptor)
    }
}
