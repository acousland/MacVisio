import AppKit
import Foundation
import MacVisioInfrastructure
import ObjectiveC

/// Stored preferences remain the authority. Neither a missing source nor a
/// changed caption rewrites its lexical URL/public-master identity.
enum PinnedLibraryReference: Hashable {
    case library(String)
    case master(String)

    var key: String { switch self { case .library(let key), .master(let key): return key } }
    var source: (url: URL, masterID: String?)? {
        let urlText: String, masterID: String?
        switch self {
        case .library(let key): urlText = key; masterID = nil
        case .master(let key):
            guard let split = key.range(of: "#master=", options: .backwards),
                  let id = UInt32(key[split.upperBound...]) else { return nil }
            urlText = String(key[..<split.lowerBound]); masterID = String(id)
        }
        guard let url = URL(string: urlText), url.isFileURL,
              url.host == nil || url.host == "" || url.host == "localhost",
              url.query == nil, url.fragment == nil, url.path.hasPrefix("/"),
              url.user == nil, url.password == nil, url.port == nil, !url.path.contains("\0") else { return nil }
        return (URL(fileURLWithPath: url.path).standardizedFileURL, masterID)
    }
    var title: String {
        guard let source else { return "Invalid stored pin" }
        return source.url.lastPathComponent + (source.masterID.map { " · Master \($0)" } ?? "")
    }
    func isPresent(in state: LibraryPins.State) -> Bool {
        switch self { case .library(let key): return state.libraries.contains(key)
        case .master(let key): return state.masters.contains(key) }
    }
}

enum PinnedLibraryFailure: Error, LocalizedError, Equatable {
    case invalidIdentity, missing, linkedSource, nonlocalSource, unsupported, changed, missingMaster, paletteChanged, limit
    case unreadable(String)
    case job(LifecycleJobError)
    var errorDescription: String? {
        switch self {
        case .invalidIdentity: return "The stored local file or public master identity is invalid. Unpin it and pin the intended source again."
        case .missing: return "The pinned file is missing. Restore it at this exact path, then Retry, or Unpin."
        case .linkedSource: return "The pinned path now contains a symbolic link. Open and pin the intended local source explicitly."
        case .nonlocalSource: return "Automatic loading requires a file on a local volume."
        case .unsupported: return "Only public VSSX stencils load automatically. Open binary stencils or templates explicitly."
        case .changed: return "The pinned source changed while it was being read. Retry to read its current contents."
        case .missingMaster: return "This public master ID is absent from the pinned file. Unpin it and choose the intended master explicitly."
        case .paletteChanged: return "Shapes changed while pinned stencils were loading. Retry to review the current palette; the pending result was not installed."
        case .limit: return "The automatic pinned-stencil source, master or retained-payload limit was reached. Unpin unused sources or open this stencil explicitly."
        case .unreadable(let detail): return "The pinned file could not be read: \(detail)"
        case .job(let error): return error.localizedDescription
        }
    }
}

struct PinnedLibraryRow: Equatable {
    enum Status: Equatable {
        case waiting, loading, loaded(Int), unavailable(PinnedLibraryFailure), cancelled
        var text: String {
            switch self {
            case .waiting: return "Waiting to load"
            case .loading: return "Loading…"
            case .loaded(let count): return "Loaded \(count) master\(count == 1 ? "" : "s")"
            case .unavailable(let failure): return failure.localizedDescription
            case .cancelled: return "Loading cancelled. Retry when ready."
            }
        }
    }
    let reference: PinnedLibraryReference
    var status: Status
    var notes: [String] = []
}

struct PinnedLibraryLoadResult {
    let rows: [PinnedLibraryRow]
    let items: [StencilDefinition]
    let retainedCost: Int
}

