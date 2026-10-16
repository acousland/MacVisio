import Foundation

/// Local file history only; showing Home never reads or downloads document contents.
final class RecentDrawingStore {
    private let defaults:UserDefaults
    private let limit:Int
    private let recentKey = "MacVisioRecentDrawings.v1"
    private let pinnedKey = "MacVisioPinnedDrawings.v1"
    private let removedKey = "MacVisioRemovedDrawings.v1"
    init(defaults:UserDefaults = .standard,limit:Int = 30) { self.defaults = defaults;self.limit = max(1,limit) }
    static func canonical(_ url:URL) -> URL { url.standardizedFileURL }
    private func urls(_ key:String) -> [URL] {
        var seen = Set<URL>()
        return (defaults.stringArray(forKey:key) ?? []).compactMap(URL.init(string:)).filter{$0.isFileURL}.map(Self.canonical).filter{seen.insert($0).inserted}
    }
    func record(_ url:URL) {
        guard url.isFileURL else { return }
        let url = Self.canonical(url)
        defaults.set(urls(removedKey).filter{$0 != url}.map(\.absoluteString),forKey:removedKey)
        defaults.set(Array(([url]+urls(recentKey).filter{$0 != url}).prefix(limit)).map(\.absoluteString),forKey:recentKey)
    }
    func togglePin(_ url:URL) {
        guard url.isFileURL else { return }
        let url = Self.canonical(url),pinned = urls(pinnedKey)
        if !pinned.contains(url) {
            defaults.set(urls(removedKey).filter{$0 != url}.map(\.absoluteString),forKey:removedKey)
        }
        defaults.set((pinned.contains(url) ? pinned.filter{$0 != url} : pinned+[url]).map(\.absoluteString),forKey:pinnedKey)
    }
    /// Forget an entry without deleting the drawing. A local suppression keeps
    /// merged system recents from resurrecting an explicitly removed file.
    func remove(_ url:URL) {
        guard url.isFileURL else { return }
        let url = Self.canonical(url)
        for key in [recentKey,pinnedKey] {
            defaults.set(urls(key).filter{$0 != url}.map(\.absoluteString),forKey:key)
        }
        defaults.set((urls(removedKey).filter{$0 != url}+[url]).map(\.absoluteString),forKey:removedKey)
    }
    /// Update the history reference after the user locates a moved drawing.
    /// This changes local history only; it never moves, opens or reads a file.
    func relocate(_ oldURL:URL,to newURL:URL) {
        guard oldURL.isFileURL,newURL.isFileURL else { return }
        let old = Self.canonical(oldURL),new = Self.canonical(newURL)
        guard old != new else { return }
        let history = urls(recentKey),pins = urls(pinnedKey)
        func relocated(_ values:[URL]) -> [URL] {
            var seen = Set<URL>()
            return values.map{$0 == old ? new : $0}.filter{seen.insert($0).inserted}
        }
        defaults.set(relocated(history.contains(old) ? history : [new]+history).prefix(limit).map(\.absoluteString),forKey:recentKey)
        defaults.set(relocated(pins).map(\.absoluteString),forKey:pinnedKey)
        defaults.set((urls(removedKey).filter{$0 != old && $0 != new}+[old]).map(\.absoluteString),forKey:removedKey)
    }
    func clearHistory() { defaults.removeObject(forKey:recentKey) }
    func entries(including systemURLs:[URL] = []) -> [RecentDrawing] {
        let removed = Set(urls(removedKey))
        let pinned = urls(pinnedKey).filter{!removed.contains($0)},pinSet = Set(pinned)
        var seen = Set<URL>()
        let history = (urls(recentKey)+systemURLs.filter{$0.isFileURL}.map(Self.canonical)).filter{!removed.contains($0) && seen.insert($0).inserted}
        return (pinned+Array(history.filter{!pinSet.contains($0)}.prefix(limit))).map { url in
            RecentDrawing(url:url,title:url.lastPathComponent,location:url.deletingLastPathComponent().path,isPinned:pinSet.contains(url))
        }
    }
}
