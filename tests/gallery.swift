import AppKit
import SwiftUI
let app=NSApplication.shared
app.setActivationPolicy(.prohibited)
app.appearance=NSAppearance(named:.darkAqua)
let model=DashboardModel(preview:true)
model.tab=4;model.connected=true
let gallery=model.gallery
func item(_ id:String,_ name:String,_ taken:Int64,_ video:Bool=false)->GalleryItem{GalleryItem(id:id,name:name,path:"DCIM/Camera/"+name,size:3200000,mime:video ? "video/mp4":"image/jpeg",taken:taken,duration:65000,width:3024,height:4032,album:"카메라",favorite:false)}
gallery.items=[item("10","Portrait.jpg",1793000000000),item("9","Seaside.jpg",1793000000000),item("8","Clouds.mp4",1792000000000,true),item("7","Undated.jpg",0)]
precondition(gallery.visible.map{$0.id}==["10","9","8","7"])
gallery.ascending=true;precondition(gallery.visible.map{$0.id}==["8","9","10","7"])
gallery.category="비디오";precondition(gallery.visible.map{$0.id}==["8"])
gallery.category="보관함";gallery.search="Seaside";precondition(gallery.visible.map{$0.id}==["9"])
gallery.search="";gallery.ascending=false;gallery.grouping="월";precondition(gallery.sections.last?.0=="촬영일 없음");gallery.grouping="모든 사진"
let symbols=["person.crop.rectangle","water.waves","cloud.sun","photo"]
for (i,item) in gallery.items.enumerated(){let image=NSImage(size:NSSize(width:400,height:500));image.lockFocus();NSColor(calibratedHue:CGFloat(i)*0.2,saturation:0.35,brightness:0.65,alpha:1).setFill();NSRect(x:0,y:0,width:400,height:500).fill();NSImage(systemSymbolName:symbols[i],accessibilityDescription:nil)?.draw(in:NSRect(x:80,y:130,width:240,height:240));image.unlockFocus();gallery.thumbnails[item.id]=image}
gallery.status="미리보기 · 합성 자료 4개"
let window=NSWindow(contentRect:NSRect(x:0,y:0,width:1280,height:800),styleMask:[.borderless],backing:.buffered,defer:false)
let host=NSHostingView(rootView:CoolDashboard(model:model).environment(\.colorScheme,.dark).environment(\.controlActiveState,.active));window.contentView=host
let folder=URL(fileURLWithPath:CommandLine.arguments[1]);try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
func save(_ name:String){host.frame=NSRect(x:0,y:0,width:1280,height:800);host.layoutSubtreeIfNeeded();RunLoop.main.run(until:Date().addingTimeInterval(0.5));host.displayIfNeeded();let bitmap=host.bitmapImageRepForCachingDisplay(in:host.bounds)!;host.cacheDisplay(in:host.bounds,to:bitmap);try!bitmap.representation(using:.png,properties:[:])!.write(to:folder.appendingPathComponent(name+".png"))}
save("gallery-grid")
let still=folder.appendingPathComponent("fixture.jpg");let image=gallery.thumbnails["9"]!;let bitmap=NSBitmapImageRep(data:image.tiffRepresentation!)!;try bitmap.representation(using:.jpeg,properties:[:])!.write(to:still);gallery.selected=gallery.items[1];gallery.original=still
save("gallery-viewer")
print("PASS: capture-date ordering, numeric ID ties, unknown dates last, video filter, search, month grouping; native grid and viewer rendered with synthetic fixtures")
