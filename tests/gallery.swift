import AppKit
import SwiftUI
import AVKit
import CryptoKit
import CoreVideo

let app=NSApplication.shared
app.setActivationPolicy(.prohibited)
app.appearance=NSAppearance(named:.darkAqua)
let output=URL(fileURLWithPath:CommandLine.arguments[1]);try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
let sandbox=output.appendingPathComponent("fixtures/"+UUID().uuidString);try FileManager.default.createDirectory(at:sandbox,withIntermediateDirectories:true)
let store=PhotoLibraryStore(folder:sandbox.appendingPathComponent(UUID().uuidString))
let gallery=GalleryModel(explorer:ExplorerModel(),store:store)
func item(_ id:String,_ name:String,_ taken:Int64,_ video:Bool=false)->GalleryItem{GalleryItem(id:id,name:name,path:"DCIM/Camera/"+name,size:3200000,mime:video ? "video/mp4":"image/jpeg",taken:taken,duration:1000,width:400,height:500,album:"카메라",favorite:false)}
gallery.items=[item("10","Portrait.jpg",1793000000000),item("9","Seaside.jpg",1793000000000),item("8","Clouds.mp4",1792000000000,true),item("7","Undated.jpg",0)]
precondition(gallery.visible.map{$0.id}==["10","9","8","7"])
gallery.ascending=true;precondition(gallery.visible.map{$0.id}==["8","9","10","7"])
gallery.category="비디오";precondition(gallery.visible.map{$0.id}==["8"])
gallery.category="보관함";gallery.search="Seaside";precondition(gallery.visible.map{$0.id}==["9"])
gallery.search="";gallery.ascending=false;gallery.grouping="월";precondition(gallery.sections.last?.0=="촬영일 없음");gallery.grouping="모든 사진"
let paths=(0..<200).map{"DCIM/"+String(repeating:"가",count:250)+"/\($0).jpg"};let batches=PhotoBatches.paths(paths);precondition(batches.flatMap{$0}==paths);precondition(batches.allSatisfy{(try!JSONSerialization.data(withJSONObject:["paths":$0])).count<=12000})
let portrait=gallery.items[0],seaside=gallery.items[1],video=gallery.items[2],undated=gallery.items[3]
gallery.annotate(portrait){$0.title="여행 사진";$0.caption="인천의 바다";$0.keywords=["여행","여름"]}
precondition(store.load().annotations[portrait.path]?.caption=="인천의 바다")
gallery.search="여행 여름";precondition(gallery.visible.map{$0.id}==[portrait.id]);gallery.search=""
gallery.toggle(portrait);precondition(gallery.favorite(portrait));gallery.toggle(portrait);precondition(!gallery.favorite(portrait));gallery.undoLibrary();precondition(gallery.favorite(portrait));gallery.redoLibrary();precondition(!gallery.favorite(portrait))
let smart=PhotoAlbum(name:"여행",rule:PhotoAlbumRule(field:"키워드",value:"여행"));let album=PhotoAlbum(name:"선택 앨범",paths:[portrait.path,seaside.path]);gallery.change{$0.albums+=[smart,album]}
gallery.category="사용자앨범:"+smart.id;precondition(gallery.visible.map{$0.id}==[portrait.id]);gallery.category="사용자앨범:"+album.id;precondition(gallery.visible.count==2)
gallery.annotate(portrait){$0.hidden=true};gallery.category="보관함";precondition(!gallery.visible.contains{$0.id==portrait.id});gallery.unlocked=false;gallery.category="가려진 항목";precondition(gallery.visible.isEmpty);gallery.unlocked=true;precondition(gallery.visible.map{$0.id}==[portrait.id]);gallery.annotate(portrait){$0.hidden=false};gallery.category="보관함"
let symbols=["person.crop.rectangle","water.waves","cloud.sun","photo"]
for (i,item) in gallery.items.enumerated(){let image=NSImage(size:NSSize(width:400,height:500));image.lockFocus();NSColor(calibratedHue:CGFloat(i)*0.2,saturation:0.35,brightness:0.65,alpha:1).setFill();NSRect(x:0,y:0,width:400,height:500).fill();NSImage(systemSymbolName:symbols[i],accessibilityDescription:nil)?.draw(in:NSRect(x:80,y:170,width:240,height:240));("COOLSYNC 2026" as NSString).draw(at:NSPoint(x:35,y:75),withAttributes:[.font:NSFont.systemFont(ofSize:32,weight:.bold),.foregroundColor:NSColor.black]);image.unlockFocus();gallery.thumbnails[item.id]=image
    let url=sandbox.appendingPathComponent(item.id+".jpg");try PhotoRendering.save(image,to:url);gallery.downloaded[item.path]=url
}
gallery.downloaded[undated.path]=gallery.downloaded[portrait.path]
let original=gallery.downloaded[portrait.path]!;let originalHash=SHA256.hash(data:try Data(contentsOf:original))
gallery.selected=portrait;gallery.original=original;gallery.beginEditing();gallery.draft.cropWidth=0.5;gallery.draft.filter="모노";gallery.draft.exposure=0.4;gallery.saveEditing()
func wait(_ predicate:()->Bool,seconds:Double=30){let end=Date().addingTimeInterval(seconds);while !predicate(),Date()<end{RunLoop.main.run(until:Date().addingTimeInterval(0.02))};precondition(predicate(),"Asynchronous operation timed out")}
wait{!gallery.saving}
precondition(gallery.note(portrait).edit != nil);let edited=gallery.currentURL!;let bitmap=NSBitmapImageRep(data:try Data(contentsOf:edited))!;let beforeBitmap=NSBitmapImageRep(data:try Data(contentsOf:original))!;precondition(bitmap.pixelsWide==beforeBitmap.pixelsWide/2 && bitmap.pixelsHigh==beforeBitmap.pixelsHigh,"Crop dimensions \(bitmap.pixelsWide)x\(bitmap.pixelsHigh)")
precondition(SHA256.hash(data:try! Data(contentsOf:original))==originalHash)
gallery.revert();precondition(gallery.note(portrait).edit==nil && gallery.currentURL==original)
let export=output.appendingPathComponent("exported");try FileManager.default.createDirectory(at:export,withIntermediateDirectories:true);gallery.exportFormat="PNG";gallery.exportBatch([portrait],to:export,originals:false);wait{FileManager.default.fileExists(atPath:export.appendingPathComponent("Portrait.png").path)}
precondition(CGImageSourceGetType(CGImageSourceCreateWithURL(export.appendingPathComponent("Portrait.png") as CFURL,nil)!) as String?=="public.png")

