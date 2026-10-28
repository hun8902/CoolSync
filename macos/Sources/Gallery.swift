import AppKit
import SwiftUI
import Combine
import CryptoKit
import AVKit
import MapKit
import UniformTypeIdentifiers
import ImageIO

struct PhotoItem:Codable,Identifiable,Equatable {
    let id:String;let path:String;let name:String;let album:String;let mime:String;let size:Int64;let date:Int64;let modified:Int64;let width:Int;let height:Int;let duration:Int64;var favorite:Bool;let generation:Int64?;let added:Int64?;let dateSource:String?
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
    var canFetch:(()->Bool)?
    var activity:((Int,Int,Int)->Void)?
    private var completed=0
    private var failures=0
    private func publishActivity(){activity?(waiting.count,completed,failures)}
    func resume(){pump()}
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
    private var requests:[UUID:URLSessionDataTask]=[:]
    private let session:URLSession={let c=URLSessionConfiguration.ephemeral;c.timeoutIntervalForRequest=15;c.timeoutIntervalForResource=20;c.httpMaximumConnectionsPerHost=2;return URLSession(configuration:c)}()
    init(){cache.countLimit=200;cache.totalCostLimit=48*1024*1024}
    func close(closeRemote:Bool=true){generation+=1;endpoint=nil;failedHosts=[];queue=[];pending=[];waiting=[:];preparing=false;active=0;reported=false;completed=0;failures=0;publishActivity();let cancelled=Array(requests.values);requests.removeAll();cancelled.forEach{$0.cancel()};if closeRemote && rpc?.connected?()==true{rpc?.callPhoto("mediaClose"){_ in}}}
    func clear(){cache.removeAllObjects()}
    private func prepare(_ done:@escaping()->Void){if endpoint != nil{done();return};pending.append(done);if preparing{return};preparing=true;let epoch=generation
        rpc?.callPhoto("mediaSession"){[weak self]r in guard let self,self.generation==epoch else{return};self.preparing=false;self.endpoint=r["endpoint"]as?[String:Any];if self.endpoint==nil{self.report(r["error"]as?String ?? "같은 Wi-Fi와 로컬 네트워크 권한을 확인하세요")};let waiting=self.pending;self.pending=[];for callback in waiting{callback()}}
    }
    func withEndpoint(_ completion:@escaping([String:Any]?)->Void){prepare{[weak self]in completion(self?.endpoint)}}
    func invalidateEndpoint(){endpoint=nil;failedHosts=[]}
    func load(_ item:PhotoItem,_ done:@escaping(NSImage?)->Void){if let data=disk?.thumbnail(item),let image=NSImage(data:data){done(image);return};guard rpc?.connected?()==true else{done(nil);return};let name=item.cacheIdentity;let id=name as NSString;if let image=cache.object(forKey:id){done(image);return};if waiting[name] != nil{waiting[name]?.append(done);return};waiting[name]=[done];queue.append((item,{[weak self]image in guard let self else{return};let callbacks=self.waiting.removeValue(forKey:name) ?? [];self.completed+=1;if image==nil{self.failures+=1};self.publishActivity();for callback in callbacks{callback(image)}}));publishActivity();pump()}

    private func pump(){guard canFetch?() != false else{return};while active<2 && !queue.isEmpty{let request=queue.removeFirst();active+=1;let epoch=generation;prepare{[weak self]in guard let self else{return};if self.generation != epoch{return};self.fetch(request.0,retry:true,epoch:epoch){image in guard epoch==self.generation else{return};self.active=max(0,self.active-1);request.1(image);self.pump()}}}}
    private func fetch(_ item:PhotoItem,retry:Bool,epoch:Int,completion:@escaping(NSImage?)->Void){
        guard let endpoint,let hosts=endpoint["hosts"]as?[String],let host=hosts.first(where:{Self.local($0) && !failedHosts.contains($0)}),let port=endpoint["port"]as?Int,(1...65535).contains(port),let token=endpoint["token"]as?String,let key=key?(),key.count==32,let url=URL(string:"http://\(host):\(port)/thumbnail")else{completion(nil);return}
        var m=Wire.Message(type:"mediaThumb");m.text=String(data:(try? JSONSerialization.data(withJSONObject:["path":item.path,"token":token])) ?? Data(),encoding:.utf8) ?? ""
        guard let payload=try? Wire.seal(m,key:key)else{completion(nil);return};let id=m.id
        var q=URLRequest(url:url);q.httpMethod="POST";q.httpBody=payload;q.setValue("application/octet-stream",forHTTPHeaderField:"Content-Type")
        let requestID=UUID()
        let task=session.dataTask(with:q){[weak self]data,response,error in
            var image:NSImage?;var thumbnailData:Data?
            if error==nil,(response as?HTTPURLResponse)?.statusCode==200,let data,data.count<=128128,let box=try? AES.GCM.SealedBox(combined:data),let clear=try? AES.GCM.open(box,using:SymmetricKey(data:key),authenticating:Data("CoolSync/media/1|\(id)".utf8)){image=NSImage(data:clear);thumbnailData=clear}
            DispatchQueue.main.async{guard let self else{return};self.requests.removeValue(forKey:requestID);guard self.generation==epoch else{return};if let image{if let thumbnailData{self.disk?.putThumbnail(thumbnailData,item)};self.cache.setObject(image,forKey:item.cacheIdentity as NSString,cost:240*240*4);completion(image)}else if hosts.contains(where:{Self.local($0) && $0 != host && !self.failedHosts.contains($0)}){self.failedHosts.insert(host);self.fetch(item,retry:retry,epoch:epoch,completion:completion)}else if retry{self.endpoint=nil;self.failedHosts=[];self.prepare{self.fetch(item,retry:false,epoch:epoch,completion:completion)}}else{self.report("썸네일을 가져오지 못했습니다. 같은 Wi-Fi에 연결하고 두 기기의 로컬 네트워크 접근을 허용하세요.");completion(nil)}}
        }
        requests[requestID]=task;task.resume()
    }
    private func report(_ message:String){if !reported{reported=true;failure?(message)}}
    static func local(_ value:String)->Bool{let a=value.split(separator:".").compactMap{Int($0)};guard a.count==4,a.allSatisfy({(0...255).contains($0)})else{return false};return a[0]==10 || (a[0]==192&&a[1]==168) || (a[0]==172&&(16...31).contains(a[1])) || (a[0]==169&&a[1]==254)}
}

