import AppKit
import SwiftUI
import Combine
import CryptoKit
import AVKit
import MapKit
import UniformTypeIdentifiers

struct PhotoItem:Codable,Identifiable,Equatable {
    let id:String;let path:String;let name:String;let album:String;let mime:String;let size:Int64;let date:Int64;let modified:Int64;let width:Int;let height:Int;let duration:Int64;var favorite:Bool;let generation:Int64?
    var cacheIdentity:String{"\(id)|\(path)|\(modified)|\(size)|\(generation ?? 0)"}
    var video:Bool{mime.hasPrefix("video/")}
    var timestamp:Date{Date(timeIntervalSince1970:Double(date)/1000)}
    var durationText:String{let seconds=duration/1000;return seconds>=3600 ? String(format:"%lld:%02lld:%02lld",seconds/3600,seconds/60%60,seconds%60):String(format:"%lld:%02lld",seconds/60,seconds%60)}
    var remote:RemoteEntry{RemoteEntry(name:name,path:path,directory:false,size:size,modified:modified)}
}
struct PhotoAlbum:Codable,Identifiable,Equatable{var id:String{path};let path:String;let name:String;let count:Int;let videos:Int}
struct PhotoSection{let title:String;let items:[PhotoItem]}
struct PhotoPin:Identifiable{let id="photo";let coordinate:CLLocationCoordinate2D}

final class PhotoThumbnails {
    weak var rpc:ExplorerModel?
    var key:(()->Data)?
    var failure:((String)->Void)?
    var disk:PhotoLibraryCache?
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
    func load(_ item:PhotoItem,_ done:@escaping(NSImage?)->Void){if let data=disk?.thumbnail(item),let image=NSImage(data:data){done(image);return};guard rpc?.connected?()==true else{done(nil);return};let name=item.cacheIdentity;let id=name as NSString;if let image=cache.object(forKey:id){done(image);return};if waiting[name] != nil{waiting[name]?.append(done);return};waiting[name]=[done];queue.append((item,{[weak self]image in guard let self else{return};let callbacks=self.waiting.removeValue(forKey:name) ?? [];for callback in callbacks{callback(image)}}));pump()}

