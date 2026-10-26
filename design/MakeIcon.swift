import AppKit
let destination=CommandLine.arguments[1]
let size=1024
let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:size,pixelsHigh:size,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
let context=NSGraphicsContext(bitmapImageRep:bitmap)!
NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current=context
let foreground=CommandLine.arguments.count>2
if foreground {
    bitmap.bitmapData!.initialize(repeating:0,count:bitmap.bytesPerRow*bitmap.pixelsHigh)
    let transform=NSAffineTransform(); transform.translateX(by:76.8,yBy:76.8); transform.scale(by:0.85); transform.concat()
} else {
let box=NSBezierPath(roundedRect:NSRect(x:0,y:0,width:1024,height:1024),xRadius:232,yRadius:232)
NSGradient(starting:NSColor(srgbRed:0.08,green:0.55,blue:1,alpha:1),ending:NSColor(srgbRed:0.02,green:0.31,blue:0.93,alpha:1))!.draw(in:box,angle:90)
let shine=NSBezierPath(roundedRect:NSRect(x:24,y:24,width:976,height:976),xRadius:216,yRadius:216); NSColor.white.withAlphaComponent(0.15).setStroke(); shine.lineWidth=3; shine.stroke()
}
NSColor.white.setStroke(); NSColor.white.setFill()
let first=NSBezierPath(); first.lineWidth=70; first.lineCapStyle = .round
first.move(to:NSPoint(x:245,y:490)); first.curve(to:NSPoint(x:775,y:600),controlPoint1:NSPoint(x:270,y:795),controlPoint2:NSPoint(x:670,y:850)); first.stroke()
let top=NSBezierPath(); top.move(to:NSPoint(x:635,y:620)); top.line(to:NSPoint(x:805,y:510)); top.line(to:NSPoint(x:840,y:710)); top.close(); top.fill()
let second=NSBezierPath(); second.lineWidth=70; second.lineCapStyle = .round
second.move(to:NSPoint(x:779,y:534)); second.curve(to:NSPoint(x:249,y:424),controlPoint1:NSPoint(x:754,y:229),controlPoint2:NSPoint(x:354,y:174)); second.stroke()
let bottom=NSBezierPath(); bottom.move(to:NSPoint(x:389,y:404)); bottom.line(to:NSPoint(x:219,y:514)); bottom.line(to:NSPoint(x:184,y:314)); bottom.close(); bottom.fill()
NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:destination))