final class PhotosModel:ObservableObject {
    @Published var items:[PhotoItem]=[]
    @Published var albums:[PhotoAlbum]=[]
    @Published var selection=Set<String>()
    @Published var album=""
    @Published var scope="all"
    @Published var search=""
    @Published var grouping="all"{didSet{if grouping != "all" && sortKey=="name"{sortKey="captured"}}}
    @Published var zoom:Double=150
    @Published var infoShown=false
    @Published var sidebarShown=false
    @Published var info:[String:String]=[:]
    @Published var latitude:Double?
    @Published var longitude:Double?
    @Published var region=MKCoordinateRegion(center:CLLocationCoordinate2D(latitude:37,longitude:127),span:MKCoordinateSpan(latitudeDelta:0.02,longitudeDelta:0.02))
    @Published var status="휴대폰에 연결하세요"
    @Published var thumbnailPending=0
    @Published var thumbnailCompleted=0
    @Published var thumbnailFailures=0
    @Published var loading=false{didSet{if !loading{thumbnails.resume()}}}
    @Published var total=0
    @Published var revision=0
    @Published var error:String?
    @Published var preview:PhotoItem?
    @Published var previewImage:NSImage?
    @Published var player:AVPlayer?
    @Published var motionAvailable=false
    @Published var motionLoading=false
    @Published var motionPlaying=false
    @Published var motionError=""
    private var motionURL:URL?
    private var previewGeneration=UUID()
    private var motionExtraction:Task<URL?,Error>?
    private var motionEndObserver:NSObjectProtocol?
    @Published var sortKey=UserDefaults.standard.string(forKey:"photoSortKey") ?? "captured"{didSet{UserDefaults.standard.set(sortKey,forKey:"photoSortKey");applyView()}}
    @Published var ascending=UserDefaults.standard.bool(forKey:"photoSortAscending"){didSet{UserDefaults.standard.set(ascending,forKey:"photoSortAscending");applyView()}}
    @Published var previewLoading=false
    @Published var previewError=""
    @Published var moving=false
    @Published private(set) var pendingDeletes:[PendingPhotoDelete]=[]
    @Published var showPendingDeletes=false
    @Published private(set) var infoStatus=""
    @Published private(set) var infoRefreshing=false
    @Published private(set) var bulkInfoActive=false
    @Published private(set) var bulkInfoDone=0
    @Published private(set) var bulkInfoTotal=0
    @Published private(set) var bulkInfoMissing=0
    @Published private(set) var bulkInfoFailures:[String]=[]
    @Published private(set) var bulkInfoStatus=""
    private var bulkInfoFailedPaths=Set<String>()
    private var bulkInfoBusy=false
    private var bulkInfoToken=UUID()
    private var infoFetchToken=UUID()
    @Published private(set) var photoSyncActivity=""
    @Published private(set) var deleteCompleted=0
    @Published private(set) var deleteActivity=""
    var deleteInFlight:Bool{!deletingIDs.isEmpty}
    func deletionState(_ value:PendingPhotoDelete)->String{
        if let error=value.error{return error}
        if value.phoneDeleted{return "휴대폰 삭제 확인됨 · Mac 반영 중"}
        if deletingIDs.contains(value.id){return "휴대폰에 삭제 요청 중 · 응답 확인 중"}
        return connected?()==true ? "자동 처리 대기":"연결되면 자동 처리"
    }
    private func automaticDeleteRetryAllowed(_ value:PendingPhotoDelete)->Bool{
        guard value.error != nil else{return true}
        if value.phoneDeleted{return true}
        if let code=value.errorCode{return ["transport","timeout","io","write"].contains(code)}
        let message=value.error ?? ""
        return !["변경", "권한", "permission", "conflict", "경로", "지원"].contains(where:{message.localizedCaseInsensitiveContains($0)})
    }
    @Published var caching=false
    @Published var cacheSummary="아직 저장된 캐시가 없습니다"
    private(set) var disk:PhotoLibraryCache?
    private var deletingIDs=Set<String>()
    private var deleteRequestToken=UUID()
    private var refreshQueued=false
    private var editedRefreshActive=false
    private var editedRefreshToken=UUID()
    private var editedRefreshFailures=Set<String>()
    private func refreshEditedOriginals(){
        guard !loading,!editedRefreshActive,connected?()==true,let disk else{return}
        let candidates=disk.catalog.items.filter{disk.refreshPaths.contains($0.path) && !editedRefreshFailures.contains($0.path)}
        guard let item=candidates.first else{return}
        if previewLoading && preview?.id==item.id{return}
        if disk.original(item,touch:false) != nil{do{try disk.setRefreshPaths(disk.refreshPaths.subtracting([item.path]));refreshEditedOriginals()}catch{self.error=error.localizedDescription};return}
        guard item.size<=disk.budget else{editedRefreshFailures.insert(item.path);photoSyncActivity="편집 사진이 캐시 한도를 초과합니다 · \(item.name)";refreshEditedOriginals();return}
        editedRefreshActive=true;let token=editedRefreshToken;let target=disk.originalURL(item);disk.protected.insert(target)
        photoSyncActivity="편집된 원본 캐시 갱신 중 · \(item.name)"
        originals.download(item,to:target,owner:"edited-refresh"){[weak self]result in
            guard let self,self.disk===disk,self.editedRefreshToken==token else{return}
            self.editedRefreshActive=false;disk.protected.remove(target)
            switch result{
            case .success(let receipt):
                do{try self.rememberOriginal(receipt.item);try disk.setRefreshPaths(disk.refreshPaths.subtracting([item.path]));disk.prune(excluding:[receipt.url]);self.photoSyncActivity="편집 사진·원본 캐시 최신 버전 반영 완료"}catch{self.editedRefreshFailures.insert(item.path);self.photoSyncActivity="캐시 갱신 기록 실패 · 다음 연결 때 재시도"}
            case .failure:
                self.editedRefreshFailures.insert(item.path);self.photoSyncActivity="편집 원본 캐시 갱신 대기 · 다음 연결 때 자동 재시도"
            }
            self.refreshCacheUsage();self.refreshEditedOriginals()
        }
    }
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
    private let originals=PhotoOriginals()
    @Published var previewPhase="원본을 가져오는 중…"
    @Published var originalProgress:Double=0
    @Published var dateAlignmentResult:String?
    @Published var dateWorkActive=false
    @Published var dateWorkProgress:Double=0
    @Published var dateWorkFailures:[String]=[]
    @Published var dateWorkNotes:[String]=[]
    private var dateWorkStopped=false
    private var dateWorkTotal=0
    private var dateWorkRemaining:[PhotoItem]=[]
    private var dateWorkToken=UUID()
    private var dateRetry:[PhotoItem]=[]
    func stopDateWork(){dateWorkStopped=true;status="현재 묶음 처리 후 중단합니다"}
    func retryDateWork(){let paths=Set(dateRetry.map{$0.path});alignModifiedDates("retry",retryPaths:paths)}
    private var transferObservation:AnyCancellable?
    var title:String{if !album.isEmpty{return albums.first{$0.path==album}?.name ?? album};return ["all":"보관함","videos":"비디오","favorites":"즐겨찾기","recent":"최근 저장된 항목","screenshots":"스크린샷"][scope] ?? "보관함"}
    var filtered:[PhotoItem]{items.filter{search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)}}
    var selected:[PhotoItem]{items.filter{selection.contains($0.path)}}
    private var libraryDates:[String:Int64]=[:]
    private var libraryDateToken=UUID()
    private var libraryDateChecked=Set<String>()
    private func refreshLibraryDates(){
        guard let disk else{return}
        let candidates=disk.catalog.items.filter{$0.date<=0 && PhotoOrdering.filenameDate($0.name)==nil && libraryDates[$0.cacheIdentity]==nil && !libraryDateChecked.contains($0.cacheIdentity)}
        guard !candidates.isEmpty else{return}
        let records=candidates.map{PhotoLibraryDates.Record(identity:$0.cacheIdentity,name:$0.name,size:$0.size,width:$0.width,height:$0.height)}
        libraryDateChecked.formUnion(candidates.map{$0.cacheIdentity})
        let token=UUID();libraryDateToken=token
        DispatchQueue.global(qos:.utility).async{[weak self]in
            let dates=PhotoLibraryDates.read(records)
            DispatchQueue.main.async{guard let self,self.libraryDateToken==token,self.disk===disk,!dates.isEmpty else{return}
                self.libraryDates.merge(dates,uniquingKeysWith:{_,new in new})
                if let data=try?JSONEncoder().encode(self.libraryDates){let url=disk.folder.appendingPathComponent("library-dates.json");try?data.write(to:url,options:.atomic);try?FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)}
                self.applyView(preservePreview:true)
            }
        }
    }
    func timelineTime(_ item:PhotoItem)->Int64{
        if item.date>0 && ["exif","video","captured"].contains(item.dateSource ?? ""){return item.date}
        return PhotoOrdering.filenameDate(item.name) ?? libraryDates[item.cacheIdentity] ?? 0
    }
    func orderTime(_ item:PhotoItem)->Int64{scope=="recent" || sortKey=="added" ? (item.added.flatMap{$0>0 ? $0:nil} ?? 0):timelineTime(item)}
    func orderDate(_ item:PhotoItem)->Date{Date(timeIntervalSince1970:Double(orderTime(item))/1000)}
    func dateSourceTitle(_ item:PhotoItem)->String{if item.date<=0 && libraryDates[item.cacheIdentity] != nil{return "사진 보관함 원본 날짜"};if timelineTime(item) != item.date || item.dateSource=="filename"{return "파일명 날짜"};return ["exif":"원본 촬영일 (EXIF)","video":"영상 내부 촬영일","captured":"기기 제공 촬영일","added":"추가일 · 원본 촬영일 없음","modified":"수정일 · 원본 촬영일 없음","unknown":"날짜 없음"][item.dateSource ?? ""] ?? "기존 목록 날짜"}
    var sections:[PhotoSection]{
        let rows=filtered;guard grouping != "all" && sortKey != "name"else{return[PhotoSection(title:"",items:rows)]}
        let formatter=DateFormatter();formatter.dateFormat=grouping=="year" ? "yyyy년":grouping=="day" ? "yyyy년 M월 d일":"yyyy년 M월"
        var result:[PhotoSection]=[]
        for item in rows{let title=orderTime(item)>0 ? formatter.string(from:orderDate(item)):"날짜 없음";if result.last?.title==title{let old=result.removeLast();result.append(PhotoSection(title:title,items:old.items+[item]))}else{result.append(PhotoSection(title:title,items:[item]))}}
        return result
    }
    func configure(identity:Data){
        if !UserDefaults.standard.bool(forKey:"galleryCaptureSortRestoredV1"){sortKey="captured";ascending=false;grouping="all";UserDefaults.standard.set(true,forKey:"galleryCaptureSortRestoredV1")}
        captureDateUpdates=[:];bulkInfoToken=UUID();bulkInfoBusy=false;bulkInfoActive=false;bulkInfoDone=0;bulkInfoFailures=[];bulkInfoFailedPaths=[];bulkInfoStatus=""
        editedRefreshToken=UUID();editedRefreshActive=false;editedRefreshFailures=[]
        dateRetry=[];dateWorkRemaining=[];dateWorkToken=UUID();dateWorkFailures=[];dateWorkNotes=[];dateWorkActive=false;dateWorkStopped=true
        pageGeneration=UUID();cacheGeneration=UUID();changeTask?.cancel();originals.cancelAll();thumbnails.close();thumbnails.clear();closePreview()
        libraryDateToken=UUID();libraryDates=[:];libraryDateChecked=[]
        disk=PhotoLibraryCache(identity:identity);if let disk,let data=try?Data(contentsOf:disk.folder.appendingPathComponent("library-dates.json")),let dates=try?JSONDecoder().decode([String:Int64].self,from:data){libraryDates=dates};thumbnails.disk=disk;thumbnails.canFetch={ [weak self] in self?.loading != true };thumbnails.activity={ [weak self] pending,completed,failures in self?.thumbnailPending=pending;self?.thumbnailCompleted=completed;self?.thumbnailFailures=failures }
        originals.thumbnails=thumbnails;originals.cacheTarget={ [weak self] item in self?.disk?.originalURL(item) };originals.key={ [weak self] in self?.thumbnails.key?() ?? Data() };originals.progress={ [weak self] owner,value in guard let self else{return};self.originalProgress=value;if owner=="preview"{self.previewPhase="원본을 가져오는 중 · \(Int(value*100))%"}}
        pendingDeletes=disk?.pending ?? [];deleteCompleted=0;deleteActivity="";photoSyncActivity="";loading=false;caching=false;deletingIDs=[]
        albums=disk?.catalog.albums ?? [];applyView();refreshCacheUsage();refreshLibraryDates()
    }
    func retryThumbnails(){thumbnails.close(closeRemote:false);thumbnails.clear();applyView()}
    func appear(){visible=true;applyView();reload()}
    func disappear(){visible=false;closePreview();thumbnails.close(closeRemote:!caching)}
    func choose(_ scope:String="all",album:String=""){self.scope=scope;self.album=album;selection=[];search="";closePreview();applyView()}
    private func applyView(preservePreview:Bool=false){
        let pending=Set(pendingDeletes.filter{$0.phoneDeleted}.map{$0.item.cacheIdentity})
        var rows=(disk?.catalog.items ?? []).filter{!pending.contains($0.cacheIdentity) && (album.isEmpty || $0.album==album) && (scope != "videos" || $0.video) && (scope != "favorites" || $0.favorite) && (scope != "screenshots" || $0.album.localizedCaseInsensitiveContains("screenshot"))}
        rows.sort{a,b in
            if sortKey=="name"{return PhotoOrdering.filename(a.name,path:a.path,id:a.id,b.name,path:b.path,id:b.id,ascending:ascending)}
            let left=orderTime(a),right=orderTime(b)
            if (left>0) != (right>0){return left>0}
            if left != right{return ascending ? left<right:left>right}
            return PhotoOrdering.identifier(a.id,b.id,ascending:ascending)
        }
        if !preservePreview,let preview,!rows.contains(where:{$0.cacheIdentity==preview.cacheIdentity}){closePreview()}
        items=rows;albums=disk?.catalog.albums ?? [];total=rows.count;selection.formIntersection(Set(rows.map{$0.path}));revision+=1
        status=connected?()==true ? "\(rows.filter{!$0.video}.count)장의 사진, \(rows.filter{$0.video}.count)개의 비디오":"Mac에 저장된 목록 · 오프라인"
        if !pendingDeletes.isEmpty{status += " · 삭제 대기 \(pendingDeletes.count)개"}
    }
    func reconnected(){
        if let disk,!disk.catalog.items.isEmpty{
            let repairKey="captureDateCatalogRepairV1."+disk.folder.lastPathComponent
            if !UserDefaults.standard.bool(forKey:repairKey){
                do{try disk.setMetadataPaths(disk.metadataPaths.union(disk.catalog.items.filter{!$0.video}.map{$0.path}));UserDefaults.standard.set(true,forKey:repairKey)}catch{self.error="촬영일 재확인 대기를 저장하지 못했습니다"}
            }
        }
        if let disk,!disk.metadataPaths.isEmpty{bulkInfoActive=true;bulkInfoTotal=bulkInfoDone+disk.metadataPaths.count}
        editedRefreshFailures=[]
        if !pendingDeletes.isEmpty{retryDeletes(automatic:true)}
        reload()
    }
    func changed(){
        changeTask?.cancel()
        let task=DispatchWorkItem{[weak self]in self?.reload()};changeTask=task;DispatchQueue.main.asyncAfter(deadline:.now()+0.5,execute:task)
    }
    func reload(){
        guard connected?()==true,let disk else{applyView();return}
        if loading || !deletingIDs.isEmpty{refreshQueued=true;return}
        pageGeneration=UUID();let generation=pageGeneration;loading=true;error=nil;status=disk.catalog.dateSchema==7 ? "변경된 사진 확인 중…":"휴대폰 사진 날짜 갱신 중…"
        syncPage(offset:0,batch:"",generation:generation,staged:disk.catalog,changes:0)
    }
    private func syncPage(offset:Int,batch:String,generation:UUID,staged:PhotoCatalog,changes:Int){
        guard let disk else{return}
        rpc?.callPhoto("mediaSync",["since":disk.catalog.dateSchema==7 ? disk.catalog.revision:"","batch":batch,"offset":offset]){[weak self]r in
            guard let self,self.pageGeneration==generation,self.disk===disk else{return}
            guard r["ok"]as?Bool==true,let events=r["events"]as?[[String:Any]],let token=r["revision"]as?String,let batch=r["batch"]as?String else{self.loading=false;self.applyView();self.status=r["error"]as?String ?? "변경분을 갱신하지 못했습니다. 저장된 목록을 유지합니다.";return}
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
            value.synced=Date();value.dateSchema=r["dateSchema"]as?Int
            do{
                let old=disk.catalog.items
                let oldIDs=Set(old.map{$0.id});let additions=value.items.filter{!oldIDs.contains($0.id)}.count
                let previouslySynced=disk.catalog.synced != nil
                let oldAlbums=disk.catalog.albums
                let selectedIDs=Set(old.filter{self.selection.contains($0.path)}.map{$0.id})
                let relocated=old.filter{item in guard let current=rows[item.id]else{return false};return current.path != item.path || current.album != item.album}.count
                let albumChanges=Set(oldAlbums.map{$0.path}).symmetricDifference(Set(value.albums.map{$0.path})).count
                let wasInAlbum = !self.album.isEmpty
                var nextAlbum=self.album
                if !nextAlbum.isEmpty && !value.albums.contains(where:{$0.path==nextAlbum}){
                    let members=old.filter{$0.album==nextAlbum}
                    let current=members.compactMap{rows[$0.id]}
                    let destinations=Set(current.map{$0.album})
                    if !members.isEmpty,current.count==members.count,destinations.count==1,let destination=destinations.first,value.albums.contains(where:{$0.path==destination}){nextAlbum=destination}
                    else{nextAlbum=""}
                }
                let obsolete=old.filter{rows[$0.id]?.cacheIdentity != $0.cacheIdentity}
                let byPath=Dictionary(value.items.map{($0.path,$0)},uniquingKeysWith:{_,last in last})
                let reopen=self.preview.flatMap{item -> PhotoItem? in guard obsolete.contains(where:{$0.id==item.id})else{return nil};return rows[item.id] ?? byPath[item.path]}
                var refreshPaths=disk.refreshPaths.intersection(Set(value.items.map{$0.path}))
                for item in obsolete where disk.original(item,touch:false) != nil{if let current=rows[item.id] ?? byPath[item.path]{refreshPaths.insert(current.path)}}
                try disk.setRefreshPaths(refreshPaths)
                if !obsolete.isEmpty{
                    self.editedRefreshToken=UUID();self.editedRefreshActive=false;self.originals.cancel(owner:"edited-refresh")
                    let identities=Set(obsolete.map{$0.cacheIdentity})
                    if let preview=self.preview,identities.contains(preview.cacheIdentity){self.closePreview()}
                    if self.caching{self.cancelCache()}
                    self.thumbnails.close(closeRemote:false);self.thumbnails.clear()
                }
                // Keep the old revision until cleanup succeeds so reconnect can retry it.
                for item in obsolete{try disk.discard(item,trashOriginal:rows[item.id]==nil)}
                try disk.commit(value)
                self.album=nextAlbum
                if wasInAlbum && nextAlbum.isEmpty{self.scope="all"}
                self.selection=Set(value.items.filter{selectedIDs.contains($0.id)}.map{$0.path})
                if previouslySynced{
                    var messages:[String]=[]
                    if additions>0{messages.append("사진 추가·복원 \(additions)개")}
                    if relocated>0{messages.append("사진 이동·경로 변경 \(relocated)개")}
                    if albumChanges>0{messages.append("앨범 목록 갱신")}
                    let edits=obsolete.filter{rows[$0.id] != nil && rows[$0.id]?.path==$0.path}.count
                    if edits>0{messages.append("사진 편집·정보 변경 \(edits)개")}
                    if !messages.isEmpty{self.photoSyncActivity=messages.joined(separator:" · ")+" · Mac 자동 반영 완료"}
                }
                self.loading=false;self.applyView();self.status += value.dateSchema==7 ? (changes+events.count==0 ? " · 변경 없음":" · 변경분 \(changes+events.count)개 반영"):" · 휴대폰 앱도 업데이트해야 사진 날짜 정렬이 적용됩니다";self.refreshCacheUsage()
                self.refreshLibraryDates()
                if let reopen{self.open(reopen)}
                if self.infoShown{self.loadInfo()};self.processPendingDeletes();self.refreshEditedOriginals();self.processBulkInfo()
                if self.refreshQueued && self.deletingIDs.isEmpty{self.refreshQueued=false;self.reload()}
            }catch{self.loading=false;self.error="Mac 캐시 저장 또는 정리를 완료하지 못했습니다: \(error.localizedDescription)";self.applyView()}
        }
    }
    func select(_ paths:Set<String>){guard selection != paths else{return};selection=paths;if infoShown{loadInfo()}}
    func loadInfo(){
        let generation=UUID();infoGeneration=generation;infoFetchToken=UUID();infoRefreshing=false;originals.cancel(owner:"info-refresh");info=[:];infoStatus="촬영정보 확인 중…";latitude=nil;longitude=nil
        guard let item=selected.first,selected.count==1 else{return}
        if let values=disk?.details(item),hasCaptureInfo(values){applyInfo(values);recordCaptureDate(item,values)}
        if let url=disk?.original(item){readLocalInfo(item,url:url,generation:generation)}else{infoStatus="휴대폰 원본 정보 확인 중 · Mac 원본 확인 전"}
        guard connected?()==true else{if disk?.original(item)==nil{infoStatus="오프라인 · 원본 촬영정보 확인 전"};return}
        rpc?.callPhoto("mediaInfo",["path":item.path]){[weak self]response in
            guard let self,self.infoGeneration==generation else{return}
            guard let values=response["info"]as?[String:Any]else{self.infoStatus=response["error"]as?String ?? "휴대폰 원본 촬영정보 조회 실패";if !self.hasCaptureInfo(self.info){self.fetchInfoOriginal(item,generation:generation)};return}
            var strings=values.mapValues{String(describing:$0)};strings["infoSchema"]="2"
            self.applyInfo(strings);self.recordCaptureDate(item,strings)
            if let url=self.disk?.original(item){self.readLocalInfo(item,url:url,generation:generation)}else{self.infoStatus=strings["metadataError"] ?? "휴대폰 촬영정보 확인됨 · Mac 원본 확인 전";self.disk?.putDetails(self.info,item)}
            if !self.hasCaptureInfo(self.info){self.fetchInfoOriginal(item,generation:generation)}
        }
    }
    func refreshAllCachedInfo(){
        guard !bulkInfoActive,let disk else{return}
        let paths=Set(disk.catalog.items.filter{!$0.video}.map{$0.path})
        guard !paths.isEmpty else{error="Mac에 캐시된 사진이 없습니다";return}
        startBulkInfo(paths)
    }
    func retryBulkInfo(){startBulkInfo(bulkInfoFailedPaths)}
    private func startBulkInfo(_ paths:Set<String>){
        guard !bulkInfoBusy,!paths.isEmpty,let disk else{return}
        do{try disk.setMetadataPaths(paths);bulkInfoToken=UUID();bulkInfoTotal=paths.count;bulkInfoDone=0;bulkInfoMissing=0;bulkInfoFailures=[];bulkInfoFailedPaths=[];bulkInfoActive=true;bulkInfoStatus="촬영정보 전체 재조회 준비 · \(paths.count)개";processBulkInfo()}catch{self.error=error.localizedDescription}
    }
    func stopBulkInfo(){flushCaptureDates(updateView:true);bulkInfoToken=UUID();bulkInfoActive=false;bulkInfoBusy=false;originals.cancel(owner:"bulk-info");try?disk?.setMetadataPaths([]);bulkInfoStatus="촬영정보 전체 재조회 중단"}
    private func processBulkInfo(){
        guard bulkInfoActive,!bulkInfoBusy,!loading,connected?()==true,let disk else{return}
        guard let path=disk.metadataPaths.first else{flushCaptureDates(updateView:true);bulkInfoActive=false;bulkInfoStatus="촬영정보 재조회 완료 · 처리 \(bulkInfoDone)개 · 정보 없음 \(bulkInfoMissing)개 · 실패 \(bulkInfoFailures.count)개";return}
        guard let item=disk.catalog.items.first(where:{$0.path==path})else{do{try disk.setMetadataPaths(disk.metadataPaths.subtracting([path]));DispatchQueue.main.async{self.processBulkInfo()}}catch{bulkInfoActive=false;bulkInfoStatus=error.localizedDescription};return}
        bulkInfoBusy=true;let token=bulkInfoToken;bulkInfoStatus="촬영정보 재조회 \(bulkInfoDone+1)/\(bulkInfoTotal) · \(item.name)"
        func complete(_ values:[String:String]?,failure:String?=nil){
            guard self.disk===disk,self.bulkInfoToken==token else{return}
            if let failure{self.bulkInfoFailures.append("\(item.name): \(failure)");self.bulkInfoFailedPaths.insert(path)}else if let values{self.recordCaptureDate(disk.catalog.items.first(where:{$0.path==path}) ?? item,values);disk.putDetails(values,disk.catalog.items.first(where:{$0.path==path}) ?? item);if !self.hasCaptureInfo(values){self.bulkInfoMissing+=1}}
            do{try disk.setMetadataPaths(disk.metadataPaths.subtracting([path]),checkpoint:(self.bulkInfoDone+1)%20==0 || disk.metadataPaths.count<=1)}catch{self.bulkInfoActive=false;self.bulkInfoStatus="진행 기록 저장 실패: \(error.localizedDescription)"}
            self.bulkInfoDone+=1;if self.bulkInfoDone%20==0{self.flushCaptureDates(updateView:false)};self.bulkInfoBusy=false;disk.prune();self.refreshCacheUsage()
            if self.infoShown && self.selected.count==1 && self.selected.first?.path==path,let values{self.applyInfo(values);self.infoStatus="전체 재조회에서 최신 촬영정보 반영"}
            DispatchQueue.main.async{self.processBulkInfo()}
        }
        rpc?.callPhoto("mediaInfo",["path":path]){[weak self]response in
            guard let self,self.disk===disk,self.bulkInfoToken==token else{return}
            var values=(response["info"]as?[String:Any] ?? [:]).mapValues{String(describing:$0)};values["infoSchema"]="3"
            let location=values["locationAllowed"]=="1" || values["locationAllowed"]=="true"
            if let url=disk.original(item),let local=try?PhotoMetadata.image(url,location:location){values.merge(local,uniquingKeysWith:{old,new in old.isEmpty ? new:old})}
            if self.hasCaptureInfo(values){complete(values);return}
            guard item.size<=disk.budget else{complete(nil,failure:"원본 재조회에 필요한 캐시 한도 초과");return}
            self.originals.download(item,to:disk.originalURL(item),owner:"bulk-info"){result in
                guard self.disk===disk,self.bulkInfoToken==token else{return}
                switch result{
                case .failure(let error):complete(nil,failure:"휴대폰 원본 재조회 실패: \(error.localizedDescription)")
                case .success(let receipt):
                    do{try self.rememberOriginal(receipt.item);let local=try PhotoMetadata.image(receipt.url,location:location);values.merge(local,uniquingKeysWith:{old,new in old.isEmpty ? new:old});complete(values)}catch{complete(nil,failure:"원본 메타데이터 읽기 실패: \(error.localizedDescription)")}
                }
            }
        }
    }
    private var captureDateUpdates:[String:(PhotoItem,Int64,String)]=[:]
    private func recordCaptureDate(_ item:PhotoItem,_ values:[String:String]){
        // Metadata belongs to the inspector; the phone snapshot owns the library date.
    }

    private func flushCaptureDates(updateView:Bool){
        guard let disk,!captureDateUpdates.isEmpty else{return}
        var catalog=disk.catalog;var changed=false
        for i in catalog.items.indices{
            let current=catalog.items[i]
            guard let (expected,time,source)=captureDateUpdates[current.id],current.cacheIdentity==expected.cacheIdentity,let data=try?JSONEncoder().encode(current),let row=(try?JSONSerialization.jsonObject(with:data))as?[String:Any],let updatedRow=PhotoCaptureMetadata.updatedRecord(row,metadata:["captureTime":String(time),"captureSource":source=="captured" ? "media-store":source])else{continue}
            if let data=try?JSONSerialization.data(withJSONObject:updatedRow),let updated=try?JSONDecoder().decode(PhotoItem.self,from:data){catalog.items[i]=updated;changed=true}
        }
        do{if changed{try disk.commit(catalog)};captureDateUpdates=[:];if changed && updateView{applyView(preservePreview:true)}}catch{self.error="확인된 촬영일을 정렬 목록에 저장하지 못했습니다: \(error.localizedDescription)"}
    }
    private func hasCaptureInfo(_ values:[String:String])->Bool{["captured","camera","lens","make"].contains{!(values[$0] ?? "").isEmpty}}
    func refreshInfoOriginal(){
        guard let item=selected.first,selected.count==1 else{return}
        infoGeneration=UUID();infoFetchToken=UUID();infoRefreshing=false;originals.cancel(owner:"info-refresh")
        fetchInfoOriginal(item,generation:infoGeneration)
    }
    private func fetchInfoOriginal(_ item:PhotoItem,generation:UUID){
        guard generation==infoGeneration,!infoRefreshing,connected?()==true,let disk else{return}
        guard item.size<=disk.budget else{infoStatus="실제 원본 재조회에 필요한 캐시 용량이 부족합니다";return}
        infoRefreshing=true;infoStatus="휴대폰 실제 원본을 다시 받아 촬영정보 확인 중…"
        let token=UUID();infoFetchToken=token;let target=disk.originalURL(item);disk.protected.insert(target)
        // Deliberately bypass both cached details and the cached original shortcut.
        originals.download(item,to:target,owner:"info-refresh"){[weak self]result in
            guard let self,self.disk===disk,self.infoGeneration==generation,self.infoFetchToken==token else{return}
            self.infoRefreshing=false;disk.protected.remove(target)
            switch result{
            case .success(let receipt):
                do{try self.rememberOriginal(receipt.item);let permission=self.info["locationAllowed"];self.info=permission.map{["locationAllowed":$0]} ?? [:];self.latitude=nil;self.longitude=nil;self.readLocalInfo(receipt.item,url:receipt.url,generation:generation);if self.preview?.id==item.id{self.preview=receipt.item;self.show(receipt.item,url:receipt.url)};disk.prune(excluding:[receipt.url]);self.refreshCacheUsage()}catch{self.infoStatus="원본 촬영정보 갱신 실패: \(error.localizedDescription)"}
            case .failure(let error):self.infoStatus="실제 원본 재조회 실패: \(error.localizedDescription)"
            }
        }
    }
    private func applyInfo(_ values:[String:String]){
        info.merge(values,uniquingKeysWith:{_,new in new})
        if info["locationAllowed"]=="false" || info["locationAllowed"]=="0"{info.removeValue(forKey:"latitude");info.removeValue(forKey:"longitude")}
        latitude=info["latitude"].flatMap(Double.init);longitude=info["longitude"].flatMap(Double.init)
        if let a=latitude,let b=longitude{region.center=CLLocationCoordinate2D(latitude:a,longitude:b)}
    }
    private func readLocalInfo(_ item:PhotoItem,url:URL,generation:UUID){
        guard infoGeneration==generation else{return}
        if item.video{
            Task{ @MainActor [weak self] in
                guard let self else{return}
                do{let time=try await self.captureTimeFromOriginal(url,video:true);guard self.infoGeneration==generation else{return};if let time{let values=["captured":Date(timeIntervalSince1970:Double(time)/1000).formatted(),"infoSchema":"3","captureTime":String(time),"captureSource":"video"];self.applyInfo(values);self.recordCaptureDate(item,values)};self.infoStatus=time==nil ? "동영상 원본 확인됨 · 내부 촬영일 정보 없음":"동영상 원본 촬영정보 확인됨";self.disk?.putDetails(self.info,item)}catch{guard self.infoGeneration==generation else{return};self.infoStatus="동영상 원본 정보 읽기 실패: \(error.localizedDescription)"}
            };return
        }
        do{let values=try PhotoMetadata.image(url,location:info["locationAllowed"] != "false" && info["locationAllowed"] != "0");applyInfo(values);recordCaptureDate(item,values);disk?.putDetails(info,item);infoStatus=hasCaptureInfo(values) ? "Mac 실제 원본에서 촬영정보 확인됨":"Mac 실제 원본 확인됨 · 촬영일·카메라 정보 없음"}catch{infoStatus="원본 이미지 메타데이터 읽기 실패: \(error.localizedDescription)"}
    }

    func toggleInfo(){infoShown.toggle();if infoShown{loadInfo()}}
    func alignModifiedDates(_ target:String="selected",retryPaths:Set<String>=[]){
        let catalog=disk?.catalog.items ?? []
        let source: [PhotoItem]
        switch target{case "all":source=catalog;case "album":source=catalog.filter{$0.album==album};case "retry":source=catalog.filter{retryPaths.contains($0.path)};default:source=selected}
        let values=source.filter{$0.mime.hasPrefix("image/") || $0.video};guard !values.isEmpty else{error="대상 사진·동영상이 없습니다";return}
        guard connected?()==true,!caching,!moving,!loading else{error="휴대폰 연결 후 진행 중인 사진 작업을 마치세요";return}
        let alert=NSAlert();alert.messageText="사진·동영상 \(values.count)개의 파일 수정일을 맞출까요?";alert.informativeText="사진은 원본 EXIF 촬영일, 동영상은 원본 내부 촬영일·생성일을 직접 새로 읽고 \(values.count)개 항목을 처리합니다. 휴대폰에서 촬영일을 확인하지 못한 항목은 Mac으로 실제 원본을 받아 추가 확인합니다. 휴대폰 파일의 수정일을 바꾸며 사진·영상 내용과 내부 메타데이터는 유지합니다. 이전 수정일은 휴대폰 앱에 기록합니다.";alert.addButton(withTitle:"수정일 맞추기");alert.addButton(withTitle:"취소")
        if alert.runModal() == .alertFirstButtonReturn{closePreview();loading=true;dateWorkActive=true;dateWorkToken=UUID();dateWorkStopped=false;dateWorkTotal=values.count;dateWorkProgress=0;dateWorkFailures=[];dateWorkNotes=[];dateRetry=[];alignDateBatch(values,updated:0,skipped:0,failed:0)}
    }
    private func alignDateBatch(_ values:[PhotoItem],updated:Int,skipped:Int,failed:Int){
        guard let disk else{loading=false;dateWorkActive=false;return}
        dateWorkRemaining=values
        dateWorkProgress=Double(dateWorkTotal-values.count)/Double(max(1,dateWorkTotal))
        if dateWorkStopped{loading=false;dateWorkActive=false;status="수정일 정리 중단 · \(values.count)개 미처리";dateRetry.append(contentsOf:values);return}
        guard !values.isEmpty else{loading=false;dateWorkActive=false;dateAlignmentResult="변경 \(updated)개 · 건너뜀 \(skipped)개 · 실패 \(failed)개\n원본 촬영일이 없거나 이미 같은 수정일인 항목은 건너뜁니다. 추가일·가져온 날짜로 대체하지 않습니다.";reload();return}
        var selected:[PhotoItem]=[];var rows:[[String:Any]]=[]
        for item in values.prefix(20){let row:[String:Any]=["id":item.id,"path":item.path,"size":item.size,"modified":item.modified,"generation":item.generation ?? 0];if let data=try?JSONSerialization.data(withJSONObject:rows+[row]),data.count<=16000{selected.append(item);rows.append(row)}else{break}}
        guard !selected.isEmpty else{loading=false;dateWorkActive=false;error="선택한 파일 경로가 너무 깁니다";return}
        status="원본 촬영일로 사진·동영상 수정일 정리 중 · \(values.count)개 남음"
        let workToken=dateWorkToken
        rpc?.callPhoto("mediaAlignDates",["items":rows]){[weak self]r in
            guard let self,self.disk===disk,self.dateWorkToken==workToken else{return}
            guard r["ok"]as?Bool==true,let results=r["results"]as?[[String:Any]]else{self.loading=false;self.dateWorkActive=false;self.dateRetry.append(contentsOf:values);self.error=r["error"]as?String ?? "파일 수정일을 정리하지 못했습니다. 다시 시도할 수 있습니다";return}
            self.resolveDateOriginals(results,items:selected,token:workToken){results in
            guard self.disk===disk,self.dateWorkToken==workToken else{return}
            var changed=0,ignored=0,errors=0;var catalog=disk.catalog
            for result in results{
                if result["status"]as?String=="updated"{changed+=1}else if result["status"]as?String=="failed"{errors+=1;if let path=result["path"]as?String,let item=selected.first(where:{$0.path==path}){self.dateRetry.append(item);self.dateWorkFailures.append("\(item.name): \(result["error"]as?String ?? "처리 실패")")}}else{ignored+=1;if let path=result["path"]as?String,let item=selected.first(where:{$0.path==path}){self.dateWorkNotes.append("\(item.name): \(result["reason"]as?String ?? "건너뜀")")}}
                if let path=result["path"]as?String,let old=selected.first(where:{$0.path==path}),let value=result["item"],let data=try?JSONSerialization.data(withJSONObject:value),let item=try?JSONDecoder().decode(PhotoItem.self,from:data){do{try disk.rekey(old,item);if let index=catalog.items.firstIndex(where:{$0.path==path}){catalog.items[index]=item}}catch{errors+=1}}
            }
            do{try disk.commit(catalog)}catch{self.loading=false;self.dateWorkActive=false;self.error="휴대폰 날짜는 처리됐지만 Mac 캐시 기록을 갱신하지 못했습니다";return}
            self.alignDateBatch(Array(values.dropFirst(selected.count)),updated:updated+changed,skipped:skipped+ignored,failed:failed+errors)
            }
        }
    }
    private func resolveDateOriginals(_ results:[[String:Any]],items:[PhotoItem],token:UUID,done:@escaping([[String:Any]])->Void){
        guard token==dateWorkToken,let disk else{return}
        guard let index=results.firstIndex(where:{$0["status"]as?String=="needsOriginal"}),let path=results[index]["path"]as?String,let item=items.first(where:{$0.path==path})else{done(results);return}
        if dateWorkStopped{var output=results;for i in output.indices where output[i]["status"]as?String=="needsOriginal"{output[i]["status"]="failed";output[i]["error"]="원본 촬영정보 확인 전 중단됨"};done(output);return}
        status="썸네일 원본 촬영정보 확인 중 · \(item.name)"
        func complete(_ row:[String:Any]){disk.prune();self.refreshCacheUsage();var output=results;output[index]=row;self.resolveDateOriginals(output,items:items,token:token,done:done)}
        func read(_ url:URL,current:PhotoItem){
            Task{ @MainActor [weak self] in
                guard let self,self.dateWorkToken==token,self.disk===disk else{return}
                let timestamp:Int64?
                do{timestamp=try await self.captureTimeFromOriginal(url,video:current.video)}catch{complete(["path":path,"status":"failed","error":"실제 원본 메타데이터 읽기 실패: \(error.localizedDescription)"]);return}
                guard self.dateWorkToken==token,self.disk===disk else{return}
                guard let timestamp else{complete(["path":path,"status":"skipped","reason":"실제 원본 다운로드·메타데이터 확인 후에도 촬영일이 없습니다"]);return}
                let row:[String:Any]=["id":current.id,"path":current.path,"size":current.size,"modified":current.modified,"generation":current.generation ?? 0,"originalCaptureTime":timestamp,"captureSource":"mac-original","originalChecked":true]
                self.rpc?.callPhoto("mediaAlignDates",["items":[row]]){response in
                    guard self.dateWorkToken==token,self.disk===disk else{return}
                    if let rows=response["results"]as?[[String:Any]],let row=rows.first{complete(row)}else{complete(["path":path,"status":"failed","error":response["error"]as?String ?? "원본 확인 후 수정일 반영 실패"])}
                }
            }
        }
        if let url=disk.original(item){read(url,current:item);return}
        guard item.size<=disk.budget else{complete(["path":path,"status":"failed","error":"원본 확인에 필요한 파일이 Mac 캐시 한도를 초과합니다"]);return}
        originals.download(item,to:disk.originalURL(item),owner:"date-info"){[weak self]result in
            guard let self,self.dateWorkToken==token,self.disk===disk else{return}
            switch result{case .success(let receipt):read(receipt.url,current:receipt.item);case .failure(let error):complete(["path":path,"status":"failed","error":"원본 촬영정보 확인 실패: \(error.localizedDescription)"])}
        }
    }
    private func captureTimeFromOriginal(_ url:URL,video:Bool)async throws->Int64?{
        if video{let asset=AVURLAsset(url:url);if let value=try await asset.load(.creationDate),let date=try await value.load(.dateValue),date.timeIntervalSince1970>0{return Int64(date.timeIntervalSince1970*1000)};return nil}
        guard let source=CGImageSourceCreateWithURL(url as CFURL,nil),let properties=CGImageSourceCopyPropertiesAtIndex(source,0,nil)as?[String:Any]else{throw NSError(domain:"CoolSync",code:1,userInfo:[NSLocalizedDescriptionKey:"원본 이미지 메타데이터를 해석하지 못했습니다"])}
        guard let exif=properties[kCGImagePropertyExifDictionary as String]as?[String:Any],let text=exif[kCGImagePropertyExifDateTimeOriginal as String]as?String else{return nil}
        let formatter=DateFormatter();formatter.locale=Locale(identifier:"en_US_POSIX");formatter.isLenient=false;formatter.dateFormat="yyyy:MM:dd HH:mm:ss"
        if let offset=exif["OffsetTimeOriginal"]as?String{formatter.timeZone=TimeZone(identifier:"GMT"+offset)}
        guard let date=formatter.date(from:text),date.timeIntervalSince1970>0 else{return nil};return Int64(date.timeIntervalSince1970*1000)
    }
    func favorite(){guard !selection.isEmpty else{return};mutate("mediaFavorite",["paths":Array(selection),"value":!selected.allSatisfy{$0.favorite}])}
    private func mutate(_ op:String,_ fields:[String:Any],done:(([String:Any])->Void)?=nil){loading=true;status="사진 작업 중…";rpc?.callPhoto(op,fields){[weak self]r in guard let self else{return};self.loading=false;if r["ok"]as?Bool==true{done?(r);self.thumbnails.clear();self.reload()}else{self.error=r["error"]as?String ?? "사진 작업을 완료하지 못했습니다"}}}
    func remove(){
        let values=selected;guard !values.isEmpty else{return}
        let a=NSAlert();a.messageText="\(values.count)개 항목을 양쪽에서 삭제할까요?";a.informativeText="휴대폰 원본을 CoolSync 휴지통으로, Mac에 보관한 원본을 Mac 휴지통으로 옮깁니다. 연결이 끊겨 있으면 삭제를 대기합니다. Finder로 따로 내보낸 파일은 유지됩니다.";a.addButton(withTitle:"양쪽 휴지통으로 이동");a.addButton(withTitle:"취소")
        if a.runModal() == .alertFirstButtonReturn{enqueueDeletes(values)}
    }
    private func enqueueDeletes(_ values:[PhotoItem]){
        guard let disk else{return}
        var queue=pendingDeletes;let known=Set(queue.map{$0.item.cacheIdentity})
        queue += values.filter{!known.contains($0.cacheIdentity)}.map{PendingPhotoDelete(item:$0)}
        do{try disk.setPending(queue);pendingDeletes=queue;deleteActivity=connected?()==true ? "휴대폰 삭제 확인 대기":"연결되면 양쪽 삭제를 자동 처리합니다";closePreview();applyView();processPendingDeletes()}catch{self.error="삭제 대기를 저장하지 못했습니다. 파일은 삭제하지 않았습니다."}
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
        deletingIDs=Set(chosen.map{$0.id});let deleteToken=UUID();deleteRequestToken=deleteToken;deleteActivity="휴대폰 삭제 확인 중 · \(chosen.count)개";status=deleteActivity;objectWillChange.send()
        rpc?.callPhoto("mediaTrashChecked",["items":requests]){[weak self]r in
            guard let self,self.disk===disk,self.deleteRequestToken==deleteToken && !self.deletingIDs.isEmpty else{return};self.deletingIDs=[]
            var queue=self.pendingDeletes
            let results=r["results"]as?[[String:Any]] ?? []
            for request in chosen{
                guard let i=queue.firstIndex(where:{$0.id==request.id})else{continue}
                if let result=results.first(where:{$0["operation"]as?String==request.id}),result["ok"]as?Bool==true{queue[i].phoneDeleted=true;queue[i].error=nil;queue[i].errorCode=nil}
                else{let result=results.first(where:{$0["operation"]as?String==request.id});queue[i].errorCode=result?["code"]as?String ?? r["code"]as?String ?? "transport";queue[i].error=results.first(where:{$0["operation"]as?String==request.id})?["error"]as?String ?? r["error"]as?String ?? "휴대폰 처리 확인이 없습니다. 다시 시도하세요."}
            }
            do{try disk.setPending(queue);self.pendingDeletes=queue;if queue.contains(where:{$0.error != nil}){self.deleteActivity="일부 삭제 미반영 · 상태에서 이유를 확인하세요";self.showPendingDeletes=true};self.finishLocalDeletes()}catch{self.error="삭제 처리 상태를 Mac에 저장하지 못했습니다. 재연결 시 다시 확인합니다."}
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
            queue.removeAll{completed.contains($0.id)};try disk.setPending(queue);pendingDeletes=queue;deleteCompleted += completed.count;applyView();refreshCacheUsage()
            if !completed.isEmpty{deleteActivity="휴대폰·Mac 양쪽 반영 완료 \(deleteCompleted)개";refreshQueued=true}
            if !queue.isEmpty && deletingIDs.isEmpty{deleteActivity += " · 대기 \(queue.count)개"}
            processPendingDeletes()
        }catch{self.error="Mac 삭제 처리 기록을 저장하지 못했습니다. 다시 시도하세요."}
    }
    func canCancelDelete(_ value:PendingPhotoDelete)->Bool{!deletingIDs.contains(value.id) && !value.phoneDeleted}
    func retryDeletes(automatic:Bool=false){
        guard deletingIDs.isEmpty,let disk else{return}
        var queue=pendingDeletes
        for i in queue.indices where !automatic || automaticDeleteRetryAllowed(queue[i]){queue[i].error=nil;queue[i].errorCode=nil}
        do{try disk.setPending(queue);pendingDeletes=queue;deleteActivity=connected?()==true ? "삭제 대기를 자동 처리합니다":"연결되면 양쪽 삭제를 자동 처리합니다";processPendingDeletes()}catch{self.error=error.localizedDescription}
    }
    func cancelDelete(_ id:String){guard !deletingIDs.contains(id),!pendingDeletes.contains(where:{$0.id==id&&$0.phoneDeleted})else{return};do{let queue=pendingDeletes.filter{$0.id != id};try disk?.setPending(queue);pendingDeletes=queue;applyView()}catch{self.error=error.localizedDescription}}
    func albumCreate(){prompt("새 앨범",value:"새 앨범"){[weak self]name in self?.mutate("mediaAlbumCreate",["name":name]){r in self?.album=r["path"]as?String ?? "";self?.scope="all"}}}
    func albumRename(){guard !album.isEmpty else{return};prompt("앨범 이름 변경",value:album.components(separatedBy:"/").last ?? ""){[weak self]name in guard let self else{return};self.mutate("mediaAlbumRename",["path":self.album,"name":name]){r in self.album=r["path"]as?String ?? self.album}}}
    func albumDelete(){guard !album.isEmpty else{return};let a=NSAlert();a.messageText="앨범을 휴지통으로 이동할까요?";a.informativeText="휴대폰의 실제 앨범 폴더와 그 안의 모든 파일을 이동합니다. CoolSync 휴지통에서 복원할 수 있습니다.";a.addButton(withTitle:"이동");a.addButton(withTitle:"취소");if a.runModal() == .alertFirstButtonReturn{mutate("mediaAlbumTrash",["path":album]){[weak self]_ in self?.album=""}}}
    private func prompt(_ title:String,value:String,done:@escaping(String)->Void){let a=NSAlert();a.messageText=title;a.informativeText="휴대폰의 실제 사진 폴더에 적용합니다.";let field=NSTextField(string:value);field.frame=NSRect(x:0,y:0,width:280,height:26);a.accessoryView=field;a.window.initialFirstResponder=field;a.addButton(withTitle:"확인");a.addButton(withTitle:"취소");if a.runModal() == .alertFirstButtonReturn{done(field.stringValue)}}
    func move(to target:String,copy:Bool=false,paths:[String]?=nil){let paths=paths ?? Array(selection);guard !paths.isEmpty else{return};mutate(copy ? "mediaCopy":"mediaMove",["paths":paths,"destination":target])}
    func chooseImport(){let p=NSOpenPanel();p.allowsMultipleSelection=true;p.canChooseDirectories=false;p.allowedContentTypes=[.image,.movie];if p.runModal() == .OK{upload(p.urls)}}
    func upload(_ urls:[URL],to target:String?=nil){let folder=target ?? (album.isEmpty ? "Pictures/CoolSync":album);let valid=urls.filter{let type=UTType(filenameExtension:$0.pathExtension);return type?.conforms(to:.image)==true || type?.conforms(to:.movie)==true};guard !valid.isEmpty else{return};if folder=="Pictures/CoolSync"{rpc?.callPhoto("mediaAlbumCreate",["name":"CoolSync","reuse":true]){[weak self]r in if r["ok"]as?Bool==true || r["code"]as?String=="exists"{self?.startUpload(valid,to:folder)}}}else{startUpload(valid,to:folder)}}
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
        let exportDate=timelineTime(item)
        if let source=disk?.original(item){DispatchQueue.global(qos:.utility).async{let failure:Error?;do{try FileManager.default.copyItem(at:source,to:target);if item.modified>0{try FileManager.default.setAttributes([.modificationDate:Date(timeIntervalSince1970:Double(item.modified)/1000)],ofItemAtPath:target.path)};try PhotoLibraryDates.applyExportDate(exportDate,to:target);failure=nil}catch{failure=error};DispatchQueue.main.async{completion(failure)}};return}
        guard connected?()==true else{completion(NSError(domain:"CoolSync",code:1,userInfo:[NSLocalizedDescriptionKey:"이 원본은 Mac에 보관되지 않았습니다. 휴대폰을 연결하세요."]));return}
        originals.download(item,to:target,owner:"export."+UUID().uuidString){[weak self]result in
            switch result{case .success(let receipt):do{try self?.rememberOriginal(receipt.item);try PhotoLibraryDates.applyExportDate(exportDate,to:target);completion(nil)}catch{completion(error)};case .failure(let error):completion(error)}
        }
    }
    private func rememberOriginal(_ item:PhotoItem)throws{
        guard let disk else{return};var catalog=disk.catalog
        if let index=catalog.items.firstIndex(where:{$0.id==item.id}),catalog.items[index] != item{let old=catalog.items[index];catalog.items[index]=item;try disk.commit(catalog);if old.cacheIdentity != item.cacheIdentity{try disk.discard(old,trashOriginal:false)};if !bulkInfoActive{applyView(preservePreview:true)}}
    }

    func isCached(_ item:PhotoItem)->Bool{disk?.original(item,touch:false) != nil}
    func cacheSelection(){
        guard connected?()==true,!caching else{error="휴대폰 연결과 원본 보관 상태를 확인하세요";return}
        let values=selected;guard !values.isEmpty,let disk else{return};guard values.reduce(Int64(0),{$0+$1.size})<=disk.budget else{error="선택한 원본이 캐시 한도를 초과합니다. 설정에서 한도를 늘리거나 선택을 줄이세요.";return};caching=true;cacheGeneration=UUID();cacheNext(values,generation:cacheGeneration)
    }
    private func cacheNext(_ values:[PhotoItem],generation:UUID){
        guard caching,cacheGeneration==generation,let disk else{return}
        let remaining=values.drop(while:{disk.original($0) != nil})
        guard let item=remaining.first else{caching=false;disk.protected=Set(preview.map{[disk.originalURL($0)]} ?? []);disk.prune();refreshCacheUsage();status="선택한 원본 보관 완료 · 오래된 캐시는 용량 한도에 따라 정리됩니다";return}
        guard connected?()==true else{caching=false;return};status="원본 보관 중 · \(item.name)"
        let target=disk.originalURL(item);disk.protected=[target]
        originals.download(item,to:target,owner:"cache"){[weak self]result in
            guard let self,self.cacheGeneration==generation,self.disk===disk else{return}
            switch result{
            case .failure(let error):self.caching=false;disk.protected=Set(self.preview.map{[disk.originalURL($0)]} ?? []);disk.prune();self.error=error.localizedDescription
            case .success(let receipt):do{try self.rememberOriginal(receipt.item);disk.touch(receipt.url);disk.protected=[receipt.url];disk.prune(excluding:[receipt.url]);self.cacheNext(Array(remaining.dropFirst()),generation:generation)}catch{self.caching=false;self.error=error.localizedDescription}
            }
        }
    }

    func cancelCache(){cacheGeneration=UUID();caching=false;originals.cancel(owner:"cache");disk?.protected=Set(preview.flatMap{item in disk.map{[$0.originalURL(item),$0.motionURL(item)]}} ?? []);disk?.prune();refreshCacheUsage();status="원본 보관을 취소했습니다"}
    var sortTitle:String{if sortKey=="name"{return "파일명 · "+(ascending ? "오름차순":"내림차순")};return (scope=="recent" || sortKey=="added" ? "추가일":"생성일")+" · "+(ascending ? "오래된순":"최신순")}
    func refreshCacheUsage(){guard let disk else{return};cacheSummary=ByteCountFormatter.string(fromByteCount:disk.bytes,countStyle:.file)+" / "+ByteCountFormatter.string(fromByteCount:disk.budget,countStyle:.file)}
    func clearCache(){
        guard !caching,!moving,!previewLoading,files?.hasTransfer != true else{error="진행 중인 전송을 마친 뒤 캐시를 정리하세요";return}
        let a=NSAlert();a.messageText="Mac 캐시만 비울까요?";a.informativeText="Mac에 임시 보관한 사진 원본·썸네일·촬영 정보만 비웁니다. 휴대폰 원본, 삭제 대기 목록, Finder로 내보낸 파일은 유지됩니다.";a.addButton(withTitle:"캐시만 비우기");a.addButton(withTitle:"취소")
        if a.runModal() == .alertFirstButtonReturn{do{closePreview();try disk?.clearFiles();thumbnails.clear();revision+=1;refreshCacheUsage()}catch{self.error=error.localizedDescription}}
    }
    func open(_ item:PhotoItem){
        closePreview();previewPhase="원본 요청 준비 중…";originalProgress=0;preview=item;selection=[item.path];previewLoading=true;previewError="";if infoShown{loadInfo()}
        guard let disk else{previewLoading=false;previewError="사진 캐시를 열지 못했습니다";return}
        if let target=disk.original(item){disk.protected=[target];show(item,url:target);return}
        guard connected?()==true else{previewLoading=false;previewError="이 원본은 Mac에 보관되지 않았습니다. 휴대폰 연결 후 열거나 ‘선택 원본 보관’을 사용하세요.";return}
        let target=disk.originalURL(item);disk.protected=[target]
        let generation=previewGeneration
        originals.download(item,to:target,owner:"preview"){[weak self]result in
            guard let self,self.previewGeneration==generation,self.preview?.path==item.path,self.disk===disk else{return}
            switch result{
            case .failure(let error):self.previewLoading=false;self.previewError=error.localizedDescription
            case .success(let receipt):do{try self.rememberOriginal(receipt.item);self.preview=receipt.item;disk.touch(receipt.url);disk.protected=[receipt.url];disk.prune(excluding:[receipt.url]);self.refreshCacheUsage();self.show(receipt.item,url:receipt.url);self.refreshEditedOriginals()}catch{self.previewLoading=false;self.previewError=error.localizedDescription}
            }
        }
    }

    private func show(_ item:PhotoItem,url:URL){
        if infoShown{readLocalInfo(item,url:url,generation:infoGeneration)}
        previewLoading=false;let generation=previewGeneration
        if item.video{
            let asset=AVURLAsset(url:url)
            Task{ @MainActor [weak self] in let playable=(try?await asset.load(.isPlayable)) ?? false;guard let self,self.previewGeneration==generation else{return};if playable{self.player=AVPlayer(url:url);self.player?.play()}else{self.previewError="이 Mac에서 재생할 수 없는 영상 형식입니다. Mac으로 저장한 뒤 다른 플레이어로 열어보세요."}}
            return
        }
        previewImage=NSImage(contentsOf:url)
        if previewImage==nil{previewError="이 Mac에서 표시할 수 없는 이미지입니다";return}
        guard let disk else{return};motionLoading=true
        let target=disk.motionURL(item)
        let extraction=Task.detached(priority:.utility){try MotionPhotoReader.extract(from:url,to:target)};motionExtraction=extraction
        Task{ @MainActor [weak self] in
            let result:URL?;let failure:String?
            do{result=try await extraction.value;failure=nil}catch is CancellationError{return}catch{result=nil;failure="모션 포토 영상을 읽지 못했습니다."}
            let playable:Bool
            if let result{playable=(try?await AVURLAsset(url:result).load(.isPlayable)) ?? false}else{playable=false}
            guard let self,self.previewGeneration==generation,self.disk===disk else{if !disk.catalog.items.contains(where:{$0.cacheIdentity==item.cacheIdentity}){try?disk.discard(item,trashOriginal:false)};disk.prune();return}
            self.motionLoading=false;self.motionExtraction=nil
            if let result,playable{self.motionURL=result;self.motionAvailable=true;disk.touch(result);disk.protected.formUnion([url,result]);disk.prune();self.revision+=1}
            else if result != nil{self.motionError="이 Mac에서 모션 포토 영상 형식을 재생할 수 없습니다."}
            else{self.motionError=failure ?? ""}
            self.refreshCacheUsage()
        }
    }

    func hasMotion(_ item:PhotoItem)->Bool{guard let disk else{return false};return FileManager.default.fileExists(atPath:disk.motionURL(item).path)}
    func togglePlayback(){
        if preview?.video==true{if player?.timeControlStatus == .playing{player?.pause()}else{player?.play()};return}
        guard motionAvailable,let url=motionURL else{return}
        if motionPlaying{player?.pause();player=nil;motionPlaying=false;return}
        let next=AVPlayer(url:url);player=next;motionPlaying=true
        if let motionEndObserver{NotificationCenter.default.removeObserver(motionEndObserver)}
        let generation=previewGeneration
        motionEndObserver=NotificationCenter.default.addObserver(forName:.AVPlayerItemDidPlayToEndTime,object:next.currentItem,queue:.main){[weak self]_ in guard let self,self.previewGeneration==generation else{return};self.player=nil;self.motionPlaying=false}
        next.play()
    }
    func closePreview(){
        previewGeneration=UUID();motionExtraction?.cancel();motionExtraction=nil
        if let motionEndObserver{NotificationCenter.default.removeObserver(motionEndObserver)};motionEndObserver=nil
        originals.cancel(owner:"preview")
        player?.pause();player=nil;preview=nil;previewImage=nil;previewLoading=false;previewError="";motionURL=nil;motionAvailable=false;motionLoading=false;motionPlaying=false;motionError="";disk?.protected=[];disk?.prune()
    }
    func canNavigatePreview(_ delta:Int)->Bool{guard let item=preview,let i=filtered.firstIndex(where:{$0.path==item.path})else{return false};return filtered.indices.contains(i+delta)}
    func nextPreview(_ delta:Int){guard let item=preview,let i=filtered.firstIndex(where:{$0.path==item.path}),filtered.indices.contains(i+delta)else{return};open(filtered[i+delta])}
    func connectionEnded(){flushCaptureDates(updateView:true);bulkInfoToken=UUID();bulkInfoBusy=false;if bulkInfoActive{bulkInfoStatus="연결되면 남은 촬영정보를 자동 재조회합니다"};infoFetchToken=UUID();infoRefreshing=false;editedRefreshToken=UUID();editedRefreshActive=false;deleteRequestToken=UUID();if !pendingDeletes.isEmpty{deleteActivity="연결되면 남은 삭제를 자동 처리합니다"};if dateWorkActive{dateRetry.append(contentsOf:dateWorkRemaining)};dateWorkRemaining=[];dateWorkToken=UUID();dateWorkStopped=true;dateWorkActive=false;pageGeneration=UUID();infoGeneration=UUID();cacheGeneration=UUID();closePreview();originals.cancelAll();changeTask?.cancel();thumbnails.close();loading=false;moving=false;caching=false;deletingIDs=[];closePreview();applyView()}
    func imported(){changed()}
}
