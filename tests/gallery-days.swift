import AppKit
import SwiftUI
let app=NSApplication.shared;app.setActivationPolicy(.prohibited);app.appearance=NSAppearance(named:.darkAqua)
let output=URL(fileURLWithPath:CommandLine.arguments[1]);try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
let model=GalleryModel(explorer:ExplorerModel(),store:PhotoLibraryStore(folder:output.appendingPathComponent("fixture-"+UUID().uuidString)))
var calendar=Calendar(identifier:.gregorian);calendar.timeZone=TimeZone(identifier:"Asia/Seoul")!
func date(_ year:Int,_ month:Int,_ day:Int,_ hour:Int=12,_ minute:Int=0,_ second:Int=0)->Date{calendar.date(from:DateComponents(year:year,month:month,day:day,hour:hour,minute:minute,second:second))!}
func row(_ id:String,_ name:String,_ time:Date?,added:Int64?=nil,video:Bool=false)->GalleryItem{GalleryItem(id:id,name:name,path:"DCIM/"+name,size:100,mime:video ? "video/mp4":"image/jpeg",taken:time.map{Int64($0.timeIntervalSince1970*1000)} ?? 0,duration:65000,width:500,height:800,album:"카메라",favorite:false,added:added)}
let now=date(2026,10,30)
model.items=[row("20","Z.jpg",date(2026,10,30,0)),row("21","Y.jpg",date(2026,10,30,0)),row("19","X.jpg",date(2026,10,29,23,59,59)),row("18","W.jpg",date(2026,10,29,0)),row("17","V.jpg",date(2026,10,25)),row("16","U.jpg",date(2026,10,20)),row("15","A.jpg",date(2025,12,31)),row("14","B.jpg",nil,added:Int64(now.timeIntervalSince1970*1000))]
model.sort="이름";model.ascending=true;let originalOrder=model.visible.map{$0.id};precondition(originalOrder.first=="15")
model.grouping="날짜별";precondition(model.visible.map{$0.id}==["21","20","19","18","17","16","15","14"])
let groups=model.daySections(now:now,calendar:calendar);precondition(groups.map{$0.title}==["오늘","어제","10월 25일","10월 20일","2025년 12월 31일","촬영일 없음"])
precondition(groups[0].items.map{$0.id}==["21","20"]);precondition(groups[1].items.map{$0.id}==["19","18"]);precondition(groups.last?.items.first?.id=="14")
model.grouping="모든 사진";precondition(model.visible.map{$0.id}==originalOrder && model.sort=="이름" && model.ascending)
model.search="Z.jpg";model.grouping="날짜별";precondition(model.daySections(now:now,calendar:calendar).flatMap{$0.items}.map{$0.id}==["20"]);model.search=""
var newYork=Calendar(identifier:.gregorian);newYork.timeZone=TimeZone(identifier:"America/New_York")!;let iso=ISO8601DateFormatter()
model.items=[row("3","DST.jpg",iso.date(from:"2026-11-01T04:15:00Z"))];precondition(model.daySections(now:iso.date(from:"2026-11-02T12:00:00Z")!,calendar:newYork).first?.title=="어제")
let actual=Calendar.current.startOfDay(for:Date());let counts=[1,3,1,5];var items:[GalleryItem]=[];var counter=30
for (group,count) in counts.enumerated(){let day=Calendar.current.date(byAdding:.day,value:-[0,1,5,10][group],to:actual)!
 for _ in 0..<count{counter+=1;let item=row(String(counter),"합성 사진 \(counter).jpg",day.addingTimeInterval(Double(counter)*60),video:counter%4==0);items.append(item)
  let image=NSImage(size:NSSize(width:400,height:500));image.lockFocus();NSColor(calibratedHue:CGFloat(counter%12)/12,saturation:0.25,brightness:0.7,alpha:1).setFill();NSRect(x:0,y:0,width:400,height:500).fill();let symbol=NSImage(systemSymbolName:["mountain.2","camera.macro","cloud.sun","water.waves"][counter%4],accessibilityDescription:nil)!;symbol.draw(in:NSRect(x:70,y:150,width:260,height:210));image.unlockFocus();model.thumbnails[item.id]=image
 }}
model.items=items;model.sync.phase = .ready;model.sync.received=items.count;model.sync.total=items.count;model.status="합성 자료 · 날짜별 보기";model.tile=145
let window=NSWindow(contentRect:NSRect(x:0,y:0,width:1280,height:1050),styleMask:[.borderless],backing:.buffered,defer:false)
let host=NSHostingView(rootView:GalleryPane(model:model).environment(\.colorScheme,.dark).environment(\.controlActiveState,.active));window.contentView=host;host.frame=NSRect(x:0,y:0,width:1280,height:1050);host.layoutSubtreeIfNeeded();RunLoop.main.run(until:Date().addingTimeInterval(0.4));host.displayIfNeeded();let bitmap=host.bitmapImageRepForCachingDisplay(in:host.bounds)!;host.cacheDisplay(in:host.bounds,to:bitmap);try bitmap.representation(using:.png,properties:[:])!.write(to:output.appendingPathComponent("gallery-day-mode.png"))
print("PASS: today/yesterday/older-year/unknown sections; KST midnight boundary; numeric-ID tie order; captured date only; name-order restored after mode switch; search retained; DST yesterday; native date-grid rendered with synthetic data")
