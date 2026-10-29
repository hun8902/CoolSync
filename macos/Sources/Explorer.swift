import AppKit
import SwiftUI
import Combine
import UniformTypeIdentifiers

struct RemoteEntry:Identifiable,Decodable {
    var id:String{path}
    let name:String
    let path:String
    let directory:Bool
    let size:Int64
    let modified:Int64
}
struct RemoteTrash:Identifiable,Decodable{let id:String;let name:String;let original:String;let deleted:Int64}
private struct ExplorerPromise{let entry:RemoteEntry;let target:URL;let quiet:Bool;let valid:(()->Bool)?;let completion:(Error?)->Void}
private enum ExplorerJob{case upload(URL,String);case download(String,URL);case mkdir(String,String)}

final class ExplorerModel:ObservableObject {
    @Published var entries:[RemoteEntry]=[]
    @Published var trash:[RemoteTrash]=[]
    @Published var trashSelection=Set<String>()
    @Published var trashWorking=false
    @Published var trashProgress:Double=0
    @Published var trashFailures:[String]=[]
    private var trashStop=false
    private var trashRetry:[RemoteTrash]=[]
    private var trashAction="deletePermanent"
    var visibleTrash:[RemoteTrash]{trash.filter{search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.original.localizedCaseInsensitiveContains(search)}}
    func stopTrashWork(){trashStop=true;status="현재 항목 처리 후 중단합니다"}
    func retryTrashWork(){runTrash(trashRetry,action:trashAction)}
    func runTrash(_ values:[RemoteTrash],action:String){
        guard !values.isEmpty,!busy,connected?()==true else{return}
        let alert=NSAlert();alert.messageText=action=="restore" ? "\(values.count)개 항목을 복원할까요?":"\(values.count)개 항목을 영구 삭제할까요?"
        alert.informativeText=action=="restore" ? "원래 위치로 복원합니다. 이름이 충돌하는 항목은 실패 내역에 표시됩니다.":"휴대폰 CoolSync 휴지통에서 원본을 삭제합니다. 복원할 수 없습니다."
        alert.addButton(withTitle:action=="restore" ? "복원":"영구 삭제");alert.addButton(withTitle:"취소")
        guard alert.runModal() == .alertFirstButtonReturn else{return}
        trashAction=action;trashRetry=[];trashFailures=[];trashStop=false;trashWorking=true;busy=true;trashProgress=0
        trashStep(values,total:values.count,action:action)
    }
    private func trashStep(_ remaining:[RemoteTrash],total:Int,action:String){
        trashProgress=Double(total-remaining.count)/Double(max(1,total))
        if remaining.isEmpty || trashStop{trashRetry.append(contentsOf:remaining);trashWorking=false;busy=false;status="처리 \(total-remaining.count)/\(total)개 · 실패 \(trashFailures.count)개";return}
        let item=remaining[0];status="\(action=="restore" ? "복원":"영구 삭제") 중 · \(total-remaining.count+1)/\(total) · \(item.name)"
        call(action,["id":item.id],quiet:true){[weak self]r in
            guard let self,self.trashWorking else{return}
            if r["ok"]as?Bool==true{self.trash.removeAll{$0.id==item.id};self.trashSelection.remove(item.id)}
            else{self.trashRetry.append(item);self.trashFailures.append("\(item.name): \(r["error"]as?String ?? "실패")")}
            self.trashStep(Array(remaining.dropFirst()),total:total,action:action)
        }
    }
    @Published var path=""
    @Published var trashMode=false
    @Published var selection=Set<String>()
    @Published var search=""
    @Published var busy=false
    @Published var status="휴대폰 연결을 기다리는 중"
    @Published var available:Int64=0
    @Published var error:String?
    @Published var needsSetup=false
    @Published var sort="name"
    @Published var ascending=true
    var send:((String,String,String)->Void)?
    var connected:(()->Bool)?
    weak var files:FileTransfer?
    private var quietCalls=Set<String>()
    private var callbacks:[String:([String:Any])->Void]=[:]
    private var timers:[String:DispatchWorkItem]=[:]
    private var history:[String]=[]
    private var clipboard:[String]=[]
    private var cutting=false
    private var jobs:[ExplorerJob]=[]
    private var queueActive=false
    private var promisedCompletion:((Error?)->Void)?
    private var promiseQueue:[ExplorerPromise]=[]
    private var quietJob=false
    private var jobDeadline:DispatchWorkItem?
    var hasClipboard:Bool{!clipboard.isEmpty}
    var visible:[RemoteEntry] {
        entries.filter{search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)}.sorted{
            if $0.path==$1.path{return false}
            if $0.directory != $1.directory{return $0.directory}
            let result:Bool
            switch sort{case "size":result=$0.size==$1.size ? $0.name<$1.name:$0.size<$1.size;case "modified":result=$0.modified==$1.modified ? $0.name<$1.name:$0.modified<$1.modified;default:result=$0.name.localizedStandardCompare($1.name) == .orderedAscending}
            return ascending ? result:!result
        }
    }
    func call(_ op:String,_ fields:[String:Any]=[:],quiet:Bool=false,completion:@escaping([String:Any])->Void){
        guard connected?()==true else{if !quiet{fail("휴대폰이 연결되어 있지 않습니다")};completion(["ok":false,"error":"휴대폰이 연결되어 있지 않습니다"]);return}
        let id=UUID().uuidString;var q=fields;q["op"]=op
        guard let data=try? JSONSerialization.data(withJSONObject:q),let text=String(data:data,encoding:.utf8)else{return}
        callbacks[id]=completion;if quiet{quietCalls.insert(id)}
        let timer=DispatchWorkItem{[weak self]in guard let self,let callback=self.callbacks.removeValue(forKey:id)else{return};self.timers.removeValue(forKey:id);self.quietCalls.remove(id);if !quiet{self.fail("기기 응답 시간이 지났습니다")};callback(["ok":false,"error":"응답 시간 초과"])}
        timers[id]=timer;let timeout:Double=45;DispatchQueue.main.asyncAfter(deadline:.now()+timeout,execute:timer);send?("fsRequest",text,id)
    }
    func handle(_ m:Wire.Message){
        guard let data=m.text.data(using:.utf8),let response=try? JSONSerialization.jsonObject(with:data)as?[String:Any]else{return}
        timers.removeValue(forKey:m.ref)?.cancel();guard let callback=callbacks.removeValue(forKey:m.ref)else{return}
        if response["code"]as?String=="setup"{needsSetup=true}
        if quietCalls.remove(m.ref)==nil && response["ok"]as?Bool != true{fail(response["error"]as?String ?? "파일 작업을 완료하지 못했습니다")}
        callback(response)
    }
    private func fail(_ message:String){busy=false;status=message;error=message}
    func browse(_ value:String,remember:Bool=true){if remember && value != path{history.append(path)};trashMode=false;path=value;search="";selection=[];reload()}
    func back(){if let previous=history.popLast(){browse(previous,remember:false)}}
    func up(){if trashMode{browse("");return};let components=path.split(separator:"/");if !components.isEmpty{browse(components.dropLast().joined(separator:"/"))}}
    func reload(){
        guard connected?()==true else{status="휴대폰 연결을 기다리는 중";return}
        if trashMode{loadTrash();return}
        let target=path;busy=true;error=nil;entries=[];loadPage(target,offset:0)
    }
    private func loadPage(_ target:String,offset:Int){
        call("list",["path":target,"offset":offset]){[weak self]result in
            guard let self,self.path==target,!self.trashMode else{return}
            guard result["ok"]as?Bool==true,let rows=result["entries"],let data=try? JSONSerialization.data(withJSONObject:rows),let values=try? JSONDecoder().decode([RemoteEntry].self,from:data)else{self.busy=false;return}
            self.needsSetup=false
            let known=Set(self.entries.map{$0.path});self.entries+=values.filter{!known.contains($0.path)};self.available=(result["free"]as?NSNumber)?.int64Value ?? 0
            let next=result["next"]as?Int ?? 0,total=result["total"]as?Int ?? 0
            if next<total && next>offset{self.loadPage(target,offset:next)}else{self.busy=false;self.status="\(self.entries.count)개 항목"}
        }
    }
    func showTrash(){trashMode=true;selection=[];search="";loadTrash()}
    private func loadTrash(offset:Int=0,collected:[RemoteTrash]=[]){
        busy=true
        call("listTrash",["offset":offset]){[weak self]r in
            guard let self,self.trashMode else{return}
            guard r["ok"]as?Bool==true,let rows=r["trash"],let d=try?JSONSerialization.data(withJSONObject:rows),let items=try?JSONDecoder().decode([RemoteTrash].self,from:d)else{self.busy=false;return}
            let all=collected+items;let next=r["next"]as?Int ?? all.count,total=r["total"]as?Int ?? all.count
            if next<total && next>offset{self.loadTrash(offset:next,collected:all)}else{self.trash=all;self.trashSelection.formIntersection(Set(all.map{$0.id}));self.busy=false;self.status="\(all.count)개 항목"}
        }
    }
    func newItem(directory:Bool){
        prompt(directory ? "새 폴더":"새 파일",value:directory ? "새 폴더":"새 파일.txt"){[weak self]name in guard let self else{return};self.mutate(directory ? "mkdir":"touch",["path":self.path,"name":name])}
    }
    func rename(){guard let item=entries.first(where:{selection.contains($0.path)}),selection.count==1 else{return};prompt("이름 변경",value:item.name){[weak self]name in self?.mutate("rename",["path":item.path,"name":name])}}
    func copy(cut:Bool){clipboard=Array(selection);cutting=cut;status="\(clipboard.count)개 항목 \(cut ? "이동":"복사") 준비";objectWillChange.send()}
    func paste(){guard !clipboard.isEmpty else{return};move(clipboard,to:path,copy:!cutting);if cutting{clipboard=[]}}
    func move(_ paths:[String],to destination:String,copy:Bool=false){mutate(copy ? "copy":"move",["paths":paths,"destination":destination])}
    func remove(){
        guard !selection.isEmpty else{return};let alert=NSAlert();alert.messageText="\(selection.count)개 항목을 휴지통으로 이동할까요?";alert.informativeText="휴대폰의 CoolSync 휴지통에서 복원할 수 있습니다.";alert.addButton(withTitle:"휴지통으로 이동");alert.addButton(withTitle:"취소")
        if alert.runModal() == .alertFirstButtonReturn{mutate("trash",["paths":Array(selection)])}
    }
    func restore(_ id:String){runTrash(trash.filter{$0.id==id},action:"restore")}
    func permanent(_ id:String){runTrash(trash.filter{$0.id==id},action:"deletePermanent")}
    private func mutate(_ op:String,_ fields:[String:Any]){busy=true;call(op,fields){[weak self]r in guard let self else{return};self.busy=false;if r["ok"]as?Bool==true{self.selection=[];self.reload()}}}
    private func prompt(_ title:String,value:String,completion:@escaping(String)->Void){let alert=NSAlert();alert.messageText=title;let input=NSTextField(string:value);input.frame=NSRect(x:0,y:0,width:300,height:26);alert.accessoryView=input;alert.addButton(withTitle:"확인");alert.addButton(withTitle:"취소");alert.window.initialFirstResponder=input;if alert.runModal() == .alertFirstButtonReturn{completion(input.stringValue)}}
    func chooseUpload(){let panel=NSOpenPanel();panel.canChooseDirectories=true;panel.canChooseFiles=true;panel.allowsMultipleSelection=true;if panel.runModal() == .OK{upload(panel.urls,to:path)}}
    func upload(_ urls:[URL],to folder:String){
        guard !queueActive,files?.hasTransfer != true else{fail("진행 중인 파일 작업을 먼저 마치세요");return}
        var planned:[ExplorerJob]=[]
        do{
            for url in urls{
                let info=try url.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey]);if info.isSymbolicLink==true{throw CocoaError(.fileReadUnsupportedScheme)}
                if info.isDirectory==true{
                    planned.append(.mkdir(folder,url.lastPathComponent));let remote=[folder,url.lastPathComponent].filter{!$0.isEmpty}.joined(separator:"/")
                    guard let iterator=FileManager.default.enumerator(at:url,includingPropertiesForKeys:[.isDirectoryKey,.isSymbolicLinkKey])else{throw CocoaError(.fileReadUnknown)}
                    let children=iterator.compactMap{$0 as? URL}.sorted{$0.pathComponents.count<$1.pathComponents.count}
                    for child in children{
                        let attrs=try child.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey]);if attrs.isSymbolicLink==true{throw CocoaError(.fileReadUnsupportedScheme)}
                        let relative=String(child.path.dropFirst(url.path.count+1));let parent=relative.split(separator:"/").dropLast().joined(separator:"/");let dest=[remote,parent].filter{!$0.isEmpty}.joined(separator:"/")
                        if attrs.isDirectory==true{planned.append(.mkdir(dest,child.lastPathComponent))}else{planned.append(.upload(child,dest))}
                    }
                }else{planned.append(.upload(url,folder))}
            }
            jobs=planned;queueActive=true;nextJob()
        }catch{fail("선택한 파일이나 폴더를 읽지 못했습니다")}
    }
    func download(move:Bool=false){
        let selected=entries.filter{selection.contains($0.path)};guard !selected.isEmpty else{return}
        if selected.count==1 && !selected[0].directory{let panel=NSSavePanel();panel.nameFieldStringValue=selected[0].name;if panel.runModal() == .OK,let url=panel.url{enqueueDownloads(selected,to:url.deletingLastPathComponent(),single:url){[weak self]error in if error==nil && move{self?.mutate("trash",["paths":selected.map{$0.path}])}}}}
        else{let panel=NSOpenPanel();panel.canChooseFiles=false;panel.canChooseDirectories=true;panel.prompt="여기에 복사";if panel.runModal() == .OK,let url=panel.url{enqueueDownloads(selected,to:url,single:nil){[weak self]error in if error==nil && move{self?.mutate("trash",["paths":selected.map{$0.path}])}}}}
    }
    func exportEntries(_ entries:[RemoteEntry],to folder:URL,completion:@escaping(Error?)->Void){enqueueDownloads(entries,to:folder,single:nil,completion:completion)}
    func promise(_ entry:RemoteEntry,to target:URL,quiet:Bool=false,valid:(()->Bool)?=nil,completion:@escaping(Error?)->Void){
        guard valid?() != false else{completion(CocoaError(.userCancelled));DispatchQueue.main.async{[weak self]in self?.resumePromises()};return}
        if queueActive || files?.hasTransfer==true{promiseQueue.append(ExplorerPromise(entry:entry,target:target,quiet:quiet,valid:valid,completion:completion));return}
        enqueueDownloads([entry],to:target.deletingLastPathComponent(),single:target,quiet:quiet){[weak self]error in completion(error);DispatchQueue.main.async{self?.resumePromises()}}
    }
    func resumePromises(){guard !queueActive,files?.hasTransfer != true,connected?()==true,!promiseQueue.isEmpty else{return};let next=promiseQueue.removeFirst();promise(next.entry,to:next.target,quiet:next.quiet,valid:next.valid,completion:next.completion)}
    private func enqueueDownloads(_ selected:[RemoteEntry],to folder:URL,single:URL?,quiet:Bool=false,completion:((Error?)->Void)?=nil){
        guard !queueActive,files?.hasTransfer != true else{completion?(CocoaError(.fileWriteUnknown));fail("진행 중인 파일 작업을 먼저 마치세요");return}
        jobs=[];queueActive=true;quietJob=quiet;promisedCompletion=completion;busy=true
        func collect(_ items:[RemoteEntry],_ parent:URL,_ done:@escaping()->Void){
            guard let item=items.first else{done();return}
            let rest=Array(items.dropFirst());let target=single != nil && selected.count==1 && item.path==selected[0].path ? single!:parent.appendingPathComponent(item.name)
            if item.directory{
                do{try FileManager.default.createDirectory(at:target,withIntermediateDirectories:false)}catch{self.stopJobs("같은 이름의 폴더가 있거나 저장할 수 없습니다");return}
                self.fetchAll(item.path){children in guard let children else{self.stopJobs("폴더를 읽지 못했습니다");return};collect(children,target){collect(rest,parent,done)}}
            }else{
                if FileManager.default.fileExists(atPath:target.path) && single==nil{self.stopJobs("같은 이름의 파일이 있습니다. 다른 저장 위치를 선택하세요.");return}
                self.jobs.append(.download(item.path,target));collect(rest,parent,done)
            }
        }
        collect(selected,folder){self.nextJob()}
    }
    private func fetchAll(_ folder:String,offset:Int=0,values:[RemoteEntry]=[],completion:@escaping([RemoteEntry]?)->Void){call("list",["path":folder,"offset":offset]){r in guard r["ok"]as?Bool==true,let rows=r["entries"],let data=try?JSONSerialization.data(withJSONObject:rows),let items=try?JSONDecoder().decode([RemoteEntry].self,from:data)else{completion(nil);return};let next=r["next"]as?Int ?? 0,total=r["total"]as?Int ?? 0;if next<total && next>offset{self.fetchAll(folder,offset:next,values:values+items,completion:completion)}else{completion(values+items)}}}
    private func nextJob(){
        guard queueActive else{return}
        jobDeadline?.cancel()
        guard !jobs.isEmpty else{queueActive=false;busy=false;status="파일 작업 완료";let silent=quietJob;quietJob=false;let completion=promisedCompletion;promisedCompletion=nil;if !silent{reload()};completion?(nil);resumePromises();return}
        let timeout=DispatchWorkItem{[weak self]in guard let self,self.queueActive,self.files?.transportActive != true else{return};self.stopJobs("파일 전송 요청에 응답이 없습니다")}
        jobDeadline=timeout;DispatchQueue.main.asyncAfter(deadline:.now()+90,execute:timeout)
        busy=true;let job=jobs.removeFirst();status="남은 작업 \(jobs.count+1)개"
        files?.onCompletion={[weak self]success in if success{self?.nextJob()}else{self?.stopJobs(self?.files?.summary ?? "파일 전송 실패")}}
        switch job{
        case .upload(let url,let folder):files?.stage(url,folder:folder)
        case .download(let remote,let target):files?.expectedDownloads[remote]=target;call("download",["path":remote],quiet:quietJob){[weak self]r in if r["ok"]as?Bool != true{self?.stopJobs(r["error"]as?String ?? "파일을 읽지 못했습니다")}}
        case .mkdir(let parent,let name):call("mkdir",["path":parent,"name":name]){[weak self]r in if r["ok"]as?Bool==true{self?.nextJob()}else{self?.stopJobs(r["error"]as?String ?? "폴더 생성 실패")}}
        }
    }
    func connectionEnded(){
        trashStop=true;trashWorking=false;trashSelection=[];trashRetry=[];trashFailures=[];trash=[]
        jobDeadline?.cancel();for timer in timers.values{timer.cancel()};timers=[:];callbacks=[:];quietCalls=[]
        jobs=[];queueActive=false;files?.expectedDownloads=[:];files?.onCompletion=nil;files?.cancel(notify:false)
        let completion=promisedCompletion;promisedCompletion=nil;completion?(CocoaError(.userCancelled))
        let promises=promiseQueue;promiseQueue=[];for request in promises{request.completion(CocoaError(.userCancelled))}
        busy=false;selection=[];error=nil;needsSetup=false;status="휴대폰 연결이 끊겼습니다"
    }
    func cancelJobs(){files?.cancel();stopJobs("작업 취소됨")}
    private func stopJobs(_ message:String){jobDeadline?.cancel();jobs=[];queueActive=false;busy=false;files?.expectedDownloads=[:];files?.onCompletion=nil;let silent=quietJob;quietJob=false;let completion=promisedCompletion;promisedCompletion=nil;if !silent{fail(message)}else{status=message};completion?(NSError(domain:"CoolSync",code:1,userInfo:[NSLocalizedDescriptionKey:message]));resumePromises()}
}
