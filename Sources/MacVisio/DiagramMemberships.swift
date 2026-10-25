import Foundation
import MacVisioInfrastructure

/// Structural references are retained source metadata, independent of group
/// parentage. This parser does not evaluate DEPENDSON or infer visual containment.
enum DiagramMemberships {
    static let namespace = "http://schemas.microsoft.com/office/visio/2012/main"
    static let relationshipCell = "Relationships"
    static let maximumReferences = 150_000
    private static let supportedContainerPolicies: Set<String> = ["User.msvSDContainerLocked", "User.msvSDContainerRequiredCategories", "User.msvSDContainerExcludedCategories", "User.msvSDContainerMargin", "User.msvSDContainerResize"]

    static func managedCellReason(_ key: String) -> String? {
        guard key.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(relationshipCell) == .orderedSame else { return nil }
        return "Relationships is managed by Memberships. Add or remove one explicit container edge there; list, lane and callout relationships remain read-only."
    }
    static func hasStructuralOwnerMetadata(_ node: DiagramNode) -> Bool {
        let aliases = node.formatting.sheet.keys.filter { managedCellReason($0) != nil }
        if !aliases.isEmpty && aliases != [relationshipCell] { return true }
        if node.formatting.sheet["User.msvStructureType"] != nil { return true }
        guard let cell = node.formatting.sheet[relationshipCell] else { return false }
        guard let parsed = try? parse(cell) else { return true }
        return parsed.clauses.contains { $0.kind == .containerMembers || $0.kind == .listMembers }
    }
    /// Preserve legacy synchronous basic commands only where no archive or
    /// structural metadata can hide a relationship owner/dependency.
    static func needsSourceProof(in diagram: Diagram, pageID: UUID) -> Bool {
        if diagram.visioArchive != nil { return true }
        guard let page = diagram.pages.first(where: { $0.id == pageID }) else { return true }
        func structural(_ detail: ShapeDetails) -> Bool {
            detail.sheet["User.msvStructureType"] != nil || detail.sheet.keys.contains { managedCellReason($0) != nil }
        }
        return page.nodes.contains { structural($0.formatting) } || page.edges.contains { structural($0.formatting) }
    }

    enum Kind: Int, CaseIterable {
        case containerMembers = 1, listMembers, callouts, containers, list, calloutTarget
        case leftBoundary, rightBoundary, topBoundary, bottomBoundary, overlappingList
    }
    enum Role: String { case container = "Container", list = "List", callout = "Callout", ordinary = "" }
    struct Clause: Equatable {
        let kind: Kind
        let targets: [UInt32]
        let raw: String
        fileprivate let prefix: String
        fileprivate let arguments: [String]
        fileprivate let suffix: String
        fileprivate func replacing(_ next: [UInt32]) -> String {
            let retained = Dictionary(uniqueKeysWithValues: zip(targets, arguments.dropFirst()).map { ($0.0, $0.1) })
            return prefix + ([arguments[0]] + next.map { retained[$0] ?? "Sheet.\($0)!SheetRef()" }).joined(separator: ",") + suffix
        }
    }
    struct Formula: Equatable {
        let clauses: [Clause]
        fileprivate let prefix: String
        fileprivate let suffix: String
        func targets(_ kind: Kind) -> [UInt32] { clauses.first { $0.kind == kind }?.targets ?? [] }
        func replacing(_ kind: Kind, with targets: [UInt32]) -> String {
            var pieces = clauses.map(\.raw)
            if let index = clauses.firstIndex(where: { $0.kind == kind }) {
                if targets.isEmpty { pieces.remove(at: index) }
                else { pieces[index] = clauses[index].replacing(targets) }
            } else if !targets.isEmpty {
                pieces.append("DEPENDSON(\(kind.rawValue)," + targets.map { "Sheet.\($0)!SheetRef()" }.joined(separator: ",") + ")")
            }
            return pieces.isEmpty ? "0" : prefix + pieces.joined(separator: ",") + suffix
        }
    }
    struct Entry {
        let id: UUID
        let publicID: UInt32
        let sourceID: String
        let title: String
        let role: Role
        let cell: ShapeSheetCell?
        let formula: Formula?
        let sourceRefusal: String?
        /// A retained source/cache owner could not prove its structural closure.
        /// Separate from missing public source for an ordinary unsaved object.
        var unprovenRetainedOwnership: Bool
        let connector: Bool
    }
    struct Relation: Hashable {
        let owner: UUID
        let target: UUID
        let kind: Kind
    }
    struct Index {
        let pageID: UUID
        let entries: [UUID: Entry]
        let order: [UUID]
        let byPublicID: [UInt32: UUID]
        let relations: [Relation]
        let outgoing: [UUID: [Relation]]
        let incoming: [UUID: [Relation]]
        let issues: [String]
        var containers: [Entry] { order.compactMap { entries[$0] }.filter { $0.role == .container && !$0.connector } }
        func contains(member: UUID, container: UUID) -> Bool {
            outgoing[member, default: []].contains { $0.kind == .containers && $0.target == container }
        }
    }
    private struct RawShape {
        var cells: [String: ShapeSheetCell] = [:]
        var ambiguous = false
        var hasMaster = false
        var deleted = false
        var name = ""
        var sourceID = ""
    }

