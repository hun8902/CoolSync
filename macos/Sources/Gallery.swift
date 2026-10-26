import AppKit
import SwiftUI
import Combine
import CryptoKit
import AVKit
import MapKit
import UniformTypeIdentifiers

struct PhotoItem:Decodable,Identifiable {
    let id:String;let path:String;let name:String;let album:String;let mime:String;let size:Int64;let date:Int64;let modified:Int64;let width:Int;let height:Int;let duration:Int64;var favorite:Bool
    var video:Bool{mime.hasPrefix("video/")}
    var timestamp:Date{Date(timeIntervalSince1970:Double(date)/1000)}
    var durationText:String{let seconds=duration/1000;return seconds>=3600 ? String(format:"%lld:%02lld:%02lld",seconds/3600,seconds/60%60,seconds%60):String(format:"%lld:%02lld",seconds/60,seconds%60)}
    var remote:RemoteEntry{RemoteEntry(name:name,path:path,directory:false,size:size,modified:modified)}
}
struct PhotoAlbum:Decodable,Identifiable{var id:String{path};let path:String;let name:String;let count:Int;let videos:Int}
struct PhotoSection{let title:String;let items:[PhotoItem]}
struct PhotoPin:Identifiable{let id="photo";let coordinate:CLLocationCoordinate2D}

final class PhotoThumbnails {
    weak var rpc:ExplorerModel?
    var key:(()->Data)?
    var failure:((String)->Void)?
    private var reported=false
    private let cache=NSCache<NSString,NSImage>()
    private var endpoint:[String:Any]?
    private var failedHosts=Set<String>()
    private var preparing=false
    private var pending:[()->Void]=[]
    private var queue:[(PhotoItem,(NSImage?)->Void)]=[]
    private var waiting:[String:[(NSImage?)->Void]]=[:]
    private var active=0
    private var generation=0
    private let session:URLSession={let c=URLSessionConfiguration.ephemeral;c.timeoutIntervalForRequest=15;c.timeoutIntervalForResource=20;c.httpMaximumConnectionsPerHost=2;return URLSession(configuration:c)}()
    init(){cache.countLimit=200;cache.totalCostLimit=48*1024*1024}
    func close(){generation+=1;endpoint=nil;failedHosts=[];queue=[];pending=[];waiting=[:];preparing=false;active=0;reported=false;session.getAllTasks{tasks in tasks.forEach{$0.cancel()}};if rpc?.connected?()==true{rpc?.call("mediaClose"){_ in}}}
    func clear(){cache.removeAllObjects()}
    private func prepare(_ done:@escaping()->Void){if endpoint != nil{done();return};pending.append(done);if preparing{return};preparing=true;let epoch=generation
        rpc?.call("mediaSession"){[weak self]r in guard let self,self.generation==epoch else{return};self.preparing=false;self.endpoint=r["endpoint"]as?[String:Any];if self.endpoint==nil{self.queue=[];self.report(r["error"]as?String ?? "같은 Wi-Fi와 로컬 네트워크 권한을 확인하세요")};let waiting=self.pending;self.pending=[];for callback in waiting{callback()}}
    }
    func load(_ item:PhotoItem,_ done:@escaping(NSImage?)->Void){let name="\(item.path)#\(item.modified)";let id=name as NSString;if let image=cache.object(forKey:id){done(image);return};if waiting[name] != nil{waiting[name]?.append(done);return};waiting[name]=[done];queue.append((item,{[weak self]image in guard let self else{return};let callbacks=self.waiting.removeValue(forKey:name) ?? [];for callback in callbacks{callback(image)}}));pump()}

