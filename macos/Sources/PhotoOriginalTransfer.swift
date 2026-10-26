import Foundation
import CryptoKit

/// Each original has its own cancellable HTTP request; ordinary file jobs are untouched.
final class PhotoOriginals {
    struct Job {let id=UUID();let item:PhotoItem;let target:URL;let owner:String;let completion:(Error?)->Void}
    weak var thumbnails:PhotoThumbnails?
    var key:(()->Data)?
    var progress:((String,Double)->Void)?
    private var waiting:[Job]=[]
    private var active:[UUID:(Job,PhotoOriginalTransfer?)]=[:]
    func download(_ item:PhotoItem,to target:URL,owner:String,completion:@escaping(Error?)->Void){
        if owner=="preview"{cancel(owner:owner)}
        let job=Job(item:item,target:target,owner:owner,completion:completion)
        if owner=="preview"{waiting.insert(job,at:0)}else{waiting.append(job)};pump()
    }
    func cancel(owner:String){
        let queued=waiting.filter{$0.owner==owner};waiting.removeAll{$0.owner==owner}
        let running=active.values.filter{$0.0.owner==owner}
        for(job,task)in running{active.removeValue(forKey:job.id);task?.cancel();job.completion(CocoaError(.userCancelled))}
        queued.forEach{$0.completion(CocoaError(.userCancelled))}
        DispatchQueue.main.async{[weak self]in self?.pump()}
    }
    func cancelAll(){let owners=Set(waiting.map{$0.owner}+active.values.map{$0.0.owner});for owner in owners{cancel(owner:owner)}}
    private func pump(){
        while active.count<2 && !waiting.isEmpty{
            let job=waiting.removeFirst();active[job.id]=(job,nil)
            endpoint(job,refresh:false)
        }
    }
    private func endpoint(_ job:Job,refresh:Bool){
        if refresh{thumbnails?.invalidateEndpoint()}
        thumbnails?.withEndpoint{[weak self]endpoint in
            guard let self,self.active[job.id] != nil else{return}
            guard let endpoint,let hosts=endpoint["hosts"]as?[String],let port=endpoint["port"]as?Int,let token=endpoint["token"]as?String,let key=self.key?(),key.count==32 else{self.finish(job,NSError(domain:"CoolSync.Photo",code:1,userInfo:[NSLocalizedDescriptionKey:"같은 Wi-Fi와 휴대폰 연결을 확인한 뒤 다시 시도하세요."]));return}
            self.attempt(job,hosts:hosts.filter{PhotoThumbnails.local($0)},port:port,token:token,key:key,refreshed:refresh)
        }
    }
    private func attempt(_ job:Job,hosts:[String],port:Int,token:String,key:Data,refreshed:Bool){
        guard active[job.id] != nil else{return}
        guard let host=hosts.first,(1...65535).contains(port),let url=URL(string:"http://\(host):\(port)/original")else{finish(job,NSError(domain:"CoolSync.Photo",code:1,userInfo:[NSLocalizedDescriptionKey:"사진 원본 연결을 열지 못했습니다. 같은 Wi-Fi인지 확인하세요."]));return}
        do{
            var message=Wire.Message(type:"mediaOriginal")
            message.text=String(data:try JSONSerialization.data(withJSONObject:["path":job.item.path,"id":job.item.id,"size":job.item.size,"modified":job.item.modified,"generation":job.item.generation ?? 0,"token":token]),encoding:.utf8) ?? ""
            var request=URLRequest(url:url);request.httpMethod="POST";request.timeoutInterval=180;request.httpBody=try Wire.seal(message,key:key);request.setValue("application/octet-stream",forHTTPHeaderField:"Content-Type")
            let task=try PhotoOriginalTransfer(request:request,key:key,reference:message.id,target:job.target,expected:job.item.size,progress:{[weak self]value in guard let self,self.active[job.id] != nil else{return};self.progress?(job.owner,value)}){[weak self]error in
                guard let self,self.active[job.id] != nil else{return}
                if let error,!(error is CancellationError),(error as NSError).code != NSUserCancelledError{
                    if hosts.count>1{self.attempt(job,hosts:Array(hosts.dropFirst()),port:port,token:token,key:key,refreshed:refreshed);return}
                    if !refreshed{self.endpoint(job,refresh:true);return}
                }
                self.finish(job,error)
            }
            active[job.id]=(job,task);task.start()
        }catch{finish(job,error)}
    }
    private func finish(_ job:Job,_ error:Error?){
        guard active.removeValue(forKey:job.id) != nil else{return}
        var result=error
        if error==nil,job.owner.hasPrefix("export."),job.item.modified>0{do{try FileManager.default.setAttributes([.modificationDate:Date(timeIntervalSince1970:Double(job.item.modified)/1000)],ofItemAtPath:job.target.path)}catch{result=NSError(domain:"CoolSync.Photo",code:4,userInfo:[NSLocalizedDescriptionKey:"파일은 저장됐지만 수정일을 적용하지 못했습니다: \(error.localizedDescription)"])}}
        job.completion(result);pump()
    }
}