    /// Accept a deliberately small grammar: SUM of DEPENDSON(category,
    /// Sheet.ID!SheetRef(), ...), one clause per documented category. Existing empty
    /// clauses are retained as source metadata; edits never author empty clauses. Names, arithmetic and dynamic calls remain
    /// opaque; callers preserve them unchanged and refuse structural edits.
    static func parse(_ cell: ShapeSheetCell?) throws -> Formula {
        guard let cell else { return Formula(clauses: [], prefix: "SUM(", suffix: ")") }
        guard ["", "BOOL"].contains(cell.unit) else { throw invalid("The relationship cell unit is unknown or incompatible.") }
        guard cell.formula.utf8.count <= 16_384 else { throw invalid("The relationship formula is too large.") }
        let value = cell.value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Double(value) == 0 || value.caseInsensitiveCompare("FALSE") == .orderedSame else {
            throw invalid("The relationship cell has an unrecognized cached value.")
        }
        let source = cell.formula
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        // An inherited value (Inh) comes from a master or style, which cannot name page shapes:
        // Visio writes structural DEPENDSON clauses only as local instance formulas, so an inherited
        // Relationships cell holds no relationships. Every stencil master instance has one.
        if trimmed.isEmpty || trimmed == "0" || trimmed.caseInsensitiveCompare("Inh") == .orderedSame { return Formula(clauses: [], prefix: "SUM(", suffix: ")") }
        let parts = try callParts(source, expected: "SUM", allowEquals: true)
        guard !parts.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return Formula(clauses: [], prefix: parts.prefix, suffix: parts.suffix)
        }
        var seen = Set<Kind>(), references = 0
        var clauses: [Clause] = []
        for raw in try split(parts.body) {
            let call = try callParts(raw, expected: "DEPENDSON")
            let arguments = try split(call.body)
            guard let first = arguments.first, let numeric = Int(first.trimmingCharacters(in: .whitespacesAndNewlines)),
                  let kind = Kind(rawValue: numeric), seen.insert(kind).inserted else {
                throw invalid("The relationship category is unknown or repeated.")
            }
            var ids: [UInt32] = [], unique = Set<UInt32>()
            for argument in arguments.dropFirst() {
                let reference = try callParts(argument, expected: nil)
                let owner = reference.name.uppercased()
                guard owner.hasPrefix("SHEET."), owner.hasSuffix("!SHEETREF"),
                      reference.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      let id = UInt32(owner.dropFirst(6).dropLast(9)), unique.insert(id).inserted else {
                    throw invalid("A relationship target is not one unique page Sheet.ID!SheetRef().")
                }
                references += 1
                guard references <= maximumReferences else { throw invalid("The relationship set is too large.") }
                ids.append(id)
            }
            if [.list, .calloutTarget, .leftBoundary, .rightBoundary, .topBoundary, .bottomBoundary, .overlappingList].contains(kind), ids.count > 1 {
                throw invalid("A singular structural relationship has multiple targets.")
            }
            clauses.append(Clause(kind: kind, targets: ids, raw: raw, prefix: call.prefix, arguments: arguments, suffix: call.suffix))
        }
        return Formula(clauses: clauses, prefix: parts.prefix, suffix: parts.suffix)
    }

    /// Structural metadata with this exact grammar must not send an otherwise
    /// bounded scalar edit through the unknown-function/full-page fallback.
    /// Unknown formulas retain that fallback. This is not scalar evaluation.
    static func isRecognizedStructuralCell(key: String, cell: ShapeSheetCell) -> Bool {
        key == relationshipCell && (try? parse(cell)) != nil
    }

    static func index(in diagram: Diagram, pageID: UUID, cancellation: LifecycleJobCancellation? = nil) throws -> Index {
        guard let page = diagram.pages.first(where: { $0.id == pageID }) else { throw invalid("The membership page is no longer available.") }
        let binding = diagram.visioArchive?.pages.first { $0.pageID == pageID }
        let raw = try rawShapes(diagram: diagram, binding: binding, cancellation: cancellation)
        return try makeIndex(page: page, binding: binding, raw: raw, sourceBacked: diagram.visioArchive != nil, cancellation: cancellation)
    }

    private static func makeIndex(page: DiagramPage, binding: VisioPageBinding?, raw: [UInt32: RawShape] = [:], sourceBacked: Bool = false,
                                  cancellation: LifecycleJobCancellation? = nil) throws -> Index {
        let objects = page.nodes.map { ($0.id, $0.text, $0.formatting, false, binding?.nodeIDs[$0.id] ?? $0.formatting.sourceShapeID) }
            + page.edges.map { ($0.id, $0.label, $0.formatting, true, binding?.edgeIDs[$0.id] ?? $0.sourceShapeID) }
        guard objects.count <= maximumReferences else { throw invalid("The page has too many structural objects.") }
        var reserved = Array(raw.keys).map(String.init)
        reserved += objects.compactMap { $0.4 }
        reserved += objects.compactMap { $0.2.sourceShapeID }
        reserved += page.edges.compactMap(\.sourceShapeID)
        reserved += Array(binding?.nodeIDs.values ?? Dictionary<UUID, String>().values)
        reserved += Array(binding?.edgeIDs.values ?? Dictionary<UUID, String>().values)
        _ = try VisioIDAllocator(reserved: reserved)
        let reservations = Set(reserved.compactMap(UInt32.init))
        var entries: [UUID: Entry] = [:], byID: [UInt32: UUID] = [:], order: [UUID] = [], issues: [String] = []
        for (offset, object) in objects.enumerated() {
            if offset.isMultiple(of: 128) { try checkpoint(cancellation) }
            let (id, text, detail, connector, explicit) = object
            if connector, let primary = page.edges[offset - page.nodes.count].sourceShapeID,
               let bound = binding?.edgeIDs[id], UInt32(primary) != UInt32(bound) {
                throw invalid("The connector's primary public identity disagrees with its source binding.")
            }
            guard entries[id] == nil else { throw invalid("A native shape identity is repeated.") }
            let publicID: UInt32
            if let explicit { guard let number = UInt32(explicit) else { throw invalid("A public shape identity is invalid.") }; publicID = number }
            else {
                // Existing ordinary formulas address native objects by these
                // ordinals. First-free/max+1 allocation would silently retarget
                // unrelated Sheet.N references in mixed explicit/nil pages.
                publicID = UInt32(offset + 1)
                guard !reservations.contains(publicID) else { throw invalid("An implicit public shape address collides with a retained source identity. Freeze identities explicitly before editing memberships.") }
            }
            if let retained = detail.sourceShapeID {
                guard explicit != nil, UInt32(retained) == publicID else { throw invalid("A retained detail sheet identity disagrees with its public shape owner.") }
            }
            guard byID[publicID] == nil else { throw invalid("Public shape identities are ambiguous on this page.") }
            byID[publicID] = id; order.append(id)
            let original = raw[publicID]
            let aliases = detail.sheet.keys.filter { managedCellReason($0) != nil }
            guard aliases.isEmpty || aliases == [relationshipCell] else { throw invalid("A native relationship cell has ambiguous casing or ownership.") }
            let cell = detail.sheet[relationshipCell] ?? original?.cells[relationshipCell]
            var refusal: String?
            if let originalCell = original?.cells[relationshipCell], (try? parse(originalCell)) == nil {
                refusal = "The original public relationship formula is unproven and read-only."
            }
            var formula: Formula?
            do { formula = try parse(cell) } catch { refusal = error.localizedDescription }
            if sourceBacked {
                if original == nil { refusal = "This shape has no proven local public source owner." }
                else if let explicit, original?.sourceID != explicit { refusal = "The public shape's bound source identity changed. Reopen the drawing before editing." }
                else if original?.deleted == true { refusal = "A deleted public shape or ancestor cannot own a membership edit. Reopen a live source." }
                else if original?.ambiguous == true { refusal = "The public shape or structural cell owner is ambiguous." }
                else if original?.hasMaster == true {
                    refusal = "Inherited structural role/policy closure is not proven. Membership edits on source master instances remain read-only, including partial local overrides."
                } else if detail.sheet[relationshipCell] == nil && original?.cells[relationshipCell] != nil {
                    refusal = "Public relationships are missing from this native cache. Reopen the public drawing before editing."
                }
            }
            let role = literalRole(detail.sheet["User.msvStructureType"])
            if let structure = detail.sheet["User.msvStructureType"], literalString(structure).flatMap(Role.init(rawValue:)) == nil {
                refusal = "The structured-shape role is unknown or unresolved and remains read-only."
            }
            if role != .ordinary, sourceBacked, original?.cells["User.msvStructureType"] == nil {
                refusal = "Inherited structured-shape roles are read-only."
            }
            if let original, sourceBacked {
                // Do not let a narrowed/sanitized native cache turn unknown
                // source units or unresolved role/policy literals into proof.
                for (key, value) in original.cells {
                    if key == "User.msvStructureType", literalString(value).flatMap(Role.init(rawValue:)) == nil {
                        refusal = "The public structured-shape role or its unit is unresolved."
                    }
                    if ["User.msvSDContainerLocked", "User.msvSDContainerResize"].contains(key), literalNumber(value) == nil {
                        refusal = "A public container policy or its unit is unresolved."
                    }
                    if ["User.msvShapeCategories", "User.msvSDContainerRequiredCategories", "User.msvSDContainerExcludedCategories"].contains(key), literalString(value) == nil {
                        refusal = "A public category policy or its unit is unresolved."
                    }
                }
                for key in original.cells.keys where key.hasPrefix("User.") && detail.sheet[key] == nil {
                    refusal = "A public structural policy is missing from this native cache. Reopen the public drawing before editing."
                }
                if role == .container, original.cells.keys.contains(where: { $0.hasPrefix("User.msvSD") && !supportedContainerPolicies.contains($0) }) {
                    refusal = "The source container has an unproven structural policy and remains read-only."
                }
            }
            // Newly authored ordinary objects have no source owner yet. A
            // bound/matching raw owner, or retained structural metadata, never
            // qualifies for that exception even when Relationships is absent.
            let hasBinding = connector ? binding?.edgeIDs[id] != nil : binding?.nodeIDs[id] != nil
            let structuralMetadata = detail.sheet.keys.contains {
                managedCellReason($0) != nil || $0.lowercased().hasPrefix("user.msv")
            }
            let newUnboundOrdinary = sourceBacked && original == nil && !hasBinding && !structuralMetadata
            let unprovenRetainedOwnership = refusal != nil && !newUnboundOrdinary
            let name = original?.name.isEmpty == false ? original!.name : text.isEmpty ? "Unnamed shape" : text
            entries[id] = Entry(id: id, publicID: publicID, sourceID: original?.sourceID ?? explicit ?? String(publicID), title: "\(name) · Sheet.\(publicID)", role: role, cell: cell, formula: formula, sourceRefusal: refusal, unprovenRetainedOwnership: unprovenRetainedOwnership, connector: connector)
            if let refusal, cell != nil { issues.append("Sheet.\(publicID): \(refusal)") }
        }
        let parentIDs = Dictionary((page.nodes.map { ($0.id, $0.parentID) } + page.edges.map { ($0.id, $0.parentID) })
            .compactMap { id, parent in parent.map { (id, $0) } }, uniquingKeysWith: { first, _ in first })
        var ownershipMemo: [UUID: Bool] = [:], ownershipVisiting = Set<UUID>()
        func unprovenOwner(_ id: UUID, depth: Int = 0) -> Bool {
            if let cached = ownershipMemo[id] { return cached }
            guard depth < 64, let entry = entries[id], ownershipVisiting.insert(id).inserted else { return true }
            let unproven = entry.unprovenRetainedOwnership || parentIDs[id].map { unprovenOwner($0, depth: depth + 1) } == true
            ownershipVisiting.remove(id); ownershipMemo[id] = unproven
            return unproven
        }
        for (offset, id) in order.enumerated() {
            if offset.isMultiple(of: 128) { try checkpoint(cancellation) }
            let unproven = unprovenOwner(id)
            entries[id]?.unprovenRetainedOwnership = unproven
        }
        var relations: [Relation] = [], outgoing: [UUID: [Relation]] = [:], incoming: [UUID: [Relation]] = [:]
        for (offset, id) in order.enumerated() {
            if offset.isMultiple(of: 128) { try checkpoint(cancellation) }
            guard let entry = entries[id], let formula = entry.formula else { continue }
            for clause in formula.clauses {
                for targetID in clause.targets {
                    guard let target = byID[targetID], target != id else { issues.append("Sheet.\(entry.publicID) has an unresolved or self relationship."); continue }
                    let relation = Relation(owner: id, target: target, kind: clause.kind)
                    if clause.kind == .containerMembers && ![Role.container, .list].contains(entry.role)
                        || clause.kind == .containers && ![Role.container, .list].contains(entries[target]?.role ?? .ordinary)
                        || clause.kind == .listMembers && entry.role != .list
                        || clause.kind == .list && entries[target]?.role != .list {
                        issues.append("A structural relationship has no proven container/list role.")
                    }
                    relations.append(relation); outgoing[id, default: []].append(relation); incoming[target, default: []].append(relation)
                    guard relations.count <= maximumReferences else { throw invalid("The page has too many structural references.") }
                }
            }
        }
        for (id, source) in raw where byID[id] == nil && source.cells[relationshipCell] != nil {
            issues.append("An unmodeled public shape has structural relationships. Reopen a supported source before editing.")
        }
        let relationSet = Set(relations)
        for relation in relations where relation.kind == .containerMembers || relation.kind == .containers {
            let reverse: Kind = relation.kind == .containerMembers ? .containers : .containerMembers
            if !relationSet.contains(Relation(owner: relation.target, target: relation.owner, kind: reverse)) {
                issues.append("A container membership lacks its reciprocal public clause.")
            }
        }
        try checkpoint(cancellation)
        return Index(pageID: page.id, entries: entries, order: order, byPublicID: byID, relations: relations, outgoing: outgoing, incoming: incoming, issues: issues)
    }

    /// Existing containers only. Lists, callouts and lane-specific policies are
    /// displayed independently but not edited by this bounded transaction.
    static func settingMembership(in diagram: Diagram, pageID: UUID, memberID: UUID, containerID: UUID, included: Bool,
                                  cancellation: LifecycleJobCancellation? = nil) throws -> Diagram {
        try checkpoint(cancellation)
        let index = try index(in: diagram, pageID: pageID, cancellation: cancellation)
        guard index.issues.isEmpty else { throw invalid(index.issues[0]) }
        guard let member = index.entries[memberID], let container = index.entries[containerID], memberID != containerID,
              container.role == .container, !container.connector else {
            throw invalid("Choose one existing shape and a different explicit Container owner.")
        }
        guard member.sourceRefusal == nil, container.sourceRefusal == nil else {
            throw invalid(member.sourceRefusal ?? container.sourceRefusal!)
        }
        guard let pageIndex = diagram.pages.firstIndex(where: { $0.id == pageID }) else { throw invalid("The membership page changed.") }
        let page = diagram.pages[pageIndex]
        try checkProtection(memberID, in: page)
        try checkProtection(containerID, in: page)
        let containerDetail = page.nodes.first { $0.id == containerID }!.formatting
        try checkContainerPolicy(containerDetail, member: details(memberID, in: page)!, adding: included)
        let currentlyIncluded = index.contains(member: memberID, container: containerID)
        guard currentlyIncluded != included else { return diagram }
        // A container can itself be a member, but cycles have no bounded local
        // movement semantics in this slice. Check the prospective member closure.
        if included {
            var pending = [memberID], visited = Set<UUID>()
            while let next = pending.popLast() {
                if visited.count.isMultiple(of: 128) { try checkpoint(cancellation) }
                guard visited.insert(next).inserted else { continue }
                guard next != containerID else { throw invalid("Container membership cannot create a cycle.") }
                pending += index.outgoing[next, default: []].filter { $0.kind == .containerMembers || $0.kind == .listMembers }.map(\.target)
            }
        }
        var result = diagram
        // Freeze the whole page's existing implicit addresses before authoring
        // any new public references. Preserve explicit lexical IDs (including
        // leading zeroes); do not renumber other formulas or source tombstones.
        for offset in result.pages[pageIndex].nodes.indices {
            let id = result.pages[pageIndex].nodes[offset].id
            if result.pages[pageIndex].nodes[offset].formatting.sourceShapeID == nil {
                result.pages[pageIndex].nodes[offset].formatting.sourceShapeID = index.entries[id]?.sourceID
            }
        }
        for offset in result.pages[pageIndex].edges.indices {
            let id = result.pages[pageIndex].edges[offset].id
            if result.pages[pageIndex].edges[offset].sourceShapeID == nil {
                result.pages[pageIndex].edges[offset].sourceShapeID = index.entries[id]?.sourceID
            }
        }
        func install(_ entry: Entry, kind: Kind, target: UInt32) throws {
            guard let parsed = entry.formula else { throw invalid("The relationship formula is unavailable.") }
            var targets = parsed.targets(kind)
            if included { targets.append(target) } else { targets.removeAll { $0 == target } }
            var cell = entry.cell ?? ShapeSheetCell(value: "0")
            cell.formula = parsed.replacing(kind, with: targets)
            // V and U are retained verbatim; these clauses continue to cache 0.
            if let offset = result.pages[pageIndex].nodes.firstIndex(where: { $0.id == entry.id }) {
                result.pages[pageIndex].nodes[offset].formatting.sourceShapeID = entry.sourceID
                result.pages[pageIndex].nodes[offset].formatting.sheet[relationshipCell] = cell
            } else if let offset = result.pages[pageIndex].edges.firstIndex(where: { $0.id == entry.id }) {
                result.pages[pageIndex].edges[offset].sourceShapeID = entry.sourceID
                result.pages[pageIndex].edges[offset].formatting.sourceShapeID = entry.sourceID
                result.pages[pageIndex].edges[offset].formatting.sheet[relationshipCell] = cell
            } else { throw invalid("The membership shape changed.") }
        }
        try install(member, kind: .containers, target: container.publicID)
        try install(container, kind: .containerMembers, target: member.publicID)
        try checkpoint(cancellation)
        return try result.validated()
    }

    /// Called before creating a native clipboard fragment. Source-backed cell
    /// ownership must be proven before the public source is left behind.
    static func validateCopy(_ objectIDs: Set<UUID>, in diagram: Diagram, pageID: UUID,
                             cancellation: LifecycleJobCancellation? = nil) throws {
        let index = try index(in: diagram, pageID: pageID, cancellation: cancellation)
        guard index.issues.isEmpty else { throw invalid(index.issues[0]) }
        for id in objectIDs {
            guard let entry = index.entries[id] else { throw invalid("A copied shape is unavailable.") }
            if entry.unprovenRetainedOwnership {
                throw invalid("Retained source ownership is unproven. Reopen a source with resolved inheritance, owner identity and structural policy before copying or removing it.")
            }
            if entry.cell != nil, let reason = entry.sourceRefusal { throw invalid(reason) }
            for relation in index.outgoing[id, default: []] + index.incoming[id, default: []] {
                guard objectIDs.contains(relation.owner), objectIDs.contains(relation.target) else {
                    throw invalid("Copy the complete container/list relationship endpoint set, or explicitly detach it first.")
                }
            }
        }
    }

    /// Native clipboard input is untrusted. Its retained relationships must be
    /// recognized, reciprocal and closed before any IDs or page arrays mutate.
    static func validatePaste(_ fragment: DiagramPage, cancellation: LifecycleJobCancellation? = nil) throws {
        let hasRelationships = fragment.nodes.contains { $0.formatting.sheet.keys.contains { managedCellReason($0) != nil } }
            || fragment.edges.contains { $0.formatting.sheet.keys.contains { managedCellReason($0) != nil } }
        guard hasRelationships else { return }
        let all = fragment.nodes.map { ($0.id, $0.formatting.sourceShapeID) }
            + fragment.edges.map { ($0.id, $0.sourceShapeID ?? $0.formatting.sourceShapeID) }
        guard all.allSatisfy({ $0.1.flatMap(UInt32.init) != nil }) else { throw invalid("Copy must freeze every related public shape identity before paste.") }
        let index = try makeIndex(page: fragment, binding: nil, cancellation: cancellation)
        guard index.issues.isEmpty else { throw invalid(index.issues[0]) }
    }

    static func validateRemoval(_ objectIDs: Set<UUID>, in diagram: Diagram, pageID: UUID,
                                cancellation: LifecycleJobCancellation? = nil) throws {
        guard !objectIDs.isEmpty else { return }
        let index = try index(in: diagram, pageID: pageID, cancellation: cancellation)
        guard index.issues.isEmpty else { throw invalid(index.issues[0]) }
        for id in objectIDs {
            guard let entry = index.entries[id] else { throw invalid("A removed source identity is unavailable.") }
            if entry.unprovenRetainedOwnership {
                throw invalid("Retained source ownership is unproven. Reopen a source with resolved inheritance, owner identity and structural policy before copying or removing it.")
            }
            if entry.cell != nil, let reason = entry.sourceRefusal { throw invalid(reason) }
        }
        for id in objectIDs where !(index.outgoing[id] ?? []).isEmpty || !(index.incoming[id] ?? []).isEmpty {
            throw invalid("A selected identity participates in structural relationships. Detach it before deleting or ungrouping.")
        }
    }

    /// Group/member geometry is independent of memberships. Container motion
    /// with members requires a future shared motion closure, so fail atomically.
    static func transformBlockReason(_ node: DiagramNode, in page: DiagramPage) -> String? {
        let aliases = node.formatting.sheet.keys.filter { managedCellReason($0) != nil }
        if !aliases.isEmpty && aliases != [relationshipCell] { return "This shape's relationship cell owner is ambiguous. Its transform is read-only." }
        let roleCell = node.formatting.sheet["User.msvStructureType"]
        let role = literalRole(roleCell)
        if let roleCell, literalString(roleCell).flatMap(Role.init(rawValue:)) == nil {
            return "The structured shape's role is unresolved. Its transform is read-only."
        }
        let parsed: Formula
        do { parsed = try parse(node.formatting.sheet[relationshipCell]) }
        catch { return "This shape has unproven relationships. Its transform is read-only." }
        if !parsed.targets(.containerMembers).isEmpty || !parsed.targets(.listMembers).isEmpty {
            return "This container has members. Detach them explicitly before transforming it; moving members with a container is not available yet."
        }
        guard role == .container || role == .list else { return nil }
        guard node.formatting.sheet[relationshipCell] != nil else { return "The container has no explicit relationship owner. Its transform is read-only." }
        // Unknown policies may acquire structural meaning on evaluation. Known
        // membership-lock values do not themselves imply a position lock.
        if role == .container {
            if node.formatting.sheet.keys.contains(where: { $0.hasPrefix("User.msvSD") && !supportedContainerPolicies.contains($0) }) {
                return "The container has an unknown structural policy. Its transform is read-only."
            }
            if let locked = node.formatting.sheet["User.msvSDContainerLocked"], literalNumber(locked) == nil {
                return "The container's membership policy is unresolved. Its transform is read-only."
            }
            if node.formatting.sheet["User.msvSDContainerResize"].flatMap(literalNumber) != 0 {
                return "The container's resize policy is unresolved or automatic. Its transform is read-only."
            }
        }
        return nil
    }

    struct TransformWork: Equatable {
        var cachedPages = 0
        var candidateNodes = 0
        var fallbackNodes = 0
        var lookupMapsBuilt = 0
    }

    /// A cached empty owner set gives ordinary warm edits an O(1) per-page
    /// proof, including pages without geometry hosts. Changed source/node-order
    /// and cold sessions fall back to a bounded metadata scan. This decision is
    /// made before calculation so only potentially refusing edits fork caches.
    static func needsTransformGuard(from before: Diagram, proposed: Diagram, changes: DocumentChangeSet,
                                    session: CalculationSession) -> Bool {
        for page in proposed.pages {
            if let cached = session.retainedStructuralNodeIDs(pageID: page.id) {
                if !cached.isEmpty { return true }
                guard let change = changes.pages[page.id] else { continue }
                let indices = session.retainedDependency(pageID: page.id)?.nodeIndices ?? session.retainedNodeIndices(pageID: page.id)
                if !change.nodeOrderChanged, change.insertedNodeIDs.isEmpty, change.deletedNodeIDs.isEmpty, let indices {
                    var valid = true
                    for id in change.changedNodeIDs {
                        guard let index = indices[id], page.nodes.indices.contains(index), page.nodes[index].id == id else { valid = false; break }
                        if hasStructuralOwnerMetadata(page.nodes[index]) { return true }
                    }
                    if valid { continue }
                }
            }
            if page.nodes.contains(where: hasStructuralOwnerMetadata) { return true }
            if let prior = before.pages.first(where: { $0.id == page.id }), prior.nodes.contains(where: hasStructuralOwnerMetadata) { return true }
        }
        return false
    }

    /// The dependency graph caches owner candidates independently of scalar
    /// formulas. Compare only that old/new union, using existing retained node
    /// indices rather than allocating whole-page dictionaries on warm edits.
    /// Both policies are checked: resolving/clearing a role cannot bypass the
    /// guard in the same operation as a geometry change. Undo keeps its existing
    /// restoration path and does not call this native-edit guard.
    @discardableResult static func validateTransforms(from before: Diagram, to after: Diagram,
                                   beforeSession: CalculationSession? = nil, afterSession: CalculationSession? = nil,
                                   cancellation: LifecycleJobCancellation? = nil) throws -> TransformWork {
        var work = TransformWork()
        let afterPages = Dictionary(after.pages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for page in before.pages {
            try checkpoint(cancellation)
            guard let next = afterPages[page.id] else { continue }
            let oldCached = beforeSession?.retainedStructuralNodeIDs(pageID: page.id)
            let newCached = afterSession?.retainedStructuralNodeIDs(pageID: page.id)
            let candidates: Set<UUID>
            if let oldCached, let newCached {
                work.cachedPages += 1
                candidates = oldCached.union(newCached)
            } else {
                // Cold/structural fallback only. No dictionary is built if the
                // page has no possible container/list owner at either endpoint.
                work.fallbackNodes += page.nodes.count + next.nodes.count
                candidates = Set(page.nodes.filter(hasStructuralOwnerMetadata).map(\.id))
                    .union(next.nodes.filter(hasStructuralOwnerMetadata).map(\.id))
            }
            guard !candidates.isEmpty else { continue }
            let oldIndices = beforeSession?.retainedDependency(pageID: page.id)?.nodeIndices ?? beforeSession?.retainedNodeIndices(pageID: page.id)
            let newIndices = afterSession?.retainedDependency(pageID: page.id)?.nodeIndices ?? afterSession?.retainedNodeIndices(pageID: page.id)
            var oldFallback: [UUID: DiagramNode]?, newFallback: [UUID: DiagramNode]?
            func lookup(_ id: UUID, page: DiagramPage, indices: [UUID: Int]?, fallback: inout [UUID: DiagramNode]?) -> DiagramNode? {
                if let indices, indices.count == page.nodes.count {
                    guard let index = indices[id] else { return nil }
                    if page.nodes.indices.contains(index), page.nodes[index].id == id { return page.nodes[index] }
                }
                if fallback == nil {
                    fallback = Dictionary(page.nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                    work.lookupMapsBuilt += 1
                }
                return fallback?[id]
            }
            for id in candidates {
                work.candidateNodes += 1
                if work.candidateNodes.isMultiple(of: 128) { try checkpoint(cancellation) }
                guard let old = lookup(id, page: page, indices: oldIndices, fallback: &oldFallback),
                      let new = lookup(id, page: next, indices: newIndices, fallback: &newFallback),
                      old.rect != new.rect || old.rotation != new.rotation
                        || old.formatting.flipX != new.formatting.flipX || old.formatting.flipY != new.formatting.flipY else { continue }
                if let reason = transformBlockReason(old, in: page) ?? transformBlockReason(new, in: next) { throw invalid(reason) }
            }
        }
        return work
    }

    static func removalBlockReason(_ objectIDs: Set<UUID>, in page: DiagramPage) -> String? {
        guard !objectIDs.isEmpty else { return nil }
        do {
            let index = try makeIndex(page: page, binding: nil)
            if !index.issues.isEmpty { return "The page has unproven relationships. Resolve them before deleting or ungrouping shapes." }
            for id in objectIDs {
            guard let entry = index.entries[id] else { throw invalid("A removed source identity is unavailable.") }
            if let reason = entry.sourceRefusal { throw invalid(reason) }
        }
        for id in objectIDs where !(index.outgoing[id] ?? []).isEmpty || !(index.incoming[id] ?? []).isEmpty {
                return "A selected identity participates in container/list/callout relationships. Detach those relationships before deleting or ungrouping it."
            }
        } catch { return "The page's structural identities are ambiguous. Deleting or ungrouping is unavailable." }
        return nil
    }

    private static func checkProtection(_ id: UUID, in page: DiagramPage) throws {
        if let node = page.nodes.first(where: { $0.id == id }) {
            if let reason = NativeEditProtection.blockReason(for: "Membership", node: node, in: page) { throw invalid(reason) }
        } else if let edge = page.edges.first(where: { $0.id == id }) {
            guard !page.isLocked(edge) else { throw invalid("The connector, its group or its layer is locked.") }
            if let reason = NativeEditProtection.blockReason(for: "Membership", node: edge.textNode, in: page) { throw invalid(reason) }
        } else { throw invalid("The membership shape is unavailable.") }
    }
    private static func checkContainerPolicy(_ container: ShapeDetails, member: ShapeDetails, adding: Bool) throws {
        if let locked = container.sheet["User.msvSDContainerLocked"] {
            guard literalNumber(locked) == 0 else { throw invalid("Container membership is locked or its lock policy is unresolved.") }
        }
        for key in container.sheet.keys where key.hasPrefix("User.msvSD") && !supportedContainerPolicies.contains(key) {
            throw invalid("This container uses a structural policy that this membership editor does not support.")
        }
        if adding {
        var categories = Set<String>()
        if let value = member.sheet["User.msvShapeCategories"] {
            guard let text = literalString(value) else { throw invalid("The member's category policy is unresolved.") }
            categories = Set(text.split(separator: ";").map(String.init))
        }
        for (key, required) in [("User.msvSDContainerRequiredCategories", true), ("User.msvSDContainerExcludedCategories", false)] {
            if let cell = container.sheet[key] {
                guard let text = literalString(cell) else { throw invalid("The container's category policy is unresolved.") }
                let values = Set(text.split(separator: ";").map(String.init))
                if required && !values.isEmpty && values.isDisjoint(with: categories) || !required && !values.isDisjoint(with: categories) {
                    throw invalid("The shape does not satisfy the container's explicit category policy.")
                }
            }
        }
        }
        // Automatic resize would require geometry changes beyond this edge-only
        // transaction. An explicit literal 0 is the bounded behavior.
        if container.sheet["User.msvSDContainerResize"].flatMap(literalNumber) != 0 {
            throw invalid("Automatic container resize is read-only in this membership editor.")
        }
    }
    private static func literalRole(_ cell: ShapeSheetCell?) -> Role {
        guard let cell, let value = literalString(cell), let role = Role(rawValue: value) else { return .ordinary }; return role
    }
    private static func literalNumber(_ cell: ShapeSheetCell) -> Double? {
        guard ["", "BOOL"].contains(cell.unit), let value = Double(cell.value), value.isFinite else { return nil }
        let formula = cell.formula.trimmingCharacters(in: .whitespacesAndNewlines)
        return formula.isEmpty || Double(formula) == value ? value : nil
    }
    private static func literalString(_ cell: ShapeSheetCell) -> String? {
        guard ["", "STR"].contains(cell.unit) else { return nil }
        let formula = cell.formula.trimmingCharacters(in: .whitespacesAndNewlines)
        if formula.isEmpty { return cell.value }
        guard let expression = try? ShapeSheet.parse(formula), case .string(let value) = expression, value == cell.value else { return nil }; return value
    }
    private static func details(_ id: UUID, in page: DiagramPage) -> ShapeDetails? {
        page.nodes.first { $0.id == id }?.formatting ?? page.edges.first { $0.id == id }?.formatting
    }
    private static func rawShapes(diagram: Diagram, binding: VisioPageBinding?, cancellation: LifecycleJobCancellation?) throws -> [UInt32: RawShape] {
        guard let source = diagram.visioArchive, let binding, let bytes = source.parts[binding.part] else { return [:] }
        let document = try VisioXML.document(bytes)
        guard let root = document.rootElement(), core(root, "PageContents") else { throw invalid("The public page owner is unknown.") }
        let owners = root.elementsLocal("Shapes").filter { core($0, "Shapes") }
        guard owners.count <= 1 else { throw invalid("The public shape collection is ambiguous.") }
        var pending = (owners.first?.children?.compactMap { $0 as? XMLElement } ?? []).map { ($0, false, false, false) }
        var result: [UInt32: RawShape] = [:], count = 0
        func live(_ element: XMLElement) -> Bool {
            guard let value = element.attribute(forName: "Del")?.stringValue else { return true }
            return ["0", "false"].contains(value.lowercased())
        }
        func ownedAttributes(_ element: XMLElement, allowed: Set<String>) -> Bool {
            (element.attributes ?? []).allSatisfy { allowed.contains($0.name ?? "") && ($0.uri ?? "").isEmpty }
        }
        while let (shape, ancestorDeleted, ancestorMaster, ancestorAmbiguous) = pending.popLast() {
            count += 1; if count.isMultiple(of: 128) { try checkpoint(cancellation) }
            guard count <= maximumReferences, core(shape, "Shape"),
                  let identifier = shape.attribute(forName: "ID"), (identifier.uri ?? "").isEmpty,
                  let rawID = identifier.stringValue, let id = UInt32(rawID), result[id] == nil else {
                throw invalid("The public shape identity or namespace is ambiguous.")
            }
            let ownershipNames: Set<String> = ["ID", "Master", "MasterShape", "Del", "Type"]
            let foreignOwnership = (shape.attributes ?? []).contains {
                ownershipNames.contains($0.localName ?? $0.name ?? "") && !($0.uri ?? "").isEmpty
            }
            var record = RawShape(ambiguous: ancestorAmbiguous || foreignOwnership,
                hasMaster: ancestorMaster || shape.attribute(forName: "Master") != nil || shape.attribute(forName: "MasterShape") != nil,
                deleted: ancestorDeleted || !live(shape), name: shape.attr("NameU") ?? shape.attr("Name") ?? "", sourceID: rawID)
            // Unrelated vendor shape attributes/payload are retained, not used
            // as ownership evidence and not rejected globally.
            func take(_ cell: XMLElement, key: String) {
                guard core(cell, "Cell"), record.cells[key] == nil else { record.ambiguous = true; return }
                if !ownedAttributes(cell, allowed: ["N", "V", "F", "U"]) || cell.childCount > 0 { record.ambiguous = true }
                record.cells[key] = ShapeSheetCell(value: cell.attr("V") ?? "", formula: cell.attr("F") ?? "", unit: cell.attr("U") ?? "")
            }
            for cell in shape.elementsLocal("Cell") where cell.attr("N") == relationshipCell { take(cell, key: relationshipCell) }
            for section in shape.elementsLocal("Section") where section.attr("N") == "User" {
                let structuralRows = section.elementsLocal("Row").filter { row in
                    guard let name = row.attr("N") else { return false }
                    return name == "msvStructureType" || name.hasPrefix("msvSD") || name == "msvShapeCategories"
                }
                guard !structuralRows.isEmpty else { continue }
                guard core(section, "Section"), live(section), ownedAttributes(section, allowed: ["N", "IX", "Del"]) else {
                    record.ambiguous = true; continue
                }
                for row in structuralRows {
                    guard core(row, "Row"), live(row), ownedAttributes(row, allowed: ["N", "IX", "Del"]), let name = row.attr("N") else {
                        record.ambiguous = true; continue
                    }
                    for cell in row.elementsLocal("Cell") where cell.attr("N") == "Value" { take(cell, key: "User." + name) }
                }
            }
            result[id] = record
            for children in shape.elementsLocal("Shapes") {
                guard core(children, "Shapes") else { throw invalid("A nested shape collection has unknown ownership.") }
                pending += (children.children?.compactMap { $0 as? XMLElement } ?? []).map { ($0, record.deleted, record.hasMaster, record.ambiguous) }
            }
        }
        return result
    }
    private static func core(_ element: XMLElement, _ name: String) -> Bool { element.localName == name && element.uri == namespace }
    private static func checkpoint(_ cancellation: LifecycleJobCancellation?) throws { try cancellation?.check(); try LifecycleJobContext.current?.checkpoint() }
    private static func invalid(_ message: String) -> DiagramError { .invalid(message) }

    private struct CallParts { let name: String; let prefix: String; let body: String; let suffix: String }
    private static func callParts(_ input: String, expected: String?, allowEquals: Bool = false) throws -> CallParts {
        guard let open = input.firstIndex(of: "("), let close = input.lastIndex(of: ")"), open < close,
              input[input.index(after: close)...].allSatisfy(\.isWhitespace) else { throw invalid("The structural formula grammar is unknown.") }
        var name = input[..<open].trimmingCharacters(in: .whitespacesAndNewlines)
        if name.hasPrefix("=") {
            guard allowEquals else { throw invalid("An embedded equals prefix is not a supported structural reference.") }
            name.removeFirst(); name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !name.isEmpty, expected == nil || name.caseInsensitiveCompare(expected!) == .orderedSame else { throw invalid("The structural formula grammar is unknown.") }
        let body = String(input[input.index(after: open)..<close])
        _ = try split(body)
        return CallParts(name: name, prefix: String(input[...open]), body: body, suffix: String(input[close...]))
    }
    private static func split(_ input: String) throws -> [String] {
        var result: [String] = [], depth = 0, start = input.startIndex, count = 0
        for position in input.indices {
            let character = input[position]
            if character == "(" { depth += 1; guard depth <= 64 else { throw invalid("The structural formula nesting is too deep.") } }
            else if character == ")" { depth -= 1; guard depth >= 0 else { throw invalid("The structural formula has unmatched parentheses.") } }
            else if character == ",", depth == 0 { result.append(String(input[start..<position])); start = input.index(after: position) }
            else if character == "\"" || character == "'" { throw invalid("Named or quoted structural references are read-only.") }
            count += 1; guard count <= 16_384 else { throw invalid("The structural formula is too large.") }
        }
        guard depth == 0 else { throw invalid("The structural formula has unmatched parentheses.") }
        result.append(String(input[start...])); return result
    }
}
