import MacVisioInfrastructure
import XCTest
@testable import MacVisio

final class LifecycleJobTests: XCTestCase {
    func testMainRunLoopHeartbeatContinuesWhileOwnedInputIsBlocked() throws {
        let service = LifecycleJobService(maximumConcurrent:1,maximumOutstanding:1)
        let started = expectation(description:"Worker started")
        let heartbeat = expectation(description:"Main heartbeat ran before worker release")
        let completed = expectation(description:"Job completed")
        let release = DispatchSemaphore(value:0)
        try service.submit(kind:.open,input:input(),work:{ _ in
            started.fulfill()
            guard release.wait(timeout:.now()+5) == .success else { throw TestError.timeout }
            return 1
        },completion:{ result in XCTAssertEqual(try? result.get(),1);completed.fulfill() })
        wait(for:[started],timeout:5)
        DispatchQueue.main.async { heartbeat.fulfill();release.signal() }
        wait(for:[heartbeat,completed],timeout:5)
    }

    private func input(ownerID: UUID = UUID(), revision: UInt64 = 1) -> LifecycleJobInput {
        LifecycleJobInput(ownerID: ownerID, snapshotID: UUID(), revision: revision)
    }

    func testWorkerAndOutstandingBoundsIncludePendingDelivery() throws {
        let service = LifecycleJobService(maximumConcurrent: 2, maximumOutstanding: 2)
        let started = expectation(description: "Two workers started")
        started.expectedFulfillmentCount = 2
        let completed = expectation(description: "Two jobs delivered")
        completed.expectedFulfillmentCount = 2
        let release = DispatchSemaphore(value: 0)
        for _ in 0..<2 {
            try service.submit(kind: .open, input: input(), work: { _ in
                XCTAssertFalse(Thread.isMainThread)
                started.fulfill()
                guard release.wait(timeout: .now() + 5) == .success else { throw TestError.timeout }
                return 7
            }, completion: { result in
                XCTAssertTrue(Thread.isMainThread)
                XCTAssertEqual(try? result.get(), 7)
                completed.fulfill()
            })
        }
        wait(for: [started], timeout: 5)
        XCTAssertEqual(service.statistics.running, 2)
        XCTAssertThrowsError(try service.submit(kind: .open, input: input(), work: { _ in 0 }, completion: { _ in
            XCTFail("A rejected job cannot deliver a result")
        })) { XCTAssertEqual($0 as? LifecycleJobError, .queueFull) }
        release.signal()
        release.signal()
        wait(for: [completed], timeout: 5)
        XCTAssertEqual(service.statistics.peakRunning, 2)
        XCTAssertEqual(service.statistics.outstanding, 0)
        XCTAssertEqual(service.statistics.completed, 2)
    }

    func testCancelledQueuedWorkDoesNotRunAndOwnerCancellationIsScoped() throws {
        let service = LifecycleJobService(maximumConcurrent: 1, maximumOutstanding: 3)
        let started = expectation(description: "First worker started")
        let completed = expectation(description: "All jobs completed once")
        completed.expectedFulfillmentCount = 3
        let release = DispatchSemaphore(value: 0)
        let owner = UUID()
        try service.submit(kind: .open, input: input(), work: { _ in
            started.fulfill()
            guard release.wait(timeout: .now() + 5) == .success else { throw TestError.timeout }
            return 1
        }, completion: { result in
            XCTAssertEqual(try? result.get(), 1)
            completed.fulfill()
        })
        wait(for: [started], timeout: 5)
        try service.submit(kind: .library, input: input(ownerID: owner), work: { _ -> Int in
            XCTFail("Cancelled queued input must not be read")
            return 2
        }, completion: { result in
            XCTAssertEqual(result.failure as? LifecycleJobError, .cancelled)
            completed.fulfill()
        })
        try service.submit(kind: .library, input: input(), work: { _ in 3 }, completion: { result in
            XCTAssertEqual(try? result.get(), 3)
            completed.fulfill()
        })
        service.cancel(ownerID: owner)
        release.signal()
        wait(for: [completed], timeout: 5)
        XCTAssertEqual(service.statistics.completed, 3)
    }

    func testCancellationAfterWorkBeforeMainDeliveryDiscardsSuccessfulResult() throws {
        let service = LifecycleJobService(maximumConcurrent: 1, maximumOutstanding: 1)
        let finishedWork = DispatchSemaphore(value: 0)
        let completed = expectation(description: "Cancellation delivered")
        let handle = try service.submit(kind: .export, input: input(), work: { _ in
            finishedWork.signal()
            return "obsolete output"
        }, completion: { result in
            XCTAssertEqual(result.failure as? LifecycleJobError, .cancelled)
            completed.fulfill()
        })
        XCTAssertEqual(finishedWork.wait(timeout: .now() + 5), .success)
        handle.cancel()
        wait(for: [completed], timeout: 5)
    }

    func testRevisionGateRejectsStaleResultAndSuppressesProgress() throws {
        let service = LifecycleJobService(maximumConcurrent: 1, maximumOutstanding: 1)
        let finishedWork = DispatchSemaphore(value: 0)
        let completed = expectation(description: "Stale input delivered")
        var current = true
        let submitted = input(revision: 7)
        try service.submit(kind: .conversion, input: submitted, accepts: { candidate in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(candidate, submitted)
            return current
        }, progress: { _ in XCTFail("Stale progress must not update the current UI") }, work: { context in
            context.progress("Converting", fraction: 0.5)
            finishedWork.signal()
            return 123
        }, completion: { result in
            XCTAssertEqual(result.failure as? LifecycleJobError, .staleInput)
            completed.fulfill()
        })
        XCTAssertEqual(finishedWork.wait(timeout: .now() + 5), .success)
        current = false
        wait(for: [completed], timeout: 5)
    }

    func testCancellationHandlersAreOneShotAndLateHandlersRunImmediately() {
        let cancellation = LifecycleJobCancellation()
        var calls = 0
        let removed = cancellation.onCancel { XCTFail("Removed handler must not run") }
        cancellation.removeHandler(removed)
        cancellation.onCancel { calls += 1 }
        cancellation.cancel()
        cancellation.cancel()
        cancellation.onCancel { calls += 1 }
        XCTAssertEqual(calls, 2)
        XCTAssertThrowsError(try cancellation.check()) {
            XCTAssertEqual($0 as? LifecycleJobError, .cancelled)
        }
    }

    private enum TestError: Error { case timeout }
}

private extension Result {
    var failure: Error? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
