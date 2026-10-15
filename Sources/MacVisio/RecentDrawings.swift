import Foundation

/// Local file history only; showing Home never reads or downloads document contents.
final class RecentDrawingStore {
    private let defaults:UserDefaults
    private let limit:Int
    private let recentKey = "MacVisioRecentDrawings.v1"
    private let pinnedKey = "MacVisioPinnedDrawings.v1"
    init(defaults:UserDefaults = .standard,limit:Int = 30) { self.defaults = defaults;self.limit = max(1,limit) }
    static func canonical(_ url:URL) -> URL { url.standardizedFileURL }
    private func urls(_ key:String) -> [URL] {
        var seen = Set<URL>()
        return (defaults.stringArray(forKey:key) ?? []).compactMap(URL.init(string:)).filter{$0.isFileURL}.map(Self.canonical).filter{seen.insert($0).inserted}
    }
    func record(_ url:URL) {
        guard url.isFileURL else { return }
        let url = Self.canonical(url)
        defaults.set(Array(([url]+urls(recentKey).filter{$0 != url}).prefix(limit)).map(\.absoluteString),forKey:recentKey)
    }
    func togglePin(_ url:URL) {
        guard url.isFileURL else { return }
        let url = Self.canonical(url),pinned = urls(pinnedKey)
        defaults.set((pinned.contains(url) ? pinned.filter{$0 != url} : pinned+[url]).map(\.absoluteString),forKey:pinnedKey)
    }
    func clearHistory() { defaults.removeObject(forKey:recentKey) }
    func entries(including systemURLs:[URL] = []) -> [RecentDrawing] {
        let pinned = urls(pinnedKey),pinSet = Set(pinned)
        var seen = Set<URL>()
        let history = (urls(recentKey)+systemURLs.filter{$0.isFileURL}.map(Self.canonical)).filter{seen.insert($0).inserted}
        return (pinned+Array(history.filter{!pinSet.contains($0)}.prefix(limit))).map { url in
            RecentDrawing(url:url,title:url.lastPathComponent,location:url.deletingLastPathComponent().path,isPinned:pinSet.contains(url))
        }
    }
}
