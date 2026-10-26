import Foundation
import Combine
import CryptoKit
let directory=URL(fileURLWithPath:CommandLine.arguments[1])
let bridge=FileTransfer()
let testKey=Data((0..<32).map{UInt8($0)})
bridge.key={testKey};bridge.connected={true}
let sample=Data((0..<(65536*3+57)).map{UInt8($0%251)})
let source=directory.appendingPathComponent("source.bin")
try sample.write(to:source)
let hash=SHA256.hash(data:sample).map{String(format:"%02x",$0)}.joined()
var stage=0
var peer:Process?
var token:AnyCancellable?
var currentID=""
bridge.sendControl={type,text,ref in
 guard type=="fileReady",let data=text.data(using:.utf8),let e=try? JSONDecoder().decode(FileEndpoint.self,from:data) else{return}
 let process=Process();process.executableURL=URL(fileURLWithPath:"/usr/bin/java")
 let target=stage==1 ? directory.appendingPathComponent("download.bin").path : source.path
 if stage==2 { process.standardError=Pipe() }
 process.arguments=["-cp",directory.path,"FilePeer",stage==1 ? "download":"upload",String(e.port),target,ref,e.token,String(sample.count)]
 do{try process.run();peer=process}catch{print(error);exit(1)}
}
func start(_ flow:String){
 let m=FileMeta(id:UUID().uuidString,name:"test.bin",size:Int64(sample.count),sha:stage==2 ? String(repeating:"0",count:64):hash,flow:flow);currentID=m.id
 let destination=directory.appendingPathComponent(stage==2 ? "protected.bin":"received.bin")
 if stage==2 { try! Data("existing file".utf8).write(to:destination) }
 bridge.startTest(m,source:flow=="download" ? source:nil,destination:flow=="upload" ? destination:nil)
}
token=bridge.$summary.sink { value in
 if stage==2 && value.contains("무결성") {
  DispatchQueue.main.async {
   precondition((try! Data(contentsOf:directory.appendingPathComponent("protected.bin")))==Data("existing file".utf8))
   precondition(!(try! FileManager.default.contentsOfDirectory(atPath:directory.path)).contains(where:{$0.hasSuffix(".partial")}))
   print("File TCP integration: PASS (both directions, 196665 bytes; AES-GCM + SHA-256 + ACK; corrupt-hash transfer rejected without replacing existing file)");exit(0)
  }
 }

 if value.contains("전송 완료") {
  DispatchQueue.main.async {
   let path=directory.appendingPathComponent(stage==0 ? "received.bin":"download.bin")
   guard (try? Data(contentsOf:path))==sample else{print("Binary file mismatch");exit(1)}
   peer?.waitUntilExit();guard peer?.terminationStatus==0 else{exit(1)}
   if stage==0{stage=1;start("download")}else{stage=2;start("upload")}
  }
 }
}
DispatchQueue.main.asyncAfter(deadline:.now()+35){print("File test timed out: \(bridge.summary)");exit(1)}
start("upload")
RunLoop.main.run()
