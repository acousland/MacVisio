import Foundation
import os.signpost

/// Explicit, process-local qualification runs. Only typed stage names, counts and
/// monotonic durations are retained; document identifiers and contents never enter
/// this collector. Timing is inclusive: nested stages must not be added together.
enum PerformanceEvidence {
    enum Stage:String,CaseIterable,Codable {
        case open,event,commit,calculation,textLayout,scenePreparation,route,draw,snapshot,encoding,save,close,mainLoopGap
        var signpostName:StaticString {
            switch self {
            case .open:return "open"
            case .event:return "event"
            case .commit:return "commit"
            case .calculation:return "calculation"
            case .textLayout:return "textLayout"
            case .scenePreparation:return "scenePreparation"
            case .route:return "route"
            case .draw:return "draw"
            case .snapshot:return "snapshot"
            case .encoding:return "encoding"
            case .save:return "save"
            case .close:return "close"
            case .mainLoopGap:return "mainLoopGap"
            }
        }
    }
    enum Counter:String,Codable,CaseIterable {
        case visitedObjects,evaluatedCells,drawnObjects,sceneObjectsPrepared
        case routeRequests,orthogonalRouteSearches,textMeasurements
        case transactionsCommitted,snapshotsCaptured,encodedDocuments,heartbeatSamples
        case renderCandidates,runtimeNodeVisits,runtimeEdgeVisits,renderRoutesPrepared
        case inputComparisonNodes,dependencySourcesCompared,hostNodesPrepared
    }
    struct StageSummary:Codable {
        var count:Int = 0
        var totalSeconds:Double = 0
        var maxSeconds:Double = 0
        var samplesSeconds:[Double] = []
        var droppedSamples:Int = 0
        fileprivate mutating func append(seconds:Double) {
            let duration = max(0,seconds)
            count += 1;totalSeconds += duration;maxSeconds = max(maxSeconds,duration)
            if samplesSeconds.count < PerformanceEvidence.sampleLimit { samplesSeconds.append(duration) }
            else { droppedSamples += 1 }
        }
    }
    struct Report:Codable {
        let schemaVersion:Int
        let runID:UUID
        let elapsedSeconds:Double
        let stages:[String:StageSummary]
        let workCounts:[String:Int]
        let unfinishedSpans:Int
        let heartbeatIntervalSeconds:Double?
        func jsonObject() throws -> Any {
            try JSONSerialization.jsonObject(with:JSONEncoder().encode(self))
        }
    }
    struct Span {
        fileprivate let runID:UUID
        fileprivate let id:UUID
        fileprivate let stage:Stage
        fileprivate let started:Double
        fileprivate let signpostID:OSSignpostID
    }
    private struct Run {
        let id:UUID
        let started:Double
        let heartbeatInterval:Double?
        var lastHeartbeat:Double
        var stages:[String:StageSummary] = [:]
        var counts:[String:Int] = [:]
        var spans:[UUID:Span] = [:]
        var timer:DispatchSourceTimer?
    }
    private static let lock = NSLock()
    private static let log = OSLog(subsystem:"com.macvisio.qualification",category:"PerformanceEvidence")
    private static var active:Run?
    // Bound profiler memory even for a long accidental run. Counts/totals/maxima
    // remain complete; reports make truncated raw samples explicit.
    private static let sampleLimit = 10_000

    /// Returns nil for overlapping runs or invalid intervals; never resets an
    /// existing run. A nil interval leaves heartbeat sampling disabled.
    @discardableResult static func beginRun(heartbeatInterval:Double? = nil) -> UUID? {
        if let interval = heartbeatInterval,(!interval.isFinite || interval <= 0) { return nil }
        lock.lock();defer { lock.unlock() }
        guard active == nil else { return nil }
        let id = UUID(),now = ProcessInfo.processInfo.systemUptime
        var run = Run(id:id,started:now,heartbeatInterval:heartbeatInterval,lastHeartbeat:now)
        if let interval = heartbeatInterval {
            let timer = DispatchSource.makeTimerSource(queue:.main)
            timer.schedule(deadline:.now()+interval,repeating:interval)
            timer.setEventHandler { recordHeartbeat(id,at:ProcessInfo.processInfo.systemUptime) }
            run.timer = timer
        }
        active = run
        run.timer?.resume()
        return id
    }
    static func endRun(_ id:UUID) -> Report? {
        lock.lock()
        guard let run = active,run.id == id else { lock.unlock();return nil }
        active = nil
        lock.unlock()
        run.timer?.cancel()
        for span in run.spans.values {
            os_signpost(.end,log:log,name:span.stage.signpostName,signpostID:span.signpostID)
        }
        return Report(schemaVersion:1,runID:id,elapsedSeconds:ProcessInfo.processInfo.systemUptime-run.started,
            stages:run.stages,workCounts:run.counts,unfinishedSpans:run.spans.count,heartbeatIntervalSeconds:run.heartbeatInterval)
    }
    static func begin(_ stage:Stage) -> Span? {
        lock.lock();defer { lock.unlock() }
        guard let runID = active?.id else { return nil }
        let span = Span(runID:runID,id:UUID(),stage:stage,started:ProcessInfo.processInfo.systemUptime,signpostID:OSSignpostID(log:log))
        active?.spans[span.id] = span
        os_signpost(.begin,log:log,name:stage.signpostName,signpostID:span.signpostID)
        return span
    }
    static func end(_ span:Span?) {
        guard let span else { return }
        lock.lock();defer { lock.unlock() }
        guard active?.id == span.runID,active?.spans.removeValue(forKey:span.id) != nil else { return }
        append(span.stage,seconds:ProcessInfo.processInfo.systemUptime-span.started)
        os_signpost(.end,log:log,name:span.stage.signpostName,signpostID:span.signpostID)
    }
    static func measure<T>(_ stage:Stage,_ body:() throws -> T) rethrows -> T {
        let span = begin(stage);defer { end(span) }
        return try body()
    }
    static func count(_ counter:Counter,by amount:Int = 1) {
        guard amount > 0 else { return }
        lock.lock();defer { lock.unlock() }
        guard active != nil else { return }
        active?.counts[counter.rawValue,default:0] += amount
    }
    private static func append(_ stage:Stage,seconds:Double) {
        active?.stages[stage.rawValue,default:StageSummary()].append(seconds:seconds)
    }
    private static func recordHeartbeat(_ id:UUID,at now:Double) {
        lock.lock();defer { lock.unlock() }
        guard active?.id == id,let interval = active?.heartbeatInterval,let previous = active?.lastHeartbeat else { return }
        append(.mainLoopGap,seconds:now-previous-interval)
        active?.lastHeartbeat = now
        active?.counts[Counter.heartbeatSamples.rawValue,default:0] += 1
        os_signpost(.event,log:log,name:"mainLoopHeartbeat")
    }
}