private final class PhotoOriginalTransfer:NSObject,URLSessionDataDelegate {
    private let request:URLRequest,key:Data,reference:String,target:URL,expected:Int64
    private let temporary:URL
    private var output:FileHandle?
    private var session:URLSession?
    private var task:URLSessionDataTask?
    private var buffer=Data(),index=0
    private var received:Int64=0
    private var header=false,complete=false,cancelled=false
    private var failure:Error?
    private var lastProgress=Date.distantPast
    private let progress:(Double)->Void,finished:(Error?)->Void
    private let queue:OperationQueue={let q=OperationQueue();q.maxConcurrentOperationCount=1;q.qualityOfService = .utility;return q}()
    init(request:URLRequest,key:Data,reference:String,target:URL,expected:Int64,progress:@escaping(Double)->Void,finished:@escaping(Error?)->Void)throws{
        self.request=request;self.key=key;self.reference=reference;self.target=target;self.expected=expected;self.progress=progress;self.finished=finished
        temporary=target.deletingLastPathComponent().appendingPathComponent(".photo-"+UUID().uuidString+".partial")
        guard FileManager.default.createFile(atPath:temporary.path,contents:nil,attributes:[.posixPermissions:0o600])else{throw CocoaError(.fileWriteUnknown)}
        output=try FileHandle(forWritingTo:temporary);super.init()
    }
    func start(){let configuration=URLSessionConfiguration.ephemeral;configuration.timeoutIntervalForRequest=180;configuration.timeoutIntervalForResource=1800;configuration.urlCache=nil;session=URLSession(configuration:configuration,delegate:self,delegateQueue:queue);task=session?.dataTask(with:request);task?.resume()}
    func cancel(){task?.cancel()}
    private func fault(_ text:String)->NSError{NSError(domain:"CoolSync.Photo",code:3,userInfo:[NSLocalizedDescriptionKey:text])}
    func urlSession(_ session:URLSession,dataTask:URLSessionDataTask,didReceive response:URLResponse,completionHandler:@escaping(URLSession.ResponseDisposition)->Void){
        guard (response as?HTTPURLResponse)?.statusCode==200 else{failure=fault("사진 정보가 변경되었거나 원본 연결이 만료됐습니다. 목록을 동기화한 뒤 다시 열어주세요.");completionHandler(.cancel);return};completionHandler(.allow)
    }
    func urlSession(_ session:URLSession,dataTask:URLSessionDataTask,didReceive data:Data){
        guard failure==nil else{return};buffer.append(data)
        do{
            while buffer.count>=4{
                let length=buffer.prefix(4).reduce(0){($0<<8)|Int($1)}
                guard (28...65564).contains(length)else{throw fault("사진 데이터 형식이 올바르지 않습니다.")}
                guard buffer.count>=length+4 else{break}
                let encrypted=Data(buffer.prefix(length+4).dropFirst(4));buffer.removeFirst(length+4)
                let clear=try AES.GCM.open(AES.GCM.SealedBox(combined:encrypted),using:SymmetricKey(data:key),authenticating:Data("CoolSync/original/1|\(reference)|\(index)".utf8));index+=1
                if !header{
                    guard let value=try JSONSerialization.jsonObject(with:clear)as?[String:Any],(value["size"]as?NSNumber)?.int64Value==expected else{throw fault("사진 원본이 변경되었습니다. 목록을 동기화하세요.")};header=true
                }else if received<expected{
                    guard !complete,!clear.isEmpty,Int64(clear.count)<=expected-received else{throw fault("사진 원본 크기가 다릅니다.")};try output?.write(contentsOf:clear);received+=Int64(clear.count)
                    if Date().timeIntervalSince(lastProgress)>0.15 || received==expected{lastProgress=Date();let value=expected==0 ? 1:Double(received)/Double(expected);DispatchQueue.main.async{self.progress(value)}}
                }else{
                    guard !complete,let end=try JSONSerialization.jsonObject(with:clear)as?[String:Any],end["done"]as?Bool==true,(end["size"]as?NSNumber)?.int64Value==expected else{throw fault("사진 저장 확인을 받지 못했습니다.")};complete=true
                }
            }
        }catch{failure=error;dataTask.cancel()}
    }
    func urlSession(_ session:URLSession,task:URLSessionTask,didCompleteWithError error:Error?){
        var result=failure ?? error
        do{
            if result==nil{guard header,complete,received==expected,buffer.isEmpty else{throw fault("사진 원본을 끝까지 받지 못했습니다.")};try output?.synchronize()}
            try output?.close();output=nil
            if result==nil{if FileManager.default.fileExists(atPath:target.path){_=try FileManager.default.replaceItemAt(target,withItemAt:temporary)}else{try FileManager.default.moveItem(at:temporary,to:target)}}
        }catch{result=error}
        if result != nil{try?FileManager.default.removeItem(at:temporary)}
        session.finishTasksAndInvalidate();self.session=nil;self.task=nil
        let final=result;DispatchQueue.main.async{self.finished(final)}
    }
    deinit{try?output?.close();try?FileManager.default.removeItem(at:temporary)}
}
