import Foundation

/// Address aliases for the currently represented definition cells. Native IDs
/// retain ownership; a numeric sheet name is resolved within its master scope.
enum DefinitionSheetReferences {
    static func aliases(_ address: DefinitionCellAddress) -> [String] {
        guard let section = address.section else { return [address.cell] }
        let prefix = ["Property": "Prop", "Character": "Char", "Paragraph": "Para",
                      "Control": "Controls", "Connection": "Connections"][section] ?? section
        if let row = address.rowName {
            return address.cell == "Value" ? ["\(prefix).\(row)", "\(prefix).\(row).Value"] : ["\(prefix).\(row).\(address.cell)"]
        }
        if let index = address.rowIndex.flatMap(UInt32.init) {
            let number = UInt64(index) + 1
            var result = ["\(prefix).\(address.cell)[\(number)]"]
            if index == 0 { result.append("\(prefix).\(address.cell)") }
            return result
        }
        return ["\(prefix).\(address.cell)"]
    }

    static func cells(_ sheet: DefinitionSheet) throws -> [String: DefinitionCell] {
        var result: [String: DefinitionCell] = [:]
        let deletedRows = Set(sheet.rows.filter(\.deleted).map {
            DefinitionCellAddress(cell: "", section: $0.section, sectionIndex: $0.sectionIndex,
                                  rowName: $0.name, rowIndex: $0.index).key
        })
        for cell in sheet.cells {
            var row = cell.address; row.cell = ""
            if deletedRows.contains(row.key) { continue }
            for name in aliases(cell.address) {
                let key = name.lowercased()
                if let prior = result[key], prior.id != cell.id {
                    throw DiagramError.invalid("Ambiguous definition cell reference: \(name).")
                }
                result[key] = cell
            }
        }
        return result
    }
}
