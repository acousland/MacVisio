import Foundation

/// Public master ownership is independent of its display name and ephemeral card ID.
struct StencilSource: Equatable {
    var url: URL
    var masterID: String
    var universalName: String
    var key: String { url.standardizedFileURL.absoluteString + "#master=" + (UInt32(masterID).map(String.init) ?? masterID) }
}

/// Small offline preferences contain identities only, never master/media payloads.
final class LibraryPins {
    struct State: Codable, Equatable {
        var version = 1
        var libraries: Set<String> = []
        var masters: Set<String> = []
        var libraryURLs: [URL] { libraries.sorted().compactMap(URL.init(string:)) }
    }
    static let shared = LibraryPins(defaults: .standard)
    static let didChange = Notification.Name("MacVisioLibraryPinsChanged")
    private let defaults: UserDefaults
    private let lock = NSLock()
    private let key = "MacVisio.LibraryPins.v1"
    init(defaults: UserDefaults) { self.defaults = defaults }

    var snapshot: State {
        lock.lock(); defer { lock.unlock() }
        return load()
    }
    private func load() -> State {
        guard let data = defaults.data(forKey:key),data.count <= 2_000_000,
              let state = try? JSONDecoder().decode(State.self,from:data),valid(state) else { return State() }
        return state
    }
    private func valid(_ state: State) -> Bool {
        state.version == 1 && state.libraries.count <= 256 && state.masters.count <= 10000
            && state.libraries.allSatisfy { $0.utf8.count <= 4096 && URL(string:$0)?.isFileURL == true }
            && state.masters.allSatisfy { !$0.isEmpty && $0.utf8.count <= 4352 }
    }
    private func update(_ edit: (inout State) -> Void) throws {
        lock.lock()
        do {
            let previous = load();var next = previous;edit(&next)
            guard valid(next) else { throw DiagramError.invalid("The pinned library or master limit has been reached.") }
            guard next != previous else { lock.unlock();return }
            let data = try JSONEncoder().encode(next)
            guard data.count <= 2_000_000 else { throw DiagramError.invalid("The pinned library preferences exceed the supported size.") }
            defaults.set(data,forKey:key);lock.unlock()
        } catch { lock.unlock();throw error }
        NotificationCenter.default.post(name:Self.didChange,object:self)
    }
    func setLibrary(_ url:URL,pinned:Bool) throws {
        guard url.isFileURL else { throw DiagramError.invalid("Choose a local library file to pin.") }
        let path = url.standardizedFileURL.absoluteString
        try update { if pinned { $0.libraries.insert(path) } else { $0.libraries.remove(path) } }
    }
    func setMaster(_ source:StencilSource,pinned:Bool) throws {
        guard source.url.isFileURL,UInt32(source.masterID) != nil else { throw DiagramError.invalid("This master has no stable public library identity.") }
        try update { if pinned { $0.masters.insert(source.key) } else { $0.masters.remove(source.key) } }
    }
    func isPinned(_ entry:VisioLibraryEntry) -> Bool { snapshot.libraries.contains(entry.url.standardizedFileURL.absoluteString) }
    func isPinned(_ source:StencilSource?) -> Bool { source.map { snapshot.masters.contains($0.key) } ?? false }
}
