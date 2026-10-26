import AppKit
let value="coolsync://pair?key="+String(repeating:"a",count:64)+"&name=CoolSync%20Mac"
let image=QRImage.make(value)!
let bitmap=NSBitmapImageRep(data:image.tiffRepresentation!)!
try bitmap.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
