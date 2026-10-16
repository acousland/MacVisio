import AppKit
import MacVisioInfrastructure
import UniformTypeIdentifiers

@objc(MacVisioDocument)
final class MacVisioDocument: NSDocument {
    static let nativeType = "com.macvisio.diagram"
    static let visioType = "com.microsoft.visio.vsdx"
    static let legacyType = "com.microsoft.visio.vsd"
    /// Monotonic revision rejects derived results; state identity is restored by undo.
    private(set) var revision: UInt64 = 0
    private(set) var stateID = UUID()
    private var savedStateID: UUID?
    private var recoveryStateID: UUID?
    private var latestPreservationArchive: VisioDocumentArchive?
    private var preservationNilSourcePageIDs = Set<UUID>()
    let lifecycleOwnerID = UUID()
    private var documentIsClosed = false
    var diagram = Diagram() {
        didSet {
            revision &+= 1
            stateID = UUID()
            runtimeRevision = nil
        }
    }
    private var pageRuntimes: [UUID: PageRuntime] = [:]
    private var runtimeRevision: UInt64?
    private(set) var lastCommittedChange: DocumentChangeSet?
    private(set) var lastRuntimeWork: [UUID: RuntimeUpdateWork] = [:]
    private(set) var lastPresentationEvent: DocumentPresentationEvent?
    func runtime(for pageID: UUID? = nil) -> PageRuntime {
        if runtimeRevision != revision {
            pageRuntimes = [:]
            runtimeRevision = revision
        }
        let page = diagram.pages.first { $0.id == (pageID ?? diagram.activePageID) } ?? diagram.page
        if let retained = pageRuntimes[page.id] { return retained }
        let retained = PageRuntime(page: page)
        pageRuntimes[page.id] = retained
        return retained
    }
    func present(_ event: DocumentPresentationEvent) { lastPresentationEvent = event }
    func activatePage(_ id: UUID) {
        guard diagram.pages.contains(where: { $0.id == id }), diagram.activePageID != id else { return }
        let identity = stateID
        let priorRevision = revision
        let priorRuntimeRevision = runtimeRevision
        diagram.activePageID = id
        stateID = identity
        revision = priorRevision
        runtimeRevision = priorRuntimeRevision
        present(.activePageChanged(id))
    }
    override var isDocumentEdited: Bool {
        if let savedStateID { return stateID != savedStateID }
        return super.isDocumentEdited
    }
    override func updateChangeCount(_ change: NSDocument.ChangeType) {
        super.updateChangeCount(change)
        // AppKit's counter and our undo-restored snapshot identity can differ.
        // Keep every title-bar badge consistent with the document's save policy.
        for controller in windowControllers {
            controller.window?.isDocumentEdited = isDocumentEdited
        }
    }
    override var hasUnautosavedChanges: Bool {
        if let savedStateID, stateID == savedStateID { return false }
        if let recoveryStateID { return stateID != recoveryStateID }
        if let savedStateID { return stateID != savedStateID }
        return super.hasUnautosavedChanges
    }
    struct SaveEvent {
        let phase: String
        let saveID: UUID
        let snapshotStateID: UUID
        let currentStateID: UUID
        let revision: UInt64
    }
    private(set) var saveEvents: [SaveEvent] = []
    /// An exact boundary hook lets regressions force the historical timing race.
    var didCaptureSaveSnapshot: (() -> Void)?
    private func recordSave(_ phase: String, id: UUID, state: UUID) {
        saveEvents.append(
            SaveEvent(
                phase: phase, saveID: id, snapshotStateID: state,
                currentStateID: stateID, revision: revision))
        if saveEvents.count > 64 { saveEvents.removeFirst(saveEvents.count - 64) }
    }
    var importWarnings: [String] = []
    private var typedImportDiagnostics: [DocumentDiagnostic] = []
    private var retiredTypedImportMessages: Set<String> = []
    private var geometryDiagnosticsByPage: [UUID: [DocumentDiagnostic]] = [:]
    private var fieldDiagnosticsByPage: [UUID: [DocumentDiagnostic]] = [:]
    private var acceptedCalculationDiagnostics: [DocumentDiagnostic] = []
    private var supplementalDiagnostics: [DocumentDiagnostic] = []
    var diagnosticInputKey: String { "\(lifecycleOwnerID.uuidString):\(stateID.uuidString):\(revision)" }
    var currentDiagnostics: [DocumentDiagnostic] {
        let representedImportMessages = Set(typedImportDiagnostics.map(\.message))
        let imported =
            typedImportDiagnostics.map { record in
                var record = record
                record.inputKey = diagnosticInputKey
                return record
            }
            + importWarnings.filter {
                !representedImportMessages.contains($0) && !retiredTypedImportMessages.contains($0)
            }.map {
                var record = DocumentDiagnostic.legacyImportNote($0, code: "import.anonymous")
                record.inputKey = diagnosticInputKey
                record.displayState = .unavailable
                return record
            }
        let derived = (acceptedCalculationDiagnostics + supplementalDiagnostics).map { diagnostic in
            var diagnostic = diagnostic
            if diagnostic.inputKey != diagnosticInputKey { diagnostic.displayState = .stale }
            return diagnostic
        }
        let representedCalculationMessages = Set(acceptedCalculationDiagnostics.map(\.message))
        let legacy = calculationIssues.filter { !representedCalculationMessages.contains($0) }.map {
            DocumentDiagnostic(
                code: "calculation.anonymous", origin: .calculation, severity: .warning,
                dimension: .rendering, target: .document, displayState: .unavailable, message: $0,
                inputKey: diagnosticInputKey)
        }
        return imported + derived + legacy
    }
    @discardableResult func setSupplementalDiagnostics(_ records: [DocumentDiagnostic], inputKey: String)
        -> Bool
    {
        guard inputKey == diagnosticInputKey else { return false }
        supplementalDiagnostics = records.map { record in
            var record = record
            record.inputKey = inputKey
            return record
        }
        diagnosticsDidChange()
        return true
    }
    private func resetDiagnosticsForRead() {
        typedImportDiagnostics = []
        retiredTypedImportMessages = []
        importWarnings = []
        acceptedCalculationDiagnostics = []
        supplementalDiagnostics = []
        calculationIssues = []
        geometryIssuesByPage = [:]
        fieldIssuesByPage = [:]
        geometryDiagnosticsByPage = [:]
        fieldDiagnosticsByPage = [:]
        calculationSession = CalculationSession()
    }
    private func publishCalculationDiagnostics() {
        acceptedCalculationDiagnostics = diagram.pages.flatMap { page in
            (geometryDiagnosticsByPage[page.id] ?? []) + (fieldDiagnosticsByPage[page.id] ?? [])
        }.map { record in
            var record = record
            record.inputKey = diagnosticInputKey
            return record
        }
        diagnosticsDidChange()
    }
    private func diagnosticsDidChange() {
        NotificationCenter.default.post(name: .macVisioDiagnosticsDidChange, object: self)
        for case let editor as EditorWindowController in windowControllers where editor.root != nil {
            editor.updateStatus()
        }
    }
    var issuesController: DocumentIssuesController?
    private var saveImpactBaseline: DocumentSaveImpact.Baseline?
    private(set) var lastSaveImpact = DocumentSaveImpact.Assessment(risks: [])
    /// Tests can select a concrete copy destination without interacting with sheets.
    var resolveSaveImpact: ((DocumentSaveImpact.Assessment) -> DocumentSaveImpact.Resolution)?
    private var policyAdmittedSaveID: UUID?
    var calculationIssues: [String] = []
    private var geometryIssuesByPage: [UUID: [String]] = [:]
    private var pendingCalculation: LifecycleJobHandle?
    private var editorCalculationAttempt: UInt64 = 0
    var isCalculating: Bool { pendingCalculation != nil }
    private(set) var lastCalculationJobError: Error?
    func cancelPendingCalculation() { pendingCalculation?.cancel() }
    private var fieldIssuesByPage: [UUID: [String]] = [:]
    private var calculationSession = CalculationSession()
    private(set) var lastCalculationWork = CalculationWork()
    let undoPayloadBudget = UndoPayloadBudget()
    private(set) var lastUndoBudgetDecision: UndoPayloadBudget.Decision?
    var legacyNative = false
    weak var documentWorkflow: DocumentWorkflow?
    private struct SaveSnapshot {
        let id: UUID
        let stateID: UUID
        let diagram: Diagram
    }
    private struct SaveArtifact {
        let id: UUID
        let archive: VisioDocumentArchive
        let sourceDiagnostics: [DocumentDiagnostic]?
    }
    private struct QueuedSave {
        let id: UUID
        let url: URL
        let typeName: String
        let operation: NSDocument.SaveOperationType
        let completion: (Error?) -> Void
    }
    private let saveSnapshotLock = NSLock()
    private var pendingSaveSnapshot: SaveSnapshot?
    private var activeAsyncSaveID: UUID?
    private var serializedSaveArtifact: SaveArtifact?
    private var sourceFileVersion: DocumentSourceVersion?
    private var unverifiedSavedSourceURL: URL?
    private var activeSaveSourceCheck: (id: UUID, version: DocumentSourceVersion)?
    private var queuedSaves: [QueuedSave] = []
    private var saveAwaitingTextCalculation: (request: QueuedSave, calculationID: UUID)?
    private var saveAwaitingImpactResolution: QueuedSave?
    private var saveDrainScheduled = false
    private var saveInProgress = false
    private var finalizingTextForSave = false
    private struct CloseRequest {
        let delegate: Any
        let selector: Selector?
        let context: UnsafeMutableRawPointer?
    }
    private var closeAwaitingTextCalculation: (request: CloseRequest, calculationID: UUID)?
    private var finalizingTextForClose = false
    /// A boundary hook keeps close-admission races reproducible after the text
    /// transaction and its undo notifications have finished.
    var didAcceptTextForClose: (() -> Void)?
    override class var autosavesInPlace: Bool { true }
    override class var writableTypes: [String] { [visioType, nativeType, legacyType] }
    override class var readableTypes: [String] { [visioType, legacyType, nativeType] }
    override class func canConcurrentlyReadDocuments(ofType typeName: String) -> Bool {
        // These readers construct value models with Foundation/XML only. AppKit
        // creates and presents their editor windows on the main thread afterward.
        typeName == visioType || typeName == nativeType
    }
    override init() {
        super.init()
        hasUndoManager = true
        undoManager?.levelsOfUndo = ResourceBudgets.undoCount
    }
    override func makeWindowControllers() {
        let controller = EditorWindowController(document: self)
        addWindowController(controller)
    }
    override func data(ofType typeName: String) throws -> Data {
        let snapshot: Diagram
        let saveID: UUID?
        if Thread.isMainThread {
            saveSnapshotLock.lock()
            let prepared = pendingSaveSnapshot
            saveSnapshotLock.unlock()
            if let prepared {
                snapshot = prepared.diagram
                saveID = prepared.id
            } else {
                let pendingBefore = pendingCalculation?.id
                let attemptBefore = editorCalculationAttempt
                commitTextEditing()
                if pendingBefore == nil, editorCalculationAttempt != attemptBefore {
                    if let error = lastCalculationJobError { throw error }
                    guard pendingCalculation == nil else {
                        throw DiagramError.invalid(
                            "Text is still being calculated. Save the drawing after that calculation finishes."
                        )
                    }
                }
                snapshot = PerformanceEvidence.measure(.snapshot) {
                    PerformanceEvidence.count(.snapshotsCaptured)
                    return diagram
                }
                saveID = nil
            }
        } else {
            saveSnapshotLock.lock()
            let saved = activeAsyncSaveID.flatMap { id in
                pendingSaveSnapshot.flatMap { $0.id == id ? $0 : nil }
            }
            if saved != nil { pendingSaveSnapshot = nil }
            saveSnapshotLock.unlock()
            guard let saved else {
                unblockUserInteraction()
                throw DiagramError.invalid("The document has no prepared snapshot for background saving.")
            }
            snapshot = saved.diagram
            saveID = saved.id
            unblockUserInteraction()
        }
        let bytes = try data(ofType: typeName, diagram: snapshot, saveID: saveID)
        PerformanceEvidence.count(.encodedDocuments)
        return bytes
    }
    private func data(ofType typeName: String, diagram snapshot: Diagram, saveID: UUID?) throws -> Data {
        let evidence = PerformanceEvidence.begin(.encoding)
        defer { PerformanceEvidence.end(evidence) }
        if typeName == Self.legacyType { return try VSDBinaryFormat.encoded(snapshot) }
        if typeName == Self.visioType {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(
                "MacVisio-save-\(UUID()).vsdx")
            defer { try? FileManager.default.removeItem(at: url) }
            let archive = try VisioFormat.writeRebased(snapshot, to: url)
            let data = try Data(contentsOf: url)
            if let saveID {
                var sourceSnapshot = snapshot
                sourceSnapshot.visioArchive = archive
                // NSDocument normally owns background encoding. A synchronous
                // fallback must not introduce a full source scan on main.
                let sourceDiagnostics =
                    Thread.isMainThread ? nil : ImportedSourceDiagnostics.scan(sourceSnapshot)
                saveSnapshotLock.lock()
                serializedSaveArtifact = SaveArtifact(
                    id: saveID, archive: archive, sourceDiagnostics: sourceDiagnostics)
                saveSnapshotLock.unlock()
            }
            return data
        }
        guard typeName == Self.nativeType else {
            throw DiagramError.invalid("This file type cannot be written.")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(snapshot.validated())
    }
    override func read(from data: Data, ofType typeName: String) throws {
        let evidence = PerformanceEvidence.begin(.open)
        defer { PerformanceEvidence.end(evidence) }
        guard data.count <= 256_000_000 else {
            throw DiagramError.invalid("This diagram exceeds the supported document size.")
        }
        if typeName == Self.legacyType {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(
                "MacVisio-read-\(UUID()).vsd")
            defer { try? FileManager.default.removeItem(at: url) }
            try data.write(to: url)
            let result = try LegacyVisioFormat.read(from: url)
            resetDiagnosticsForRead()
            diagram = result.diagram
            importWarnings = result.warnings
            typedImportDiagnostics =
                result.diagnostics
                + ImagePreviewDiagnostics.records(in: result.diagram).filter { record in
                    !result.diagnostics.contains(where: { $0.id == record.id })
                }
            legacyNative = result.legacyNative
            saveImpactBaseline = .init(snapshot: diagram)
            return
        }
        if typeName == Self.visioType {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(
                "MacVisio-read-\(UUID()).vsdx")
            defer { try? FileManager.default.removeItem(at: url) }
            try data.write(to: url)
            let result = try VisioFormat.read(from: url)
            resetDiagnosticsForRead()
            diagram = result.diagram
            importWarnings = result.warnings
            typedImportDiagnostics = result.diagnostics
            legacyNative = false
            saveImpactBaseline = .init(snapshot: diagram)
            return
        }
        let loaded = GeometrySheet.refreshCompositeCaches(
            try JSONDecoder().decode(Diagram.self, from: data).validated())
        resetDiagnosticsForRead()
        diagram = loaded
        typedImportDiagnostics = ImportedSourceDiagnostics.scan(loaded)
        legacyNative = false
        saveImpactBaseline = .init(snapshot: diagram)
    }
    override func read(from url: URL, ofType typeName: String) throws {
        let evidence = PerformanceEvidence.begin(.open)
        defer { PerformanceEvidence.end(evidence) }
        let version = try DocumentSourceVersion.read(url)
        guard try version.url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw DiagramError.invalid("Choose a regular drawing file.")
        }
        let loaded: Diagram
        let warnings: [String]
        let typedDiagnostics: [DocumentDiagnostic]
        let isLegacy: Bool
        if ["vsd", "vst"].contains(url.pathExtension.lowercased()) || typeName == Self.legacyType {
            let result = try LegacyVisioFormat.read(from: version.url)
            loaded = result.diagram
            warnings = result.warnings
            typedDiagnostics =
                result.diagnostics
                + ImagePreviewDiagnostics.records(in: loaded).filter { record in
                    !result.diagnostics.contains(where: { $0.id == record.id })
                }
            isLegacy = result.legacyNative
        } else if ["vsdx", "vstx"].contains(url.pathExtension.lowercased()) || typeName == Self.visioType {
            let result = try VisioFormat.read(from: version.url)
            loaded = try result.diagram.validated()
            warnings = result.warnings
            typedDiagnostics = result.diagnostics
            isLegacy = false
        } else {
            guard version.bytes <= 256_000_000 else {
                throw DiagramError.invalid("This diagram exceeds the supported document size.")
            }
            let data = try Data(contentsOf: version.url, options: .mappedIfSafe)
            guard data.count <= 256_000_000 else {
                throw DiagramError.invalid("This diagram exceeds the supported document size.")
            }
            loaded = GeometrySheet.refreshCompositeCaches(
                try JSONDecoder().decode(Diagram.self, from: data).validated())
            warnings = []
            typedDiagnostics = ImportedSourceDiagnostics.scan(loaded)
            isLegacy = false
        }
        try version.check(contentsAt: url)
        resetDiagnosticsForRead()
        diagram = loaded
        importWarnings = warnings
        typedImportDiagnostics = typedDiagnostics
        legacyNative = isLegacy
        saveImpactBaseline = .init(snapshot: diagram)
        saveSnapshotLock.lock()
        sourceFileVersion = version
        unverifiedSavedSourceURL = nil
        saveSnapshotLock.unlock()
    }
    override func revert(toContentsOf url: URL, ofType typeName: String) throws {
        guard !saveInProgress else {
            throw DiagramError.invalid("Wait for the current save to finish before reverting the drawing.")
        }
        cancelPendingCalculation()
        try super.revert(toContentsOf: url, ofType: typeName)
        savedStateID = stateID
        recoveryStateID = stateID
        latestPreservationArchive = diagram.visioArchive
        preservationNilSourcePageIDs = []
        calculationSession = CalculationSession()
        calculationIssues = []
        geometryIssuesByPage = [:]
        fieldIssuesByPage = [:]
        geometryDiagnosticsByPage = [:]
        fieldDiagnosticsByPage = [:]
        acceptedCalculationDiagnostics = []
        supplementalDiagnostics = []
        diagnosticsDidChange()
        pageRuntimes = [:]
        runtimeRevision = nil
        lastCommittedChange = nil
        lastRuntimeWork = [:]
        undoPayloadBudget.invalidateCurrentEstimate()
        let abandoned = queuedSaves
        queuedSaves.removeAll()
        abandoned.forEach { $0.completion(LifecycleJobError.cancelled) }
        for controller in windowControllers { (controller as? EditorWindowController)?.refresh() }
    }
    override func write(to url: URL, ofType typeName: String) throws {
        let ext = url.pathExtension.lowercased()
        guard (ext != "vsd" || typeName == Self.legacyType), (ext != "vsdx" || typeName == Self.visioType)
        else { throw DiagramError.invalid("The file extension does not match its selected format.") }
        saveSnapshotLock.lock()
        let directVersion = activeSaveSourceCheck == nil ? sourceFileVersion : nil
        let directUnverified = activeSaveSourceCheck == nil ? unverifiedSavedSourceURL : nil
        let policyAdmitted = policyAdmittedSaveID != nil
        saveSnapshotLock.unlock()
        if directUnverified == DocumentSourceVersion.canonical(url) { throw DocumentSourceConflict(url: url) }
        if let directVersion, DocumentSourceVersion.canonical(url) == directVersion.url {
            try directVersion.check()
        }
        if !policyAdmitted,
            let original = sourceFileVersion?.url ?? fileURL.map(DocumentSourceVersion.canonical),
            DocumentSourceVersion.canonical(url) == original
        {
            try DocumentWritePolicy.requireWritableOriginal(original)
        }
        if !policyAdmitted,
            let original = sourceFileVersion?.url ?? fileURL.map(DocumentSourceVersion.canonical),
            DocumentSourceVersion.canonical(url) == original
        {
            let assessment = DocumentSaveImpact.assess(
                snapshot: diagram, baseline: saveImpactBaseline,
                diagnostics: currentDiagnostics, format: Self.impactFormat(typeName))
            if assessment.requiresReview { throw DocumentSaveImpact.UnsafeOverwrite(assessment: assessment) }
        }
        try super.write(to: url, ofType: typeName)
    }
    override func writeSafely(
        to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType
    ) throws {
        saveSnapshotLock.lock()
        let expected = activeSaveSourceCheck?.version
        saveSnapshotLock.unlock()
        try expected?.check()
        try super.writeSafely(to: url, ofType: typeName, for: saveOperation)
    }
    override func write(
        to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType,
        originalContentsURL: URL?
    ) throws {
        saveSnapshotLock.lock()
        let expected = activeSaveSourceCheck?.version
        saveSnapshotLock.unlock()
        try expected?.check(contentsAt: originalContentsURL)
        try super.write(
            to: url, ofType: typeName, for: saveOperation, originalContentsURL: originalContentsURL)
        try expected?.check(contentsAt: originalContentsURL)
    }
    override func canAsynchronouslyWrite(
        to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType
    ) -> Bool {
        guard Self.writableTypes.contains(typeName),
            (url.pathExtension.lowercased() != "vsd" || typeName == Self.legacyType),
            (url.pathExtension.lowercased() != "vsdx" || typeName == Self.visioType)
        else { return false }
        saveSnapshotLock.lock()
        defer { saveSnapshotLock.unlock() }
        guard let pendingSaveSnapshot else { return false }
        if activeAsyncSaveID == pendingSaveSnapshot.id { return true }
        guard activeAsyncSaveID == nil else { return false }
        activeAsyncSaveID = pendingSaveSnapshot.id
        return true
    }
    override func save(
        to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType,
        completionHandler: @escaping (Error?) -> Void
    ) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [self] in
                save(to: url, ofType: typeName, for: saveOperation, completionHandler: completionHandler)
            }
            return
        }
        let saveID = UUID()
        guard !documentIsClosed else {
            completionHandler(LifecycleJobError.cancelled)
            return
        }
        let request = QueuedSave(
            id: saveID, url: url, typeName: typeName, operation: saveOperation, completion: completionHandler)
        if saveInProgress || !queuedSaves.isEmpty || saveDrainScheduled {
            guard queuedSaves.count < 31 else {
                completionHandler(LifecycleJobError.queueFull)
                return
            }
            queuedSaves.append(request)
            return
        }
        performSave(request)
    }
    private func performSave(_ request: QueuedSave) {
        saveInProgress = true
        let pendingBefore = pendingCalculation?.id
        let attemptBefore = editorCalculationAttempt
        finalizingTextForSave = true
        commitTextEditing()
        finalizingTextForSave = false
        // A Save that finalizes active text owns that text commit. A calculation
        // already pending before this request keeps the committed-snapshot rule.
        if pendingBefore == nil, editorCalculationAttempt != attemptBefore {
            if let error = lastCalculationJobError {
                failSaveBeforeSnapshot(request, error: error)
                return
            }
            if let calculationID = pendingCalculation?.id {
                saveAwaitingTextCalculation = (request, calculationID)
                recordSave("waiting-for-text", id: request.id, state: stateID)
                return
            }
        }
        captureAndPerformSave(request)
    }
    private func finishTextCalculationForSave(_ calculationID: UUID, error: Error?) {
        guard let waiting = saveAwaitingTextCalculation, waiting.calculationID == calculationID else {
            return
        }
        saveAwaitingTextCalculation = nil
        if let error {
            failSaveBeforeSnapshot(waiting.request, error: error)
            return
        }
        guard !documentIsClosed else {
            failSaveBeforeSnapshot(waiting.request, error: LifecycleJobError.cancelled)
            return
        }
        captureAndPerformSave(waiting.request)
    }
    private func failSaveBeforeSnapshot(_ request: QueuedSave, error: Error) {
        recordSave("failed", id: request.id, state: stateID)
        request.completion(error)
        saveInProgress = false
        scheduleQueuedSaveDrain()
    }
    private func captureAndPerformSave(_ request: QueuedSave) {
        let acknowledgesDocument = [
            NSDocument.SaveOperationType.saveOperation, .saveAsOperation, .autosaveInPlaceOperation,
            .autosaveAsOperation,
        ].contains(request.operation)
        saveSnapshotLock.lock()
        let baseline = sourceFileVersion
        let unverified = unverifiedSavedSourceURL
        saveSnapshotLock.unlock()
        let originalURL = fileURL.map(DocumentSourceVersion.canonical) ?? baseline?.url
        let sameSource = originalURL == DocumentSourceVersion.canonical(request.url)
        let expected = acknowledgesDocument && sameSource ? baseline : nil
        do {
            if sameSource {
                try DocumentWritePolicy.requireWritableOriginal(DocumentSourceVersion.canonical(request.url))
            }
            if acknowledgesDocument && sameSource
                && unverified == DocumentSourceVersion.canonical(request.url)
            {
                throw DocumentSourceConflict(url: request.url)
            }
            if let expected, expected.url != DocumentSourceVersion.canonical(request.url) {
                throw DocumentSourceConflict(url: request.url)
            }
            try expected?.check()
        } catch {
            recordSave("source-conflict", id: request.id, state: stateID)
            request.completion(error)
            saveInProgress = false
            scheduleQueuedSaveDrain()
            return
        }
        let saveEvidence = PerformanceEvidence.begin(.save)
        let snapshot = PerformanceEvidence.measure(.snapshot) {
            PerformanceEvidence.count(.snapshotsCaptured)
            return diagram
        }
        let snapshotStateID = stateID
        let snapshotRecord = SaveSnapshot(id: request.id, stateID: snapshotStateID, diagram: snapshot)
        let assessment = DocumentSaveImpact.assess(
            snapshot: snapshot, baseline: saveImpactBaseline,
            diagnostics: currentDiagnostics, format: Self.impactFormat(request.typeName))
        lastSaveImpact = assessment
        if sameSource && assessment.requiresReview {
            PerformanceEvidence.end(saveEvidence)
            guard request.operation == .saveOperation || request.operation == .saveAsOperation else {
                failSaveBeforeSnapshot(
                    request, error: DocumentSaveImpact.UnsafeOverwrite(assessment: assessment))
                return
            }
            resolveUnsafeSave(request, snapshot: snapshotRecord, assessment: assessment)
            return
        }
        performCapturedSave(request, snapshot: snapshotRecord, saveEvidence: saveEvidence)
    }
    private static func impactFormat(_ typeName: String) -> DocumentSaveImpact.Format {
        typeName == nativeType ? .native : typeName == legacyType ? .legacy : .visio
    }
    private func resolveUnsafeSave(
        _ request: QueuedSave, snapshot: SaveSnapshot, assessment: DocumentSaveImpact.Assessment
    ) {
        saveAwaitingImpactResolution = request
        let resolved: (DocumentSaveImpact.Resolution) -> Void = { [weak self] resolution in
            guard let self, self.saveAwaitingImpactResolution?.id == request.id else { return }
            self.saveAwaitingImpactResolution = nil
            let destination: URL
            let typeName: String
            switch resolution {
            case .cancel:
                failSaveBeforeSnapshot(request, error: CocoaError(.userCancelled))
                return
            case .copy(let url):
                destination = url
                typeName = request.typeName
            case .nativeCopy(let url):
                destination = url
                typeName = Self.nativeType
            }
            guard
                DocumentSourceVersion.canonical(destination) != DocumentSourceVersion.canonical(request.url),
                fileURL.map(DocumentSourceVersion.canonical) != DocumentSourceVersion.canonical(destination),
                !documentIsClosed
            else {
                failSaveBeforeSnapshot(
                    request, error: DocumentSaveImpact.UnsafeOverwrite(assessment: assessment))
                return
            }
            let copy = QueuedSave(
                id: request.id, url: destination, typeName: typeName,
                operation: .saveToOperation, completion: request.completion)
            performCapturedSave(copy, snapshot: snapshot, saveEvidence: PerformanceEvidence.begin(.save))
        }
        if let resolveSaveImpact {
            resolved(resolveSaveImpact(assessment))
            return
        }
        guard let window = windowControllers.compactMap(\.window).first, window.attachedSheet == nil else {
            saveAwaitingImpactResolution = nil
            failSaveBeforeSnapshot(request, error: DocumentSaveImpact.UnsafeOverwrite(assessment: assessment))
            return
        }
        let alert = NSAlert()
        alert.messageText = "Preserve the original drawing"
        alert.informativeText = assessment.risks.map(\.message).joined(separator: "\n\n")
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Save a Copy…")
        alert.addButton(withTitle: "Save Native Copy…")
        alert.beginSheetModal(for: window) { response in
            guard response != .alertFirstButtonReturn else {
                resolved(.cancel)
                return
            }
            let native = response == .alertThirdButtonReturn
            let panel = NSSavePanel()
            panel.title = native ? "Save Native Copy" : "Save a Copy"
            panel.nameFieldStringValue =
                request.url.deletingPathExtension().lastPathComponent + " Copy."
                + (native ? "macvisio" : request.url.pathExtension)
            panel.beginSheetModal(for: window) { response in
                guard response == .OK, let url = panel.url else {
                    resolved(.cancel)
                    return
                }
                resolved(native ? .nativeCopy(url) : .copy(url))
            }
        }
    }
    private func performCapturedSave(
        _ request: QueuedSave, snapshot snapshotRecord: SaveSnapshot, saveEvidence: PerformanceEvidence.Span?
    ) {
        let snapshotStateID = snapshotRecord.stateID
        // Recovery and Save To must preserve the unsaved-document contract even
        // when AppKit acknowledges its own independently captured change token.
        if savedStateID == nil {
            savedStateID = super.isDocumentEdited ? UUID() : snapshotStateID
        }
        saveSnapshotLock.lock()
        pendingSaveSnapshot = snapshotRecord
        policyAdmittedSaveID = request.id
        let originalURL = fileURL.map(DocumentSourceVersion.canonical) ?? sourceFileVersion?.url
        let sameSource = originalURL == DocumentSourceVersion.canonical(request.url)
        activeSaveSourceCheck = sameSource ? sourceFileVersion.map { (id: request.id, version: $0) } : nil
        saveSnapshotLock.unlock()
        recordSave("captured", id: request.id, state: snapshotStateID)
        didCaptureSaveSnapshot?()
        super.save(to: request.url, ofType: request.typeName, for: request.operation) { [weak self] error in
            defer { PerformanceEvidence.end(saveEvidence) }
            guard let self else {
                request.completion(error)
                return
            }
            if Thread.isMainThread {
                self.completeSave(request, snapshot: snapshotRecord, error: error)
            } else {
                DispatchQueue.main.async { [self] in
                    self.completeSave(request, snapshot: snapshotRecord, error: error)
                }
            }
        }
    }
    private func completeSave(_ request: QueuedSave, snapshot: SaveSnapshot, error: Error?) {
        let artifact = finishSaveSnapshot(request.id)
        let acknowledgesDocument = [
            NSDocument.SaveOperationType.saveOperation, .saveAsOperation, .autosaveInPlaceOperation,
            .autosaveAsOperation,
        ].contains(request.operation)
        if error == nil && acknowledgesDocument {
            let writtenVersion = try? DocumentSourceVersion.read(request.url)
            saveSnapshotLock.lock()
            if let writtenVersion {
                sourceFileVersion = writtenVersion
                unverifiedSavedSourceURL = nil
            } else {
                unverifiedSavedSourceURL = DocumentSourceVersion.canonical(request.url)
            }
            saveSnapshotLock.unlock()
            var savedBaseline = snapshot.diagram
            if let artifact { savedBaseline.visioArchive = artifact.archive }
            saveImpactBaseline = .init(snapshot: savedBaseline)
            savedStateID = snapshot.stateID
            recoveryStateID = snapshot.stateID
            if !documentIsClosed, let artifact { installPreservation(artifact, for: snapshot.diagram) }
            updateChangeCount(.changeCleared)
            if stateID != snapshot.stateID { updateChangeCount(.changeDone) }
        } else if error == nil && request.operation == .autosaveElsewhereOperation {
            recoveryStateID = snapshot.stateID
        }
        recordSave(error == nil ? "succeeded" : "failed", id: request.id, state: snapshot.stateID)
        if error == nil
            && [NSDocument.SaveOperationType.saveOperation, .saveAsOperation].contains(request.operation)
        {
            documentWorkflow?.noteRecent(request.url)
        }
        request.completion(error)
        saveInProgress = false
        scheduleQueuedSaveDrain()
    }
    /// Source-only updates must not become semantic transactions or invalidate
    /// retained runtime state. Newer pages remain live; binding originals name
    /// only the exact snapshot that reached the destination.
    private func installPreservation(_ artifact: SaveArtifact, for snapshot: Diagram) {
        let archive = artifact.archive
        guard diagram.visioArchive?.sourceResourceID == snapshot.visioArchive?.sourceResourceID else {
            return
        }
        if snapshot.visioArchive == nil {
            let savedPages = Set(snapshot.pages.map(\.id))
            guard !savedPages.isDisjoint(with: diagram.pages.map(\.id)) else { return }
            // Only the latest nil-source origin can adopt this new baseline.
            // Replacing this set bounds it by one snapshot's page count.
            preservationNilSourcePageIDs = savedPages
        }
        latestPreservationArchive = archive
        let identity = stateID
        let priorRevision = revision
        let priorRuntimeRevision = runtimeRevision
        diagram.visioArchive = archive
        calculationSession = CalculationSession()
        stateID = identity
        revision = priorRevision
        runtimeRevision = priorRuntimeRevision
        // Retire only messages represented by a real typed producer. The set
        // remains bounded by this read's compatibility-warning array.
        retiredTypedImportMessages.formUnion(
            Set(typedImportDiagnostics.map(\.message)).intersection(importWarnings))
        if let records = artifact.sourceDiagnostics {
            typedImportDiagnostics = records
        } else {
            typedImportDiagnostics = typedImportDiagnostics.filter {
                $0.code != "import.source-inspection-unavailable"
            }.map { record in
                var record = record
                record.displayState = .stale
                return record
            }
            typedImportDiagnostics.append(
                DocumentDiagnostic(
                    code: "import.source-inspection-unavailable", origin: .importer, severity: .information,
                    dimension: .interchange, target: .document, displayState: .unavailable,
                    message:
                        "Source limitations need to be checked again. Reopen this saved drawing to refresh them."
                ))
        }
        diagnosticsDidChange()
    }
    private func finishSaveSnapshot(_ id: UUID) -> SaveArtifact? {
        saveSnapshotLock.lock()
        defer { saveSnapshotLock.unlock() }
        if pendingSaveSnapshot?.id == id { pendingSaveSnapshot = nil }
        if policyAdmittedSaveID == id { policyAdmittedSaveID = nil }
        if activeAsyncSaveID == id { activeAsyncSaveID = nil }
        if activeSaveSourceCheck?.id == id { activeSaveSourceCheck = nil }
        guard serializedSaveArtifact?.id == id else { return nil }
        let artifact = serializedSaveArtifact
        serializedSaveArtifact = nil
        return artifact
    }
    private func scheduleQueuedSaveDrain() {
        guard Thread.isMainThread, !saveInProgress, !queuedSaves.isEmpty, !saveDrainScheduled else { return }
        saveDrainScheduled = true
        DispatchQueue.main.async { [weak self] in self?.drainQueuedSave() }
    }
    private func drainQueuedSave() {
        guard Thread.isMainThread else { return }
        saveDrainScheduled = false
        guard !saveInProgress, !queuedSaves.isEmpty else { return }
        let request = queuedSaves.removeFirst()
        performSave(request)
    }
    override func willPresentError(_ error: Error) -> Error {
        let presented = super.willPresentError(error) as NSError
        var cause = presented
        var visited = Set<ObjectIdentifier>()
        for _ in 0..<16 {
            guard visited.insert(ObjectIdentifier(cause)).inserted,
                let underlying = cause.userInfo[NSUnderlyingErrorKey] as? NSError
            else { break }
            cause = underlying
        }
        if cause.domain == DocumentSourceConflict.errorDomain {
            var details = presented.userInfo
            details[NSLocalizedFailureReasonErrorKey] = cause.localizedDescription
            details[NSLocalizedRecoverySuggestionErrorKey] = cause.localizedRecoverySuggestion
            return NSError(domain: presented.domain, code: presented.code, userInfo: details)
        }
        guard presented.localizedFailureReason == nil else { return presented }
        let diagramErrorDomain = (DiagramError.invalid("") as NSError).domain
        guard cause.domain == diagramErrorDomain,
            cause.localizedDescription != presented.localizedDescription
        else { return presented }
        var details = presented.userInfo
        details[NSLocalizedFailureReasonErrorKey] = cause.localizedDescription
        return NSError(domain: presented.domain, code: presented.code, userInfo: details)
    }
    override func close() {
        let evidence = PerformanceEvidence.begin(.close)
        defer { PerformanceEvidence.end(evidence) }
        documentIsClosed = true
        issuesController?.close()
        issuesController = nil
        LifecycleJobService.shared.cancel(ownerID: lifecycleOwnerID)
        for controller in windowControllers { (controller as? EditorWindowController)?.lifecycleJobs.close() }
        let abandoned = queuedSaves
        queuedSaves.removeAll()
        let waiting = saveAwaitingTextCalculation
        saveAwaitingTextCalculation = nil
        let impact = saveAwaitingImpactResolution
        saveAwaitingImpactResolution = nil
        let waitingClose = closeAwaitingTextCalculation
        closeAwaitingTextCalculation = nil
        if waiting != nil || impact != nil { saveInProgress = false }
        impact?.completion(LifecycleJobError.cancelled)
        waiting?.request.completion(LifecycleJobError.cancelled)
        if let waitingClose { replyToClose(waitingClose.request, shouldClose: false) }
        abandoned.forEach { $0.completion(LifecycleJobError.cancelled) }
        let workflow = documentWorkflow
        super.close()
        workflow?.documentClosed(self)
    }
    func commitTextEditing() {
        for controller in windowControllers {
            guard let editor = controller as? EditorWindowController else { continue }
            if let fieldEditor = editor.window?.firstResponder as? NSTextView, fieldEditor.isFieldEditor,
                let field = fieldEditor.delegate as? NSTextField,
                field.isDescendant(of: editor.root.inspector)
            {
                editor.window?.makeFirstResponder(editor.canvas)
            }
            editor.canvas.finishEditing(commit: true)
        }
    }
    override func canClose(
        withDelegate delegate: Any, shouldClose shouldCloseSelector: Selector?,
        contextInfo: UnsafeMutableRawPointer?
    ) {
        let request = CloseRequest(delegate: delegate, selector: shouldCloseSelector, context: contextInfo)
        // One continuation owns text finalization. Repeated close attempts get
        // a definite refusal without retaining an unbounded delegate queue.
        guard !documentIsClosed, closeAwaitingTextCalculation == nil, !finalizingTextForClose else {
            replyToClose(request, shouldClose: false)
            return
        }
        let pendingBefore = pendingCalculation?.id
        let attemptBefore = editorCalculationAttempt
        finalizingTextForClose = true
        commitTextEditing()
        finalizingTextForClose = false
        if pendingBefore == nil, editorCalculationAttempt != attemptBefore {
            if lastCalculationJobError != nil {
                replyToClose(request, shouldClose: false)
                return
            }
            if let calculationID = pendingCalculation?.id {
                closeAwaitingTextCalculation = (request, calculationID)
                return
            }
        }
        continueClose(request)
    }
    private func finishTextCalculationForClose(_ calculationID: UUID, error: Error?) {
        guard let waiting = closeAwaitingTextCalculation, waiting.calculationID == calculationID else {
            return
        }
        guard error == nil, !documentIsClosed else {
            closeAwaitingTextCalculation = nil
            replyToClose(waiting.request, shouldClose: false)
            return
        }
        let acceptedInput = LifecycleJobInput(
            ownerID: lifecycleOwnerID, snapshotID: stateID, revision: revision)
        didAcceptTextForClose?()
        // Leave the calculation/file-access completion stack before starting a
        // new AppKit activity. Admission itself must not wait on main: a prior
        // asynchronous save may still need main to finish its serialization.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.validatePendingTextClose(calculationID, input: acceptedInput) else {
                return
            }
            self.performActivity(withSynchronousWaiting: false) { [weak self] activityCompleted in
                defer { activityCompleted() }
                guard let self, self.validatePendingTextClose(calculationID, input: acceptedInput)
                else { return }
                self.closeAwaitingTextCalculation = nil
                // canClose starts its own activity. continueActivity is the
                // documented nesting boundary that prevents it waiting on us.
                self.continueActivity { self.continueClose(waiting.request) }
            }
        }
    }
    private func validatePendingTextClose(_ calculationID: UUID, input: LifecycleJobInput) -> Bool {
        guard let waiting = closeAwaitingTextCalculation, waiting.calculationID == calculationID else {
            return false
        }
        guard !documentIsClosed, pendingCalculation == nil, lifecycleOwnerID == input.ownerID,
            stateID == input.snapshotID, revision == input.revision
        else {
            closeAwaitingTextCalculation = nil
            replyToClose(waiting.request, shouldClose: false)
            return false
        }
        return true
    }
    private func continueClose(_ request: CloseRequest) {
        super.canClose(
            withDelegate: request.delegate, shouldClose: request.selector, contextInfo: request.context)
    }
    private func replyToClose(_ request: CloseRequest, shouldClose: Bool) {
        guard let selector = request.selector, let receiver = request.delegate as? NSObject,
            receiver.responds(to: selector), let implementation = receiver.method(for: selector)
        else { return }
        // NSDocument's documented delegate ABI is document:shouldClose:contextInfo:.
        typealias CloseReply =
            @convention(c) (AnyObject, Selector, NSDocument, Bool, UnsafeMutableRawPointer?) -> Void
        let callback = unsafeBitCast(implementation, to: CloseReply.self)
        callback(receiver, selector, self, shouldClose, request.context)
    }
    func prepareControlGesture() -> ControlEditing.Baseline {
        let input = LifecycleJobInput(ownerID: lifecycleOwnerID, snapshotID: stateID, revision: revision)
        return ControlEditing.prepare(
            diagram, geometryIssuesByPage: geometryIssuesByPage, session: calculationSession,
            inputIdentity: input)
    }
    func adjustControlInEditor(
        baseline: ControlEditing.Baseline, node: UUID, control: String, to point: CGPoint,
        forceAsync: Bool = false
    ) {
        let current = LifecycleJobInput(ownerID: lifecycleOwnerID, snapshotID: stateID, revision: revision)
        guard baseline.inputIdentity.map({ $0 == current }) ?? (baseline.input == diagram) else {
            lastCalculationJobError = LifecycleJobError.staleInput
            return
        }
        let activePageID = diagram.activePageID
        var controlInput = baseline.input
        controlInput.activePageID = activePageID
        replaceInEditor(
            with: controlInput, action: "Adjust Control Handle", forceAsync: forceAsync,
            preparation: { cancellation in
                let result = try ControlEditing.preview(
                    baseline: baseline, node: node, control: control, to: point, cancellation: cancellation)
                var prepared = result.diagram
                // The control belongs to its frozen page; adjusting it does not
                // request navigation back to that page after a view activation.
                prepared.activePageID = activePageID
                return (prepared, result.work)
            })
    }
    private struct PendingEditorSelection {
        weak var editor: EditorWindowController?
        let pageID: UUID
        let nodeIDs: Set<UUID>
        let edgeID: UUID?
    }
    private func restorePendingEditorSelections(
        _ selections: [PendingEditorSelection], input: LifecycleJobInput
    ) {
        guard !documentIsClosed, pendingCalculation == nil, lifecycleOwnerID == input.ownerID,
            stateID == input.snapshotID, revision == input.revision
        else { return }
        for selection in selections {
            guard let editor = selection.editor,
                windowControllers.contains(where: { $0 === editor }),
                diagram.activePageID == selection.pageID
            else { continue }
            editor.canvas.select(selection.nodeIDs, edge: selection.edgeID)
        }
    }
    /// Native large edits own a worker snapshot. A document sheet prevents a
    /// second command from being based on an unfinished result; other windows
    /// and autosave continue to use their committed state.
    func replaceInEditor(
        with next: Diagram, action: String, forceAsync: Bool = false,
        preparation: ((LifecycleJobCancellation) throws -> (diagram: Diagram, work: CalculationWork))? = nil
    ) {
        guard pendingCalculation == nil else {
            for controller in windowControllers {
                (controller as? EditorWindowController)?.root.showMessage(
                    "Wait for calculation to finish or cancel it.")
            }
            return
        }
        guard !documentIsClosed, preparation != nil || next != diagram else { return }
        editorCalculationAttempt &+= 1
        lastCalculationJobError = nil
        guard
            forceAsync
                || (!windowControllers.isEmpty && next.pages.reduce(0, { $0 + $1.nodes.count }) >= 2000)
        else {
            if let preparation {
                lastCalculationJobError = nil
                do {
                    let prepared = try preparation(LifecycleJobCancellation())
                    let priorRevision = revision
                    replace(with: prepared.diagram, action: action)
                    var work = prepared.work
                    if revision != priorRevision { work.add(lastCalculationWork) }
                    lastCalculationWork = work
                } catch {
                    lastCalculationJobError = error
                    for controller in windowControllers {
                        (controller as? EditorWindowController)?.root.showMessage(error.localizedDescription)
                    }
                }
            } else {
                replace(with: next, action: action)
            }
            return
        }
        let previous = diagram
        let previousIssues = calculationIssues
        let previousGeometry = geometryIssuesByPage
        let previousFields = fieldIssuesByPage
        let previousGeometryDiagnostics = geometryDiagnosticsByPage
        let previousFieldDiagnostics = fieldDiagnosticsByPage
        let refreshDiagnostics = acceptedCalculationDiagnostics.contains { $0.inputKey != diagnosticInputKey }
        let initialChanges = preparation == nil ? DocumentChangeSet.between(previous, next) : nil
        let session = refreshDiagnostics ? CalculationSession() : calculationSession.fork()
        let input = LifecycleJobInput(ownerID: lifecycleOwnerID, snapshotID: stateID, revision: revision)
        let requestID = UUID()
        // Commands may immediately select inserted objects or clear a deleted
        // selection after submission. Those IDs are provisional until commit.
        let selections = windowControllers.compactMap { controller -> PendingEditorSelection? in
            guard let editor = controller as? EditorWindowController else { return nil }
            return PendingEditorSelection(
                editor: editor, pageID: diagram.activePageID,
                nodeIDs: editor.canvas.selectedNodes, edgeID: editor.canvas.selectedEdge)
        }
        let progress = LifecycleProgressController(title: "Calculating drawing", detail: action)
        lastCalculationJobError = nil
        do {
            pendingCalculation = try LifecycleJobService.shared.submit(
                id: requestID, kind: .calculation, input: input,
                accepts: { [weak self] candidate in
                    guard let self, !self.documentIsClosed, self.pendingCalculation?.id == requestID else {
                        return false
                    }
                    return candidate.ownerID == self.lifecycleOwnerID && candidate.snapshotID == self.stateID
                        && candidate.revision == self.revision
                }, progress: { progress.update($0) },
                work: { context in
                    context.progress(
                        preparation == nil ? "Evaluating affected shapes" : "Preparing control geometry")
                    let prepared = try preparation?(context.cancellation)
                    try context.checkpoint()
                    let preparedDiagram = prepared?.diagram ?? next
                    let changes = initialChanges ?? DocumentChangeSet.between(previous, preparedDiagram)
                    let synchronized = ShapeRichText.synchronize(
                        preparedDiagram, previous: previous, changes: changes, session: session)
                    let output = try CalculationJobs.evaluate(
                        synchronized, input: input, previous: previous,
                        previousIssues: previousIssues, previousGeometryIssuesByPage: previousGeometry,
                        previousFieldIssuesByPage: previousFields,
                        previousGeometryDiagnosticsByPage: previousGeometryDiagnostics,
                        previousFieldDiagnosticsByPage: previousFieldDiagnostics,
                        refreshDiagnostics: refreshDiagnostics, session: session, changes: changes,
                        cancellation: context.cancellation)
                    return prepared.map { output.includingPreparationWork($0.work) } ?? output
                },
                completion: { [weak self] outcome in
                    progress.finish()
                    guard let self, self.pendingCalculation?.id == requestID else { return }
                    self.pendingCalculation = nil
                    var completionError: Error?
                    let hasTextContinuation =
                        self.saveAwaitingTextCalculation?.calculationID == requestID
                        || self.closeAwaitingTextCalculation?.calculationID == requestID
                    defer {
                        self.finishTextCalculationForSave(requestID, error: completionError)
                        self.finishTextCalculationForClose(requestID, error: completionError)
                    }
                    switch outcome {
                    case .success(let output):
                        do {
                            let current = LifecycleJobInput(
                                ownerID: self.lifecycleOwnerID, snapshotID: self.stateID,
                                revision: self.revision)
                            let result = try output.accepted(ifCurrent: current)
                            var accepted = result.diagram
                            // Ordinary semantic edits do not own page presentation.
                            // Preserve a newer view activation, while explicit page
                            // creation/activation requests retain their target.
                            if accepted.activePageID == previous.activePageID,
                                accepted.pages.contains(where: { $0.id == self.diagram.activePageID })
                            {
                                accepted.activePageID = self.diagram.activePageID
                            }
                            self.calculationSession = session
                            self.lastCalculationWork = result.work
                            self.applyCalculated(
                                accepted, issues: result.issues,
                                geometryIssuesByPage: result.geometryIssuesByPage,
                                fieldIssuesByPage: result.fieldIssuesByPage,
                                geometryDiagnosticsByPage: result.geometryDiagnosticsByPage,
                                fieldDiagnosticsByPage: result.fieldDiagnosticsByPage, action: action)
                        } catch {
                            completionError = error
                            self.lastCalculationJobError = error
                            self.restorePendingEditorSelections(selections, input: input)
                            for controller in self.windowControllers {
                                (controller as? EditorWindowController)?.refresh()
                            }
                        }
                    case .failure(let error):
                        completionError = error
                        self.lastCalculationJobError = error
                        self.restorePendingEditorSelections(selections, input: input)
                        for controller in self.windowControllers {
                            (controller as? EditorWindowController)?.refresh()
                        }
                        if !hasTextContinuation,
                            (error as? LifecycleJobError) != .cancelled
                                && (error as? LifecycleJobError) != .staleInput
                        {
                            self.presentError(error)
                        }
                    }
                })
            progress.onCancel = { [weak self] in self?.cancelPendingCalculation() }
            if let window = windowControllers.first?.window, window.isVisible {
                progress.show(attachedTo: window)
            }
        } catch {
            progress.finish()
            lastCalculationJobError = error
            // A submission failure returns before the command posts its
            // provisional selection, so restore on the following main turn.
            DispatchQueue.main.async { [weak self] in
                self?.restorePendingEditorSelections(selections, input: input)
            }
            if !finalizingTextForSave && !finalizingTextForClose { presentError(error) }
        }
    }

    func replace(with next: Diagram, action: String) {
        guard next != diagram else { return }
        let refreshDiagnostics = acceptedCalculationDiagnostics.contains { $0.inputKey != diagnosticInputKey }
        if refreshDiagnostics { calculationSession = CalculationSession() }
        let changes = DocumentChangeSet.between(diagram, next)
        var synchronizationVisits = 0
        let synchronized = ShapeRichText.synchronize(
            next, previous: diagram, changes: changes, session: calculationSession
        ) { synchronizationVisits += $0 }
        let calculation = DiagramCalculation.recalculate(
            synchronized, previous: diagram,
            previousIssues: calculationIssues, previousGeometryIssuesByPage: geometryIssuesByPage,
            previousFieldIssuesByPage: fieldIssuesByPage,
            previousGeometryDiagnosticsByPage: geometryDiagnosticsByPage,
            previousFieldDiagnosticsByPage: fieldDiagnosticsByPage,
            refreshDiagnostics: refreshDiagnostics,
            session: calculationSession, changes: changes)
        lastCalculationWork = calculation.work
        lastCalculationWork.richTextNodes += synchronizationVisits
        PerformanceEvidence.count(.inputComparisonNodes, by: lastCalculationWork.inputComparisonNodes)
        PerformanceEvidence.count(
            .dependencySourcesCompared, by: lastCalculationWork.dependencySourcesCompared)
        PerformanceEvidence.count(.hostNodesPrepared, by: lastCalculationWork.hostNodesPrepared)
        applyCalculated(
            calculation.diagram, issues: calculation.issues,
            geometryIssuesByPage: calculation.geometryIssuesByPage,
            fieldIssuesByPage: calculation.fieldIssuesByPage,
            geometryDiagnosticsByPage: calculation.geometryDiagnosticsByPage,
            fieldDiagnosticsByPage: calculation.fieldDiagnosticsByPage, action: action)
    }
    private func applyCalculated(
        _ next: Diagram, issues: [String], geometryIssuesByPage nextGeometryIssuesByPage: [UUID: [String]],
        fieldIssuesByPage nextFieldIssuesByPage: [UUID: [String]],
        geometryDiagnosticsByPage nextGeometryDiagnostics: [UUID: [DocumentDiagnostic]] = [:],
        fieldDiagnosticsByPage nextFieldDiagnostics: [UUID: [DocumentDiagnostic]] = [:], action: String,
        restoringStateID: UUID? = nil
    ) {
        let evidence = PerformanceEvidence.begin(.commit)
        defer { PerformanceEvidence.end(evidence) }
        var next = next
        let nilSourceCompatible =
            next.visioArchive == nil && !preservationNilSourcePageIDs.isDisjoint(with: next.pages.map(\.id))
        if let current = latestPreservationArchive,
            nilSourceCompatible || next.visioArchive?.sourceLineageID == current.sourceLineageID
        {
            if next.visioArchive?.sourceResourceID != current.sourceResourceID {
                calculationSession = CalculationSession()
            }
            next.visioArchive = current
        }
        let previousIssues = calculationIssues
        let previousGeometryIssuesByPage = geometryIssuesByPage
        let previousFieldIssuesByPage = fieldIssuesByPage
        let previousGeometryDiagnostics = geometryDiagnosticsByPage
        let previousFieldDiagnostics = fieldDiagnosticsByPage
        calculationIssues = issues
        geometryIssuesByPage = nextGeometryIssuesByPage
        fieldIssuesByPage = nextFieldIssuesByPage
        geometryDiagnosticsByPage = nextGeometryDiagnostics
        fieldDiagnosticsByPage = nextFieldDiagnostics
        guard next != diagram else {
            publishCalculationDiagnostics()
            return
        }
        PerformanceEvidence.count(.transactionsCommitted)
        // Compatibility commands still produce value snapshots. Diff exactly once
        // at commit; all derived consumers receive this explicit affected set.
        let changes = DocumentChangeSet.between(diagram, next)
        if runtimeRevision != revision { pageRuntimes = [:] }
        let previous = diagram
        let previousStateID = stateID
        if savedStateID == nil && !super.isDocumentEdited { savedStateID = previousStateID }
        if restoringStateID == nil {
            let decision = undoPayloadBudget.prepare(
                previous: previous, previousStateID: previousStateID, next: next, changes: changes,
                historyIsEmpty: !(undoManager?.canUndo ?? false))
            lastUndoBudgetDecision = decision
            if decision.discardOldHistory, let manager = undoManager {
                let groupingLevel = manager.groupingLevel
                manager.removeAllActions()
                // NSUndoManager drops open groups when clearing history. Keep
                // the caller's group contract before registering this action.
                while manager.groupingLevel < groupingLevel { manager.beginUndoGrouping() }
            }
        } else {
            undoPayloadBudget.invalidateCurrentEstimate()
            calculationSession = CalculationSession()
        }
        let ownsUndoGroup =
            undoManager?.groupingLevel == 0 && !(undoManager?.isUndoing ?? false)
            && !(undoManager?.isRedoing ?? false)
        if ownsUndoGroup { undoManager?.beginUndoGrouping() }
        defer { if ownsUndoGroup { undoManager?.endUndoGrouping() } }
        undoManager?.registerUndo(withTarget: self) { target in
            target.applyCalculated(
                previous, issues: previousIssues, geometryIssuesByPage: previousGeometryIssuesByPage,
                fieldIssuesByPage: previousFieldIssuesByPage,
                geometryDiagnosticsByPage: previousGeometryDiagnostics,
                fieldDiagnosticsByPage: previousFieldDiagnostics, action: action,
                restoringStateID: previousStateID)
        }
        undoManager?.setActionName(action)
        diagram = next
        if let restoringStateID {
            stateID = restoringStateID
        } else {
            undoPayloadBudget.didInstall(stateID: stateID)
        }
        for id in changes.deletedPageIDs { pageRuntimes[id] = nil }
        lastRuntimeWork = [:]
        for page in next.pages {
            if let change = changes.pages[page.id], let runtime = pageRuntimes[page.id] {
                let work = runtime.apply(page: page, changes: change)
                lastRuntimeWork[page.id] = work
                PerformanceEvidence.count(.runtimeNodeVisits, by: work.nodeVisits)
                PerformanceEvidence.count(.runtimeEdgeVisits, by: work.edgeVisits)
            }
        }
        runtimeRevision = revision
        lastCommittedChange = changes
        publishCalculationDiagnostics()
        updateChangeCount(.changeDone)
        for controller in windowControllers {
            (controller as? EditorWindowController)?.refresh(changes: changes)
        }
    }
}