/// Uses the accepted LRU implementation. The declared payload charge includes
/// serialized fragment/media bytes, strings and structural allowance; it is
/// conservative accounting, not an allocator/RSS measurement.
final class PinnedStencilCache {
    struct Key: Hashable {
        let url: URL, device: UInt64, inode: UInt64, bytes: UInt64, modified: Date?
        init(_ version: DocumentSourceVersion) {
            url = version.url; device = version.device; inode = version.inode
            bytes = version.bytes; modified = version.modified
        }
    }
    struct Value {
        let items: [StencilDefinition]
        let warnings: [String]
        let costs: [Int]
        var cost: Int { costs.reduce(0, +) + warnings.reduce(0) { $0 + $1.utf8.count * 2 + 64 } }
    }
    typealias Reader = (URL) throws -> (items: [StencilDefinition], warnings: [String])
    static let shared = PinnedStencilCache()
    static let maximumCost = ResourceBudgets.retainedPaths
    private let storage: ResourceBudgetCache<Key, Value>
    init(maximumCount: Int = 16, maximumCost: Int = PinnedStencilCache.maximumCost) {
        storage = ResourceBudgetCache(maximumCount: maximumCount, maximumCost: maximumCost)
    }
    var statistics: ResourceBudgetCache<Key, Value>.Statistics { storage.statistics }
    func removeAll() { storage.removeAll() }

    func read(_ url: URL, reader: Reader = VisioStencil.read(from:)) throws -> Value {
        try LifecycleJobContext.current?.checkpoint()
        try Self.validateLocalFile(url)
        let before = try DocumentSourceVersion.read(url), key = Key(before)
        if let value = storage.value(for: key) { return value }
        let imported = try reader(url)
        try LifecycleJobContext.current?.checkpoint()
        do { try Self.validateLocalFile(url) }
        catch let error as LifecycleJobError { throw error }
        catch { throw PinnedLibraryFailure.changed }
        guard let after = try? DocumentSourceVersion.read(url), before == after else { throw PinnedLibraryFailure.changed }
        var seen = Set<String>(), costs: [Int] = []
        for item in imported.items {
            try LifecycleJobContext.current?.checkpoint()
            guard let source = item.source, source.url == before.url,
                  UInt32(source.masterID) != nil, seen.insert(source.key).inserted else {
                throw PinnedLibraryFailure.invalidIdentity
            }
            let bytes = try JSONEncoder().encode(item.fragment).count
            costs.append(bytes * 2 + (item.name.utf8.count + item.family.utf8.count + source.key.utf8.count + source.universalName.utf8.count) * 2 + 2048)
        }
        let warnings = imported.warnings.prefix(8).map { String($0.prefix(512)) }
        let value = Value(items: imported.items, warnings: warnings, costs: costs)
        guard value.cost <= Self.maximumCost else { throw PinnedLibraryFailure.limit }
        storage.insert(value, for: key, cost: value.cost)
        return value
    }

    private static func validateLocalFile(_ url: URL) throws {
        guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost",
              url.pathExtension.lowercased() == "vssx" else { throw PinnedLibraryFailure.unsupported }
        do {
            // Match the existing library path policy: reject a linked file,
            // resolve lexical parent aliases, retain the original stored key.
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType != .typeSymbolicLink else { throw PinnedLibraryFailure.linkedSource }
            let resource = try url.resourceValues(forKeys: [.isRegularFileKey, .volumeIsLocalKey])
            guard resource.volumeIsLocal == true else { throw PinnedLibraryFailure.nonlocalSource }
            guard resource.isRegularFile == true else { throw PinnedLibraryFailure.unreadable("The source is not a regular file.") }
        } catch let failure as PinnedLibraryFailure { throw failure }
        catch let error as NSError {
            if error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) { throw PinnedLibraryFailure.missing }
            throw PinnedLibraryFailure.unreadable(String(error.localizedDescription.prefix(512)))
        }
    }
}

