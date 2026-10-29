import AppKit
import SwiftUI
import AVKit
import ImageIO
import Combine
import Photos
import PhotosUI
import MapKit

struct GalleryItem:Identifiable,Codable {
    let id:String;let name:String;let path:String;let size:Int64;let mime:String;let taken:Int64;let duration:Int64;let width:Int;let height:Int;let album:String;let favorite:Bool;var added:Int64?=nil;var bucket:String?=nil;var live:Bool?=nil
    var video:Bool{mime.hasPrefix("video/")}
    var date:Date?{taken>0 ? Date(timeIntervalSince1970:Double(taken)/1000):nil}
    var remote:RemoteEntry{RemoteEntry(name:name,path:path,directory:false,size:size,modified:0)}
}
final class GalleryModel:ObservableObject {
    let transport=GalleryTransport()
    @Published var sync=PhotoSyncState()
    @Published var syncEvents:[PhotoSyncEvent]=[]
    @Published var thumbnailErrors:[String:String]=[:]
    var previewRequested=Set<String>()
    var previewFinished=Set<String>()
    var catalogPending:[GalleryItem]=[]
    var readOverride:((String,[String:Any],@escaping([String:Any])->Void)->Void)?
    var store:PhotoLibraryStore
    @Published var libraryDoc=PhotoLibraryDocument()
    @Published var selection=Set<String>()
    @Published var deleted:[RemoteTrash]=[]
    @Published var deletedSelection=Set<String>()
    @Published var unlocked=false
    @Published var editing=false
    @Published var draft=PhotoAdjustment()
    @Published var editPreview:NSImage?
    @Published var saving=false
    @Published var analysisRunning=false
    @Published var analysisProgress=""
    @Published var motionPaths=Set<String>()
    @Published var slideshow=false
    @Published var slideshowInterval=5.0
    @Published var slideshowMusic:URL?
    @Published var slideshowItems:[GalleryItem]=[]
    var undoDocuments:[PhotoLibraryDocument]=[]
    var redoDocuments:[PhotoLibraryDocument]=[]
    var draftHistory:[PhotoAdjustment]=[]
    var draftFuture:[PhotoAdjustment]=[]
    var lastDraft=PhotoAdjustment()
    var suppressDraft=false
    var editAfterOpen=false
    @Published var exportFormat="원래 포맷"
    @Published var exportQuality=0.95
    @Published var timelinePrefix=""
    var selectionAnchor:String?
    var downloaded:[String:URL]=[:]
    var copiedEdit:PhotoAdjustment?
    var librarySession=UUID()
    var libraryIdentity=""
    var previewWork:DispatchWorkItem?
    var analysisStop=false
    var activeExport:AVAssetExportSession?
    let analysisWorker=DispatchQueue(label:"app.coolsync.photos.analysis",qos:.utility)
    let explorer:ExplorerModel
    @Published var items:[GalleryItem]=[]
    @Published var thumbnails:[String:NSImage]=[:]
    @Published var selected:GalleryItem?
    @Published var originalIssue:String?
    @Published var original:URL?
    @Published var motion:URL?
    @Published var livePhoto:PHLivePhoto?
    @Published var loading=false
    @Published var status="휴대폰을 연결하세요"
    @Published var search=""
    @Published var category="보관함"
    @Published var ascending=false
    @Published var sort="촬영일"
    @Published var grouping="모든 사진"
    @Published var tile:Double=160
    @Published var favorites=Set(UserDefaults.standard.stringArray(forKey:"galleryFavorites") ?? [])
    var generation=UUID()
    var waiting=Set<String>()
    var queue:[GalleryItem]=[]
    var fetching=false
    let cache=FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask)[0].appendingPathComponent("CoolSync/Gallery",isDirectory:true)
    init(explorer:ExplorerModel,store:PhotoLibraryStore=PhotoLibraryStore()){
        self.explorer=explorer;self.store=store;libraryDoc=store.load();try?FileManager.default.createDirectory(at:cache,withIntermediateDirectories:true)
        transport.bootstrap={ [weak explorer]completion in explorer?.call("mediaSession",quiet:true,completion:completion) }
        transport.legacyCatalog={ [weak explorer]fields,completion in
            explorer?.call("mediaList",fields,quiet:true){result in var result=result;if var rows=result["items"]as?[[String:Any]]{for i in rows.indices{rows[i]["taken"]=rows[i]["date"] ?? 0;rows[i]["album"]=(rows[i]["album"]as?String ?? "").split(separator:"/").last.map(String.init) ?? "기타"};result["items"]=rows};completion(result)}
        }
        transport.onState={ [weak self]state in self?.sync.device=state;self?.event("device screen=\(state.interactive), locked=\(state.locked), file access=\(state.storage), battery exempt=\(state.batteryExempt)") }
    }
    var albums:[String]{Array(Set(items.map{$0.album})).sorted{$0.localizedStandardCompare($1) == .orderedAscending}}
    func favorite(_ item:GalleryItem)->Bool{note(item).favorite ?? (item.favorite || favorites.contains(item.path))}
    func toggle(_ item:GalleryItem){let value = !favorite(item);annotate(item){$0.favorite=value}}
    var visible:[GalleryItem]{
        let duplicates=category=="중복된 항목" ? duplicatePaths:Set<String>()
        return items.filter{item in (category=="중복된 항목" ? duplicates.contains(item.path) && !note(item).hidden:matches(item,category)) && searchMatch(item) && (timelinePrefix.isEmpty || captureDate(item).map{let f=DateFormatter();f.dateFormat="yyyy-MM";return f.string(from:$0).hasPrefix(timelinePrefix)}==true)}.sorted{a,b in
            if category=="최근 저장된 항목",a.added != b.added{return (a.added ?? 0)>(b.added ?? 0)}
            if sort=="제목" || sort=="이름"{let c=(sort=="제목" ? title(a):a.name).localizedStandardCompare(sort=="제목" ? title(b):b.name);if c != .orderedSame{return ascending ? c == .orderedAscending:c == .orderedDescending}}
            else{let left=captureDate(a),right=captureDate(b);if left != right{guard let left else{return false};guard let right else{return true};return ascending ? left<right:left>right}}
            return ascending ? (Int64(a.id) ?? 0)<(Int64(b.id) ?? 0):(Int64(a.id) ?? 0)>(Int64(b.id) ?? 0)
        }
    }
    var sections:[(String,[GalleryItem])]{
        if grouping=="모든 사진"{return [("",visible)]}
        let formatter=DateFormatter();formatter.dateFormat=grouping=="년" ? "yyyy년":"yyyy년 M월"
        var result:[(String,[GalleryItem])]=[]
        for item in visible{let key=captureDate(item).map{formatter.string(from:$0)} ?? "촬영일 없음";if result.last?.0==key{result[result.count-1].1.append(item)}else{result.append((key,[item]))}}
        return result
    }
    func reload(){beginPhotoLoad()}
    func thumb(_ item:GalleryItem){
        if note(item).rendered != nil{if thumbnails[item.id]==nil{refreshEditedThumbnail(item)};return}
        guard thumbnails[item.id]==nil,!waiting.contains(item.id),thumbnailErrors[item.id]==nil else{return}
        if let image=NSImage(contentsOf:thumbnailURL(item)){thumbnails[item.id]=image;return}
        waiting.insert(item.id);previewRequested.insert(item.id);queue.append(item);thumbnailProgress();pump()
    }
    func cancelThumb(_ item:GalleryItem){if queue.contains(where:{$0.id==item.id}){queue.removeAll{$0.id==item.id};waiting.remove(item.id);previewRequested.remove(item.id)};thumbnailProgress()}
    private func pump(){
        guard !fetching,!queue.isEmpty else{thumbnailProgress();return};fetching=true;let item=queue.removeFirst(),token=generation;thumbnailProgress()
        readGallery("galleryThumb",["id":item.id,"path":item.path]){[weak self]response in
            guard let self,self.generation==token else{return};self.fetching=false;self.waiting.remove(item.id);self.previewFinished.insert(item.id)
            if response["ok"]as?Bool==true,let text=response["image"]as?String,let data=Data(base64Encoded:text),let image=NSImage(data:data){if self.thumbnails.count>600,let first=self.thumbnails.keys.first{self.thumbnails.removeValue(forKey:first)};self.thumbnails[item.id]=image;try?data.write(to:self.thumbnailURL(item),options:.atomic);self.thumbnailErrors.removeValue(forKey:item.id)}
            else{self.thumbnailErrors[item.id]=response["error"]as?String ?? "미리보기 응답을 읽지 못했습니다";self.event("preview failed: "+(response["code"]as?String ?? "decode"))}
            self.thumbnailProgress();self.pump()
        }
    }
    func open(_ item:GalleryItem){
        // Keep downloaded originals bounded; only CoolSync's own cache is touched.
        if let urls=try?FileManager.default.contentsOfDirectory(at:cache,includingPropertiesForKeys:[.fileSizeKey,.contentModificationDateKey]){
            let ordered=urls.sorted{((try?$0.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate) ?? .distantPast)<((try?$1.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate) ?? .distantPast)}
            var bytes=ordered.reduce(Int64(0)){$0+Int64((try?$1.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0)}
            for url in ordered where bytes>1_000_000_000{let size=Int64((try?url.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0);if url != original && url != motion{try?FileManager.default.removeItem(at:url);bytes-=size}}
        }
        selected=item;originalIssue=nil;original=nil;motion=nil;livePhoto=nil;status="원본 불러오는 중…"
        fetch(item,valid:{[weak self] in self?.selected?.id==item.id}){[weak self]result in
            guard let self,self.selected?.id==item.id else{return}
            do{let target=try result.get();self.original=target;self.status=item.name;self.readMetadata(target,item:item);if self.editAfterOpen{self.editAfterOpen=false;self.beginEditing()};if !item.video{self.extractMotion(target,item.id);self.loadLivePair(item,target)}}catch{self.status=error.localizedDescription;self.originalIssue=error.localizedDescription;self.editAfterOpen=false}
        }
    }
    private func loadLivePair(_ item:GalleryItem,_ still:URL){let token=librarySession;
        let base=(item.path as NSString).deletingPathExtension
        guard let companion=items.first(where:{$0.video && ($0.path as NSString).deletingPathExtension==base && ($0.path as NSString).pathExtension.lowercased()=="mov"}) else{return}
        fetch(companion,valid:{[weak self] in self?.selected?.id==item.id}){[weak self] result in
            guard let self,self.selected?.id==item.id,case .success(let video)=result else{return}
            PHLivePhoto.request(withResourceFileURLs:[still,video],placeholderImage:nil,targetSize:.zero,contentMode:.aspectFit){[weak self] photo,_ in
                DispatchQueue.main.async{guard self?.librarySession==token,self?.selected?.id==item.id else{return};self?.livePhoto=photo;if photo != nil{self?.motionPaths.insert(item.path);var a=self?.libraryDoc.annotations[item.path] ?? PhotoAnnotation();if !a.labels.contains("live"){a.labels.append("live")};self?.libraryDoc.annotations[item.path]=a;self?.persist()}}
            }
        }
    }
    private func extractMotion(_ url:URL,_ id:String){let token=librarySession;DispatchQueue.global(qos:.utility).async{[weak self] in
        // Samsung/Google Motion Photo embeds a complete ISO BMFF movie after the still image.
        guard let self,let data=try?Data(contentsOf:url,options:.mappedIfSafe) else{return}
        let marker=Data("ftyp".utf8);var found:URL?
        var start=0
        while start<data.count,let range=data.range(of:marker,options:[],in:start..<data.count){start=range.upperBound;let pos=range.lowerBound;guard pos>=4,pos+8<data.count else{continue}
            let brand=String(data:data[(pos+4)..<(pos+8)],encoding:.ascii) ?? ""
            guard ["isom","mp42","mp41","qt  ","3gp4"].contains(brand) else{continue}
            let out=url.deletingPathExtension().appendingPathExtension("motion.mp4")
            do{try data[(pos-4)...].write(to:out);if AVURLAsset(url:out).tracks(withMediaType:.video).isEmpty{try?FileManager.default.removeItem(at:out)}else{found=out;break}}catch{}
        }
        DispatchQueue.main.async{if self.librarySession==token,self.selected?.id==id{self.motion=found;if found != nil,let path=self.selected?.path{self.motionPaths.insert(path);var a=self.libraryDoc.annotations[path] ?? PhotoAnnotation();if !a.labels.contains("live"){a.labels.append("live")};self.libraryDoc.annotations[path]=a;self.persist()}}}
    }}
    func step(_ delta:Int){let list=slideshow ? slideshowItems:visible;guard let id=selected?.id,let index=list.firstIndex(where:{$0.id==id}),list.indices.contains(index+delta)else{return};open(list[index+delta])}
    func disconnect(){transport.invalidate();sync.phase = .disconnected;sync.message="휴대폰 연결이 끊겼습니다 · 재연결을 기다립니다";sync.issueCode="disconnected";fetching=false;activeExport?.cancelExport();activeExport=nil;saving=false;previewWork?.cancel();librarySession=UUID();analysisStop=true;analysisRunning=false;unlocked=false;slideshow=false;editing=false;selection=[];downloaded=[:];generation=UUID();loading=false;selected=nil;original=nil;motion=nil;livePhoto=nil;items=[];queue=[];waiting=[];thumbnails=[:];status="휴대폰 연결이 끊겼습니다"}
    func export(){guard let original,let selected else{return};let panel=NSSavePanel();panel.nameFieldStringValue=selected.name;if panel.runModal() == .OK,let url=panel.url{do{if FileManager.default.fileExists(atPath:url.path){try FileManager.default.removeItem(at:url)};try FileManager.default.copyItem(at:original,to:url)}catch{status=error.localizedDescription}}}
}
