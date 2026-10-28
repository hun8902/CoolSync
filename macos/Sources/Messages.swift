import SwiftUI
import AppKit
import CryptoKit

struct InboxEntry:Codable,Identifiable,Equatable {
    let id:String;let kind:String;let package:String;let app:String;let title:String;let body:String;let thread:String;let postedAt:Int64;let sensitive:Bool;let redacted:Bool;let outgoing:Bool
    func displayTitle(_ hide:Bool)->String{hidden(hide) && (kind != "sms" || MessageCodes.extract(title) != nil) ? app:(title.isEmpty ? app:title)}
    var date:Date{Date(timeIntervalSince1970:Double(postedAt)/1000)}
    var code:String?{redacted ? nil:MessageCodes.extract(title+" "+body)}
    func hidden(_ enabled:Bool)->Bool{redacted || (enabled && (sensitive || code != nil))}
}
enum MessageCodes {
    static func extract(_ text:String)->String?{
        guard text.range(of:#"인증|확인.?코드|일회용|verification|verify|one.time|security code|\bOTP\b|\bcode\b"#,options:[.regularExpression,.caseInsensitive]) != nil else{return nil}
        guard let range=text.range(of:#"(?<![0-9])[0-9]{4,8}(?![0-9])"#,options:.regularExpression)else{return nil}
        return String(text[range])
    }
    static func copy(_ code:String){NSPasteboard.general.clearContents();NSPasteboard.general.setString(code,forType:.string);NSPasteboard.general.setData(Data(),forType:.init("org.nspasteboard.ConcealedType"))}
}
final class MessageInbox:ObservableObject {
    @Published private(set) var items:[InboxEntry]=[]
    @Published var selection:String?
    @Published var search=""
    @Published var filter="all"
    @Published var status="새로 수신한 앱 알림이 여기에 표시됩니다"
    @Published var syncing=false
    private var folder:URL?
    private var syncToken=UUID()
    var request:((Int)->Void)?
    func configure(identity:Data,baseDirectory:URL?=nil){
        syncToken=UUID();syncing=false;selection=nil;items=[]
        let hash=SHA256.hash(data:identity).map{String(format:"%02x",$0)}.joined()
        folder=(baseDirectory ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("CoolSync/Messages",isDirectory:true)).appendingPathComponent(hash,isDirectory:true)
        guard let folder else{return}
        do{try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700]);if let data=try?Data(contentsOf:folder.appendingPathComponent("inbox.json")){items=try JSONDecoder().decode([InboxEntry].self,from:data)}}catch{status="저장된 알림함을 읽지 못했습니다"}
    }
    @discardableResult func receive(_ row:[String:String])->InboxEntry?{
        guard let id=row["eventID"],!id.isEmpty else{return nil}
        let package=row["package"] ?? "phone",title=String((row["title"] ?? "").prefix(160)),body=String((row["body"] ?? "").prefix(1200))
        let entry=InboxEntry(id:id,kind:row["kind"] ?? "app",package:package,app:row["app"] ?? "휴대폰",title:title,body:body,thread:row["thread"] ?? package+":"+title,postedAt:Int64(row["postedAt"] ?? "") ?? Int64(Date().timeIntervalSince1970*1000),sensitive:row["sensitive"]=="true",redacted:row["redacted"]=="true",outgoing:row["outgoing"]=="true")
        var values=items.filter{$0.id != id}
        if entry.kind=="sms"{values.removeAll{$0.kind=="sms" && $0.title==entry.title && $0.body==entry.body && $0.outgoing==entry.outgoing && abs($0.postedAt-entry.postedAt)<2000}}
        values.append(entry);items=Array(values.sorted{$0.postedAt==$1.postedAt ? $0.id<$1.id:$0.postedAt>$1.postedAt}.prefix(500));save();return entry
    }
    private func save(){guard let folder else{return};do{let url=folder.appendingPathComponent("inbox.json");try JSONEncoder().encode(items).write(to:url,options:.atomic);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)}catch{status="알림함 저장 실패 · "+error.localizedDescription}}
    func refresh(){guard !syncing else{return};syncing=true;status="휴대폰 알림함을 가져오는 중…";let token=UUID();syncToken=token;request?(0);DispatchQueue.main.asyncAfter(deadline:.now()+90){[weak self]in guard let self,self.syncToken==token,self.syncing else{return};self.syncing=false;self.status="알림함 응답 시간이 지났습니다. 연결 후 다시 시도하세요"}}
    func page(_ value:[String:Any]){
        guard syncing else{return}
        if let error=value["error"]as?String{syncing=false;status=error;return}
        guard let rows=value["items"]as?[[String:String]],let next=value["next"]as?Int,let total=value["total"]as?Int,next<=total else{syncing=false;status="휴대폰 알림함 형식을 확인하지 못했습니다";return}
        for row in rows{receive(row)}
        if next<total && !rows.isEmpty{request?(next)}else{syncing=false;status="\(items.count)개 · 이 Mac에 최대 500개 저장"}
    }
    func connectionEnded(){syncToken=UUID();syncing=false}
    var threads:[InboxEntry]{
        var seen=Set<String>()
        return items.filter{entry in
            guard filter=="all" || entry.kind==filter else{return false}
            let hidden=entry.hidden(UserDefaults.standard.object(forKey:"hideSensitiveMessages")as?Bool ?? true)
            guard search.isEmpty || entry.displayTitle(hidden).localizedCaseInsensitiveContains(search) || entry.app.localizedCaseInsensitiveContains(search) || (!hidden && entry.body.localizedCaseInsensitiveContains(search))else{return false}
            return seen.insert(entry.thread).inserted
        }
    }
    var selectedThread:String?{if let selection,threads.contains(where:{$0.thread==selection}){return selection};return threads.first?.thread}
    var conversation:[InboxEntry]{items.filter{$0.thread==selectedThread}.sorted{$0.postedAt<$1.postedAt}}
}

