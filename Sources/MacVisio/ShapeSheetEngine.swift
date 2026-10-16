import MacVisioInfrastructure
import Foundation

enum ShapeSheetEngine {
    static let geometryKeys = ["Width","Height","PinX","PinY","LocPinX","LocPinY","Angle","LineWeight","Char.Size"]
    static let textKeys = ["TxtWidth","TxtHeight","TxtPinX","TxtPinY","TxtLocPinX","TxtLocPinY","TxtAngle","LeftMargin","RightMargin","TopMargin","BottomMargin","VerticalAlign"]
    struct Calculation { var diagram:Diagram; var issues:[String]; var issuesByPage:[UUID:[String]] = [:]; var work = CalculationWork(); var changedNodeIDsByPage: [UUID: Set<UUID>] = [:]; var cancelled = false }
    static func defaults(_ node:DiagramNode,page:DiagramPage,onDefaultPinFormulaEvaluation:(()->Void)? = nil) -> [String:Double] {
        defaults(node,page:page,nodesByID:nil,onDefaultPinFormulaEvaluation:onDefaultPinFormulaEvaluation)
    }
    static func defaults(_ node:DiagramNode,page:DiagramPage,nodesByID:[UUID:DiagramNode],onDefaultPinFormulaEvaluation:(()->Void)? = nil) -> [String:Double] {
        defaults(node,page:page,nodesByID:Optional(nodesByID),onDefaultPinFormulaEvaluation:onDefaultPinFormulaEvaluation)
    }
    private static func defaults(_ node:DiagramNode,page:DiagramPage,nodesByID:[UUID:DiagramNode]?,onDefaultPinFormulaEvaluation:(()->Void)?) -> [String:Double] {
        let local = nodesByID.map { VisioPreservation.localNode(node,in:page,nodesByID:$0) } ?? VisioPreservation.localNode(node,in:page)
        let height = node.parentID.flatMap{id in nodesByID?[id]?.height ?? page.nodes.first(where:{$0.id == id})?.height} ?? page.height
        func loc(_ key:String,_ fallback:Double) -> Double {
            guard let cell = node.formatting.sheet[key] else { return fallback }
            if !cell.formula.isEmpty {
                onDefaultPinFormulaEvaluation?()
                if let result = try? ShapeSheet.evaluate(cell.formula,resolve:{ name in if name.lowercased() == "width" { return node.sheetWidth/72 };if name.lowercased() == "height" { return node.sheetHeight/72 };throw DiagramError.invalid("Unresolved pin formula") }) { return result }
            }
            return Double(cell.value) ?? fallback
        }
        let lx = loc("LocPinX",node.sheetWidth/144),ly = loc("LocPinY",node.sheetHeight/144),a = -local.rotation * .pi/180,dx = (node.sheetWidth/144-lx)*(local.formatting.flipX ? -1 : 1),dy = (node.sheetHeight/144-ly)*(local.formatting.flipY ? -1 : 1)
        let box = node.formatting.textBox,tw = (box?.width ?? 1)*node.width/72,th = (box?.height ?? 1)*node.height/72
        let tx = (box?.centerX ?? 0.5)*node.width/72+node.sheetOrigin.x/72,ty = (1-(box?.centerY ?? 0.5))*node.height/72+node.sheetOrigin.y/72
        let ta = -(box?.rotation ?? 0)*Double.pi/180,tlx = Double(node.formatting.sheet["TxtLocPinX"]?.value ?? "") ?? tw/2,tly = Double(node.formatting.sheet["TxtLocPinY"]?.value ?? "") ?? th/2
        var values = ["Width":node.sheetWidth/72,"Height":node.sheetHeight/72,"PinX":local.center.x/72-dx*cos(a)+dy*sin(a),"PinY":(height-local.center.y)/72-dx*sin(a)-dy*cos(a),"LocPinX":lx,"LocPinY":ly,"Angle":a,"LineWeight":node.strokeWidth/72,"Char.Size":node.fontSize/72]
        values.merge(["TxtWidth":tw,"TxtHeight":th,"TxtPinX":tx-(tw/2-tlx)*cos(ta)+(th/2-tly)*sin(ta),"TxtPinY":ty-(tw/2-tlx)*sin(ta)-(th/2-tly)*cos(ta),"TxtLocPinX":tlx,"TxtLocPinY":tly,"TxtAngle":ta,"LeftMargin":(box?.left ?? 0)/72,"RightMargin":(box?.right ?? 0)/72,"TopMargin":(box?.top ?? 0)/72,"BottomMargin":(box?.bottom ?? 0)/72,"VerticalAlign":Double(box?.verticalAlignment ?? 1)]){_,new in new};return values
    }
    static func recalculate(_ input:Diagram,previous:Diagram? = nil,skipUnchangedPagesComparedTo comparison:Diagram? = nil,retainedIssuesByPage:[UUID:[String]] = [:],incrementalNodes:Bool = false,session:CalculationSession? = nil,changes:DocumentChangeSet? = nil,cancellation:LifecycleJobCancellation? = nil) -> Calculation {
        var diagram = input,issues = Set<String>(),issuesByPage:[UUID:[String]] = [:]
        var work = CalculationWork()
        var changedNodeIDsByPage: [UUID: Set<UUID>] = [:]
        var nodeIndicesByPage: [UUID: [UUID: Int]] = [:]
        let session = session ?? CalculationSession()
        let colorPalette = ShapeSheetColorPalette(documentArchive:diagram.visioArchive)
        var comparisonPageIndices:[UUID:Int]? = nil
        if let comparison,changes.map({ !$0.sourceResourcesChanged }) ?? (comparison.visioArchive == input.visioArchive) {
            var indices:[UUID:Int] = [:]
            for pageIndex in comparison.pages.indices where indices[comparison.pages[pageIndex].id] == nil {
                indices[comparison.pages[pageIndex].id] = pageIndex
            }
            comparisonPageIndices = indices
        }
        for pageIndex in diagram.pages.indices {
            if cancellation?.isCancelled == true { return Calculation(diagram:input,issues:[],work:work,cancelled:true) }
            let pageID = diagram.pages[pageIndex].id
            let binding = diagram.visioArchive?.pages.first(where:{$0.pageID == pageID})
            let indexedBefore = session.indexedNodes, comparedBefore = session.comparedSources
            let pageChanges = changes?.pages[pageID]
            let trusted = changes != nil && changes?.sourceResourcesChanged == false && changes?.insertedPageIDs.contains(pageID) == false
            let dependency = incrementalNodes ? session.index(for: diagram.pages[pageIndex], binding: binding, changes: pageChanges, trustChanges: trusted) : nil
            work.dependencyNodesIndexed += session.indexedNodes - indexedBefore
            work.dependencySourcesCompared += session.comparedSources - comparedBefore
            if dependency?.volatileNodes.isEmpty != false, let comparison,let comparisonPageIndices,
               let comparisonPageIndex = comparisonPageIndices[pageID],
               (trusted ? pageChanges == nil : diagram.pages[pageIndex] == comparison.pages[comparisonPageIndex]) {
                let retained = retainedIssuesByPage[pageID] ?? []
                issuesByPage[pageID] = retained
                issues.formUnion(retained)
                continue
            }
            var page = diagram.pages[pageIndex]
            var affected: Set<UUID>?
            if let dependency, let comparison, let comparisonPageIndices,
               let oldIndex = comparisonPageIndices[pageID],
               retainedIssuesByPage[pageID, default: []].isEmpty,
               !dependency.requiresFullPage {
                if trusted, let pageChanges, !pageChanges.pagePropertiesChanged, !pageChanges.hierarchyChanged,
                   !pageChanges.nodeOrderChanged, pageChanges.deletedNodeIDs.isEmpty, pageChanges.insertedNodeIDs.isEmpty {
                    affected = dependency.affected(by: pageChanges.changedNodeIDs)
                } else {
                    work.inputComparisonNodes += page.nodes.count + comparison.pages[oldIndex].nodes.count
                    if let changed = CalculationInvalidation.changedNodes(in: page, comparedTo: comparison.pages[oldIndex]) {
                        affected = dependency.affected(by: changed)
                    }
                }
            }
            let candidates: [Int]
            if let dependency {
                let selected = affected.map { dependency.geometryNodeIDs.intersection($0) } ?? dependency.geometryNodeIDs
                candidates = selected.compactMap { dependency.nodeIndices[$0] }.sorted()
            } else {
                work.inputComparisonNodes += page.nodes.count
                candidates = page.nodes.indices.filter { !page.nodes[$0].formatting.sheet.isEmpty || !page.nodes[$0].formatting.connectionPoints.isEmpty || !page.nodes[$0].formatting.controls.isEmpty || page.nodes[$0].formatting.geometry != nil }
            }
            guard !candidates.isEmpty else { issuesByPage[pageID] = []; continue }
            work.geometryPages += 1
            if incrementalNodes && affected == nil { work.conservativePages += 1 }
            var pageIssues = Set<String>()
            let old = previous?.pages.first(where:{$0.id == page.id})
            let preparedBefore = session.preparedHostNodes
            let oldNodesByID = old.map { oldPage in
                if trusted, let retained = session.retainedNodes(pageID: oldPage.id) { return retained }
                work.hostNodesPrepared += oldPage.nodes.count
                return Dictionary(uniqueKeysWithValues: oldPage.nodes.map { ($0.id, $0) })
            }
            var pageNodesByID = session.nodes(for: page, changes: pageChanges, trustChanges: trusted)
            work.hostNodesPrepared += session.preparedHostNodes - preparedBefore
            for i in candidates {
                if cancellation?.isCancelled == true { return Calculation(diagram:input,issues:[],work:work,cancelled:true) }
                if let prior = oldNodesByID?[page.nodes[i].id],let oldPage = old,let oldNodesByID {
                    if prior.width != page.nodes[i].width || prior.height != page.nodes[i].height { page.nodes[i].formatting.controls = ControlGeometry.resized(page.nodes[i].formatting.controls,from:prior,to:page.nodes[i]) }
                    let before = defaults(prior,page:oldPage,nodesByID:oldNodesByID,onDefaultPinFormulaEvaluation:{work.defaultPinFormulaEvaluations += 1}),after = defaults(page.nodes[i],page:page,nodesByID:pageNodesByID,onDefaultPinFormulaEvaluation:{work.defaultPinFormulaEvaluations += 1})
                    for key in geometryKeys where abs((before[key] ?? 0)-(after[key] ?? 0)) > 1e-10 {
                        let existing = page.nodes[i].formatting.sheet[key]
                        if existing == prior.formatting.sheet[key],!(existing?.formula.trimmingCharacters(in:.whitespacesAndNewlines).uppercased().hasPrefix("GUARD(") ?? false) {
                            page.nodes[i].formatting.sheet[key] = ShapeSheetCell(value:format(after[key]!))
                        }
                    }
                    for property in page.nodes[i].formatting.data where prior.formatting.data.first(where:{$0.key == property.key})?.value != property.value {
                        page.nodes[i].formatting.sheet["Prop."+property.key] = ShapeSheetCell(value:property.value)
                    }
                } else if previous != nil {
                    let values = defaults(page.nodes[i],page:page,nodesByID:pageNodesByID,onDefaultPinFormulaEvaluation:{work.defaultPinFormulaEvaluations += 1})
                    for key in ["PinX","PinY","Angle"] { page.nodes[i].formatting.sheet[key] = ShapeSheetCell(value:format(values[key]!)) }
                }
                pageNodesByID[page.nodes[i].id] = page.nodes[i]
            }
            let source = page
            let nodeIndices = dependency?.nodeIndices ?? Dictionary(uniqueKeysWithValues:source.nodes.enumerated().map{($0.element.id,$0.offset)})
            let sourceNodesByID = pageNodesByID
            nodeIndicesByPage[pageID] = nodeIndices
            var sheetIDs = dependency?.identifiers ?? [:]
            if dependency == nil { for (i,node) in source.nodes.enumerated() { let id = binding?.nodeIDs[node.id] ?? node.formatting.sourceShapeID ?? String(i+1); if sheetIDs[id] == nil { sheetIDs[id] = node.id } } }
            let context = ShapeSheetContext(page:source,binding:binding,colorPalette:colorPalette,nodesByID:sourceNodesByID,identifiers:sheetIDs,cancellation:cancellation)
            var steps = 0
            func resolve(_ nodeID:UUID,_ key:String,_ depth:Int = 0) throws -> Double {
                try context.number(nodeID,key)
            }
            var dataCache:[String:CompositeGeometry] = [:],dataVisiting = Set<String>()
            func resolveData(_ nodeID:UUID,_ key:String,_ depth:Int = 0) throws -> CompositeGeometry {
                steps += 1;guard depth < 64,steps < 100000,let i = nodeIndices[nodeID] else { throw DiagramError.invalid("Composite geometry dependency limit exceeded.") }
                let node = source.nodes[i],name = node.formatting.sheet.keys.first{$0.caseInsensitiveCompare(key) == .orderedSame} ?? key,token = nodeID.uuidString+"!"+name.lowercased()
                if let cached = dataCache[token] { return cached }
                guard dataVisiting.insert(token).inserted else { throw DiagramError.invalid("Circular composite geometry dependency.") };defer { dataVisiting.remove(token) }
                guard let cell = node.formatting.sheet[name] ?? GeometrySheet.cell(name,on:node) else { throw DiagramError.invalid("Unknown composite geometry cell: \(key)") }
                let cached = cell.formula.isEmpty || ["Inh","No Formula"].contains(cell.formula),formula = cached ? cell.value : cell.formula
                func target(_ reference:String) throws -> (UUID,String) {
                    if let bang = reference.firstIndex(of:"!") { let sheet = String(reference[..<bang]);guard sheet.uppercased().hasPrefix("SHEET."),let id = sheetIDs[String(sheet.dropFirst(6))] else { throw DiagramError.invalid("Unknown composite geometry reference: \(reference)") };return (id,String(reference[reference.index(after:bang)...])) };return (nodeID,reference)
                }
                let result = try CompositeGeometry.evaluate(formula,numeric:{ reference in
                    if reference.uppercased() == "THEPAGE!PAGEWIDTH" { return source.width/72 };if reference.uppercased() == "THEPAGE!PAGEHEIGHT" { return source.height/72 }
                    let (id,key) = try target(reference);return try resolve(id,key,depth+1)
                },data:{ reference in let (id,key) = try target(reference);return try resolveData(id,key,depth+1) },cached:cached)
                dataCache[token] = result;return result
            }
            for i in candidates {
                if cancellation?.isCancelled == true { return Calculation(diagram:input,issues:[],work:work,cancelled:true) }
                work.geometryNodes += 1
                PerformanceEvidence.count(.visitedObjects)
                var node = source.nodes[i],values = defaults(node,page:source,nodesByID:sourceNodesByID,onDefaultPinFormulaEvaluation:{work.defaultPinFormulaEvaluations += 1})
                for key in geometryKeys where node.formatting.sheet[key] != nil {
                    do {
                        let value = try resolve(node.id,key);values[key] = value
                        if node.formatting.sheet[key].flatMap({Double($0.value)}).map({abs($0-value)>1e-10}) ?? true { node.formatting.sheet[key]?.value = format(value) }
                    }
                    catch { pageIssues.insert(error.localizedDescription) }
                }
                for key in node.formatting.sheet.keys.sorted() where key.hasPrefix("User.") || key.hasPrefix("Prop.") {
                    guard let cell = node.formatting.sheet[key],!cell.formula.isEmpty,!["No Formula","Inh"].contains(cell.formula) else { continue }
                    do { let value = try context.value(node.id,key),cached = ShapeSheetContext.cached(value);if cell.value != cached { node.formatting.sheet[key]?.value = cached } }
                    catch { if let data = try? resolveData(node.id,key) { node.formatting.sheet[key]?.value = data.formula } else { pageIssues.insert(error.localizedDescription) } }
                }
                for j in node.formatting.data.indices { let key = "Prop."+node.formatting.data[j].key;if let cell = node.formatting.sheet[key],!cell.formula.isEmpty,!["No Formula","Inh"].contains(cell.formula) { node.formatting.data[j].value = cell.value } }
                for j in node.formatting.connectionPoints.indices {
                    let port = node.formatting.connectionPoints[j]
                    for (key,isX) in [(port.xCell,true),(port.yCell,false)] {
                        do {
                            let value = try resolve(node.id,key)
                            if isX { if Double(port.x.value).map({abs($0-value)>1e-10}) ?? true { node.formatting.connectionPoints[j].x.value = format(value) } }
                            else { if Double(port.y.value).map({abs($0-value)>1e-10}) ?? true { node.formatting.connectionPoints[j].y.value = format(value) } }
                        } catch { pageIssues.insert(error.localizedDescription) }
                    }
                }
                let signedWidth = (values["Width"] ?? node.sheetWidth/72)*72,signedHeight = (values["Height"] ?? node.sheetHeight/72)*72
                let width = abs(signedWidth),height = abs(signedHeight)
                if width > 0,width*page.paperScale <= 20000,height > 0,height*page.paperScale <= 20000 {
                    let local = VisioPreservation.localNode(node,in:source,nodesByID:sourceNodesByID)
                    let angle = values["Angle"] ?? -local.rotation * .pi/180
                    let lx = values["LocPinX"] ?? signedWidth/144,ly = values["LocPinY"] ?? signedHeight/144
                    let dx = (signedWidth/144-lx)*(local.formatting.flipX ? -1 : 1),dy = (signedHeight/144-ly)*(local.formatting.flipY ? -1 : 1)
                    let cx = (values["PinX"] ?? local.center.x/72)+dx*cos(angle)-dy*sin(angle)
                    let cy = (values["PinY"] ?? ((node.parentID.flatMap{id in sourceNodesByID[id]?.height} ?? source.height)-local.center.y)/72)+dx*sin(angle)+dy*cos(angle)
                    node.width = width;node.height = height
                    node.formatting.negativeWidth = signedWidth < 0 ? true : nil;node.formatting.negativeHeight = signedHeight < 0 ? true : nil
                    if let parentID = node.parentID,let parent = sourceNodesByID[parentID] {
                        var dx = cx*72-parent.sheetOrigin.x-parent.width/2,dy = parent.height-(cy*72-parent.sheetOrigin.y)-parent.height/2;let a = parent.rotation * .pi/180
                        if parent.formatting.flipX { dx = -dx };if parent.formatting.flipY { dy = -dy }
                        node.x = parent.center.x+dx*cos(a)-dy*sin(a)-width/2;node.y = parent.center.y+dx*sin(a)+dy*cos(a)-height/2
                        node.rotation = parent.rotation+(parent.formatting.flipX != parent.formatting.flipY ? angle : -angle)*180 / .pi
                    } else { node.x = cx*72-width/2;node.y = source.height-cy*72-height/2;node.rotation = -angle*180 / .pi }
                } else { pageIssues.insert("A ShapeSheet dimension is outside the supported range; its cached geometry was retained.") }
                if let size = values["Char.Size"],(1...500).contains(size*72) { node.fontSize = size*72 }
                if let weight = values["LineWeight"],(0...100).contains(weight*72) { node.strokeWidth = weight*72 }
                if source.nodes[i].formatting.sheet.keys.contains(where:{textKeys.contains($0)}) {
                    var textValues = defaults(node,page:source,nodesByID:sourceNodesByID,onDefaultPinFormulaEvaluation:{work.defaultPinFormulaEvaluations += 1})
                    for key in textKeys where node.formatting.sheet[key] != nil {
                        do { let value = try resolve(node.id,key);textValues[key] = value;if node.formatting.sheet[key].flatMap({Double($0.value)}).map({abs($0-value)>1e-10}) ?? true { node.formatting.sheet[key]?.value = CompositeGeometry.number(value) } }
                        catch { pageIssues.insert("\(key): \(error.localizedDescription)") }
                    }
                    let tw = (textValues["TxtWidth"] ?? node.width/72)*72,th = (textValues["TxtHeight"] ?? node.height/72)*72,tx = (textValues["TxtPinX"] ?? node.width/144)*72,ty = (textValues["TxtPinY"] ?? node.height/144)*72
                    let lx = (textValues["TxtLocPinX"] ?? tw/144)*72,ly = (textValues["TxtLocPinY"] ?? th/144)*72,a = textValues["TxtAngle"] ?? 0
                    if tw > 0,th > 0,tw*page.paperScale < 100000,th*page.paperScale < 100000 {
                        var box = node.formatting.textBox ?? ShapeTextBox();box.width = tw/node.width;box.height = th/node.height;box.centerX = (tx+(tw/2-lx)*cos(a)-(th/2-ly)*sin(a)-node.sheetOrigin.x)/node.width;box.centerY = (node.height-ty-(tw/2-lx)*sin(a)-(th/2-ly)*cos(a)+node.sheetOrigin.y)/node.height;box.rotation = -a*180 / .pi
                        box.left = (textValues["LeftMargin"] ?? 0)*72;box.right = (textValues["RightMargin"] ?? 0)*72;box.top = (textValues["TopMargin"] ?? 0)*72;box.bottom = (textValues["BottomMargin"] ?? 0)*72;box.verticalAlignment = Int(exactly:textValues["VerticalAlign"] ?? 1) ?? box.verticalAlignment
                        if let original = node.formatting.textBox {
                            for path in [\ShapeTextBox.centerX,\.centerY,\.width,\.height,\.rotation,\.left,\.right,\.top,\.bottom] where abs(box[keyPath:path]-original[keyPath:path])<1e-9 { box[keyPath:path] = original[keyPath:path] }
                        };node.formatting.textBox = box
                    } else { pageIssues.insert("Calculated text dimensions exceeded the supported range; its cached text block was retained.") }
                }
                for c in node.formatting.controls.indices {
                    for key in node.formatting.controls[c].cells.keys {
                        guard var cell = node.formatting.controls[c].cells[key],!cell.formula.isEmpty,!["Inh","No Formula"].contains(cell.formula) else { continue }
                        do { cell.value = ShapeSheetContext.cached(try context.value(node.id,"Controls."+node.formatting.controls[c].name+"."+key));node.formatting.controls[c].cells[key] = cell }
                        catch { pageIssues.insert("Controls.\(node.formatting.controls[c].name).\(key): \(error.localizedDescription)") }
                    }
                }
                if let sections = node.formatting.geometry {
                    for key in GeometrySheet.names(sections) {
                        guard var cell = GeometrySheet.cell(key,on:node) else { continue }
                        if cell.formula.isEmpty || ["Inh","No Formula"].contains(cell.formula) { continue }
                        if let type = GeometrySheet.compositeType(key,on:node) {
                            do { let data = try resolveData(node.id,key);guard data.name == type else { throw DiagramError.invalid("Wrong composite geometry type.") };if cell.value != data.formula { cell.value = data.formula;try GeometrySheet.set(key,cell,on:&node) } }
                            catch { pageIssues.insert("\(key): \(error.localizedDescription)") };continue
                        }
                        do { let value = try resolve(node.id,key);if Double(cell.value).map({abs($0-value)>1e-10}) ?? true { cell.value = CompositeGeometry.number(value);try GeometrySheet.set(key,cell,on:&node) } }
                        catch { pageIssues.insert("\(key): \(error.localizedDescription)") }
                    }
                    let rendered = VisioFormat.geometryPaths(node.formatting.geometry!,width:node.sheetWidth/72,height:node.sheetHeight/72)
                    if rendered.paths.allSatisfy({$0.commands.allSatisfy{$0.isValid(xScale:node.width*page.paperScale,yScale:node.height*page.paperScale)}}) { node.formatting.paths = rendered.paths } else { pageIssues.insert("Calculated geometry exceeded the drawing bounds; its previous path was retained.") }
                    pageIssues.formUnion(rendered.warnings)
                }
                let originalNode = source.nodes[i]
                if abs(node.x-originalNode.x)<1e-9 { node.x = originalNode.x };if abs(node.y-originalNode.y)<1e-9 { node.y = originalNode.y }
                if abs(node.width-originalNode.width)<1e-9 { node.width = originalNode.width };if abs(node.height-originalNode.height)<1e-9 { node.height = originalNode.height }
                if abs(node.rotation-originalNode.rotation)<1e-9 { node.rotation = originalNode.rotation }
                if node != input.pages[pageIndex].nodes[i] { changedNodeIDsByPage[pageID, default: []].insert(node.id) }
                page.nodes[i] = node
            }
            work.add(context.work)
            diagram.pages[pageIndex] = page
            let pageIssueList = pageIssues.sorted()
            issuesByPage[pageID] = pageIssueList
            issues.formUnion(pageIssueList)
        }
        if cancellation?.isCancelled == true { return Calculation(diagram:input,issues:[],work:work,cancelled:true) }
        let synchronized = ShapeRichText.synchronizeCalculation(diagram,previous:input,affectedNodeIDsByPage:changedNodeIDsByPage,nodeIndicesByPage:nodeIndicesByPage)
        work.richTextNodes += changedNodeIDsByPage.values.reduce(0) { $0 + $1.count }
        return Calculation(diagram:synchronized,issues:issues.sorted(),issuesByPage:issuesByPage,work:work,changedNodeIDsByPage:changedNodeIDsByPage)
    }
    static func format(_ value:Double) -> String { String(format:"%.12g",locale:Locale(identifier:"en_US_POSIX"),value) }
}
