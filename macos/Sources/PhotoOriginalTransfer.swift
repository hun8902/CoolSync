import Foundation
import CryptoKit

struct PhotoOriginalReceipt {let item:PhotoItem;let url:URL}

/// Ordinary file jobs and original previews own separate requests and cancellation.
final class PhotoOriginals {
    struct Job {let id=UUID();let item:PhotoItem;let target:URL;let owner:String;let completion:(Result<PhotoOriginalReceipt,Error>)->Void}
    weak var thumbnails:PhotoThumbnails?
    var key:(()->Data)?
    var cacheTarget:((PhotoItem)->URL?)?
    var progress:((String,Double)->Void)?
    private var waiting:[Job]=[]
    private var active:[UUID:(Job,PhotoOriginalTransfer?)]=[:]
    func download(_ item:PhotoItem,to target:URL,owner:String,completion:@escaping(Result<PhotoOriginalReceipt,Error>)->Void){
        if owner=="preview"{cancel(owner:owner)}
        let job=Job(item:item,target:target,owner:owner,completion:completion)
        if owner=="preview"{waiting.insert(job,at:0)}else{waiting.append(job)};pump()
    }
    func cancel(owner:String){
        let queued=waiting.filter{$0.owner==owner};waiting.removeAll{$0.owner==owner}
        let running=active.values.filter{$0.0.owner==owner}
        for(job,task)in running{active.removeValue(forKey:job.id);task?.cancel();job.completion(.failure(CocoaError(.userCancelled)))}
        queued.forEach{$0.completion(.failure(CocoaError(.userCancelled)))}
        DispatchQueue.main.async{[weak self]in self?.pump()}
    }
    func cancelAll(){let owners=Set(waiting.map{$0.owner}+active.values.map{$0.0.owner});for owner in owners{cancel(owner:owner)}}
    private func pump(){while active.count<2 && !waiting.isEmpty{let job=waiting.removeFirst();active[job.id]=(job,nil);endpoint(job,refresh:false)}}
    private func endpoint(_ job:Job,refresh:Bool){
        if refresh{thumbnails?.invalidateEndpoint()}
        thumbnails?.withEndpoint{[weak self]endpoint in
            guard let self,self.active[job.id] != nil else{return}
            guard let endpoint else{self.finish(job,nil,CocoaError(.fileReadUnknown));return}
            if (endpoint["originalAPI"]as?Int ?? 0)<2{
                // Older Android apps already support managed downloads. Let their request finish
                // even if a preview is closed, so a late offer never becomes an orphaned transfer.
                self.thumbnails?.rpc?.promise(job.item.remote,to:job.target,quiet:true,valid:{ [weak self] in self?.active[job.id] != nil }){[weak self]error in
                    guard let self else{return}
                    self.finish(job,error==nil ? PhotoOriginalReceipt(item:job.item,url:job.target):nil,error,staged:false)
                }
                return
            }
            guard let hosts=endpoint["hosts"]as?[String],let port=endpoint["port"]as?Int,let token=endpoint["token"]as?String,let key=self.key?(),key.count==32 else{self.finish(job,nil,NSError(domain:"CoolSync.Photo",code:1,userInfo:[NSLocalizedDescriptionKey:"사진 연결 정보를 받지 못했습니다. 다시 연결하세요."]));return}
            self.attempt(job,hosts:hosts.filter{PhotoThumbnails.local($0)},port:port,token:token,key:key,refreshed:refresh)
        }
    }
    private func attempt(_ job:Job,hosts:[String],port:Int,token:String,key:Data,refreshed:Bool){
        guard active[job.id] != nil else{return}
        guard let host=hosts.first,(1...65535).contains(port),let url=URL(string:"http://\(host):\(port)/original")else{finish(job,nil,NSError(domain:"CoolSync.Photo",code:1,userInfo:[NSLocalizedDescriptionKey:"사진 원본 연결을 열지 못했습니다. 같은 Wi-Fi인지 확인하세요."]));return}
        do{
            var message=Wire.Message(type:"mediaOriginal")
            message.text=String(data:try JSONSerialization.data(withJSONObject:["path":job.item.path,"id":job.item.id,"size":job.item.size,"modified":job.item.modified,"generation":job.item.generation ?? 0,"token":token]),encoding:.utf8) ?? ""
            var request=URLRequest(url:url);request.httpMethod="POST";request.timeoutInterval=180;request.httpBody=try Wire.seal(message,key:key);request.setValue("application/octet-stream",forHTTPHeaderField:"Content-Type")
            let task=try PhotoOriginalTransfer(request:request,key:key,reference:message.id,target:job.target,item:job.item,progress:{[weak self]value in guard let self,self.active[job.id] != nil else{return};self.progress?(job.owner,value)}){[weak self]receipt,error in
                guard let self,self.active[job.id] != nil else{if let receipt{try?FileManager.default.removeItem(at:receipt.url)};return}
                if let error,(error as NSError).domain != "CoolSync.Photo.Server",(error as NSError).code != NSUserCancelledError{
                    if hosts.count>1{self.attempt(job,hosts:Array(hosts.dropFirst()),port:port,token:token,key:key,refreshed:refreshed);return}
                    if !refreshed{self.endpoint(job,refresh:true);return}
                }
                self.finish(job,receipt,error)
            }
            active[job.id]=(job,task);task.start()
        }catch{finish(job,nil,error)}
    }
    private func finish(_ job:Job,_ receipt:PhotoOriginalReceipt?,_ error:Error?,staged:Bool=true){
        guard active.removeValue(forKey:job.id) != nil else{if staged,let receipt{try?FileManager.default.removeItem(at:receipt.url)};return}
        if let error{job.completion(.failure(error));pump();return}
        guard let receipt else{job.completion(.failure(CocoaError(.fileReadUnknown)));pump();return}
        let export=job.owner.hasPrefix("export.")
        let target=export ? job.target:(cacheTarget?(receipt.item) ?? job.target)
        do{
            if staged{
                if FileManager.default.fileExists(atPath:target.path){if export{throw CocoaError(.fileWriteFileExists)};_=try FileManager.default.replaceItemAt(target,withItemAt:receipt.url)}else{try FileManager.default.moveItem(at:receipt.url,to:target)}
            }
            if export,receipt.item.modified>0{try FileManager.default.setAttributes([.modificationDate:Date(timeIntervalSince1970:Double(receipt.item.modified)/1000)],ofItemAtPath:target.path)}
            job.completion(.success(PhotoOriginalReceipt(item:receipt.item,url:staged ? target:receipt.url)))
        }catch{if staged{try?FileManager.default.removeItem(at:receipt.url)};job.completion(.failure(error))}
        pump()
    }
}

