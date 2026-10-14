import Foundation

enum VisioXML {
    static func document(_ data:Data) throws -> XMLDocument {
        guard let text = String(data:data,encoding:.utf8), !text.localizedCaseInsensitiveContains("<!DOCTYPE"), !text.localizedCaseInsensitiveContains("<!ENTITY") else { throw DiagramError.invalid("Package XML must be UTF-8 without a DTD.") }
        let document = try XMLDocument(data:data,options:[.nodePreserveAll,.nodeLoadExternalEntitiesNever])
        // Foundation drops whitespace-only text nodes, even with xml:space and
        // nodePreserveWhitespace. Rebuild ordered Text children with XMLParser.
        let builder = TextBuilder(),parser = XMLParser(data:data);parser.shouldResolveExternalEntities = false;parser.delegate = builder
        guard parser.parse() else { throw DiagramError.invalid("Invalid or oversized package XML.") }
        var originals:[XMLElement] = []
        func find(_ element:XMLElement) { if element.localTag == "Text" { originals.append(element) } else { for child in (element.children ?? []).compactMap({$0 as? XMLElement}) { find(child) } } }
        if let root = document.rootElement() { find(root) }
        guard originals.count == builder.texts.count else { throw DiagramError.invalid("Inconsistent package text XML.") }
        for (original,rebuilt) in zip(originals,builder.texts) { original.setChildren((rebuilt.children ?? []).map{$0.copy() as! XMLNode}) }
        return document
    }
    static func element(_ xml:String) throws -> XMLElement {
        guard let root = try document(Data(xml.utf8)).rootElement() else { throw DiagramError.invalid("Missing XML element.") }; return root
    }
    static func relationshipPart(_ part:String) -> String {
        let parent = (part as NSString).deletingLastPathComponent
        return (parent.isEmpty ? "" : parent+"/")+"_rels/"+(part as NSString).lastPathComponent+".rels"
    }
    static func value(_ element:XMLElement?,_ cell:String) -> String? { element?.elementsLocal("Cell").first { $0.attr("N") == cell }?.attr("V") }
    static func number(_ element:XMLElement?,_ cell:String,_ fallback:Double = 0) -> Double { Double(value(element,cell) ?? "") ?? fallback }
    @discardableResult static func set(_ element:XMLElement,_ cell:String,_ value:String,formula:String? = nil) -> XMLElement {
        let node = element.elementsLocal("Cell").first { $0.attr("N") == cell } ?? XMLElement(name:"Cell")
        if node.parent == nil { element.insertChild(node,at:0) }
        node.setAttr("N",cell); node.setAttr("V",value); node.setAttr("F",formula)
        return node
    }
    static func set(_ element:XMLElement,_ cell:String,_ value:Double,formula:String? = nil) { set(element,cell,String(format:"%.12g",locale:Locale(identifier:"en_US_POSIX"),value),formula:formula) }
    static func section(_ element:XMLElement,_ name:String) -> XMLElement {
        if let existing = element.elementsLocal("Section").first(where:{$0.attr("N") == name}) { return existing }
        let section = XMLElement(name:"Section"); section.setAttr("N",name); element.addChild(section); return section
    }
    static func row(_ element:XMLElement,_ section:String) -> XMLElement {
        let s = self.section(element,section)
        if let existing = s.elementsLocal("Row").first { return existing }
        let row = XMLElement(name:"Row"); row.setAttr("IX","0"); s.addChild(row); return row
    }
    static func setText(_ element:XMLElement,_ text:String) {
        let existing = element.firstLocal("Text") ?? XMLElement(name:"Text")
        if existing.parent == nil { element.addChild(existing) }
        existing.setChildren([XMLNode.text(withStringValue:text) as! XMLNode])
    }
    private final class TextBuilder:NSObject,XMLParserDelegate {
        var texts:[XMLElement] = []
        private var stack:[XMLElement] = []
        private var depth = 0,count = 0
        func parser(_ parser:XMLParser,didStartElement name:String,namespaceURI:String?,qualifiedName:String?,attributes:[String:String]) {
            depth += 1;count += 1;guard depth <= 100,count <= 500000 else { parser.abortParsing();return }
            guard !stack.isEmpty || name.split(separator:":").last == "Text" else { return }
            let element = XMLElement(name:name)
            for (key,value) in attributes {
                if key == "xmlns" || key.hasPrefix("xmlns:") { element.addNamespace(XMLNode.namespace(withName:key == "xmlns" ? "" : String(key.dropFirst(6)),stringValue:value) as! XMLNode) }
                else { element.addAttribute(XMLNode.attribute(withName:key,stringValue:value) as! XMLNode) }
            }
            if let parent = stack.last { parent.addChild(element) };stack.append(element)
        }
        func parser(_ parser:XMLParser,foundCharacters value:String) { guard let parent = stack.last else { return };if let last = parent.children?.last,last.kind == .text { last.stringValue = (last.stringValue ?? "")+value } else { parent.addChild(XMLNode.text(withStringValue:value) as! XMLNode) } }
        func parser(_ parser:XMLParser,foundCDATA data:Data) { if let text = String(data:data,encoding:.utf8) { self.parser(parser,foundCharacters:text) } }
        func parser(_ parser:XMLParser,didEndElement name:String,namespaceURI:String?,qualifiedName:String?) {
            if let element = stack.popLast(),stack.isEmpty { texts.append(element) };depth -= 1
        }
        func parser(_ parser:XMLParser,resolveExternalEntityName name:String,systemID:String?) -> Data? { nil }
    }
}
extension XMLElement {
    var localTag: String { localName ?? name?.split(separator:":").last.map(String.init) ?? "" }
    func elementsLocal(_ name:String) -> [XMLElement] { (children ?? []).compactMap { $0 as? XMLElement }.filter { $0.localTag == name } }
    func firstLocal(_ name:String) -> XMLElement? { elementsLocal(name).first }
    func attr(_ name:String) -> String? { attribute(forName:name)?.stringValue }
    func setAttr(_ name:String,_ value:String?) {
        if let existing = attribute(forName:name) { if let value = value { existing.stringValue = value } else { removeAttribute(forName:name) } }
        else if let value = value { addAttribute(XMLNode.attribute(withName:name,stringValue:value) as! XMLNode) }
    }
    var allShapes: [XMLElement] { elementsLocal("Shape").flatMap { [$0]+($0.firstLocal("Shapes")?.allShapes ?? []) } }
}