    private func pump(){while active<2 && !queue.isEmpty{let request=queue.removeFirst();active+=1;let epoch=generation;prepare{[weak self]in guard let self else{return};if self.generation != epoch{return};self.fetch(request.0,retry:true,epoch:epoch){image in guard epoch==self.generation else{return};self.active=max(0,self.active-1);request.1(image);self.pump()}}}}
    private func fetch(_ item:PhotoItem,retry:Bool,epoch:Int,completion:@escaping(NSImage?)->Void){
        guard let endpoint,let hosts=endpoint["hosts"]as?[String],let host=hosts.first(where:{Self.local($0) && !failedHosts.contains($0)}),let port=endpoint["port"]as?Int,(1...65535).contains(port),let token=endpoint["token"]as?String,let key=key?(),key.count==32,let url=URL(string:"http://\(host):\(port)/thumbnail")else{completion(nil);return}
        var m=Wire.Message(type:"mediaThumb");m.text=String(data:(try? JSONSerialization.data(withJSONObject:["path":item.path,"token":token])) ?? Data(),encoding:.utf8) ?? ""
        guard let payload=try? Wire.seal(m,key:key)else{completion(nil);return};let id=m.id
        var q=URLRequest(url:url);q.httpMethod="POST";q.httpBody=payload;q.setValue("application/octet-stream",forHTTPHeaderField:"Content-Type")
        session.dataTask(with:q){[weak self]data,response,error in
            var image:NSImage?
            if error==nil,(response as?HTTPURLResponse)?.statusCode==200,let data,data.count<=128128,let box=try? AES.GCM.SealedBox(combined:data),let clear=try? AES.GCM.open(box,using:SymmetricKey(data:key),authenticating:Data("CoolSync/media/1|\(id)".utf8)){image=NSImage(data:clear)}
            DispatchQueue.main.async{guard let self,self.generation==epoch else{return};if let image{self.cache.setObject(image,forKey:"\(item.path)#\(item.modified)"as NSString,cost:240*240*4);completion(image)}else if hosts.contains(where:{Self.local($0) && $0 != host && !self.failedHosts.contains($0)}){self.failedHosts.insert(host);self.fetch(item,retry:retry,epoch:epoch,completion:completion)}else if retry{self.endpoint=nil;self.failedHosts=[];self.prepare{self.fetch(item,retry:false,epoch:epoch,completion:completion)}}else{self.queue=[];self.report("썸네일을 가져오지 못했습니다. 같은 Wi-Fi에 연결하고 두 기기의 로컬 네트워크 접근을 허용하세요.");completion(nil)}}
        }.resume()
    }
    private func report(_ message:String){if !reported{reported=true;failure?(message)}}
    private static func local(_ value:String)->Bool{let a=value.split(separator:".").compactMap{Int($0)};guard a.count==4,a.allSatisfy({(0...255).contains($0)})else{return false};return a[0]==10 || (a[0]==192&&a[1]==168) || (a[0]==172&&(16...31).contains(a[1])) || (a[0]==169&&a[1]==254)}
}

