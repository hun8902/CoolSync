import Foundation
import AppKit
import CryptoKit

struct PhotoSyncEvent:Identifiable {let id=UUID();let date=Date();let text:String}
enum PhotoSyncPhase:String,Codable {case idle,connecting,catalog,previews,ready,failed,canceled,disconnected,cached}
struct PhotoSyncState {
    var phase:PhotoSyncPhase = .idle
    var received=0;var total:Int?;var pages=0;var nextOffset=0
    var started:Date?;var updated:Date?;var message="사진 보관함을 열면 휴대폰 목록을 불러옵니다"
    var dateWarning:String?
    var issue:String?;var issueCode="";var cached=false
    var previewRequested=0;var previewFinished=0;var previewFailed=0
    var device:GalleryDeviceState?
    var busy:Bool{phase == .connecting || phase == .catalog || phase == .previews}
    var fraction:Double?{guard let total,total>0 else{return nil};return min(1,Double(received)/Double(total))}
}
struct PhotoCatalogCache:Codable {let updated:Date;let items:[GalleryItem]}

extension GalleryModel {
    func event(_ text:String){syncEvents.append(PhotoSyncEvent(text:text));if syncEvents.count>80{syncEvents.removeFirst(syncEvents.count-80)}}
    var syncDiagnostics:String{let formatter=ISO8601DateFormatter();var values=["CoolSync photo diagnostics","Mac build: "+(Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion")as?String ?? "test"),"Phase: "+sync.phase.rawValue,"Catalog: \(sync.received)/\(sync.total.map(String.init) ?? "unknown") · page \(sync.pages)","Previews: \(sync.previewFinished)/\(sync.previewRequested), failed \(sync.previewFailed)","Error code: "+sync.issueCode];if let device=sync.device{values.append("Android build: \(device.build), screen on: \(device.interactive), locked: \(device.locked), first unlock: \(device.userUnlocked), file access: \(device.storage), battery exempt: \(device.batteryExempt)")};values+=syncEvents.map{formatter.string(from:$0.date)+" "+$0.text};return values.joined(separator:"\n")}
    func copySyncDiagnostics(){NSPasteboard.general.clearContents();NSPasteboard.general.setString(syncDiagnostics,forType:.string)}
    func ensureLoaded(){if !loading && (items.isEmpty || sync.cached || sync.phase == .idle || sync.phase == .disconnected){reload()}}
    func readGallery(_ op:String,_ fields:[String:Any],completion:@escaping([String:Any])->Void){if let readOverride{readOverride(op,fields,completion);return};transport.call(op,fields,completion:completion)}
    func beginPhotoLoad(resume:Bool=false){
        if loading{return}
        guard explorer.connected?()==true else{sync.phase = .disconnected;sync.message="휴대폰 연결을 기다리고 있습니다";sync.issue="CoolSync의 연결 화면에서 휴대폰 연결 상태를 확인하세요";sync.issueCode="disconnected";status=sync.message;event("disconnected before catalog request");return}
        generation=UUID();queue=[];waiting=[];fetching=false;previewRequested=[];previewFinished=[];thumbnailErrors=[:];sync.previewRequested=0;sync.previewFinished=0;sync.previewFailed=0
        loading=true;sync.dateWarning=nil;sync.started=Date();sync.issue=nil;sync.issueCode="";sync.phase = .connecting;sync.message="휴대폰 사진 연결 준비 중…";status=sync.message
        if !resume{sync.nextOffset=0;sync.received=0;sync.pages=0;sync.total=nil;catalogPending=[];transport.invalidate()}else{catalogPending=items}
        event(resume ? "resume catalog at \(sync.nextOffset)":"start catalog refresh")
        page(resume ? sync.nextOffset:0,generation)
    }
    func cancelPhotoLoad(){generation=UUID();transport.invalidate();loading=false;queue=[];waiting=[];fetching=false;sync.phase = .canceled;sync.message="사진 불러오기를 중단했습니다 · 받은 \(items.count)개는 표시합니다";status=sync.message;event("catalog canceled by user")}
    func resumePhotoLoad(){beginPhotoLoad(resume:sync.nextOffset>0)}
    func retryPhotoLoad(){if loading{cancelPhotoLoad()};beginPhotoLoad()}
    func failPhotoLoad(_ code:String,_ text:String){loading=false;sync.phase = .failed;sync.issueCode=code;sync.issue=text;sync.message="사진 불러오기 실패 · \(sync.received)개 수신";status=text;event("catalog failed: "+code)}
    func page(_ offset:Int,_ token:UUID){
        sync.phase = .catalog;sync.message=sync.total.map{"사진 목록 받는 중 · \(sync.received)/\($0)개"} ?? "휴대폰 사진 목록을 요청했습니다 · 응답 대기 중";status=sync.message
        readGallery("gallery",["offset":offset,"limit":offset==0 ? 1:200]){[weak self]response in
            guard let self,self.generation==token,self.loading else{return}
            guard response["ok"]as?Bool==true else{let code=response["code"]as?String ?? "response";let text=response["error"]as?String ?? "휴대폰이 사진 목록을 반환하지 않았습니다";self.failPhotoLoad(code,text);return}
            do{
                guard let rows=response["items"]else{throw GalleryNetworkError.unavailable("사진 응답에 목록이 없습니다 · Android와 Mac을 함께 업데이트하세요")}
                let data=try JSONSerialization.data(withJSONObject:rows);let values=try JSONDecoder().decode([GalleryItem].self,from:data)
                if let source=response["dateStatus"]as?String{self.event("date source: Samsung \(source), matched \(response["samsungDates"]as?Int ?? 0)/\(values.count), original recovered \(response["originalDates"]as?Int ?? 0)");if !["available","empty"].contains(source){self.sync.dateWarning="삼성 전용 날짜 DB 접근 불가 (\(source)) · 기본 목록·원본 촬영일로 표시 중"}}
                let next=(response["next"]as?NSNumber)?.intValue ?? offset+values.count,total=(response["total"]as?NSNumber)?.intValue ?? next
                guard next>=offset,total>=0,next<=total,next>offset || next>=total else{throw GalleryNetworkError.unavailable("사진 목록의 다음 페이지 정보가 올바르지 않습니다")}
                let known=Set(self.catalogPending.map{$0.id});self.catalogPending+=values.filter{!known.contains($0.id)};self.items=self.catalogPending
                self.sync.received=self.items.count;self.sync.total=total;self.sync.nextOffset=next;self.sync.pages+=1;self.sync.updated=Date();self.sync.cached=false
                self.event("catalog page \(self.sync.pages): \(values.count) rows, cursor \(next)/\(total)")
                if next<total{self.page(next,token)}else{self.loading=false;self.sync.phase = self.queue.isEmpty && !self.fetching ? .ready:.previews;self.sync.message=self.items.isEmpty ? "휴대폰 사진 목록을 정상적으로 확인했습니다 · 사진 0개":"사진 목록 수신 완료 · \(self.items.count)개";self.status=self.sync.message;self.saveCatalogCache();self.event("catalog complete: \(self.items.count) items");for item in self.visible.prefix(80) where self.thumbnails[item.id]==nil && self.thumbnailErrors[item.id]==nil{self.thumb(item)}}
            }catch{self.failPhotoLoad("decode",error.localizedDescription)}
        }
    }
    func saveCatalogCache(){let value=PhotoCatalogCache(updated:Date(),items:items);if let data=try?JSONEncoder().encode(value){try?data.write(to:store.folder.appendingPathComponent("catalog.json"),options:.atomic)}}
    func readCatalogCache(){let url=store.folder.appendingPathComponent("catalog.json");guard let data=try?Data(contentsOf:url),let value=try?JSONDecoder().decode(PhotoCatalogCache.self,from:data)else{return};items=value.items;sync.cached=true;sync.received=items.count;sync.total=items.count;sync.updated=value.updated;sync.phase = .cached;sync.message="저장된 목록 \(items.count)개 · 연결 후 최신 목록을 확인합니다";status=sync.message}
    func thumbnailURL(_ item:GalleryItem)->URL{let key=SHA256.hash(data:Data((item.id+"|"+item.path+"|\(item.size)|\(item.taken)").utf8)).map{String(format:"%02x",$0)}.joined();let directory=store.folder.appendingPathComponent("Previews");try?FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true);return directory.appendingPathComponent(key+".jpg")}
    func retryThumbnail(_ item:GalleryItem){thumbnailErrors.removeValue(forKey:item.id);waiting.remove(item.id);thumb(item)}
    func retryFailedPreviews(){let ids=Set(thumbnailErrors.keys);for item in visible where ids.contains(item.id){retryThumbnail(item)}}
    func thumbnailProgress(){sync.previewRequested=previewRequested.count;sync.previewFinished=previewFinished.count;sync.previewFailed=thumbnailErrors.count;if !loading && sync.phase != .failed && sync.phase != .canceled && sync.phase != .disconnected{sync.phase=fetching || !queue.isEmpty ? .previews:.ready};if sync.phase == .previews{sync.message="미리보기 받는 중 · \(sync.previewFinished)/\(sync.previewRequested)개"}else if sync.phase == .ready{sync.message=sync.previewFailed>0 ? "사진 목록 수신 완료 · 미리보기 \(sync.previewFailed)개 실패":"사진 목록·미리보기 수신 완료 · \(items.count)개"}}
}