struct MessagesPane:View {
    @ObservedObject var inbox:MessageInbox
    @AppStorage("hideSensitiveMessages") private var hide=true
    var body:some View{
        HStack(spacing:0){
            VStack(spacing:0){
                HStack{Text("메시지").font(.title2.weight(.semibold));Spacer();Button{inbox.refresh()}label:{Image(systemName:"arrow.clockwise")}.disabled(inbox.syncing).help("휴대폰 알림함 동기화")}.padding(18)
                TextField("검색",text:$inbox.search).textFieldStyle(.roundedBorder).padding(.horizontal,14).padding(.bottom,10)
                List(selection:$inbox.selection){ForEach(inbox.threads){entry in
                    HStack(alignment:.top,spacing:10){avatar(entry,size:38);VStack(alignment:.leading,spacing:5){HStack{Text(entry.displayTitle(hide)).fontWeight(.semibold).lineLimit(1);Spacer(minLength:4);Text(entry.date,style:.date).font(.system(size:10)).foregroundStyle(.secondary)};Text(entry.hidden(hide) ? "민감한 내용 숨김":entry.body).font(.system(size:12)).foregroundStyle(.secondary).lineLimit(2);if entry.kind != "sms"{Text(entry.app).font(.system(size:10)).foregroundStyle(.secondary)}}}.padding(.vertical,7).tag(entry.thread).listRowBackground(entry.thread==inbox.selectedThread ? Color.accentColor.opacity(0.6):Color.clear)
                }}.listStyle(.sidebar)
            }.frame(width:290).background(.thinMaterial)
            Divider()
            VStack(spacing:0){
                if let entry=inbox.conversation.last{
                    HStack(spacing:10){avatar(entry,size:34);VStack(alignment:.leading,spacing:3){Text(entry.displayTitle(hide)).font(.headline).lineLimit(1);Text(entry.kind=="sms" ? "문자 메시지 · SMS":entry.app).font(.caption).foregroundStyle(.secondary)};Spacer();Toggle(isOn:$hide){Image(systemName:hide ? "eye.slash":"eye")}.toggleStyle(.button).help("민감한 내용 숨기기")}.padding(16).background(.bar)
                    Divider()
                    ScrollViewReader{proxy in ScrollView{LazyVStack(spacing:18){ForEach(inbox.conversation){message in
                        VStack(spacing:8){Text(message.date.formatted(date:.abbreviated,time:.shortened)).font(.caption).foregroundStyle(.secondary)
                            HStack{if message.outgoing{Spacer(minLength:60)};VStack(alignment:.leading,spacing:10){Text(message.hidden(hide) ? "민감한 내용이 숨겨져 있습니다":message.body).textSelection(.enabled).fixedSize(horizontal:false,vertical:true);if !message.hidden(hide),let code=message.code{Button{MessageCodes.copy(code)}label:{Label("인증번호 \(code) 복사",systemImage:"doc.on.doc")}.buttonStyle(.bordered)}}.padding(.horizontal,15).padding(.vertical,12).background(message.outgoing ? Color.green.opacity(0.85):Color.secondary.opacity(0.15),in:RoundedRectangle(cornerRadius:18)).foregroundStyle(message.outgoing ? Color.white:Color.primary);if !message.outgoing{Spacer(minLength:60)}}
                        }.id(message.id)
                    }}.padding(22)}.onAppear{if let id=inbox.conversation.last?.id{proxy.scrollTo(id,anchor:.bottom)}}.onChange(of:inbox.selectedThread){_ in if let id=inbox.conversation.last?.id{proxy.scrollTo(id,anchor:.bottom)}}.onChange(of:inbox.conversation.last?.id){id in if let id{proxy.scrollTo(id,anchor:.bottom)}}}
                }else{
                    Spacer();Image(systemName:"bubble.left.and.bubble.right").font(.system(size:44,weight:.light)).foregroundStyle(.secondary);Text("앱 알림함").font(.title2).padding(.top,12);Text("휴대폰 CoolSync 설정에서 알림 공유를 켜세요.").font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(20);Spacer()
                }
                Divider();HStack{if inbox.syncing{ProgressView().controlSize(.small)};Text(inbox.status).font(.caption).foregroundStyle(.secondary).lineLimit(2);Spacer();Text("수신함").font(.caption).foregroundStyle(.secondary)}.padding(12)
            }.frame(maxWidth:.infinity,maxHeight:.infinity).background(Color(nsColor:.textBackgroundColor))
        }
    }
    private func avatar(_ entry:InboxEntry,size:CGFloat)->some View{ZStack{Circle().fill(entry.kind=="sms" ? Color.purple.opacity(0.35):Color.blue.opacity(0.2));Image(systemName:entry.kind=="sms" ? "person.fill":"app.fill").font(.system(size:size*0.48)).foregroundStyle(.secondary)}.frame(width:size,height:size)}
}
