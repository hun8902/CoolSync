import AppKit
// Render QR modules directly into a bitmap: works without Core Image/Metal availability.
enum QRImage {
    static func make(_ value:String)->NSImage? {
        guard let code=try? QRCode.encode(text:value,ecl:.medium) else{return nil}
        let scale=6, border=4, side=(code.size+border*2)*scale
        guard let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:side,pixelsHigh:side,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:side*4,bitsPerPixel:32),let bytes=bitmap.bitmapData else{return nil}
        for y in 0..<side { for x in 0..<side {
            let black=code.getModule(x:x/scale-border,y:y/scale-border)
            let p=(y*side+x)*4; let c:UInt8=black ? 0:255
            bytes[p]=c;bytes[p+1]=c;bytes[p+2]=c;bytes[p+3]=255
        } }
        let image=NSImage(size:NSSize(width:side,height:side));image.addRepresentation(bitmap);return image
    }
}