enum PinnedLibraryLoader {
    static let maximumSources = 32
    static let maximumMasters = 10_000
    static let maximumCost = PinnedStencilCache.maximumCost
    static func references(in state: LibraryPins.State) -> [PinnedLibraryReference] {
        state.libraries.sorted().map(PinnedLibraryReference.library) + state.masters.sorted().map(PinnedLibraryReference.master)
    }
    static func load(_ state: LibraryPins.State, cache: PinnedStencilCache = .shared,
                     maximumSources: Int = PinnedLibraryLoader.maximumSources, maximumCost: Int = PinnedLibraryLoader.maximumCost,
                     reader: PinnedStencilCache.Reader = VisioStencil.read(from:)) throws -> PinnedLibraryLoadResult {
        guard state.version == 1, state.libraries.count <= 256, state.masters.count <= 10_000,
              state.libraries.allSatisfy({ $0.utf8.count <= 4096 }), state.masters.allSatisfy({ $0.utf8.count <= 4352 }),
              state.libraries.reduce(0, { $0 + $1.utf8.count }) + state.masters.reduce(0, { $0 + $1.utf8.count }) <= 2_000_000,
              maximumSources >= 0, maximumCost >= 0 else { throw PinnedLibraryFailure.limit }
        var rows = references(in: state).map { PinnedLibraryRow(reference: $0, status: .waiting) }
        var groups: [URL: [Int]] = [:]
        for i in rows.indices {
            try LifecycleJobContext.current?.checkpoint()
            guard let source = rows[i].reference.source else { rows[i].status = .unavailable(.invalidIdentity); continue }
            guard source.url.pathExtension.lowercased() == "vssx" else { rows[i].status = .unavailable(.unsupported); continue }
            groups[source.url, default: []].append(i)
        }
        var items: [StencilDefinition] = [], seen = Set<String>()
        var cost = rows.reduce(0) { $0 + $1.reference.key.utf8.count * 2 + 512 }
        guard cost <= maximumCost else { throw PinnedLibraryFailure.limit }
        for (ordinal, url) in groups.keys.sorted(by: { $0.absoluteString < $1.absoluteString }).enumerated() {
            try LifecycleJobContext.current?.checkpoint()
            let indices = groups[url]!
            guard ordinal < maximumSources else { for i in indices { rows[i].status = .unavailable(.limit) }; continue }
            do {
                LifecycleJobContext.current?.progress("Loading pinned \(url.lastPathComponent)", fraction: Double(ordinal) / Double(max(1, min(maximumSources, groups.count))))
                let value = try cache.read(url, reader: reader)
                var publicCounts: [String: Int] = [:]
                for item in value.items {
                    try LifecycleJobContext.current?.checkpoint()
                    if let id = item.source.flatMap({ UInt32($0.masterID).map(String.init) }) { publicCounts[id, default: 0] += 1 }
                }
                let entireLibrary = indices.contains { if case .library = rows[$0].reference { return true }; return false }
                let ids = Set(indices.compactMap { rows[$0].reference.source?.masterID })
                let chosen = value.items.indices.filter { index in
                    guard let source = value.items[index].source, !seen.contains(source.key) else { return false }
                    return entireLibrary || UInt32(source.masterID).map { ids.contains(String($0)) } == true
                }
                let addedCost = chosen.reduce(0) { $0 + value.costs[$1] } + value.warnings.reduce(0) { $0 + $1.utf8.count * 2 + 64 }
                guard items.count + chosen.count <= maximumMasters, addedCost <= maximumCost - cost else { throw PinnedLibraryFailure.limit }
                items.append(contentsOf: chosen.map { value.items[$0] }); cost += addedCost
                seen.formUnion(chosen.compactMap { value.items[$0].source?.key })
                for i in indices {
                    try LifecycleJobContext.current?.checkpoint()
                    let id = rows[i].reference.source?.masterID
                    let count = id.map { publicCounts[$0, default: 0] } ?? value.items.count
                    rows[i].status = count > 0 ? .loaded(count) : .unavailable(.missingMaster)
                    if i == indices.first { rows[i].notes = value.warnings }
                }
            } catch let error as LifecycleJobError { throw error }
            catch {
                let failure = (error as? PinnedLibraryFailure) ?? .unreadable(String(error.localizedDescription.prefix(512)))
                for i in indices { rows[i].status = .unavailable(failure) }
            }
        }
        try LifecycleJobContext.current?.checkpoint()
        return PinnedLibraryLoadResult(rows: rows, items: items, retainedCost: cost)
    }
}

