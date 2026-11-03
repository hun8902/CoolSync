import AppKit
import SwiftUI
let app=NSApplication.shared;app.setActivationPolicy(.prohibited);app.appearance=NSAppearance(named:.darkAqua)
let output=URL(fileURLWithPath:CommandLine.arguments[1]);try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
class RecordingWindow:CoolSyncWindow{var zoomCalls=0;override func performZoom(_ sender:Any?){zoomCalls+=1}}
let window=RecordingWindow(contentRect:NSRect(x:0,y:0,width:1040,height:700),styleMask:[.titled,.closable,.miniaturizable,.resizable,.fullSizeContentView],backing:.buffered,defer:false)
func event(_ point:NSPoint,_ count:Int=2)->NSEvent{NSEvent.mouseEvent(with:.leftMouseDown,location:point,modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,eventNumber:0,clickCount:count,pressure:1)!}
let top=NSPoint(x:window.frame.width/2,y:window.frame.height-8)
precondition(window.isTitlebarDoubleClick(event(top)))
precondition(!window.isTitlebarDoubleClick(event(top,1)))
precondition(!window.isTitlebarDoubleClick(event(NSPoint(x:100,y:100))))
for kind in [NSWindow.ButtonType.closeButton,.miniaturizeButton,.zoomButton]{let b=window.standardWindowButton(kind)!;let p=b.convert(NSPoint(x:b.bounds.midX,y:b.bounds.midY),to:nil);precondition(!window.isTitlebarDoubleClick(event(p)))}
window.sendEvent(event(top));window.sendEvent(event(top));precondition(window.zoomCalls==2)
let model=GalleryModel(explorer:ExplorerModel(),store:PhotoLibraryStore(folder:output.appendingPathComponent("fixture-"+UUID().uuidString)));model.sync.phase = .ready
let host=NSHostingView(rootView:GalleryPane(model:model,exit:{}).environment(\.colorScheme,.dark));window.contentView=host;host.frame=NSRect(x:0,y:0,width:1040,height:700);host.layoutSubtreeIfNeeded();RunLoop.main.run(until:Date().addingTimeInterval(0.3));host.displayIfNeeded()
let bitmap=host.bitmapImageRepForCachingDisplay(in:host.bounds)!;host.cacheDisplay(in:host.bounds,to:bitmap);try bitmap.representation(using:.png,properties:[:])!.write(to:output.appendingPathComponent("gallery-back-button.png"))
print("PASS: titlebar double click invokes zoom/restore; single click, content and traffic-light controls excluded; gallery back button native render")
