import Foundation
import CryptoKit

struct GalleryEndpoint:Decodable {let hosts:[String];let port:Int;let token:String;var state:GalleryDeviceState?;var catalogAPI:Int?}
struct GalleryDeviceState:Decodable {let interactive:Bool;let locked:Bool;let userUnlocked:Bool;let storage:Bool;let batteryExempt:Bool;let powerSave:Bool;let build:Int}
enum GalleryNetworkError:LocalizedError{case unavailable(String);var errorDescription:String?{switch self{case .unavailable(let text):return text}}}

/// Reuses the pre-removal gallery protocol: mediaSession + authenticated HTTP + per-request AES-GCM.
final class GalleryTransport {
    var key:(()->Data)?
    var bootstrap:((@escaping([String:Any])->Void)->Void)?
    var legacyCatalog:(([String:Any],@escaping([String:Any])->Void)->Void)?
    var onState:((GalleryDeviceState)->Void)?
    private var endpoint:GalleryEndpoint?
    private var lastUse=Date.distantPast
    private var generation=UUID()
    private var preparing=false
    private var waiting:[(Result<Void,Error>)->Void]=[]
    private var requests:[UUID:URLSessionDataTask]=[:]
    private let session:URLSession={let configuration=URLSessionConfiguration.ephemeral;configuration.timeoutIntervalForRequest=15;configuration.timeoutIntervalForResource=20;configuration.httpMaximumConnectionsPerHost=2;configuration.requestCachePolicy = .reloadIgnoringLocalCacheData;return URLSession(configuration:configuration)}()
    func invalidate(){generation=UUID();endpoint=nil;lastUse = .distantPast;preparing=false;waiting=[];let active=Array(requests.values);requests=[:];active.forEach{$0.cancel()}}
    func prepare(completion:@escaping(Result<Void,Error>)->Void){
        if endpoint != nil,Date().timeIntervalSince(lastUse)<50{completion(.success(()));return}
        waiting.append(completion);guard !preparing else{return};preparing=true;let epoch=generation
        guard let bootstrap else{finishPrepare(.failure(GalleryNetworkError.unavailable("사진 연결 정보가 준비되지 않았습니다")));return}
        bootstrap{[weak self]response in guard let self,self.generation==epoch else{return}
            do{guard response["ok"]as?Bool==true else{let code=response["code"]as?String ?? "connection";let message=code=="operation" ? "휴대폰 CoolSync에 사진 전송 기능이 없습니다 · Android 앱도 최신 빌드로 업데이트하세요":response["error"]as?String ?? "사진 연결 정보를 받지 못했습니다";throw NSError(domain:"Gallery",code:1,userInfo:[NSLocalizedDescriptionKey:message,"galleryCode":code])}
                let value=response["endpoint"] ?? response;let data=try JSONSerialization.data(withJSONObject:value);let endpoint=try JSONDecoder().decode(GalleryEndpoint.self,from:data);guard (1...65535).contains(endpoint.port),!endpoint.token.isEmpty,endpoint.hosts.contains(where:Self.local)else{throw GalleryNetworkError.unavailable("사진 연결 주소가 올바르지 않습니다")};self.endpoint=endpoint;self.lastUse=Date();if let state=endpoint.state{self.onState?(state)};self.finishPrepare(.success(()))
            }catch{self.finishPrepare(.failure(error))}
        }
    }
    private func finishPrepare(_ result:Result<Void,Error>){preparing=false;let callbacks=waiting;waiting=[];callbacks.forEach{$0(result)}}
    func call(_ op:String,_ fields:[String:Any]=[:],completion:@escaping([String:Any])->Void){prepare{[weak self]result in guard let self else{return};switch result{case .failure(let error):completion(["ok":false,"code":(error as NSError).userInfo["galleryCode"]as?String ?? "connection","error":error.localizedDescription]);case .success:
        guard let endpoint=self.endpoint else{completion(["ok":false,"code":"endpoint","error":"사진 연결 정보가 없습니다"]);return}
        if op=="gallery",(endpoint.catalogAPI ?? 0)<1,let legacy=self.legacyCatalog{legacy(fields,completion);return}
        self.fetch(op,fields,endpoint:endpoint,hosts:endpoint.hosts.filter(Self.local),epoch:self.generation,completion:completion)
    }}}
    private func fetch(_ op:String,_ fields:[String:Any],endpoint:GalleryEndpoint,hosts:[String],epoch:UUID,completion:@escaping([String:Any])->Void){
        guard generation==epoch else{return}
        guard let host=hosts.first,let key=key?(),key.count==32,let url=URL(string:"http://\(host):\(endpoint.port)/\(op=="galleryThumb" ? "thumbnail":"catalog")")else{completion(["ok":false,"code":"session","error":"휴대폰 사진 연결과 같은 Wi-Fi를 확인하세요"]);return}
        var query=fields;query["token"]=endpoint.token;query["op"]=op
        var message=Wire.Message(type:op=="galleryThumb" ? "mediaThumb":"mediaCatalog")
        guard let body=try?JSONSerialization.data(withJSONObject:query)else{completion(["ok":false,"code":"request","error":"사진 요청을 만들지 못했습니다"]);return};message.text=String(data:body,encoding:.utf8) ?? ""
        guard let payload=try?Wire.seal(message,key:key)else{completion(["ok":false,"code":"authentication","error":"사진 요청을 암호화하지 못했습니다"]);return}
        var request=URLRequest(url:url);request.httpMethod="POST";request.httpBody=payload;request.setValue("application/octet-stream",forHTTPHeaderField:"Content-Type")
        let requestID=UUID(),reference=message.id
        let task=session.dataTask(with:request){[weak self]data,response,error in
            var parsed:[String:Any]?
            if error==nil,(response as?HTTPURLResponse)?.statusCode==200,let data,data.count<=512000,let box=try?AES.GCM.SealedBox(combined:data),let clear=try?AES.GCM.open(box,using:SymmetricKey(data:key),authenticating:Data("CoolSync/media/1|\(reference)".utf8)){
                if op=="galleryThumb",clear.count<=128000{parsed=["ok":true,"image":clear.base64EncodedString()]}else{parsed=(try?JSONSerialization.jsonObject(with:clear))as?[String:Any]}
            }
            DispatchQueue.main.async{guard let self,self.generation==epoch else{return};self.requests.removeValue(forKey:requestID);if let parsed{self.lastUse=Date();completion(parsed)}else if hosts.count>1{self.fetch(op,fields,endpoint:endpoint,hosts:Array(hosts.dropFirst()),epoch:epoch,completion:completion)}else{self.endpoint=nil;let status=(response as?HTTPURLResponse)?.statusCode;let code=status==403 ? "permission":status==404 ? "missing":"wifi";let text=status==403 ? "휴대폰 사진·파일 접근 권한을 확인하세요":status==404 ? "휴대폰에서 사진 파일을 찾지 못했습니다":"사진 전송 응답을 받지 못했습니다 · 같은 Wi-Fi와 로컬 네트워크 접근을 확인한 뒤 다시 시도하세요";completion(["ok":false,"code":code,"error":text])}}
        };requests[requestID]=task;task.resume()
    }
    static func local(_ value:String)->Bool{let a=value.split(separator:".").compactMap{Int($0)};guard a.count==4,a.allSatisfy({(0...255).contains($0)})else{return false}
        #if COOLSYNC_TESTING
        if a[0]==127{return true}
        #endif
        return a[0]==10 || a[0]==192 && a[1]==168 || a[0]==172 && (16...31).contains(a[1]) || a[0]==169 && a[1]==254
    }
}