// Real 1-second H.264 fixture, followed by trim/speed/mute/crop export and reopen.
let movie=sandbox.appendingPathComponent("fixture.mov");let writer=try AVAssetWriter(outputURL:movie,fileType:.mov)
let input=AVAssetWriterInput(mediaType:.video,outputSettings:[AVVideoCodecKey:AVVideoCodecType.h264,AVVideoWidthKey:160,AVVideoHeightKey:120]);input.expectsMediaDataInRealTime=false
let adaptor=AVAssetWriterInputPixelBufferAdaptor(assetWriterInput:input,sourcePixelBufferAttributes:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32ARGB,kCVPixelBufferWidthKey as String:160,kCVPixelBufferHeightKey as String:120]);writer.add(input);writer.startWriting();writer.startSession(atSourceTime:.zero)
for index in 0..<12{wait{input.isReadyForMoreMediaData};var buffer:CVPixelBuffer?;CVPixelBufferCreate(kCFAllocatorDefault,160,120,kCVPixelFormatType_32ARGB,nil,&buffer);let pixel=buffer!;CVPixelBufferLockBaseAddress(pixel,[]);memset(CVPixelBufferGetBaseAddress(pixel),Int32(30+index*10),CVPixelBufferGetDataSize(pixel));CVPixelBufferUnlockBaseAddress(pixel,[]);precondition(adaptor.append(pixel,withPresentationTime:CMTime(value:Int64(index),timescale:12)))}
input.markAsFinished();var finished=false;writer.endSession(atSourceTime:CMTime(seconds:1,preferredTimescale:12));writer.finishWriting{finished=true};wait{finished};precondition(writer.status == .completed)
gallery.downloaded[video.path]=movie;gallery.selected=video;gallery.original=movie;gallery.beginEditing();gallery.draft.trimStart=0.25;gallery.draft.trimEnd=0.75;gallery.draft.speed=2;gallery.draft.muted=true;gallery.draft.cropWidth=0.5;gallery.saveEditing();wait({!gallery.saving},seconds:60)
precondition(gallery.note(video).rendered != nil,gallery.status);let editedVideo=AVURLAsset(url:gallery.currentURL!);let seconds=CMTimeGetSeconds(editedVideo.duration);precondition(abs(seconds-0.25)<0.12);precondition(editedVideo.tracks(withMediaType:.audio).isEmpty);precondition(editedVideo.tracks(withMediaType:.video).first?.naturalSize.width==80)

