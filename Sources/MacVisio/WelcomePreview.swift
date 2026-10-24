import AppKit

enum WelcomePreview {
    static func render(to output:URL,section:WelcomeSection = .home,compact:Bool = false,empty:Bool = false) throws {
        let controller = WelcomeWindowController(onNew:{_ in},onOpen:{},onRecent:{_ in},onPin:{_ in},onBack:{},onSave:{},onSaveAs:{},onClose:{})
        let entries = empty ? [] : [
            RecentDrawing(url:URL(fileURLWithPath:"/Users/you/Documents/Operations Map.vsdx"),title:"Operations Map.vsdx",location:"Documents",isPinned:true),
            RecentDrawing(url:URL(fileURLWithPath:"/Users/you/Documents/System Landscape.vsdx"),title:"System Landscape.vsdx",location:"Documents",isPinned:false),
            RecentDrawing(url:URL(fileURLWithPath:"/Users/you/Documents/Project Overview.vsdx"),title:"Project Overview.vsdx",location:"Documents",isPinned:false)]
        controller.refresh(recents:entries,section:section,canGoBack:false)
        if compact { controller.window?.setContentSize(CGSize(width:480,height:440)) }
        guard let view = controller.window?.contentView else { throw DiagramError.invalid("The start screen could not be created.") }
        view.layoutSubtreeIfNeeded()
        controller.refresh(recents:entries,section:section,canGoBack:false)
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in:view.bounds) else { throw DiagramError.invalid("The start screen could not be rendered.") }
        view.cacheDisplay(in:view.bounds,to:bitmap)
        guard let data = bitmap.representation(using:.png,properties:[:]) else { throw DiagramError.invalid("The preview could not be encoded.") }
        try data.write(to:output,options:.atomic)
    }
}