/// A single replaceable owned request bounds startup fan-out. Pin changes cancel
/// the predecessor. Ordinary drawing edits do not invalidate library resources.
final class PinnedLibraryCoordinator {
    private weak var editor: EditorWindowController?
    private let owner: LifecycleJobOwner
    let pins: LibraryPins
    private let cache: PinnedStencilCache
    private let reader: PinnedStencilCache.Reader
    private let service: LifecycleJobService
    private var observer: NSObjectProtocol?
    private var handle: LifecycleJobHandle?
    private var generation = UUID()
    private var started = false
    private var installedIDs = Set<UUID>()
    private(set) var rows: [PinnedLibraryRow] = []
    var onChange: (() -> Void)?
    var isLoading: Bool { handle != nil }
    init(editor: EditorWindowController, pins: LibraryPins = .shared, cache: PinnedStencilCache = .shared,
         service: LifecycleJobService = .shared, reader: @escaping PinnedStencilCache.Reader = VisioStencil.read(from:)) {
        self.editor = editor; owner = editor.lifecycleJobs; self.pins = pins
        self.cache = cache; self.service = service; self.reader = reader
        observer = NotificationCenter.default.addObserver(forName: LibraryPins.didChange, object: pins, queue: .main) { [weak self] _ in
            guard let self, self.started else { return }; self.reload()
        }
    }
    deinit { handle?.cancel(); if let observer { NotificationCenter.default.removeObserver(observer) } }
    func start() { guard !started else { return }; started = true; reload() }
    func reload() {
        guard owner.isActive, editor != nil else { return }
        handle?.cancel(); handle = nil
        let request = UUID(), state = pins.snapshot; generation = request
        let baseline = editor?.stencils ?? []
        rows = PinnedLibraryLoader.references(in: state).map { PinnedLibraryRow(reference: $0, status: .loading) }
        guard !rows.isEmpty else { install([]); onChange?(); return }
        let input = LifecycleJobInput(ownerID: owner.id, snapshotID: request, revision: 0), id = UUID()
        let cache = cache, reader = reader, owner = owner
        do {
            let next = try service.submit(id: id, kind: .library, input: input, accepts: { [weak self] candidate in
                guard let self else { return false }
                return owner.isActive && candidate.ownerID == owner.id && self.generation == candidate.snapshotID && self.pins.snapshot == state && self.paletteStillAccepts(baseline)
            }, work: { _ in try PinnedLibraryLoader.load(state, cache: cache, reader: reader) }, completion: { [weak self] result in
                owner.finish(id)
                guard let self, owner.isActive, self.generation == request, self.pins.snapshot == state else { return }
                self.handle = nil
                guard self.paletteStillAccepts(baseline) else {
                    self.rows = self.rows.map { row in var row = row; row.status = .unavailable(.paletteChanged); return row }
                    self.onChange?(); return
                }
                switch result {
                case .success(let loaded): self.rows = loaded.rows; self.install(loaded.items)
                case .failure(let error):
                    self.rows = self.rows.map { row in
                        var row = row
                        if let job = error as? LifecycleJobError { row.status = job == .cancelled ? .cancelled : .unavailable(.job(job)) }
                        else { row.status = .unavailable((error as? PinnedLibraryFailure) ?? .unreadable(String(error.localizedDescription.prefix(512)))) }
                        return row
                    }
                }
                self.onChange?()
            })
            handle = next; owner.track(next, replacing: "pinned-stencils")
        } catch {
            let failure = (error as? LifecycleJobError).map(PinnedLibraryFailure.job) ?? (error as? PinnedLibraryFailure) ?? .unreadable(String(error.localizedDescription.prefix(512)))
            rows = rows.map { row in var row = row; row.status = .unavailable(failure); return row }
        }
        onChange?()
    }
    func cancel() {
        generation = UUID(); handle?.cancel(); handle = nil
        rows = rows.map { row in var row = row; if row.status == .loading { row.status = .cancelled }; return row }
        onChange?()
    }
    func detach() {
        cancel(); if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
        onChange = nil; editor = nil; installedIDs = []; rows = []
    }
    /// New manual entries can merge. Existing entries cannot disappear, change
    /// or move under an outstanding result, including automatic entries which
    /// the user removed or edited. Explicit Retry captures the newer baseline.
    private func paletteStillAccepts(_ baseline: [StencilDefinition]) -> Bool {
        guard let editor else { return false }
        let current = editor.stencils
        guard Set(current.map(\.id)).count == current.count else { return false }
        let baselineIDs = Set(baseline.map(\.id))
        guard current.filter({ baselineIDs.contains($0.id) }).map(\.id) == baseline.map(\.id) else { return false }
        let byID = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
        return baseline.allSatisfy { prior in
            guard let now = byID[prior.id] else { return false }
            return prior.name == now.name && prior.family == now.family && prior.source == now.source && prior.fragment == now.fragment
        }
    }
    private func install(_ items: [StencilDefinition]) {
        guard owner.isActive, let editor else { return }
        let prior = editor.stencils.filter { installedIDs.contains($0.id) }
        let priorIDs = Dictionary(prior.compactMap { item in item.source.map { ($0.key, item.id) } }, uniquingKeysWith: { first, _ in first })
        var retained = editor.stencils.filter { !installedIDs.contains($0.id) }
        var seen = Set(retained.compactMap { $0.source?.key }), added = Set<UUID>()
        for var item in items {
            guard let key = item.source?.key, seen.insert(key).inserted else { continue }
            item.id = priorIDs[key] ?? item.id; retained.append(item); added.insert(item.id)
        }
        editor.stencils = retained; installedIDs = added
        editor.root.stencil.refreshCategories()
    }
}

