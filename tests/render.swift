import AppKit
import SwiftUI
let app=NSApplication.shared
app.setActivationPolicy(.prohibited)
app.appearance=NSAppearance(named:.aqua)
let output=URL(fileURLWithPath:CommandLine.arguments[1])
try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
let model=DashboardModel(preview:true)
let window=NSWindow(contentRect:NSRect(x:0,y:0,width:980,height:740),styleMask:[.borderless],backing:.buffered,defer:false)
let host=NSHostingView(rootView:AnyView(CoolDashboard(model:model).environment(\.controlActiveState,.active)));window.contentView=host
func save(_ name:String){
 host.frame=NSRect(x:0,y:0,width:980,height:740);host.layoutSubtreeIfNeeded();host.displayIfNeeded()
 RunLoop.main.run(until:Date().addingTimeInterval(0.25))
 guard let bitmap=host.bitmapImageRepForCachingDisplay(in:host.bounds) else{exit(1)}
 host.cacheDisplay(in:host.bounds,to:bitmap)
 try! bitmap.representation(using:.png,properties:[:])!.write(to:output.appendingPathComponent(name+".png"))
}
model.pairing=true;save("mac-pairing")
model.pairing=false;model.connected=true;model.name="Galaxy Fold8";model.model="미리보기 기기";model.system="16";model.status="연결됨 · 복사 대기";model.lastSync=Date();save("mac-device")
model.tab=1
model.explorer.entries=[RemoteEntry(name:"DCIM",path:"DCIM",directory:true,size:0,modified:1780000000000),RemoteEntry(name:"Documents",path:"Documents",directory:true,size:0,modified:1780000000000),RemoteEntry(name:"Download",path:"Download",directory:true,size:0,modified:1780000000000),RemoteEntry(name:"회의 메모.txt",path:"회의 메모.txt",directory:false,size:1804,modified:1780000000000)]
model.explorer.status="4개 항목";model.explorer.available=128000000000
save("mac-files")
model.tab=2;save("mac-settings")
model.history.add(text:"회의 일정은 오후 3시입니다.",source:"Mac");model.history.add(text:"https://github.com/hun8902/CoolSync",source:"휴대폰");model.history.favorite(model.history.entries[0].id);model.clipboardState.selection=model.history.entries[0].id;model.tab=3;save("mac-clipboard")
app.appearance=NSAppearance(named:.darkAqua);host.rootView=AnyView(CoolDashboard(model:model).environment(\.controlActiveState,.active).environment(\.colorScheme,.dark));save("mac-clipboard-dark")
print("Native SwiftUI screenshots saved (preview data, no Bluetooth or keychain access)")