gallery.selected=portrait;gallery.original=original;gallery.motion=movie;gallery.beginEditing();gallery.draft.exposure=0.2;gallery.recordDraft();gallery.draft.exposure=0.7;gallery.recordDraft();gallery.undoEdit();precondition(gallery.draft.exposure==0.2);gallery.redoEdit();precondition(gallery.draft.exposure==0.7)
gallery.draft.keyFrame=0.5;gallery.selectKeyPhoto();precondition(gallery.note(portrait).rendered != nil)
gallery.bounce();wait({!gallery.saving},seconds:60);let bounceURL=gallery.currentURL!;precondition(CGImageSourceGetCount(CGImageSourceCreateWithURL(bounceURL as CFURL,nil)!)>1)
gallery.longExposure();wait({!gallery.saving},seconds:60);precondition(gallery.note(portrait).edit?.liveEffect=="장노출");precondition(NSImage(contentsOf:gallery.currentURL!) != nil);gallery.revert();gallery.cancelEditing();gallery.motion=nil
// Vision and SHA run on fixture originals, never a paired phone.
gallery.selected=nil;gallery.original=nil;gallery.startAnalysis();wait({!gallery.analysisRunning},seconds:90)
precondition(gallery.note(portrait).analyzed);precondition(gallery.note(portrait).text.localizedCaseInsensitiveContains("COOLSYNC"),gallery.note(portrait).text)
precondition(gallery.note(portrait).fingerprint==gallery.note(undated).fingerprint);precondition(gallery.duplicateGroups.contains{$0.count==2 && $0.contains{$0.id==portrait.id}})
gallery.annotate(seaside){$0.latitude=37.5;$0.longitude=126.5;$0.place="인천"}
let person=PhotoPerson(name:"테스트 인물",paths:[portrait.path],portrait:gallery.thumbnails[portrait.id]!.tiffRepresentation);gallery.change{$0.people.append(person);$0.annotations[portrait.path]?.people=[person.id]}
precondition(gallery.peopleVisible.count==1)
precondition(store.load()==gallery.libraryDoc)
gallery.sync.phase = .ready;gallery.sync.total=gallery.items.count;gallery.sync.received=gallery.items.count;gallery.status="합성 자료 · 편집·저장·Vision 분석 검증 완료"
let viewer=GalleryViewerState();let window=NSWindow(contentRect:NSRect(x:0,y:0,width:1440,height:900),styleMask:[.borderless],backing:.buffered,defer:false)
let host=NSHostingView(rootView:GalleryPane(model:gallery,viewer:viewer).environment(\.colorScheme,.dark).environment(\.controlActiveState,.active));window.contentView=host
func save(_ name:String){host.frame=NSRect(x:0,y:0,width:1440,height:900);host.layoutSubtreeIfNeeded();RunLoop.main.run(until:Date().addingTimeInterval(0.5));host.displayIfNeeded();let bitmap=host.bitmapImageRepForCachingDisplay(in:host.bounds)!;host.cacheDisplay(in:host.bounds,to:bitmap);try!bitmap.representation(using:.png,properties:[:])!.write(to:output.appendingPathComponent(name+".png"))}
gallery.selection=[portrait.id,seaside.id];save("photos-library")
gallery.selection=[];gallery.selected=portrait;gallery.original=original;viewer.info=true;save("photos-info")
viewer.info=false;gallery.beginEditing();gallery.draft.saturation=0.2;gallery.refreshPreview();RunLoop.main.run(until:Date().addingTimeInterval(0.5));save("photos-editor");gallery.cancelEditing()
gallery.selected=nil;gallery.category="모음";save("photos-collections")
gallery.category="사람들";save("photos-people")
gallery.category="중복된 항목";save("photos-duplicates")
precondition(SHA256.hash(data:try! Data(contentsOf:original))==originalHash)
print("PASS: capture date/numeric-ID ordering; unknown-date placement; metadata persistence/search; favorites/undo/redo; albums/smart rules; hidden authorization gate; nondestructive image edit/crop/save/reopen/revert; PNG export; actual H264 trim/speed/mute/crop export and reopen; Vision OCR; SHA duplicate grouping; person membership; six native UI renders; original byte invariance; edit undo/redo; Live key frame, animated bounce and long-exposure output")