final class PhotosModel:ObservableObject {
    @Published var items:[PhotoItem]=[]
    @Published var albums:[PhotoAlbum]=[]
    @Published var selection=Set<String>()
    @Published var album=""
    @Published var scope="all"
    @Published var search=""
    @Published var grouping="all"
    @Published var zoom:Double=150
    @Published var infoShown=false
    @Published var sidebarShown=true
    @Published var info:[String:String]=[:]
    @Published var latitude:Double?
    @Published var longitude:Double?
    @Published var region=MKCoordinateRegion(center:CLLocationCoordinate2D(latitude:37,longitude:127),span:MKCoordinateSpan(latitudeDelta:0.02,longitudeDelta:0.02))
    @Published var status="휴대폰에 연결하세요"
    @Published var loading=false
    @Published var total=0
    @Published var revision=0
    @Published var error:String?
    @Published var preview:PhotoItem?
    @Published var previewImage:NSImage?
    @Published var player:AVPlayer?
    @Published var previewLoading=false
    @Published var previewError=""
    @Published var moving=false
    weak var rpc:ExplorerModel?
    weak var files:FileTransfer?
    var connected:(()->Bool)?
    var thumbnails=PhotoThumbnails()
    var lastSelection:String?
    private var pageGeneration=UUID()
    private var infoGeneration=UUID()
    private var visible=false
    private var transferObservation:AnyCancellable?
    var title:String{if !album.isEmpty{return albums.first{$0.path==album}?.name ?? album};return ["all":"보관함","videos":"비디오","favorites":"즐겨찾기","recent":"최근 저장된 항목","screenshots":"스크린샷"][scope] ?? "보관함"}
    var filtered:[PhotoItem]{items.filter{search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)}}
    var selected:[PhotoItem]{items.filter{selection.contains($0.path)}}
    var sections:[PhotoSection]{let rows=filtered;guard grouping != "all"else{return[PhotoSection(title:"",items:rows)]};let formatter=DateFormatter();formatter.dateFormat=grouping=="year" ? "yyyy년":"yyyy년 M월";var result:[PhotoSection]=[];for item in rows{let title=formatter.string(from:item.timestamp);if result.last?.title==title{let old=result.removeLast();result.append(PhotoSection(title:title,items:old.items+[item]))}else{result.append(PhotoSection(title:title,items:[item]))}};return result}
    func appear(){visible=true;reload()}
    func disappear(){visible=false;thumbnails.close();closePreview()}
    func choose(_ scope:String="all",album:String=""){self.scope=scope;self.album=album;selection=[];search="";closePreview();reload()}
    func reload(){guard connected?()==true else{status="휴대폰에 연결하세요";return};pageGeneration=UUID();let generation=pageGeneration;loading=true;error=nil;items=[];revision+=1
        rpc?.call("mediaAlbums",["refresh":true]){[weak self]r in guard let self,self.pageGeneration==generation else{return};if let rows=r["albums"],let d=try?JSONSerialization.data(withJSONObject:rows),let values=try?JSONDecoder().decode([PhotoAlbum].self,from:d){self.albums=values};self.page(0,generation:generation)}
    }
    private func page(_ offset:Int,generation:UUID){rpc?.call("mediaList",["album":album,"scope":scope,"offset":offset]){[weak self]r in
        guard let self,self.pageGeneration==generation else{return};guard r["ok"]as?Bool==true,let rows=r["items"],let data=try?JSONSerialization.data(withJSONObject:rows),let values=try?JSONDecoder().decode([PhotoItem].self,from:data)else{self.loading=false;self.error=r["error"]as?String ?? "사진 목록을 읽지 못했습니다";return}
        self.items+=values;self.total=r["total"]as?Int ?? self.items.count;self.revision+=1;let next=r["next"]as?Int ?? self.items.count
        if next<self.total&&next>offset{self.page(next,generation:generation)}else{self.loading=false;self.status="\(self.items.filter{!$0.video}.count)장의 사진, \(self.items.filter{$0.video}.count)개의 비디오";if self.infoShown{self.loadInfo()}}
    }}
    func select(_ paths:Set<String>){selection=paths;if infoShown{loadInfo()}}
    func loadInfo(){let generation=UUID();infoGeneration=generation;info=[:];latitude=nil;longitude=nil;guard let item=selected.first,selected.count==1 else{return};rpc?.call("mediaInfo",["path":item.path]){[weak self]r in guard let self,self.infoGeneration==generation,let values=r["info"]as?[String:Any]else{return};self.info=values.mapValues{String(describing:$0)};self.latitude=(values["latitude"]as?NSNumber)?.doubleValue;self.longitude=(values["longitude"]as?NSNumber)?.doubleValue;if let a=self.latitude,let b=self.longitude{self.region.center=CLLocationCoordinate2D(latitude:a,longitude:b)}}}
    func toggleInfo(){infoShown.toggle();if infoShown{loadInfo()}}
    func favorite(){guard !selection.isEmpty else{return};mutate("mediaFavorite",["paths":Array(selection),"value":!selected.allSatisfy{$0.favorite}])}
    private func mutate(_ op:String,_ fields:[String:Any],done:(([String:Any])->Void)?=nil){loading=true;status="사진 작업 중…";rpc?.call(op,fields){[weak self]r in guard let self else{return};self.loading=false;if r["ok"]as?Bool==true{done?(r);self.thumbnails.clear();self.reload()}else{self.error=r["error"]as?String ?? "사진 작업을 완료하지 못했습니다"}}}
    func remove(){guard !selection.isEmpty else{return};let a=NSAlert();a.messageText="\(selection.count)개 항목을 휴지통으로 이동할까요?";a.informativeText="휴대폰의 실제 파일을 CoolSync 휴지통으로 이동합니다.";a.addButton(withTitle:"휴지통으로 이동");a.addButton(withTitle:"취소");if a.runModal() == .alertFirstButtonReturn{mutate("mediaTrash",["paths":Array(selection)])}}
    func albumCreate(){prompt("새 앨범",value:"새 앨범"){[weak self]name in self?.mutate("mediaAlbumCreate",["name":name]){r in self?.album=r["path"]as?String ?? "";self?.scope="all"}}}
    func albumRename(){guard !album.isEmpty else{return};prompt("앨범 이름 변경",value:album.components(separatedBy:"/").last ?? ""){[weak self]name in guard let self else{return};self.mutate("mediaAlbumRename",["path":self.album,"name":name]){r in self.album=r["path"]as?String ?? self.album}}}
    func albumDelete(){guard !album.isEmpty else{return};let a=NSAlert();a.messageText="앨범을 휴지통으로 이동할까요?";a.informativeText="휴대폰의 실제 앨범 폴더와 그 안의 모든 파일을 이동합니다. CoolSync 휴지통에서 복원할 수 있습니다.";a.addButton(withTitle:"이동");a.addButton(withTitle:"취소");if a.runModal() == .alertFirstButtonReturn{mutate("mediaAlbumTrash",["path":album]){[weak self]_ in self?.album=""}}}
    private func prompt(_ title:String,value:String,done:@escaping(String)->Void){let a=NSAlert();a.messageText=title;a.informativeText="휴대폰의 실제 사진 폴더에 적용합니다.";let field=NSTextField(string:value);field.frame=NSRect(x:0,y:0,width:280,height:26);a.accessoryView=field;a.window.initialFirstResponder=field;a.addButton(withTitle:"확인");a.addButton(withTitle:"취소");if a.runModal() == .alertFirstButtonReturn{done(field.stringValue)}}
    func move(to target:String,copy:Bool=false,paths:[String]?=nil){let paths=paths ?? Array(selection);guard !paths.isEmpty else{return};mutate(copy ? "mediaCopy":"mediaMove",["paths":paths,"destination":target])}
    func chooseImport(){let p=NSOpenPanel();p.allowsMultipleSelection=true;p.canChooseDirectories=false;p.allowedContentTypes=[.image,.movie];if p.runModal() == .OK{upload(p.urls)}}
    func upload(_ urls:[URL],to target:String?=nil){let folder=target ?? (album.isEmpty ? "Pictures/CoolSync":album);let valid=urls.filter{let type=UTType(filenameExtension:$0.pathExtension);return type?.conforms(to:.image)==true || type?.conforms(to:.movie)==true};guard !valid.isEmpty else{return};if folder=="Pictures/CoolSync"{rpc?.call("mediaAlbumCreate",["name":"CoolSync","reuse":true]){[weak self]r in if r["ok"]as?Bool==true || r["code"]as?String=="exists"{self?.startUpload(valid,to:folder)}}}else{startUpload(valid,to:folder)}}
    private func startUpload(_ urls:[URL],to folder:String){guard files?.hasTransfer != true,rpc?.busy != true else{error="진행 중인 파일 작업을 먼저 마치세요";return};rpc?.upload(urls,to:folder);status="\(urls.count)개 가져오는 중"}
    func export(move:Bool=false){guard files?.hasTransfer != true,rpc?.busy != true else{error="진행 중인 파일 작업을 먼저 마치세요";return};let values=selected;guard !values.isEmpty else{return};let p=NSOpenPanel();p.canChooseFiles=false;p.canChooseDirectories=true;p.prompt=move ? "여기로 이동":"여기에 복사";if p.runModal() == .OK,let folder=p.url{moving=true;rpc?.exportEntries(values.map{$0.remote},to:folder){[weak self]error in guard let self else{return};self.moving=false;if let error{self.error=error.localizedDescription}else if move{self.mutate("mediaTrash",["paths":values.map{$0.path}])}else{self.status="Mac에 \(values.count)개 저장 완료"}}}}
    func open(_ item:PhotoItem){guard files?.hasTransfer != true else{error="진행 중인 파일 전송을 마친 뒤 열어주세요";return};closePreview();preview=item;selection=[item.path];previewLoading=true;previewError="";if infoShown{loadInfo()};let directory=FileManager.default.temporaryDirectory.appendingPathComponent("CoolSyncPhotoPreview",isDirectory:true);try?FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700]);let target=directory.appendingPathComponent(item.id+"-"+String(item.modified)+"-"+item.name)
        if FileManager.default.fileExists(atPath:target.path){show(item,url:target);return}
        rpc?.promise(item.remote,to:target){[weak self]error in guard let self,self.preview?.path==item.path else{return};if let error{self.previewLoading=false;self.previewError=error.localizedDescription}else{self.show(item,url:target)}}
    }
    private func show(_ item:PhotoItem,url:URL){previewLoading=false;if item.video{let asset=AVURLAsset(url:url);Task{let playable=(try?await asset.load(.isPlayable)) ?? false;await MainActor.run{guard self.preview?.path==item.path else{return};if playable{self.player=AVPlayer(url:url);self.player?.play()}else{self.previewError="이 Mac에서 재생할 수 없는 영상 형식입니다. Mac으로 저장한 뒤 다른 플레이어로 열어보세요."}}}}else{previewImage=NSImage(contentsOf:url);if previewImage==nil{previewError="이 Mac에서 표시할 수 없는 이미지입니다"}}}
    func closePreview(){if previewLoading&&preview != nil{rpc?.cancelJobs()};player?.pause();player=nil;preview=nil;previewImage=nil;previewLoading=false;previewError=""}
    func nextPreview(_ delta:Int){guard let item=preview,let i=filtered.firstIndex(where:{$0.path==item.path}),filtered.indices.contains(i+delta)else{return};open(filtered[i+delta])}
    func connectionEnded(){pageGeneration=UUID();infoGeneration=UUID();thumbnails.close();loading=false;moving=false;closePreview();status="휴대폰 연결이 끊겼습니다"}
    func imported(){if visible{thumbnails.clear();reload()}}
}
