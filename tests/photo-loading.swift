import AppKit
import SwiftUI
let app=NSApplication.shared;app.setActivationPolicy(.prohibited);app.appearance=NSAppearance(named:.darkAqua)
let output=URL(fileURLWithPath:CommandLine.arguments[1]);try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
let port=Int(CommandLine.arguments[2])!
func wait(_ predicate:()->Bool,_ seconds:Double=10){let deadline=Date().addingTimeInterval(seconds);while !predicate(),Date()<deadline{RunLoop.main.run(until:Date().addingTimeInterval(0.01))};precondition(predicate(),"callback timeout")}
let transport=GalleryTransport();transport.key={Data((0..<32).map{UInt8($0)})};transport.bootstrap={complete in complete(["ok":true,"hosts":["127.0.0.1"],"port":port,"token":"fixture-token"])}
var done=false;transport.call("galleryState"){response in precondition(response["ok"]as?Bool==true);precondition((response["payload"]as?String)?.count==80000);done=true};wait{done}
for mode in ["tamper","wrongref","oversize","eof"]{done=false;transport.call("galleryState",["mode":mode]){response in precondition(response["ok"]as?Bool==false,"must reject \(mode)");done=true};wait{done}}
var canceledCallback=false;transport.call("galleryState",["mode":"wait"]){_ in canceledCallback=true};RunLoop.main.run(until:Date().addingTimeInterval(0.05));transport.invalidate();RunLoop.main.run(until:Date().addingTimeInterval(0.9));precondition(!canceledCallback)
func model()->GalleryModel{let explorer=ExplorerModel();explorer.connected={true};return GalleryModel(explorer:explorer,store:PhotoLibraryStore(folder:output.appendingPathComponent("fixture-"+UUID().uuidString)))}
func row(_ id:String)->[String:Any]{["id":id,"name":"Photo\(id).jpg","path":"DCIM/Photo\(id).jpg","size":100,"mime":"image/jpeg","taken":1793000000000,"duration":0,"width":400,"height":500,"album":"Camera","favorite":false]}
let success=model();var callbacks:[([String:Any])->Void]=[]
success.readOverride={op,fields,callback in if op=="gallery"{callbacks.append(callback)}else{callback(["ok":false,"code":"fixture","error":"미리보기 실패 합성 사례"])}}
success.reload();precondition(success.loading && success.sync.phase == .catalog && success.sync.issue==nil);precondition(callbacks.count==1)
callbacks.removeFirst()(["ok":true,"items":[row("1")],"next":1,"total":2]);precondition(success.sync.received==1 && success.sync.total==2 && success.loading);precondition(callbacks.count==1)
callbacks.removeFirst()(["ok":true,"items":[row("2")],"next":2,"total":2]);precondition(!success.loading && success.items.count==2 && success.sync.received==2 && success.sync.pages==2);precondition(success.thumbnailErrors.count==2)
let cached=GalleryModel(explorer:ExplorerModel(),store:success.store);cached.readCatalogCache();precondition(cached.items.count==2 && cached.sync.cached)
let failure=model();failure.readOverride={_,_,callback in callback(["ok":false,"code":"unlock","error":"재부팅 후 첫 잠금 해제 필요"]) };failure.reload();precondition(!failure.loading && failure.sync.phase == .failed && failure.sync.issueCode=="unlock");precondition(failure.items.isEmpty)
let malformed=model();malformed.readOverride={_,_,callback in callback(["ok":true,"items":[["id":"bad"]],"next":1,"total":1])};malformed.reload();precondition(!malformed.loading && malformed.sync.phase == .failed && malformed.sync.issueCode=="decode")
let canceled=model();var stale:(([String:Any])->Void)?;canceled.readOverride={_,_,callback in stale=callback};canceled.reload();canceled.cancelPhotoLoad();stale?(["ok":true,"items":[row("3")],"next":1,"total":1]);precondition(canceled.sync.phase == .canceled && !canceled.loading && canceled.items.isEmpty)
let empty=model();empty.readOverride={_,_,callback in callback(["ok":true,"items":[],"next":0,"total":0])};empty.reload();precondition(empty.sync.phase == .ready && empty.items.isEmpty)
let window=NSWindow(contentRect:NSRect(x:0,y:0,width:1280,height:800),styleMask:[.borderless],backing:.buffered,defer:false)
func snapshot(_ model:GalleryModel,_ name:String){let host=NSHostingView(rootView:GalleryPane(model:model).environment(\.colorScheme,.dark));window.contentView=host;host.frame=NSRect(x:0,y:0,width:1280,height:800);host.layoutSubtreeIfNeeded();RunLoop.main.run(until:Date().addingTimeInterval(0.3));host.displayIfNeeded();let image=host.bitmapImageRepForCachingDisplay(in:host.bounds)!;host.cacheDisplay(in:host.bounds,to:image);try!image.representation(using:.png,properties:[:])!.write(to:output.appendingPathComponent(name+".png"))}
let pending=model();pending.readOverride={_,_,_ in};pending.reload();snapshot(pending,"loading")
snapshot(failure,"failure")
success.sync.device=GalleryDeviceState(interactive:false,locked:true,userUnlocked:true,storage:true,batteryExempt:true,powerSave:false,build:1052);snapshot(success,"preview-failure-screen-off")
snapshot(empty,"empty-confirmed")
print("PASS: restored HTTP/AES-GCM 240KB reply; tampering/ref/length/EOF rejection; cancellation; partial catalog counts; explicit unlock and decode errors; stale reply rejection; confirmed empty vs failed; cache restore; thumbnail failures; screen-off state; four native loading-state renders")
