import Foundation

/// A transport record for native presentation and preservation policy. Adapters
/// must supply real source identities; this type never guesses them from prose.
/// It deliberately has no dependency on a calculation/runtime implementation.
struct DocumentDiagnostic: Codable, Equatable, Identifiable {
    enum Severity: String, Codable { case information, warning, error }
    enum Origin: String, Codable { case importer, calculation, preservation, font, content }
    enum Dimension: String, Codable { case preservation, rendering, editing, behavior, interchange }
    enum DisplayState: String, Codable { case evaluated, cached, stale, unavailable, notApplicable }
    enum Target: Codable, Hashable {
        case document
        case page(UUID)
        case shape(page: UUID, shape: UUID)
        case connector(page: UUID, connector: UUID)

        var pageID: UUID? {
            switch self {
            case .document: return nil
            case .page(let id), .shape(let id, _), .connector(let id, _): return id
            }
        }
        var objectID: UUID? {
            switch self {
            case .document, .page: return nil
            case .shape(_, let id), .connector(_, let id): return id
            }
        }
    }
    struct Source: Codable, Hashable {
        /// Package-relative part name; never interpreted as a URL or executed.
        var part: String?
        var visioID: String?
        /// The exact authored address, not an address parsed from a message.
        var cell: String?
        /// Distinguishes source features sharing a target, e.g. master or solution.
        var feature: String?
    }
    struct ID: Codable, Hashable {
        var origin: Origin
        var code: String
        var target: Target
        var source: Source
    }
    enum Action: String, Codable { case viewDetails, revealTarget, inspectCell, reviewPolicy, saveCopy }

    var code: String
    var origin: Origin
    var severity: Severity
    var dimension: Dimension
    var target: Target
    var source: Source = Source()
    var displayState: DisplayState
    var message: String
    /// Opaque producer key. The owner must compare this with accepted input
    /// identity before presenting a result; this record does not own revisions.
    var inputKey: String?
    var requestedActions: [Action] = [.viewDetails]

    /// Presentation wording, severity and cache state can change without losing
    /// issue identity. Two objects reporting identical text remain distinct.
    var id: ID { ID(origin: origin, code: code, target: target, source: source) }
    var isMaterial: Bool { severity != .information }
    var actions: [Action] {
        var seen = Set<Action>()
        return requestedActions.filter { action in
            guard seen.insert(action).inserted else { return false }
            switch action {
            case .revealTarget: return target.pageID != nil
            case .inspectCell: return target.pageID != nil && source.cell?.isEmpty == false
            case .viewDetails, .reviewPolicy, .saveCopy: return true
            }
        }
    }

    /// Anonymous legacy notes stay document-scoped. Conversion is a truthful
    /// bridge, not object-level acceptance for an importer/calculation producer.
    static func legacyImportNote(_ message: String, code: String) -> DocumentDiagnostic {
        DocumentDiagnostic(code: code, origin: .importer, severity: .warning,
                           dimension: .interchange, target: .document,
                           displayState: .notApplicable, message: message)
    }
}
