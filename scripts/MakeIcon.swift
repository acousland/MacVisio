import AppKit
let destination = URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent("MacVisio.iconset")
try FileManager.default.createDirectory(at:destination,withIntermediateDirectories:true)
for size in [16,32,128,256,512] {
    for scale in [1,2] {
        let pixels = size*scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:pixels,pixelsHigh:pixels,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        let context = NSGraphicsContext(bitmapImageRep:bitmap)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
        context.cgContext.scaleBy(x:Double(pixels)/512,y:Double(pixels)/512)
        let tile = NSBezierPath(roundedRect:CGRect(x:36,y:36,width:440,height:440),xRadius:96,yRadius:96)
        NSGradient(starting:NSColor(srgbRed:0.21,green:0.45,blue:0.77,alpha:1),ending:NSColor(srgbRed:0.16,green:0.28,blue:0.55,alpha:1))!.draw(in:tile,angle:65)
        let line = NSBezierPath(); line.move(to:CGPoint(x:256,y:346)); line.line(to:CGPoint(x:256,y:255)); line.move(to:CGPoint(x:156,y:200)); line.line(to:CGPoint(x:256,y:255)); line.line(to:CGPoint(x:356,y:200)); line.lineWidth = 15; line.lineCapStyle = .round; NSColor.white.withAlphaComponent(0.8).setStroke(); line.stroke()
        for rect in [CGRect(x:189,y:320,width:134,height:80),CGRect(x:80,y:131,width:152,height:88),CGRect(x:281,y:131,width:152,height:88)] {
            NSColor.white.setFill(); NSBezierPath(roundedRect:rect,xRadius:18,yRadius:18).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try bitmap.representation(using:.png,properties:[:])!.write(to:destination.appendingPathComponent(name))
    }
}
