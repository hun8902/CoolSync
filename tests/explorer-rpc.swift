import AppKit
import Foundation
let model=ExplorerModel();model.connected={true}
var calls:[String]=[]
model.send={type,text,ref in
 precondition(type=="fsRequest")
 let q=try! JSONSerialization.jsonObject(with:Data(text.utf8))as![String:Any]
 let op=q["op"]as!String;calls.append(op)
 var answer:[String:Any]=["ok":true]
 if op=="list"{
  let offset=q["offset"]as?Int ?? 0;let path=q["path"]as?String ?? ""
  let rows:[[String:Any]]=offset==0 ? [["name":"Folder","path":path.isEmpty ? "Folder":path+"/Folder","directory":true,"size":0,"modified":0],["name":"b.txt","path":path+"b.txt","directory":false,"size":11,"modified":10]]:[["name":"a.txt","path":path+"a.txt","directory":false,"size":2,"modified":11]]
  answer=["ok":true,"entries":rows,"path":path,"offset":offset,"next":offset==0 ? 2:3,"total":3,"free":1000]
 }else if op=="move"{precondition((q["paths"]as![String])==["b.txt"]);precondition(q["destination"]as?String=="")}
 else if op=="listTrash"{answer=["ok":true,"trash":[["id":UUID().uuidString,"name":"trash.txt","original":"Folder/trash.txt","deleted":0]]]}
 var m=Wire.Message(type:"fsResponse");m.ref=ref;m.text=String(data:try!JSONSerialization.data(withJSONObject:answer),encoding:.utf8)!
 model.handle(m)
}
model.browse("");precondition(model.entries.count==3 && !model.busy && model.available==1000)
precondition(model.visible.first?.directory==true)
model.search="a.txt";precondition(model.visible.count==1);model.search=""
model.selection=["b.txt"];model.copy(cut:true);model.paste();precondition(calls.contains("move"))
model.showTrash();precondition(model.trash.count==1 && !model.busy)
model.restore(model.trash[0].id);precondition(calls.contains("restore"))
model.connectionEnded();precondition(!model.busy && model.selection.isEmpty)
print("Mac explorer RPC: PASS (request correlation, directory pagination, selection/cut/paste, search, trash/restore)")
