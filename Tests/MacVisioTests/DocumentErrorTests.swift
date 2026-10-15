import AppKit
import XCTest
@testable import MacVisio

final class DocumentErrorTests:XCTestCase {
    func testSaveAlertIncludesUnderlyingDiagramFailureWithoutLosingRecoveryInformation() {
        let document = MacVisioDocument()
        let cause = DiagramError.invalid("The drawing exceeds its supported size limit.") as NSError
        let error = NSError(domain:NSCocoaErrorDomain,code:NSFileWriteUnknownError,userInfo:[
            NSLocalizedDescriptionKey:"The document could not be saved.",
            NSLocalizedRecoverySuggestionErrorKey:"Save a separate copy.",
            NSUnderlyingErrorKey:cause])
        let presented = document.willPresentError(error) as NSError
        XCTAssertEqual(presented.domain,error.domain)
        XCTAssertEqual(presented.code,error.code)
        XCTAssertEqual(presented.localizedDescription,error.localizedDescription)
        XCTAssertEqual(presented.localizedFailureReason,cause.localizedDescription)
        XCTAssertEqual(presented.localizedRecoverySuggestion,error.localizedRecoverySuggestion)
        XCTAssertEqual(presented.userInfo[NSUnderlyingErrorKey] as? NSError,cause)
    }

    func testExistingFailureReasonRemainsAvailable() {
        let document = MacVisioDocument()
        let error = NSError(domain:NSCocoaErrorDomain,code:NSFileWriteNoPermissionError,userInfo:[
            NSLocalizedDescriptionKey:"The document could not be saved.",
            NSLocalizedFailureReasonErrorKey:"The folder is read-only.",
            NSUnderlyingErrorKey:DiagramError.invalid("A more specific error.") as NSError])
        XCTAssertEqual((document.willPresentError(error) as NSError).localizedFailureReason,"The folder is read-only.")
    }
}
