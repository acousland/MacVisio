import AppKit

extension EditorWindowController {
    func insertTextField(formula:String,picture:String = "",type:Int = 0,into id:UUID,range:NSRange? = nil) throws {
        var next = diagramDocument.diagram
        guard let i = next.page.nodes.firstIndex(where:{$0.id == id}),!next.page.isLocked(next.page.nodes[i]) else { return }
        next.page.nodes[i] = try TextFieldEngine.inserting(formula:formula,picture:picture,type:type,into:next.page.nodes[i],range:range)
        _ = try next.validated();diagramDocument.replaceInEditor(with:next,action:"Insert Text Field")
    }
    @objc func insertField(_ sender:Any?) {
        let caret = canvas.fieldInsertionPosition();canvas.finishEditing(commit:true)
        guard selection.count == 1,let node = selection.first,!diagramDocument.diagram.page.isLocked(node) else { return }
        let view = FieldInsertionView(properties:node.formatting.data)
        let alert = NSAlert();alert.messageText = "Insert Text Field";alert.informativeText = "Fields update when page information, geometry or Shape Data changes.";alert.accessoryView = view;alert.addButton(withTitle:"Insert");alert.addButton(withTitle:"Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do { try insertTextField(formula:view.formula.stringValue,picture:view.picture.stringValue,type:view.kind.indexOfSelectedItem == 0 ? 0 : view.kind.indexOfSelectedItem == 1 ? 2 : 5,into:node.id,range:caret?.0 == node.id ? caret?.1 : nil) } catch { presentError(error) }
    }
    @objc func editTextFields(_ sender:Any?) {
        canvas.finishEditing(commit:true);guard selection.count == 1,let node = selection.first,!diagramDocument.diagram.page.isLocked(node) else { return }
        let old = node.formatting.textFields ?? []
        let grid = PropertyGrid(columns:["Field","Formula","Format","Type","Unit"],rows:old.map{[String($0.index),$0.cells["Value"]?.formula ?? "",$0.cells["Format"]?.value ?? "",$0.cells["Type"]?.value ?? "0",$0.cells["Value"]?.unit ?? ""]},width:880)
        guard grid.run(title:"Text Fields",message:"Edit field formulas and format pictures. Type: 0 text, 2 number, 5 date. Removing a field keeps its current display as ordinary text.") else { return }
        do {
            var fields:[ShapeTextField] = []
            for row in grid.rows where !row.allSatisfy(\.isEmpty) {
                guard let index = UInt32(row[0]),let type = Int(row[3]),[0,2,5,6,7].contains(type) else { throw DiagramError.invalid("Invalid field index or type.") }
                var field = old.first{$0.index == Int(index)} ?? ShapeTextField(index:Int(index),cells:[:],cached:"")
                field.cells["Value"] = ShapeSheetCell(value:field.cells["Value"]?.value ?? "",formula:row[1],unit:row[4]);field.cells["Format"] = ShapeSheetCell(value:row[2],unit:"STR");field.cells["Type"] = ShapeSheetCell(value:String(type));fields.append(field)
            }
            try setTextFields(fields,for:node.id)
        } catch { presentError(error) }
    }
    func setTextFields(_ fields:[ShapeTextField],for id:UUID) throws {
        var next = diagramDocument.diagram;guard let i = next.page.nodes.firstIndex(where:{$0.id == id}) else { return }
        next.page.nodes[i].formatting.textFields = fields
        if let runs = next.page.nodes[i].formatting.textRuns { next.page.nodes[i].formatting.textRuns = runs.map{run in var run = run;if let field = run.fieldIndex,!fields.contains(where:{$0.index == field}) { run.fieldIndex = nil;run.fieldToken = nil };return run} }
        _ = try next.validated();diagramDocument.replaceInEditor(with:next,action:"Edit Text Fields")
    }
}
private final class FieldInsertionView:FlippedView {
    let source = NSPopUpButton(),formula = NSTextField(string:"PAGENAME()"),picture = NSTextField(string:""),kind = NSPopUpButton()
    private var formulas:[String] = [],types:[Int] = []
    init(properties:[ShapeDataProperty]) {
        super.init(frame:CGRect(x:0,y:0,width:500,height:160))
        let labels = ["Page name","Page number","Number of pages","Shape width","Shape height","Current date"]+properties.map{$0.label.isEmpty ? $0.key : $0.label}+["Custom formula"]
        formulas = ["PAGENAME()","PAGENUMBER()","PAGECOUNT()","FORMAT(Width,FIELDPICTURE(1))","FORMAT(Height,FIELDPICTURE(1))","TODAY()"]+properties.map{"Prop."+$0.key}+[""]
        types = [0,2,2,0,0,5]+properties.map{$0.type == 5 ? 5 : [2,6,7].contains($0.type) ? 2 : 0}+[0]
        source.addItems(withTitles:labels);source.target = self;source.action = #selector(changed(_:));kind.addItems(withTitles:["Text","Number","Date"])
        for (title,y,control) in [("Source",10,source as NSView),("Formula",48,formula as NSView),("Format",86,picture as NSView),("Value type",124,kind as NSView)] { let label = NSTextField(labelWithString:title);label.frame = CGRect(x:0,y:y+4,width:85,height:20);addSubview(label);control.frame = CGRect(x:95,y:y,width:400,height:28);addSubview(control) }
    }
    required init?(coder:NSCoder) { fatalError() }
    @objc private func changed(_ sender:Any?) { let i = source.indexOfSelectedItem;formula.stringValue = formulas[i];kind.selectItem(at:types[i] == 0 ? 0 : types[i] == 2 ? 1 : 2);picture.stringValue = types[i] == 5 ? "yyyy-MM-dd" : "" }
}
