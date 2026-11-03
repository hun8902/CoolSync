import Foundation
import AppKit
let root=URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent("fixture-"+UUID().uuidString);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try?FileManager.default.removeItem(at:root)}
func model()->GalleryModel{let e=ExplorerModel();e.connected={true};return GalleryModel(explorer:e,store:PhotoLibraryStore(folder:root.appendingPathComponent(UUID().uuidString)),cacheFolder:root.appendingPathComponent("cache"))}
func row(_ id:String)->GalleryItem{GalleryItem(id:id,name:id+".jpg",path:"DCIM/"+id+".jpg",size:4,mime:"image/jpeg",taken:1000,duration:0,width:10,height:10,album:"Camera",favorite:false)}
func response(_ rows:[GalleryItem])->[String:Any]{let d=try!JSONEncoder().encode(rows);return ["ok":true,"items":try!JSONSerialization.jsonObject(with:d),"next":rows.count,"total":rows.count]}
let g=model();g.items=[row("1"),row("2")];g.selected=row("1");g.selection=["1"];g.slideshow=true;g.editing=true;g.sync.phase = .ready;g.galleryVisible=true
var callbacks:[([String:Any])->Void]=[];var requests=0
g.readOverride={op,_,done in if op=="gallery"{requests+=1;callbacks.append(done)}else{done(["ok":false])}}
precondition(requests==0);g.galleryDidChange();precondition(requests==1 && g.items.count==2)
for _ in 0..<20{g.galleryDidChange()};precondition(requests==1,"changes during load must not start concurrent requests")
callbacks.removeFirst()(response([row("2")]));precondition(requests==2 && callbacks.count==1 && g.selected==nil && g.selection.isEmpty && !g.slideshow && !g.editing)
callbacks.removeFirst()(response([row("2")]));precondition(!g.loading && !g.galleryDirty && g.items.map{$0.id}==["2"])
for _ in 0..<20{g.ensureLoaded()};precondition(requests==2,"idle view must not poll")
g.galleryVisible=false;g.galleryDidChange();precondition(requests==2 && g.galleryDirty);g.galleryVisible=true;g.ensureLoaded();precondition(requests==3);callbacks.removeFirst()(response([row("2")]))
let t=model();t.items=[row("1"),row("2")];t.selected=row("1");t.sync.phase = .ready
var refs:[String]=[];t.explorer.send={type,text,ref in refs.append(ref)}
t.trashItems([row("1")]);precondition(t.items.map{$0.id}==["2"] && t.selected==nil && t.photoTrashRunning && t.pendingTrashPaths.contains("DCIM/1.jpg"),"Mac trash must update before phone response")
precondition(t.pendingTrashPaths.contains("DCIM/1.jpg"),"pending trash must remain hidden until response")
var m=Wire.Message(type:"fsResponse");m.ref=refs.removeFirst();m.text="{\"ok\":false,\"error\":\"synthetic failure\"}";t.explorer.handle(m)
precondition(t.items.count==2 && !t.photoTrashRunning && t.pendingTrashPaths.isEmpty,"failed trash restores local display")
t.trashItems([row("1")]);m.ref=refs.removeFirst();m.text="{\"ok\":true}";t.explorer.handle(m);precondition(t.items.map{$0.id}==["2"] && !t.photoTrashRunning && t.pendingTrashPaths.isEmpty)
t.galleryVisible=true;var restoredCallbacks:[([String:Any])->Void]=[];t.readOverride={op,_,done in if op=="gallery"{restoredCallbacks.append(done)}else{done(["ok":false])}}
t.ensureLoaded();restoredCallbacks.removeFirst()(response([row("1"),row("2")]));precondition(t.items.count==2,"restored original at same path and ID must reappear")
t.disconnect();precondition(!t.photoTrashRunning && t.pendingTrashPaths.isEmpty)
let u=model();u.items=[row("1"),row("2")];u.sync.phase = .ready;u.galleryVisible=true
var snapshots:[([String:Any])->Void]=[];var deleteRef=""
u.readOverride={op,_,done in if op=="gallery"{snapshots.append(done)}else{done(["ok":false])}}
u.explorer.send={_,_,ref in deleteRef=ref};u.galleryDidChange();u.trashItems([row("1")])
var accepted=Wire.Message(type:"fsResponse");accepted.ref=deleteRef;accepted.text="{\"ok\":true}";u.explorer.handle(accepted)
precondition(snapshots.count==2 && u.items.map{$0.id}==["2"])
snapshots.removeFirst()(response([row("1"),row("2")]));precondition(u.items.map{$0.id}==["2"] && u.loading,"pre-delete reply must be rejected")
snapshots.removeFirst()(response([row("2")]));u.galleryDidChange();snapshots.removeFirst()(response([row("1"),row("2")]));precondition(u.items.count==2,"restore of same ID and path must be visible")
let d=model();d.unlocked=true;var trashRequests:[String]=[];d.explorer.send={_,_,ref in trashRequests.append(ref)}
d.loadDeleted();d.loadDeleted();precondition(trashRequests.count==2)
func trashReply(_ ref:String,_ ids:[String]){var value=Wire.Message(type:"fsResponse");value.ref=ref;value.text=String(data:try!JSONSerialization.data(withJSONObject:["ok":true,"trash":ids.map{["id":$0,"name":"one.jpg","original":"DCIM/one.jpg","deleted":1000]as[String:Any]},"next":ids.count,"total":ids.count]),encoding:.utf8)!;d.explorer.handle(value)}
trashReply(trashRequests[1],["new"]);precondition(trashRequests.count==3)
trashReply(trashRequests[0],["old"]);precondition(d.deleted.map{$0.id}==["new"] && trashRequests.count==3)
trashReply(trashRequests[2],[]);precondition(d.deleted.map{$0.id}==["new"],"older trash replies must not replace a newer snapshot")
print("PASS: event-only refresh; burst coalescing and in-flight follow-up; no idle requests; hidden gallery dirtied until entry; deleted detail closes; Mac trash updates before response; stale resurrection blocked; failure rollback; successful reconciliation; disconnect cleanup")