final class EditorWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    unowned let diagramDocument: MacVisioDocument
    let canvas = CanvasView(frame: .zero)
    let scrollView = NSScrollView()
    var root: EditorRootView!
    private(set) var retainedScene: RetainedRenderScene!
    var stencils: [StencilDefinition] = []
    private var fittedInitialPage = false
    private var editorIsDetached = false
    var selection: [DiagramNode] {
        let runtime = diagramDocument.runtime()
        return canvas.selectedNodes.sorted {
            runtime.nodeIndexByID[$0, default: 0] < runtime.nodeIndexByID[$1, default: 0]
        }.compactMap { runtime.nodesByID[$0] }
    }
    var editableSelectionIDs: Set<UUID> {
        let runtime = diagramDocument.runtime()
        return runtime.selectionMembership(
            Set(selection.filter { !runtime.isLocked(nodeID: $0.id) }.map(\.id)), includingDescendants: true)
    }
    init(document: MacVisioDocument) {
        diagramDocument = document
        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = CGRect(
            x: 0, y: 0, width: min(1450, screen.width - 50), height: min(930, screen.height - 65))
        let window = NSWindow(
            contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.minSize = CGSize(width: 760, height: 560)
        window.autorecalculatesKeyViewLoop = true
        window.title = document.diagram.title
        window.titlebarAppearsTransparent = true
        window.backgroundColor = EditorPalette.panel
        EditorAppearance.apply()
        window.appearance = nil
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("MacVisioEditor")
        canvas.editor = self
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.documentView = canvas
        root = EditorRootView(editor: self)
        window.contentView = root
        window.setAccessibilityIdentifier("MacVisioEditor")
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }
    override func close() {
        detachEditor()
        super.close()
    }
    private func detachEditor() {
        guard !editorIsDetached else { return }
        editorIsDetached = true
        if lifecycleJobs.isActive { canvas.finishEditing(commit: true) }
        lifecycleJobs.close()
        root?.detachEditor()
        canvas.detachEditor()
        retainedScene = nil
        stencils = []
    }
    override func showWindow(_ sender: Any?) {
        guard !editorIsDetached else { return }
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        let fit = !fittedInitialPage
        fittedInitialPage = true
        DispatchQueue.main.async { [weak self, weak document = diagramDocument] in
            guard let self, !self.editorIsDetached, self.lifecycleJobs.isActive,
                let document, self.window?.isVisible == true
            else { return }
            // Hold the document through this delayed callback; the controller
            // can outlive its unowned document while AppKit drains autoreleases.
            withExtendedLifetime(document) {
                if fit { self.canvas.fitPage() }
                self.window?.makeFirstResponder(self.canvas)
            }
        }
    }
    func windowDidBecomeKey(_ notification: Notification) {
        guard !editorIsDetached, lifecycleJobs.isActive else { return }
        diagramDocument.documentWorkflow?.documentActivated(diagramDocument)
    }
    func windowDidResize(_ notification: Notification) {
        guard !editorIsDetached, lifecycleJobs.isActive else { return }
        canvas.refreshSize()
    }
    func windowWillClose(_ notification: Notification) { detachEditor() }
    func refresh(changes: DocumentChangeSet? = nil) {
        guard !editorIsDetached, lifecycleJobs.isActive, root != nil else { return }
        retainedScene = RetainedRenderScene(
            scene: diagramDocument.diagram.scene(), revision: diagramDocument.revision,
            previous: retainedScene)
        let page = diagramDocument.diagram.page
        canvas.selectedNodes.formIntersection(Set(page.nodes.map(\.id)))
        if !page.edges.contains(where: { $0.id == canvas.selectedEdge }) { canvas.selectedEdge = nil }
        if changes == nil || changes!.documentStructureChanged || changes!.activePageChanged
            || changes!.pages.values.contains(where: { $0.pagePropertiesChanged })
        {
            root.refreshPages()
        }
        root.refreshImportNotes()
        diagramDocument.issuesController?.reload()
        root.inspector.refresh()
        canvas.refreshSize()
        updateStatus()
    }
    func selectionChanged() {
        diagramDocument.present(
            .selectionChanged(
                pageID: diagramDocument.diagram.activePageID, nodeIDs: canvas.selectedNodes,
                edgeID: canvas.selectedEdge))
        root.inspector.refresh()
        updateStatus()
    }
    func updateStatus() {
        let page = diagramDocument.diagram.page
        let prefix =
            canvas.pendingSource != nil
            ? "Click a destination shape"
            : canvas.tool == .connector
                ? "Click two shapes to connect"
                : canvas.tool == .text
                    ? "Click the page to add text"
                    : canvas.selectedNodes.count > 0
                        ? "\(canvas.selectedNodes.count) selected"
                        : "\(page.nodes.count) shapes · \(page.edges.count) connectors"
        let materialIssues = diagramDocument.currentDiagnostics.filter(\.isMaterial).count
        root.status.stringValue =
            "\(page.name)   /   \(prefix)" + (materialIssues == 0 ? "" : "   /   \(materialIssues) issues")
        root.zoomLabel.stringValue = "\(Int((canvas.zoom*100).rounded()))%"
        root.ribbon.refreshSelection()
    }
    func setTool(_ tool: CanvasTool) {
        canvas.finishEditing(commit: true)
        canvas.tool = tool
        updateStatus()
        window?.makeFirstResponder(canvas)
    }
    func visibleCenter() -> CGPoint {
        CGPoint(
            x: (canvas.visibleRect.midX - canvas.pageOrigin.x) / canvas.coordinateZoom,
            y: (canvas.visibleRect.midY - canvas.pageOrigin.y) / canvas.coordinateZoom)
    }
    func insertShape(_ kind: ShapeKind, at point: CGPoint? = nil) {
        canvas.finishEditing(commit: true)
        var next = diagramDocument.diagram
        let factor = next.page.paperScale
        let size = CGSize(width: kind.defaultSize.width / factor, height: kind.defaultSize.height / factor)
        let center = visibleCenter()
        let p = point ?? CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2)
        var n = DiagramNode(
            kind: kind,
            x: max(0, min(next.page.width - size.width, DiagramGeometry.snapped(p.x, grid: 10 / factor))),
            y: max(0, min(next.page.height - size.height, DiagramGeometry.snapped(p.y, grid: 10 / factor))))
        n.width = size.width
        n.height = size.height
        if point == nil {
            var attempts = 0
            while next.page.nodes.contains(where: { abs($0.x - n.x) < 5 && abs($0.y - n.y) < 5 })
                && attempts < 12
            {
                n.x = min(next.page.width - n.width, n.x + 20)
                n.y = min(next.page.height - n.height, n.y + 20)
                attempts += 1
            }
        }
        next.page.nodes.append(n)
        diagramDocument.replaceInEditor(with: next, action: "Add \(kind.title)")
        canvas.select([n.id])
        setTool(.pointer)
    }
    func connect(_ source: UUID, to target: UUID, sourcePort: String? = nil, targetPort: String? = nil) {
        var next = diagramDocument.diagram
        guard let targetNode = next.page.nodes.first(where: { $0.id == target }),
            next.page.permitsGlue(to: targetNode)
        else { return }
        var edge = DiagramEdge(source: source, target: target)
        edge.parentID = DiagramOperations.commonGroup(source, target, in: next.page)
        edge.sourcePort = sourcePort
        edge.targetPort = targetPort
        next.page.edges.append(edge)
        diagramDocument.replaceInEditor(with: next, action: "Connect Shapes")
        canvas.select([], edge: edge.id)
    }
    func setConnectionPoints(_ points: [ShapeConnectionPoint], for nodeID: UUID) throws {
        var next = diagramDocument.diagram
        let original = next.page
        guard let index = next.page.nodes.firstIndex(where: { $0.id == nodeID }),
            !next.page.isLocked(next.page.nodes[index])
        else { throw DiagramError.invalid("Select an unlocked shape to edit connection points.") }
        let old = next.page.nodes[index].formatting.connectionPoints
        next.page.nodes[index].formatting.connectionPoints = points
        for i in next.page.edges.indices {
            let route = DiagramGeometry.route(next.page.edges[i], in: original)
            func replacement(_ key: String?) -> String? {
                guard let key else { return nil }
                if points.contains(where: { $0.id == key }) { return key }
                return old.first(where: { $0.id == key }).flatMap { point in
                    points.first { $0.index == point.index }?.id
                }
            }
            if next.page.edges[i].source == nodeID, let key = next.page.edges[i].sourcePort {
                if let key = replacement(key) {
                    next.page.edges[i].sourcePort = key
                } else {
                    next.page.edges[i].sourcePort = nil
                    next.page.edges[i].source = UUID()
                    next.page.edges[i].sourcePosition = route.first.map(DiagramPoint.init)
                }
            }
            if next.page.edges[i].target == nodeID, let key = next.page.edges[i].targetPort {
                if let key = replacement(key) {
                    next.page.edges[i].targetPort = key
                } else {
                    next.page.edges[i].targetPort = nil
                    next.page.edges[i].target = UUID()
                    next.page.edges[i].targetPosition = route.last.map(DiagramPoint.init)
                }
            }
        }
        diagramDocument.replaceInEditor(with: try next.validated(), action: "Edit Connection Points")
    }
    func modifySelection(_ action: String, _ body: (inout DiagramNode) -> Void) {
        var next = diagramDocument.diagram
        var blockedReason: String?
        let roots = DiagramOperations.roots(canvas.selectedNodes, in: next.page)
        for id in roots {
            guard let i = next.page.nodes.firstIndex(where: { $0.id == id }),
                !next.page.isLocked(next.page.nodes[i])
            else { continue }
            let previous = next.page.nodes[i]
            body(&next.page.nodes[i])
            let changed = next.page.nodes[i]
            if let reason = NativeEditProtection.blockReason(
                changing: previous, to: changed, in: diagramDocument.diagram.page)
            {
                next.page.nodes[i] = previous
                blockedReason = reason
                continue
            }
            if previous.rect != changed.rect || previous.rotation != changed.rotation
                || previous.formatting.flipX != changed.formatting.flipX
                || previous.formatting.flipY != changed.formatting.flipY
            {
                if previous.formatting.isGroup {
                    var before = next.page
                    before.nodes[i] = previous
                    var candidate = next.page
                    DiagramOperations.transformChildren(in: &candidate, from: previous, to: changed)
                    let oldNodes = Dictionary(uniqueKeysWithValues: before.nodes.map { ($0.id, $0) })
                    let oldEdges = Dictionary(uniqueKeysWithValues: before.edges.map { ($0.id, $0) })
                    var reason: String?
                    for node in candidate.nodes where node.id != previous.id {
                        guard let original = oldNodes[node.id], original != node else { continue }
                        if let blocked = NativeEditProtection.blockReason(
                            changing: original, to: node, in: before)
                        {
                            reason = "A group member prevents this transform: " + blocked
                            break
                        }
                    }
                    if reason == nil,
                        candidate.edges.contains(where: { edge in
                            oldEdges[edge.id].map { $0 != edge && before.isLocked($0) } ?? false
                        })
                    {
                        reason = "A group connector or its layer is locked."
                    }
                    if let reason {
                        next.page = before
                        blockedReason = reason
                        continue
                    }
                    next.page = candidate
                } else {
                    DiagramOperations.transformChildren(in: &next.page, from: previous, to: changed)
                }
            }
        }
        diagramDocument.replaceInEditor(with: next, action: action)
        if let blockedReason { root?.status.stringValue = blockedReason }
    }
    func modifyEdge(_ action: String, _ body: (inout DiagramEdge) -> Void) {
        var next = diagramDocument.diagram
        if let i = next.page.edges.firstIndex(where: { $0.id == canvas.selectedEdge }),
            !next.page.isLocked(next.page.edges[i])
        {
            body(&next.page.edges[i])
            diagramDocument.replaceInEditor(with: next, action: action)
        }
    }
    @objc func deleteSelection(_ sender: Any?) {
        canvas.finishEditing(commit: true)
        var next = diagramDocument.diagram
        let ids = editableSelectionIDs
        let lockedEdges = Set(next.page.edges.filter { next.page.isLocked($0) }.map(\.id))
        next.page.nodes.removeAll { ids.contains($0.id) }
        next.page.edges.removeAll {
            ids.contains($0.source) || ids.contains($0.target) || $0.parentID.map(ids.contains) == true
                || ($0.id == canvas.selectedEdge && !lockedEdges.contains($0.id))
        }
        diagramDocument.replaceInEditor(with: next, action: "Delete")
        canvas.select([])
    }
    @objc func duplicateSelection(_ sender: Any?) {
        let diagram = diagramDocument.diagram
        let fragment = DiagramOperations.fragment(
            editableSelectionIDs, edges: Set([canvas.selectedEdge].compactMap { $0 }), from: diagram.page,
            binding: diagram.visioArchive?.pages.first { $0.pageID == diagram.page.id })
        pasteFragment(fragment)
    }
    func copySelection() {
        let ids = canvas.selectedNodes
        let expanded = DiagramOperations.expandedSelection(ids, in: diagramDocument.diagram.page)
        let diagram = diagramDocument.diagram
        let fragment = DiagramOperations.fragment(
            expanded, edges: Set([canvas.selectedEdge].compactMap { $0 }), from: diagram.page,
            binding: diagram.visioArchive?.pages.first { $0.pageID == diagram.page.id })
        guard !fragment.nodes.isEmpty || !fragment.edges.isEmpty,
            let data = try? JSONEncoder().encode(fragment)
        else { return }
        let board = NSPasteboard.general
        board.clearContents()
        board.setData(data, forType: CanvasView.fragmentPasteboardType)
        board.setString(fragment.nodes.map(\.text).joined(separator: "\n"), forType: .string)
    }
    func pasteSelection() {
        canvas.finishEditing(commit: true)
        guard let data = NSPasteboard.general.data(forType: CanvasView.fragmentPasteboardType),
            let fragment = try? JSONDecoder().decode(DiagramPage.self, from: data)
        else { return }
        pasteFragment(fragment)
    }
    func pasteFragment(_ fragment: DiagramPage, at point: CGPoint? = nil) {
        canvas.finishEditing(commit: true)
        var next = diagramDocument.diagram
        let binding = next.visioArchive?.pages.first(where: { $0.pageID == next.page.id })
        let reserved = (binding?.nodeIDs.map { $0.value } ?? []) + (binding?.edgeIDs.map { $0.value } ?? [])
        do {
            let ids = try DiagramOperations.insert(
                fragment, into: &next.page, at: point, reservedIDs: reserved)
            diagramDocument.replaceInEditor(with: next, action: "Insert Shapes")
            canvas.select(ids)
            setTool(.pointer)
        } catch { presentError(error) }
    }
    func insertStencil(_ definition: StencilDefinition, at point: CGPoint? = nil) {
        let center = point ?? visibleCenter()
        pasteFragment(
            definition.fragment,
            at: CGPoint(
                x: center.x - definition.fragment.width / 2, y: center.y - definition.fragment.height / 2))
    }
    @objc func editText(_ sender: Any?) {
        if let id = canvas.selectedNodes.first {
            canvas.beginEditing(id)
        } else if canvas.selectedEdge != nil {
            editConnectorLabel()
        }
    }
    func editConnectorLabel() {
        guard let edge = diagramDocument.diagram.page.edges.first(where: { $0.id == canvas.selectedEdge }),
            !diagramDocument.diagram.page.isLocked(edge)
        else { return }
        let alert = NSAlert()
        alert.messageText = "Connector label"
        alert.addButton(withTitle: "Apply")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: edge.label)
        field.frame = CGRect(x: 0, y: 0, width: 300, height: 24)
        alert.accessoryView = field
        if alert.runModal() == .alertFirstButtonReturn {
            modifyEdge("Edit Connector Label") { $0.label = field.stringValue }
        }
    }
    @objc func bringToFront(_ sender: Any?) {
        var next = diagramDocument.diagram
        let moved = next.page.nodes.filter { editableSelectionIDs.contains($0.id) && !next.page.isLocked($0) }
        let ids = Set(moved.map(\.id))
        next.page.nodes.removeAll { ids.contains($0.id) }
        next.page.nodes.append(contentsOf: moved)
        diagramDocument.replaceInEditor(with: next, action: "Bring to Front")
    }
    @objc func sendToBack(_ sender: Any?) {
        var next = diagramDocument.diagram
        let moved = next.page.nodes.filter { editableSelectionIDs.contains($0.id) && !next.page.isLocked($0) }
        let ids = Set(moved.map(\.id))
        next.page.nodes.removeAll { ids.contains($0.id) }
        next.page.nodes.insert(contentsOf: moved, at: 0)
        diagramDocument.replaceInEditor(with: next, action: "Send to Back")
    }
    @objc func toggleLock(_ sender: Any?) {
        var next = diagramDocument.diagram
        let lock = selection.contains { !$0.locked }
        for i in next.page.nodes.indices where canvas.selectedNodes.contains(next.page.nodes[i].id) {
            next.page.nodes[i].locked = lock
        }
        diagramDocument.replaceInEditor(with: next, action: lock ? "Lock Shapes" : "Unlock Shapes")
    }
    @objc func alignLeft(_ sender: Any?) {
        guard let x = selection.filter({ !$0.locked }).map(\.x).min() else { return }
        modifySelection("Align Left") { $0.x = x }
    }
    @objc func boldText(_ sender: Any?) {
        if canvas.formatEditingText("bold") { return }
        let enabled = !(selection.first?.bold ?? false)
        modifySelection("Bold Text") { $0.bold = enabled }
    }
    @objc func italicText(_ sender: Any?) {
        if canvas.formatEditingText("italic") { return }
        let enabled = !(selection.first?.formatting.italic ?? false)
        modifySelection("Italic Text") { $0.formatting.italic = enabled }
    }
    @objc func underlineText(_ sender: Any?) {
        if canvas.formatEditingText("underline") { return }
        let enabled = !(selection.first?.formatting.underline ?? false)
        modifySelection("Underline Text") { $0.formatting.underline = enabled }
    }
    @objc func alignCenter(_ sender: Any?) {
        guard !selection.isEmpty else { return }
        let x = selection.map { $0.center.x }.reduce(0, +) / Double(selection.count)
        modifySelection("Align Center") { $0.x = x - $0.width / 2 }
    }
    @objc func alignTop(_ sender: Any?) {
        guard let y = selection.filter({ !$0.locked }).map(\.y).min() else { return }
        modifySelection("Align Top") { $0.y = y }
    }
    @objc func distributeHorizontal(_ sender: Any?) { distribute(horizontal: true) }
    @objc func distributeVertical(_ sender: Any?) { distribute(horizontal: false) }
    private func distribute(horizontal: Bool) {
        let page = diagramDocument.diagram.page
        let roots = DiagramOperations.roots(canvas.selectedNodes, in: page)
        let nodes = page.nodes.filter { roots.contains($0.id) && !page.isLocked($0) }.sorted {
            horizontal ? $0.center.x < $1.center.x : $0.center.y < $1.center.y
        }
        guard nodes.count >= 3 else { return }
        let start = horizontal ? nodes.first!.center.x : nodes.first!.center.y
        let end = horizontal ? nodes.last!.center.x : nodes.last!.center.y
        var next = diagramDocument.diagram
        for (position, node) in nodes.enumerated() {
            guard let i = next.page.nodes.firstIndex(where: { $0.id == node.id }) else { continue }
            let c = start + (end - start) * Double(position) / Double(nodes.count - 1)
            if horizontal {
                next.page.nodes[i].x = c - node.width / 2
            } else {
                next.page.nodes[i].y = c - node.height / 2
            }
            if node.formatting.isGroup {
                let changed = next.page.nodes[i]
                DiagramOperations.transformChildren(in: &next.page, from: node, to: changed)
            }
        }
        diagramDocument.replaceInEditor(with: next, action: "Distribute Shapes")
    }
    @objc func addPage(_ sender: Any?) {
        canvas.finishEditing(commit: true)
        var next = diagramDocument.diagram
        var page = DiagramPage()
        page.name = "Page \(next.pages.count+1)"
        next.pages.append(page)
        next.activePageID = page.id
        diagramDocument.replaceInEditor(with: next, action: "Add Page")
        canvas.select([])
        canvas.fitPage()
    }
    @objc func duplicatePage(_ sender: Any?) {
        canvas.finishEditing(commit: true)
        var next = diagramDocument.diagram
        var p = next.page
        p.id = UUID()
        p.name += " Copy"
        // IDs need only be unique within a page, so connections remain intact.
        next.pages.append(p)
        next.activePageID = p.id
        diagramDocument.replaceInEditor(with: next, action: "Duplicate Page")
        canvas.select([])
    }
    @objc func deletePage(_ sender: Any?) {
        guard diagramDocument.diagram.pages.count > 1 else { return }
        let alert = NSAlert()
        alert.messageText = "Delete \(diagramDocument.diagram.page.name)?"
        alert.informativeText = "The page and its contents will be removed. You can undo this change."
        alert.addButton(withTitle: "Delete Page")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        canvas.finishPageInteraction()
        var next = diagramDocument.diagram
        do {
            try PageOperations.delete(next.page.id, in: &next)
            diagramDocument.replaceInEditor(with: next, action: "Delete Page")
            canvas.select([])
            canvas.fitPage()
        } catch { presentError(error) }
    }
    func switchPage(_ id: UUID) {
        guard diagramDocument.diagram.pages.contains(where: { $0.id == id }) else { return }
        window?.makeFirstResponder(canvas)
        canvas.finishPageInteraction()
        root.capturePageViewState()
        diagramDocument.activatePage(id)
        canvas.select([])
        setTool(.pointer)
        refresh()
        if !root.restorePageViewState(for: id) { canvas.fitPage() }
    }
    @objc func zoomIn(_ sender: Any?) { canvas.setZoom(canvas.zoom * 1.2) }
    @objc func zoomOut(_ sender: Any?) { canvas.setZoom(canvas.zoom / 1.2) }
    @objc func fitPage(_ sender: Any?) { canvas.fitPage() }
    @objc func actualSize(_ sender: Any?) { canvas.setZoom(1) }
    @objc func toggleGrid(_ sender: Any?) {
        canvas.showsGrid.toggle()
        canvas.needsDisplay = true
    }
    @objc func toggleSnap(_ sender: Any?) {
        canvas.snapsToGrid.toggle()
        root.snapButton.state = canvas.snapsToGrid ? .on : .off
    }
    @objc func pointerTool(_ sender: Any?) { setTool(.pointer) }
    @objc func connectorTool(_ sender: Any?) { setTool(.connector) }
    @objc func textTool(_ sender: Any?) { setTool(.text) }
    @objc func exportPDF(_ sender: Any?) { exportFile(ext: "pdf") }
    @objc func exportAllPagesPDF(_ sender: Any?) { exportFile(ext: "pdf", allPages: true) }
    @objc func exportPNG(_ sender: Any?) { exportFile(ext: "png") }
    @objc func exportSVG(_ sender: Any?) { exportFile(ext: "svg") }
    @objc func exportVSDX(_ sender: Any?) { exportFile(ext: "vsdx") }
    @objc func exportVSD(_ sender: Any?) { exportFile(ext: "vsd") }
    @objc func exportTemplate(_ sender: Any?) { exportFile(ext: "vstx") }
    func exportFile(ext: String, allPages: Bool = false) {
        canvas.finishEditing(commit: true)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: ext) ?? .data]
        panel.nameFieldStringValue = "\(diagramDocument.diagram.title).\(ext)"
        if ext == "vsd" {
            panel.message =
                "Experimental binary VSD: cached graphics/text; advanced behavior is incomplete. Output has not been validated in Microsoft Visio. Keep original files."
        }
        if allPages {
            panel.message =
                "Export foreground pages with their assigned backgrounds. Background pages are not separate PDF pages."
        }
        guard let window = window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self = self, let url = panel.url else { return }
            let snapshot = self.diagramDocument.diagram
            let owner = self.lifecycleJobs
            let input = LifecycleJobInput(
                ownerID: owner.id, snapshotID: self.diagramDocument.stateID,
                revision: self.diagramDocument.revision)
            let progress = LifecycleProgressController(
                title: "Exporting drawing", detail: url.lastPathComponent)
            do {
                guard let format = OwnedExportFormat(rawValue: ext) else {
                    throw DiagramError.invalid("This export format is unavailable.")
                }
                let handle = try OwnedExportJobs.submit(
                    snapshot: snapshot, input: input, sourceURL: self.diagramDocument.fileURL,
                    destination: url, format: format, allPages: allPages, owner: owner,
                    progress: { progress.update($0) },
                    completion: { [weak self] result in
                        progress.finish()
                        switch result {
                        case .success: self?.root.showMessage("Exported \(url.lastPathComponent)")
                        case .failure(let error):
                            if (error as? LifecycleJobError) != .cancelled
                                && (error as? LifecycleJobError) != .staleInput
                            {
                                self?.presentError(error)
                            }
                        }
                    })
                progress.onCancel = { handle.cancel() }
                progress.show()
            } catch {
                progress.finish()
                self.presentError(error)
            }
        }
    }
    @objc func printDiagram(_ sender: Any?) {
        canvas.finishEditing(commit: true)
        let view = ExportPageView(scene: diagramDocument.diagram.scene())
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.horizontalPagination = .fit
        info.verticalPagination = .fit
        info.isHorizontallyCentered = true
        info.isVerticallyCentered = true
        NSPrintOperation(view: view, printInfo: info).run()
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(editGeometry(_:)) {
            return selection.count == 1 && selection[0].formatting.geometry != nil
                && !diagramDocument.diagram.page.isLocked(selection[0])
        }
        if menuItem.action == #selector(editControls(_:)) {
            return selection.count == 1 && !diagramDocument.diagram.page.isLocked(selection[0])
        }
        if menuItem.action == #selector(editControlCells(_:)) {
            return selection.count == 1 && !selection[0].formatting.controls.isEmpty
                && !diagramDocument.diagram.page.isLocked(selection[0])
        }
        if [#selector(insertField(_:)), #selector(editTextFields(_:))].contains(menuItem.action) {
            return selection.count == 1 && !diagramDocument.diagram.page.isLocked(selection[0])
        }
        if [#selector(boldText(_:)), #selector(italicText(_:)), #selector(underlineText(_:))].contains(
            menuItem.action)
        {
            return canvas.isEditingText || !selection.isEmpty
        }
        if menuItem.action == #selector(exportSelectionStencil(_:)) {
            return !canvas.selectedNodes.isEmpty || canvas.selectedEdge != nil
        }
        if [#selector(editBackgroundPage(_:)), #selector(matchBackgroundSize(_:))].contains(menuItem.action) {
            return diagramDocument.diagram.page.backgroundPageID != nil
        }
        if menuItem.action == #selector(exportAllPagesPDF(_:)) {
            return diagramDocument.diagram.pages.contains { $0.isBackground != true }
        }
        if menuItem.action == #selector(toggleGrid(_:)) { menuItem.state = canvas.showsGrid ? .on : .off }
        if menuItem.action == #selector(toggleSnap(_:)) { menuItem.state = canvas.snapsToGrid ? .on : .off }
        if [#selector(deleteSelection(_:)), #selector(editText(_:))].contains(menuItem.action) {
            return !canvas.selectedNodes.isEmpty || canvas.selectedEdge != nil
        }
        if [
            #selector(duplicateSelection(_:)), #selector(bringToFront(_:)), #selector(sendToBack(_:)),
            #selector(toggleLock(_:)),
        ].contains(menuItem.action) {
            return !selection.isEmpty
        }
        if [#selector(alignLeft(_:)), #selector(alignCenter(_:)), #selector(alignTop(_:))].contains(
            menuItem.action)
        {
            return selection.count >= 2
        }
        if [#selector(distributeHorizontal(_:)), #selector(distributeVertical(_:))].contains(menuItem.action)
        {
            return selection.count >= 3
        }
        if menuItem.action == #selector(deletePage(_:)) { return diagramDocument.diagram.pages.count > 1 }
        return true
    }
}