private var pinnedLibraryCoordinatorKey: UInt8 = 0
private var pinnedLibraryControlsKey: UInt8 = 0
extension EditorWindowController {
    /// Configure an isolated preference/cache owner before first presentation.
    /// This also lets native startup tests avoid the user's shared preferences.
    @discardableResult
    func configurePinnedLibraries(pins: LibraryPins, cache: PinnedStencilCache = .shared,
                                  service: LifecycleJobService = .shared,
                                  reader: @escaping PinnedStencilCache.Reader = VisioStencil.read(from:)) -> Bool {
        guard lifecycleJobs.isActive, objc_getAssociatedObject(self, &pinnedLibraryCoordinatorKey) == nil else { return false }
        let value = PinnedLibraryCoordinator(editor: self, pins: pins, cache: cache, service: service, reader: reader)
        objc_setAssociatedObject(self, &pinnedLibraryCoordinatorKey, value, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return true
    }
    var pinnedLibraries: PinnedLibraryCoordinator {
        if let existing = objc_getAssociatedObject(self, &pinnedLibraryCoordinatorKey) as? PinnedLibraryCoordinator { return existing }
        let value = PinnedLibraryCoordinator(editor: self)
        objc_setAssociatedObject(self, &pinnedLibraryCoordinatorKey, value, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return value
    }
    /// Root calls once after an editor becomes visible. Loading never focuses a control.
    func startPinnedLibraries() { guard lifecycleJobs.isActive else { return }; pinnedLibraries.start() }
    func detachPinnedLibraries() {
        (objc_getAssociatedObject(self, &pinnedLibraryControlsKey) as? PinnedLibraryControls)?.detach()
        (objc_getAssociatedObject(self, &pinnedLibraryCoordinatorKey) as? PinnedLibraryCoordinator)?.detach()
        objc_setAssociatedObject(self, &pinnedLibraryControlsKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        objc_setAssociatedObject(self, &pinnedLibraryCoordinatorKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
    @objc func managePinnedLibraries(_ sender: Any?) {
        guard lifecycleJobs.isActive else { return }
        guard (window?.firstResponder as? NSTextView)?.hasMarkedText() != true else { root.showMessage("Finish text composition before managing pinned libraries."); return }
        let controls: PinnedLibraryControls
        if let existing = objc_getAssociatedObject(self, &pinnedLibraryControlsKey) as? PinnedLibraryControls { controls = existing }
        else {
            controls = PinnedLibraryControls(editor: self, coordinator: pinnedLibraries)
            objc_setAssociatedObject(self, &pinnedLibraryControlsKey, controls, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        pinnedLibraries.start(); controls.showWindow(nil)
    }
}
