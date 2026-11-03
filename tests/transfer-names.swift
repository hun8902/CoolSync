import Foundation
let root=URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent("fixture-"+UUID().uuidString);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try?FileManager.default.removeItem(at:root)}
let nfd="가나다무".decomposedStringWithCanonicalMapping
let normalized=try TransferNames.name(nfd+".jpg");precondition(Array(normalized.unicodeScalars)==Array("가나다무.jpg".unicodeScalars))
precondition(try! TransferNames.newRelativePath(nfd+"/"+nfd)=="가나다무/가나다무")
precondition(try! TransferNames.name("ㄱㅏ 😀.txt")=="ㄱㅏ 😀.txt")
precondition(try! TransferNames.name(String(repeating:"a",count:190)+".jpeg")==String(repeating:"a",count:190)+".jpeg")
precondition((try?TransferNames.name(String(repeating:"가",count:85)+"a"))==nil)
let directory=root.appendingPathComponent(nfd);try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
let nested=directory.appendingPathComponent(nfd);try FileManager.default.createDirectory(at:nested,withIntermediateDirectories:true)
let source=nested.appendingPathComponent(nfd+".txt");let bytes=Data("original sentinel 😀".utf8);try bytes.write(to:source)
let explorer=ExplorerModel();let files=FileTransfer();explorer.files=files;explorer.connected={true};files.connected={true};files.key={Data(repeating:1,count:32)}
let existingParent="기존".decomposedStringWithCanonicalMapping
var created:[String]=[];var offers=0
explorer.send={type,text,ref in let q=try!JSONSerialization.jsonObject(with:Data(text.utf8))as![String:Any];let op=q["op"]as!String
 if op=="mkdir"{let parent=q["path"]as!String;let name=q["name"]as!String;precondition(Array(name.unicodeScalars)==Array("가나다무".unicodeScalars));created.append([parent,name].filter{!$0.isEmpty}.joined(separator:"/"))}
 var reply=Wire.Message(type:"fsResponse");reply.ref=ref;reply.text="{\"ok\":true}";explorer.handle(reply)
}
files.sendControl={type,text,ref in if type=="fileOffer"{let m=try!JSONDecoder().decode(FileMeta.self,from:Data(text.utf8));precondition(Array(m.name.unicodeScalars)==Array("가나다무.txt".unicodeScalars));precondition(Array(m.path!.unicodeScalars)==Array((existingParent+"/가나다무/가나다무").unicodeScalars));offers+=1}}
explorer.upload([directory],to:existingParent)
let deadline=Date().addingTimeInterval(10);while offers==0 && Date()<deadline{RunLoop.main.run(until:Date().addingTimeInterval(0.01))}
precondition(offers==1 && created==["기존/가나다무","기존/가나다무/가나다무"])
precondition(try! Data(contentsOf:source)==bytes);explorer.cancelJobs()
let collision=ExplorerModel();var sent=0;collision.connected={true};collision.send={_,_,_ in sent+=1};collision.upload([source,source],to:"")
precondition(sent==0 && collision.error?.contains("중복") == true)
let invalid=ExplorerModel();invalid.connected={true};var rejected=false;invalid.call("mkdir",["path":"","name":String(repeating:"가",count:86)]){response in rejected=response["ok"]as?Bool==false};precondition(rejected && invalid.error != nil)
print("PASS: NFC wire names and nested destinations; original URLs and bytes preserved; compatibility jamo/emoji preserved; long extension preserved; UTF-8 boundary; duplicate plan rejected before first request")