private final class PhotoOriginalTransfer:NSObject,URLSessionDataDelegate {
    private let request:URLRequest,key:Data,reference:String,requested:PhotoItem
    private let temporary:URL
    private var expected:Int64
    private var actual:PhotoItem?
    private var output:FileHandle?,session:URLSession?,task:URLSessionDataTask?
    private var buffer=Data(),index=0
    private var received:Int64=0
    private var header=false,complete=false,handedOff=false
    private var failure:Error?
    private var lastProgress=Date.distantPast
    private let progress:(Double)->Void,finished:(PhotoOriginalReceipt?,Error?)->Void
    private let queue:OperationQueue={let q=OperationQueue();q.maxConcurrentOperationCount=1;q.qualityOfService = .utility;return q}()
    init(request:URLRequest,key:Data,reference:String,target:URL,item:PhotoItem,progress:@escaping(Double)->Void,finished:@escaping(PhotoOriginalReceipt?,Error?)->Void)throws{
        self.request=request;self.key=key;self.reference=reference;self.requested=item;self.expected=item.size;self.progress=progress;self.finished=finished
        temporary=target.deletingLastPathComponent().appendingPathComponent(".photo-"+UUID().uuidString+".partial")
        guard FileManager.default.createFile(atPath:temporary.path,contents:nil,attributes:[.posixPermissions:0o600])else{throw CocoaError(.fileWriteUnknown)}
        output=try FileHandle(forWritingTo:temporary);super.init()
    }
    func start(){let c=URLSessionConfiguration.ephemeral;c.timeoutIntervalForRequest=180;c.timeoutIntervalForResource=1800;c.urlCache=nil;session=URLSession(configuration:c,delegate:self,delegateQueue:queue);task=session?.dataTask(with:request);task?.resume()}
    func cancel(){task?.cancel()}
    private func fault(_ text:String)->NSError{NSError(domain:"CoolSync.Photo",code:3,userInfo:[NSLocalizedDescriptionKey:text])}
    func urlSession(_ session:URLSession,dataTask:URLSessionDataTask,didReceive response:URLResponse,completionHandler:@escaping(URLSession.ResponseDisposition)->Void){
        let code=(response as?HTTPURLResponse)?.statusCode ?? 0
        guard code==200 else{let descriptions=[401:"휴대폰 사진 연결 인증이 만료됐습니다. 다시 연결하세요.",403:"휴대폰에서 파일 관리 권한을 허용하세요.",404:"휴대폰에서 이 사진을 찾지 못했습니다. 목록을 갱신하세요.",409:"사진 원본이 변경되었습니다. 목록을 갱신하세요.",415:"휴대폰 앱이 원본 전송 형식을 지원하지 않습니다. 두 앱을 업데이트하세요.",500:"휴대폰에서 사진을 읽지 못했습니다. 다시 시도하세요."]
            failure=NSError(domain:code==401 ? "CoolSync.Photo":"CoolSync.Photo.Server",code:code,userInfo:[NSLocalizedDescriptionKey:descriptions[code] ?? "휴대폰이 사진 요청을 처리하지 못했습니다 (HTTP \(code))."]);completionHandler(.cancel);return}
        completionHandler(.allow)
    }
    func urlSession(_ session:URLSession,dataTask:URLSessionDataTask,didReceive data:Data){
        guard failure==nil else{return};buffer.append(data)
        do{
            while buffer.count>=4{
                let length=buffer.prefix(4).reduce(0){($0<<8)|Int($1)};guard (28...65564).contains(length)else{throw fault("사진 데이터 형식이 올바르지 않습니다.")};guard buffer.count>=length+4 else{break}
                let encrypted=Data(buffer.prefix(length+4).dropFirst(4));buffer.removeFirst(length+4)
                let clear=try AES.GCM.open(AES.GCM.SealedBox(combined:encrypted),using:SymmetricKey(data:key),authenticating:Data("CoolSync/original/1|\(reference)|\(index)".utf8));index+=1
                if !header{
                    guard let value=try JSONSerialization.jsonObject(with:clear)as?[String:Any],let size=(value["size"]as?NSNumber)?.int64Value,(0...FileTransfer.limit).contains(size)else{throw fault("사진 원본 정보를 확인하지 못했습니다.")}
                    if let row=value["item"]{
                        let item=try JSONDecoder().decode(PhotoItem.self,from:JSONSerialization.data(withJSONObject:row))
                        guard item.id==requested.id,item.path==requested.path,item.size==size else{throw fault("요청한 사진과 다른 원본입니다. 목록을 갱신하세요.")};actual=item
                    }else{guard size==requested.size else{throw fault("사진 크기가 변경되었습니다. 목록을 갱신하세요.")};actual=requested}
                    expected=size;header=true
                }else if received<expected{
                    guard !complete,!clear.isEmpty,Int64(clear.count)<=expected-received else{throw fault("사진 원본 크기가 다릅니다.")};try output?.write(contentsOf:clear);received+=Int64(clear.count)
                    if Date().timeIntervalSince(lastProgress)>0.15 || received==expected{lastProgress=Date();let value=expected==0 ? 1:Double(received)/Double(expected);DispatchQueue.main.async{self.progress(value)}}
                }else{guard !complete,let end=try JSONSerialization.jsonObject(with:clear)as?[String:Any],end["done"]as?Bool==true,(end["size"]as?NSNumber)?.int64Value==expected else{throw fault("사진 저장 확인을 받지 못했습니다.")};complete=true}
            }
        }catch{failure=error;dataTask.cancel()}
    }
    func urlSession(_ session:URLSession,task:URLSessionTask,didCompleteWithError error:Error?){
        var result=failure ?? error
        do{if result==nil{guard header,complete,received==expected,buffer.isEmpty else{throw fault("사진 원본을 끝까지 받지 못했습니다.")};try output?.synchronize()};try output?.close();output=nil}catch{result=error}
        let receipt:PhotoOriginalReceipt?
        if result==nil,let actual{receipt=PhotoOriginalReceipt(item:actual,url:temporary);handedOff=true}else{receipt=nil;try?FileManager.default.removeItem(at:temporary)}
        session.finishTasksAndInvalidate();self.session=nil;self.task=nil
        let final=result;DispatchQueue.main.async{self.finished(receipt,final)}
    }
    deinit{try?output?.close();if !handedOff{try?FileManager.default.removeItem(at:temporary)}}
}