    private func pump(){while active<2 && !queue.isEmpty{let request=queue.removeFirst();active+=1;let epoch=generation;prepare{[weak self]in guard let self else{return};if self.generation != epoch{return};self.fetch(request.0,retry:true,epoch:epoch){image in guard epoch==self.generation else{return};self.active=max(0,self.active-1);request.1(image);self.pump()}}}}
    private func fetch(_ item:PhotoItem,retry:Bool,epoch:Int,completion:@escaping(NSImage?)->Void){
        guard let endpoint,let hosts=endpoint["hosts"]as?[String],let host=hosts.first(where:{Self.local($0) && !failedHosts.contains($0)}),let port=endpoint["port"]as?Int,(1...65535).contains(port),let token=endpoint["token"]as?String,let key=key?(),key.count==32,let url=URL(string:"http://\(host):\(port)/thumbnail")else{completion(nil);return}
        var m=Wire.Message(type:"mediaThumb");m.text=String(data:(try? JSONSerialization.data(withJSONObject:["path":item.path,"token":token])) ?? Data(),encoding:.utf8) ?? ""
        guard let payload=try? Wire.seal(m,key:key)else{completion(nil);return};let id=m.id
        var q=URLRequest(url:url);q.httpMethod="POST";q.httpBody=payload;q.setValue("application/octet-stream",forHTTPHeaderField:"Content-Type")
        session.dataTask(with:q){[weak self]data,response,error in
            var image:NSImage?;var thumbnailData:Data?
            if error==nil,(response as?HTTPURLResponse)?.statusCode==200,let data,data.count<=128128,let box=try? AES.GCM.SealedBox(combined:data),let clear=try? AES.GCM.open(box,using:SymmetricKey(data:key),authenticating:Data("CoolSync/media/1|\(id)".utf8)){image=NSImage(data:clear);thumbnailData=clear}
            DispatchQueue.main.async{guard let self,self.generation==epoch else{return};if let image{if let thumbnailData{self.disk?.putThumbnail(thumbnailData,item)};self.cache.setObject(image,forKey:item.cacheIdentity as NSString,cost:240*240*4);completion(image)}else if hosts.contains(where:{Self.local($0) && $0 != host && !self.failedHosts.contains($0)}){self.failedHosts.insert(host);self.fetch(item,retry:retry,epoch:epoch,completion:completion)}else if retry{self.endpoint=nil;self.failedHosts=[];self.prepare{self.fetch(item,retry:false,epoch:epoch,completion:completion)}}else{self.queue=[];self.report("썸네일을 가져오지 못했습니다. 같은 Wi-Fi에 연결하고 두 기기의 로컬 네트워크 접근을 허용하세요.");completion(nil)}}
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
    @Published var sidebarShown=false
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
    @Published private(set) var pendingDeletes:[PendingPhotoDelete]=[]
    @Published var showPendingDeletes=false
    @Published var caching=false
    @Published var cacheSummary="아직 저장된 캐시가 없습니다"
    private(set) var disk:PhotoLibraryCache?
    private var deletingIDs=Set<String>()
    private var refreshQueued=false
    private var cacheGeneration=UUID()
    private var changeTask:DispatchWorkItem?
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
    func configure(identity:Data){
        pageGeneration=UUID();cacheGeneration=UUID();changeTask?.cancel();thumbnails.close();thumbnails.clear();closePreview()
        disk=PhotoLibraryCache(identity:identity);thumbnails.disk=disk;pendingDeletes=disk?.pending ?? [];loading=false;caching=false;deletingIDs=[]
        albums=disk?.catalog.albums ?? [];applyView();refreshCacheUsage()
    }
    func appear(){visible=true;applyView();reload()}
    func disappear(){visible=false;thumbnails.close();closePreview()}
    func choose(_ scope:String="all",album:String=""){self.scope=scope;self.album=album;selection=[];search="";closePreview();applyView()}
    private func applyView(){
        let pending=Set(pendingDeletes.map{$0.item.cacheIdentity})
        var rows=(disk?.catalog.items ?? []).filter{!pending.contains($0.cacheIdentity) && (album.isEmpty || $0.album==album) && (scope != "videos" || $0.video) && (scope != "favorites" || $0.favorite) && (scope != "screenshots" || $0.album.localizedCaseInsensitiveContains("screenshot"))}
        rows.sort{scope=="recent" ? ($0.modified==$1.modified ? $0.id>$1.id:$0.modified>$1.modified):($0.date==$1.date ? $0.id>$1.id:$0.date>$1.date)}
        items=rows;albums=disk?.catalog.albums ?? [];total=rows.count;selection.formIntersection(Set(rows.map{$0.path}));revision+=1
        status=connected?()==true ? "\(rows.filter{!$0.video}.count)장의 사진, \(rows.filter{$0.video}.count)개의 비디오":"Mac에 저장된 목록 · 오프라인"
        if !pendingDeletes.isEmpty{status += " · 삭제 대기 \(pendingDeletes.count)개"}
    }
    func reconnected(){if visible || !pendingDeletes.isEmpty{reload()}}
    func changed(){
        guard visible else{return};changeTask?.cancel()
        let task=DispatchWorkItem{[weak self]in self?.reload()};changeTask=task;DispatchQueue.main.asyncAfter(deadline:.now()+0.5,execute:task)
    }
    func reload(){
        guard connected?()==true,let disk else{applyView();return}
        if loading || !deletingIDs.isEmpty{refreshQueued=true;return}
        pageGeneration=UUID();let generation=pageGeneration;loading=true;error=nil;status="변경된 사진 확인 중…"
        syncPage(offset:0,batch:"",generation:generation,staged:disk.catalog,changes:0)
    }
    private func syncPage(offset:Int,batch:String,generation:UUID,staged:PhotoCatalog,changes:Int){
        guard let disk else{return}
        rpc?.call("mediaSync",["since":disk.catalog.revision,"batch":batch,"offset":offset]){[weak self]r in
            guard let self,self.pageGeneration==generation,self.disk===disk else{return}
            guard r["ok"]as?Bool==true,let events=r["events"]as?[[String:Any]],let token=r["revision"]as?String,let batch=r["batch"]as?String else{self.loading=false;self.error=r["error"]as?String ?? "사진 변경분을 확인하지 못했습니다";self.applyView();return}
            var value=staged
            if offset==0 && r["reset"]as?Bool==true{value=PhotoCatalog()}
            var rows=Dictionary(value.items.map{($0.id,$0)},uniquingKeysWith:{_,last in last})
            var albums=Dictionary(value.albums.map{($0.path,$0)},uniquingKeysWith:{_,last in last})
            for event in events{
                if let id=event["removed"]as?String{rows.removeValue(forKey:id)}
                if let path=event["removedAlbum"]as?String{albums.removeValue(forKey:path)}
                if let row=event["item"]{guard let data=try?JSONSerialization.data(withJSONObject:row),let item=try?JSONDecoder().decode(PhotoItem.self,from:data)else{self.loading=false;self.error="사진 변경분 형식을 확인하지 못했습니다. 기존 캐시를 유지합니다.";return};rows[item.id]=item}
                if let row=event["album"]{guard let data=try?JSONSerialization.data(withJSONObject:row),let album=try?JSONDecoder().decode(PhotoAlbum.self,from:data)else{self.loading=false;self.error="앨범 변경분 형식을 확인하지 못했습니다";return};albums[album.path]=album}
            }
            value.items=Array(rows.values);value.albums=albums.values.sorted{$0.name.localizedStandardCompare($1.name) == .orderedAscending};value.revision=token
            let next=r["next"]as?Int ?? offset,total=r["total"]as?Int ?? 0
            guard next>=offset,next<=total,(next>offset || next==total)else{self.loading=false;self.error="사진 동기화 순서를 확인하지 못했습니다. 다시 동기화하세요.";return}
            if next<total && next>offset{self.status="변경분 \(next)/\(total)개 반영 중…";self.syncPage(offset:next,batch:batch,generation:generation,staged:value,changes:changes+events.count);return}
            value.synced=Date()
            do{
                let old=disk.catalog.items;try disk.commit(value)
                for item in old{if let current=rows[item.id],current.cacheIdentity==item.cacheIdentity{continue};try disk.discard(item,trashOriginal:rows[item.id]==nil)}
                self.loading=false;self.applyView();self.status += changes+events.count==0 ? " · 변경 없음":" · 변경분 \(changes+events.count)개 반영";self.refreshCacheUsage()
                if self.infoShown{self.loadInfo()};self.processPendingDeletes()
                if self.refreshQueued && self.deletingIDs.isEmpty{self.refreshQueued=false;self.reload()}
            }catch{self.loading=false;self.error="Mac 캐시 저장 또는 정리를 완료하지 못했습니다: \(error.localizedDescription)";self.applyView()}
        }
    }
    func select(_ paths:Set<String>){selection=paths;if infoShown{loadInfo()}}
    func loadInfo(){
        let generation=UUID();infoGeneration=generation;info=[:];latitude=nil;longitude=nil
        guard let item=selected.first,selected.count==1 else{return}
        if let values=disk?.details(item){applyInfo(values)}
        guard connected?()==true else{return}
        rpc?.call("mediaInfo",["path":item.path]){[weak self]r in guard let self,self.infoGeneration==generation,let values=r["info"]as?[String:Any]else{return};let strings=values.mapValues{String(describing:$0)};self.disk?.putDetails(strings,item);self.applyInfo(strings)}
    }
    private func applyInfo(_ values:[String:String]){info=values;latitude=values["latitude"].flatMap(Double.init);longitude=values["longitude"].flatMap(Double.init);if let a=latitude,let b=longitude{region.center=CLLocationCoordinate2D(latitude:a,longitude:b)}}
    func toggleInfo(){infoShown.toggle();if infoShown{loadInfo()}}
    func favorite(){guard !selection.isEmpty else{return};mutate("mediaFavorite",["paths":Array(selection),"value":!selected.allSatisfy{$0.favorite}])}
    private func mutate(_ op:String,_ fields:[String:Any],done:(([String:Any])->Void)?=nil){loading=true;status="사진 작업 중…";rpc?.call(op,fields){[weak self]r in guard let self else{return};self.loading=false;if r["ok"]as?Bool==true{done?(r);self.thumbnails.clear();self.reload()}else{self.error=r["error"]as?String ?? "사진 작업을 완료하지 못했습니다"}}}
    func remove(){
        let values=selected;guard !values.isEmpty else{return}
        let a=NSAlert();a.messageText="\(values.count)개 항목을 양쪽에서 삭제할까요?";a.informativeText="휴대폰 원본을 CoolSync 휴지통으로, Mac에 보관한 원본을 Mac 휴지통으로 옮깁니다. 연결이 끊겨 있으면 삭제를 대기합니다. Finder로 따로 내보낸 파일은 유지됩니다.";a.addButton(withTitle:"양쪽 휴지통으로 이동");a.addButton(withTitle:"취소")
        if a.runModal() == .alertFirstButtonReturn{enqueueDeletes(values)}
    }
    private func enqueueDeletes(_ values:[PhotoItem]){
        guard let disk else{return}
        var queue=pendingDeletes;let known=Set(queue.map{$0.item.cacheIdentity})
        queue += values.filter{!known.contains($0.cacheIdentity)}.map{PendingPhotoDelete(item:$0)}
        do{try disk.setPending(queue);pendingDeletes=queue;closePreview();applyView();processPendingDeletes()}catch{self.error="삭제 대기를 저장하지 못했습니다. 파일은 삭제하지 않았습니다."}
    }
    private func processPendingDeletes(){
        guard !loading,deletingIDs.isEmpty,let disk else{return}
        if pendingDeletes.contains(where:{$0.phoneDeleted && $0.error==nil}){finishLocalDeletes();return}
        let candidates=pendingDeletes.filter{$0.error==nil && !$0.phoneDeleted}
        guard !candidates.isEmpty else{if refreshQueued && connected?()==true{refreshQueued=false;reload()};return}
        guard connected?()==true else{return}
        var requests:[[String:Any]]=[];var chosen:[PendingPhotoDelete]=[]
        for value in candidates.prefix(20){
            guard let data=try?JSONEncoder().encode(value.item),let row=try?JSONSerialization.jsonObject(with:data)else{continue}
            let request:[String:Any]=["operation":value.id,"item":row]
            guard let bytes=try?JSONSerialization.data(withJSONObject:requests+[request]),bytes.count<=16000 else{break}
            requests.append(request);chosen.append(value)
        }
        guard !chosen.isEmpty else{error="삭제 요청이 너무 큽니다. 항목을 다시 선택하세요.";return}
        deletingIDs=Set(chosen.map{$0.id});status="양쪽 삭제 중 · \(chosen.count)개"
        rpc?.call("mediaTrashChecked",["items":requests]){[weak self]r in
            guard let self,self.disk===disk,!self.deletingIDs.isEmpty else{return};self.deletingIDs=[]
            var queue=self.pendingDeletes
            let results=r["results"]as?[[String:Any]] ?? []
            for request in chosen{
                guard let i=queue.firstIndex(where:{$0.id==request.id})else{continue}
                if let result=results.first(where:{$0["operation"]as?String==request.id}),result["ok"]as?Bool==true{queue[i].phoneDeleted=true;queue[i].error=nil}
                else{queue[i].error=results.first(where:{$0["operation"]as?String==request.id})?["error"]as?String ?? r["error"]as?String ?? "휴대폰 처리 확인이 없습니다. 다시 시도하세요."}
            }
            do{try disk.setPending(queue);self.pendingDeletes=queue;self.finishLocalDeletes()}catch{self.error="삭제 처리 상태를 Mac에 저장하지 못했습니다. 재연결 시 다시 확인합니다."}
        }
    }
    private func finishLocalDeletes(){
        guard let disk else{return}
        var queue=pendingDeletes;var completed=Set<String>();var identities=Set<String>()
        for value in queue where value.phoneDeleted && value.error==nil{
            do{try disk.discard(value.item,trashOriginal:true);completed.insert(value.id);identities.insert(value.item.cacheIdentity)}
            catch{if let i=queue.firstIndex(where:{$0.id==value.id}){queue[i].error="휴대폰 처리 완료 · Mac 캐시 정리 실패: \(error.localizedDescription)"}}
        }
        do{
            var catalog=disk.catalog;catalog.items.removeAll{identities.contains($0.cacheIdentity)};try disk.commit(catalog)
            queue.removeAll{completed.contains($0.id)};try disk.setPending(queue);pendingDeletes=queue;applyView();refreshCacheUsage()
            if !completed.isEmpty{refreshQueued=true}
            processPendingDeletes()
        }catch{self.error="Mac 삭제 처리 기록을 저장하지 못했습니다. 다시 시도하세요."}
    }
    func canCancelDelete(_ value:PendingPhotoDelete)->Bool{!deletingIDs.contains(value.id) && !value.phoneDeleted}
    func retryDeletes(){guard deletingIDs.isEmpty else{return};var queue=pendingDeletes;for i in queue.indices{queue[i].error=nil};do{try disk?.setPending(queue);pendingDeletes=queue;processPendingDeletes()}catch{self.error=error.localizedDescription}}
    func cancelDelete(_ id:String){guard !deletingIDs.contains(id),!pendingDeletes.contains(where:{$0.id==id&&$0.phoneDeleted})else{return};do{let queue=pendingDeletes.filter{$0.id != id};try disk?.setPending(queue);pendingDeletes=queue;applyView()}catch{self.error=error.localizedDescription}}
    func albumCreate(){prompt("새 앨범",value:"새 앨범"){[weak self]name in self?.mutate("mediaAlbumCreate",["name":name]){r in self?.album=r["path"]as?String ?? "";self?.scope="all"}}}
    func albumRename(){guard !album.isEmpty else{return};prompt("앨범 이름 변경",value:album.components(separatedBy:"/").last ?? ""){[weak self]name in guard let self else{return};self.mutate("mediaAlbumRename",["path":self.album,"name":name]){r in self.album=r["path"]as?String ?? self.album}}}
    func albumDelete(){guard !album.isEmpty else{return};let a=NSAlert();a.messageText="앨범을 휴지통으로 이동할까요?";a.informativeText="휴대폰의 실제 앨범 폴더와 그 안의 모든 파일을 이동합니다. CoolSync 휴지통에서 복원할 수 있습니다.";a.addButton(withTitle:"이동");a.addButton(withTitle:"취소");if a.runModal() == .alertFirstButtonReturn{mutate("mediaAlbumTrash",["path":album]){[weak self]_ in self?.album=""}}}
    private func prompt(_ title:String,value:String,done:@escaping(String)->Void){let a=NSAlert();a.messageText=title;a.informativeText="휴대폰의 실제 사진 폴더에 적용합니다.";let field=NSTextField(string:value);field.frame=NSRect(x:0,y:0,width:280,height:26);a.accessoryView=field;a.window.initialFirstResponder=field;a.addButton(withTitle:"확인");a.addButton(withTitle:"취소");if a.runModal() == .alertFirstButtonReturn{done(field.stringValue)}}
    func move(to target:String,copy:Bool=false,paths:[String]?=nil){let paths=paths ?? Array(selection);guard !paths.isEmpty else{return};mutate(copy ? "mediaCopy":"mediaMove",["paths":paths,"destination":target])}
    func chooseImport(){let p=NSOpenPanel();p.allowsMultipleSelection=true;p.canChooseDirectories=false;p.allowedContentTypes=[.image,.movie];if p.runModal() == .OK{upload(p.urls)}}
    func upload(_ urls:[URL],to target:String?=nil){let folder=target ?? (album.isEmpty ? "Pictures/CoolSync":album);let valid=urls.filter{let type=UTType(filenameExtension:$0.pathExtension);return type?.conforms(to:.image)==true || type?.conforms(to:.movie)==true};guard !valid.isEmpty else{return};if folder=="Pictures/CoolSync"{rpc?.call("mediaAlbumCreate",["name":"CoolSync","reuse":true]){[weak self]r in if r["ok"]as?Bool==true || r["code"]as?String=="exists"{self?.startUpload(valid,to:folder)}}}else{startUpload(valid,to:folder)}}
    private func startUpload(_ urls:[URL],to folder:String){guard files?.hasTransfer != true,rpc?.busy != true else{error="진행 중인 파일 작업을 먼저 마치세요";return};rpc?.upload(urls,to:folder);status="\(urls.count)개 가져오는 중"}
    func export(move:Bool=false){
        guard files?.hasTransfer != true,rpc?.busy != true else{error="진행 중인 파일 작업을 먼저 마치세요";return};let values=selected;guard !values.isEmpty else{return}
        let p=NSOpenPanel();p.canChooseFiles=false;p.canChooseDirectories=true;p.prompt=move ? "여기로 이동":"여기에 복사"
        guard p.runModal() == .OK,let folder=p.url else{return}
        moving=true;exportSequence(values,to:folder){[weak self]failure in guard let self else{return};self.moving=false;if let failure{self.error=failure.localizedDescription}else if move{self.enqueueDeletes(values)}else{self.status="Mac에 \(values.count)개 저장 완료"}}
    }
    private func exportSequence(_ values:[PhotoItem],to folder:URL,completion:@escaping(Error?)->Void){guard let item=values.first else{completion(nil);return};promiseExport(item,to:folder.appendingPathComponent(item.name)){[weak self]error in if let error{completion(error)}else{self?.exportSequence(Array(values.dropFirst()),to:folder,completion:completion)}}}
    func promiseExport(_ item:PhotoItem,to target:URL,completion:@escaping(Error?)->Void){
        guard !FileManager.default.fileExists(atPath:target.path)else{completion(NSError(domain:"CoolSync",code:2,userInfo:[NSLocalizedDescriptionKey:"같은 이름의 파일이 있습니다. 다른 저장 위치를 선택하세요."]));return}
        if let source=disk?.original(item){DispatchQueue.global(qos:.utility).async{let failure:Error?;do{try FileManager.default.copyItem(at:source,to:target);failure=nil}catch{failure=error};DispatchQueue.main.async{completion(failure)}};return}
        guard connected?()==true else{completion(NSError(domain:"CoolSync",code:1,userInfo:[NSLocalizedDescriptionKey:"이 원본은 Mac에 보관되지 않았습니다. 휴대폰을 연결하세요."]));return}
        rpc?.promise(item.remote,to:target,completion:completion)
    }
    func isCached(_ item:PhotoItem)->Bool{disk?.original(item,touch:false) != nil}
    func cacheSelection(){
        guard connected?()==true,!caching,files?.hasTransfer != true else{error="휴대폰 연결과 진행 중인 전송을 확인하세요";return}
        let values=selected;guard !values.isEmpty,let disk else{return};guard values.reduce(Int64(0),{$0+$1.size})<=disk.budget else{error="선택한 원본이 캐시 한도를 초과합니다. 설정에서 한도를 늘리거나 선택을 줄이세요.";return};caching=true;cacheGeneration=UUID();cacheNext(values,generation:cacheGeneration)
    }
    private func cacheNext(_ values:[PhotoItem],generation:UUID){
        guard caching,cacheGeneration==generation,let disk else{return}
        let remaining=values.drop(while:{disk.original($0) != nil})
        guard let item=remaining.first else{caching=false;disk.protected=Set(preview.map{[disk.originalURL($0)]} ?? []);disk.prune();refreshCacheUsage();status="선택한 원본 보관 완료 · 오래된 캐시는 용량 한도에 따라 정리됩니다";return}
        guard connected?()==true else{caching=false;return};status="원본 보관 중 · \(item.name)"
        let target=disk.originalURL(item);disk.protected=[target]
        rpc?.promise(item.remote,to:target){[weak self]error in guard let self,self.cacheGeneration==generation,self.disk===disk else{return};if let error{self.caching=false;disk.protected=Set(self.preview.map{[disk.originalURL($0)]} ?? []);disk.prune();self.error=error.localizedDescription;return};disk.touch(target);disk.prune(excluding:Set([target]+(self.preview.map{[disk.originalURL($0)]} ?? [])));self.cacheNext(Array(remaining.dropFirst()),generation:generation)}
    }
    func refreshCacheUsage(){guard let disk else{return};cacheSummary=ByteCountFormatter.string(fromByteCount:disk.bytes,countStyle:.file)+" / "+ByteCountFormatter.string(fromByteCount:disk.budget,countStyle:.file)}
    func clearCache(){
        guard !caching,!previewLoading,files?.hasTransfer != true else{error="진행 중인 전송을 마친 뒤 캐시를 정리하세요";return}
        let a=NSAlert();a.messageText="Mac 캐시만 비울까요?";a.informativeText="Mac에 임시 보관한 사진 원본·썸네일·촬영 정보만 비웁니다. 휴대폰 원본, 삭제 대기 목록, Finder로 내보낸 파일은 유지됩니다.";a.addButton(withTitle:"캐시만 비우기");a.addButton(withTitle:"취소")
        if a.runModal() == .alertFirstButtonReturn{do{closePreview();try disk?.clearFiles();thumbnails.clear();revision+=1;refreshCacheUsage()}catch{self.error=error.localizedDescription}}
    }
    func open(_ item:PhotoItem){
        guard files?.hasTransfer != true else{error="진행 중인 파일 전송을 마친 뒤 열어주세요";return};closePreview();preview=item;selection=[item.path];previewLoading=true;previewError="";if infoShown{loadInfo()}
        guard let disk else{previewLoading=false;previewError="사진 캐시를 열지 못했습니다";return}
        if let target=disk.original(item){disk.protected=[target];show(item,url:target);return}
        guard connected?()==true else{previewLoading=false;previewError="이 원본은 Mac에 보관되지 않았습니다. 휴대폰 연결 후 열거나 ‘선택 원본 보관’을 사용하세요.";return}
        let target=disk.originalURL(item);disk.protected=[target]
        rpc?.promise(item.remote,to:target){[weak self]error in guard let self,self.preview?.path==item.path,self.disk===disk else{return};if let error{self.previewLoading=false;self.previewError=error.localizedDescription}else{disk.touch(target);disk.prune(excluding:[target]);self.refreshCacheUsage();self.show(item,url:target)}}
    }
    private func show(_ item:PhotoItem,url:URL){previewLoading=false;if item.video{let asset=AVURLAsset(url:url);Task{let playable=(try?await asset.load(.isPlayable)) ?? false;await MainActor.run{guard self.preview?.path==item.path else{return};if playable{self.player=AVPlayer(url:url);self.player?.play()}else{self.previewError="이 Mac에서 재생할 수 없는 영상 형식입니다. Mac으로 저장한 뒤 다른 플레이어로 열어보세요."}}}}else{previewImage=NSImage(contentsOf:url);if previewImage==nil{previewError="이 Mac에서 표시할 수 없는 이미지입니다"}}}
    func closePreview(){if previewLoading&&preview != nil{rpc?.cancelJobs()};player?.pause();player=nil;preview=nil;previewImage=nil;previewLoading=false;previewError="";disk?.protected=[];disk?.prune()}
    func nextPreview(_ delta:Int){guard let item=preview,let i=filtered.firstIndex(where:{$0.path==item.path}),filtered.indices.contains(i+delta)else{return};open(filtered[i+delta])}
    func connectionEnded(){pageGeneration=UUID();infoGeneration=UUID();cacheGeneration=UUID();changeTask?.cancel();thumbnails.close();loading=false;moving=false;caching=false;deletingIDs=[];closePreview();applyView()}
    func imported(){changed()}
}
