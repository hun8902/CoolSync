import AppKit
import CryptoKit
let directory=URL(fileURLWithPath:CommandLine.arguments[1]);let bridge=FileTransfer();bridge.connected={true};bridge.key={Data((0..<32).map{UInt8($0)})};bridge.canReceiveImage={_ in true}
let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:16,pixelsHigh:16,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
let bytes=bitmap.representation(using:.png,properties:[:])!;let source=directory.appendingPathComponent("image.png");try bytes.write(to:source)
let hash=SHA256.hash(data:bytes).map{String(format:"%02x",$0)}.joined();let time=Int64(Date().timeIntervalSince1970*1000)
var child:Process?
bridge.sendControl={type,text,ref in
 guard type=="fileReady",let endpoint=try? JSONDecoder().decode(FileEndpoint.self,from:Data(text.utf8))else{return}
 let p=Process();p.executableURL=URL(fileURLWithPath:"/usr/bin/java");p.arguments=["-cp",directory.path,"FilePeer","upload",String(endpoint.port),source.path,ref,endpoint.token,String(bytes.count)];try! p.run();child=p
}
bridge.imageReceived={url,receivedAt in precondition(receivedAt==time);precondition((try! Data(contentsOf:url))==bytes);precondition(NSImage(contentsOf:url) != nil);child?.waitUntilExit();precondition(child?.terminationStatus==0);print("Clipboard image transport PASS: auto-accepted image offer, AES-GCM transfer, hash and image validation, image callback, original PNG retained");exit(0)}
var meta=FileMeta(id:UUID().uuidString,name:"image.png",size:Int64(bytes.count),sha:hash,flow:"upload");meta.clipboard=true;meta.clipTime=time
var message=Wire.Message(type:"fileOffer");message.text=String(data:try JSONEncoder().encode(meta),encoding:.utf8)!;message.ref=meta.id
bridge.handle(message)
DispatchQueue.main.asyncAfter(deadline:.now()+20){print("Image transport timeout: \(bridge.summary)");exit(1)}
RunLoop.main.run()
