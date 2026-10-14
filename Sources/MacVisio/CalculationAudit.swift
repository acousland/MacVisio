import Foundation

enum CalculationAudit {
    static func inspect(_ input:URL,to output:URL) throws {
        let pages:[DiagramPage],bindings:[VisioPageBinding]
        if ["vssx","vss"].contains(input.pathExtension.lowercased()) { pages = try VisioStencil.read(from:input).items.map(\.fragment);bindings = [] }
        else { let doc = MacVisioDocument();try doc.read(from:input,ofType:input.pathExtension.lowercased() == "vsd" ? MacVisioDocument.legacyType : MacVisioDocument.visioType);pages = doc.diagram.pages;bindings = doc.diagram.visioArchive?.pages ?? [] }
        var details:[[String:Any]] = [],count = 0,success = 0,failures = 0
        for page in pages {
            let context = ShapeSheetContext(page:page,binding:bindings.first{$0.pageID == page.id})
            var rows:[[String:Any]] = []
            for node in page.nodes {
                for control in node.formatting.controls {
                    for (key,cell) in control.cells.sorted(by:{$0.key<$1.key}) where !cell.formula.isEmpty && !["Inh","No Formula"].contains(cell.formula) {
                        count += 1
                        let name = "Controls."+control.name+"."+key;var result:[String:Any] = ["shape":node.formatting.sourceShapeID ?? node.id.uuidString,"cell":name,"formula":cell.formula,"cached":cell.value]
                        do { let value = try context.value(node.id,name);result["calculated"] = ShapeSheetContext.cached(value);result["evaluated"] = true;success += 1 }
                        catch { result["evaluated"] = false;result["error"] = error.localizedDescription;failures += 1 }
                        rows.append(result)
                    }
                }
            }
            if !rows.isEmpty { details.append(["page":page.name,"controls":rows]) }
        }
        let report:[String:Any] = ["source":input.lastPathComponent,"controlFormulaCells":count,"evaluated":success,"failed":failures,"pages":details,"scope":"Formula evaluation against imported cached page snapshots; successful calculation does not prove Windows or full stencil behavior","windowsValidated":false,"fullBehavioralParity":false]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:output,options:.atomic)
    }
}
