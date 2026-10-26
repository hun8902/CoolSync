import AppKit
import SwiftUI
import Combine
import CoreImage
import UserNotifications

final class DashboardModel: ObservableObject {
    @Published var status="휴대폰을 연결해 주세요"
    @Published var connectionIssue=""
    @Published var showConnectionIssue=false
    @Published var connected=false
    @Published var connecting=false
    @Published var notificationStatus="아직 수신한 알림이 없습니다"
    @Published var notificationPermissionIssue=""
    @Published var name="연결된 휴대폰 없음"
    @Published var model=""
    @Published var system=""
    @Published var lastSync: Date?
    @Published var tab=0
    @Published var pairing=false
    @Published var keyHex=""
    let files=FileTransfer()
    let explorer=ExplorerModel()
    let photos=PhotosModel()
    let clipboardState=ClipboardPaneState()
    let history:ClipHistory
    var engine: SyncEngine?
    var onStatus: ((String)->Void)?
    init(preview: Bool=false) {
        history=preview ? ClipHistory(folder:FileManager.default.temporaryDirectory.appendingPathComponent("CoolSyncPreview-"+UUID().uuidString),recording:true):ClipHistory.shared
        if preview { keyHex=String(repeating:"0",count:64); return }
        do {
            let key=try KeyStore.load();photos.configure(identity:key);keyHex=key.map{String(format:"%02x",$0)}.joined()
            let value=SyncEngine(key:key); engine=value
            value.changed={ [weak self, weak value] status in
                guard let self, let value else { return }; let wasConnected=self.connected; self.status=status; if status.contains("실패") || status.contains("시간 초과") || status.contains("권한") { self.connectionIssue=status }; if value.authenticated { self.connectionIssue="" }; self.connected=value.authenticated;self.connecting=value.connecting; self.name=value.peerName; self.model=value.peerModel; self.system=value.peerOS; self.lastSync=value.lastSync; self.onStatus?(status)
                if wasConnected && !value.authenticated { self.explorer.connectionEnded();self.photos.connectionEnded() }
                if value.authenticated { self.pairing=false; if !wasConnected { self.refreshNotificationPermission();self.photos.reconnected();self.explorer.reload() } }
            }
            photos.rpc=explorer;photos.files=files;photos.connected={ [weak value] in value?.authenticated ?? false };photos.thumbnails.rpc=explorer;photos.thumbnails.failure={ [weak self] message in self?.photos.status=message };photos.thumbnails.key={ [weak value] in value?.key ?? Data() };explorer.onFilesystemChange={ [weak self] in self?.photos.imported() }
            value.phoneNotification={ [weak self] app,title,body,package,icon,finished in
                PhoneNotificationIcons.shared.cache(package:package,encodedIcon:icon)
                func result(_ text:String){DispatchQueue.main.async{self?.notificationStatus=text};finished(text)}
                guard UserDefaults.standard.object(forKey:"phoneNotifications") as? Bool ?? true else { result("Mac CoolSync 설정에서 휴대폰 알림 표시가 꺼져 있습니다");return }
                let center=UNUserNotificationCenter.current()
                let content=UNMutableNotificationContent();content.title=app;content.subtitle=title;content.body=body;content.sound = .default
                content.threadIdentifier="phone."+app;content.userInfo=["kind":"phoneNotification"]
                func deliver(){
                    let cleanup=PhoneNotificationIcons.shared.decorate(content,package:package)
                    center.add(UNNotificationRequest(identifier:UUID().uuidString,content:content,trigger:nil)){error in
                        cleanup();result(error.map{"Mac 알림 등록 실패 · "+$0.localizedDescription} ?? "Mac 알림 센터에 등록했습니다")
                    }
                }
                center.getNotificationSettings{settings in
                    if settings.authorizationStatus == .notDetermined {
                        center.requestAuthorization(options:[.alert,.sound]){allowed,error in if allowed{deliver()}else{result("Mac 알림 권한이 허용되지 않았습니다. 시스템 설정 → 알림 → CoolSync에서 허용하세요")}}
                    } else if settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional {
                        if settings.notificationCenterSetting == .disabled { result("Mac 시스템 설정 → 알림 → CoolSync에서 알림 센터 표시를 켜세요") }else{deliver()}
                    } else { result("Mac 알림 권한이 거부되어 있습니다. 시스템 설정 → 알림 → CoolSync에서 허용하세요") }
                }
            }
            value.mediaChanged={ [weak self] in self?.photos.changed() }
            value.fileMessage={ [weak self] message in self?.files.handle(message) }
            value.filesystemMessage={ [weak self] message in self?.explorer.handle(message) }
            explorer.files=files; explorer.connected={ [weak value] in value?.authenticated ?? false }; explorer.send={ [weak value] type,text,ref in value?.sendControl(type,text,ref) }
            files.sendControl={ [weak value] type,text,ref in value?.sendControl(type,text,ref) }
            files.key={ [weak value] in value?.key ?? Data() }; files.connected={ [weak value] in value?.authenticated ?? false }
            value.imageCopied={ [weak self] url,time in self?.files.stage(url,folder:nil,clipboard:true,clipTime:time) }
            files.canReceiveImage={ [weak value] time in value?.canApplyImage(time) ?? false }
            files.imageReceived={ [weak value] url,time in value?.applyImage(url,time:time) }
            name=value.peerName; model=value.peerModel; pairing=model.isEmpty
        } catch { status="키체인 접근을 허용한 뒤 다시 실행하세요" }
    }
    func refreshNotificationPermission() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            let issue:String
            if settings.authorizationStatus == .denied { issue="macOS에서 CoolSync 알림이 꺼져 있습니다. Mac 알림 설정에서 허용하세요." }
            else if settings.authorizationStatus == .notDetermined { issue="첫 알림을 받을 때 Mac의 알림 권한을 허용하세요." }
            else if settings.notificationCenterSetting == .disabled { issue="macOS에서 CoolSync의 알림 센터 표시가 꺼져 있습니다." }
            else { issue="" }
            DispatchQueue.main.async { self?.notificationPermissionIssue=issue }
        }
    }
    var pairURL: String { var url=URLComponents(); url.scheme="coolsync"; url.host="pair"; url.queryItems=[URLQueryItem(name:"key",value:keyHex),URLQueryItem(name:"name",value:Host.current().localizedName ?? "Mac")]; return url.string ?? "" }
    func reset() {
        let alert=NSAlert(); alert.messageText="기존 등록을 지우고 새로 연결할까요?"; alert.informativeText="기존 연결 키와 휴대폰 정보를 초기화합니다. 휴대폰의 CoolSync에서 QR 스캔을 눌러 새 QR을 스캔하세요."; alert.addButton(withTitle:"새 연결 만들기"); alert.addButton(withTitle:"취소")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do { let key=try KeyStore.replace(); explorer.connectionEnded(); files.cancel(); photos.configure(identity:key);engine?.replaceKey(key); keyHex=key.map{String(format:"%02x",$0)}.joined(); name="연결된 휴대폰 없음";model="";system="";connectionIssue="";pairing=true;tab=0;UserDefaults.standard.removeObject(forKey:"peerName");UserDefaults.standard.removeObject(forKey:"peerModel") } catch { status="연결 키 저장 실패" }
    }
}

struct CoolDashboard:View {
    @ObservedObject var model:DashboardModel
    @ObservedObject private var photos:PhotosModel
    @AppStorage("appearance") private var appearance="system"
    init(model:DashboardModel){self.model=model;self.photos=model.photos}
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    var body:some View{
        HStack(spacing:0){
            Group {
                VStack(spacing:0) {
                    HStack(spacing:12){Image(systemName:"iphone.gen3").font(.system(size:25,weight:.regular)).foregroundStyle(Color.accentColor).frame(width:38,height:42).background(Color.accentColor.opacity(0.09),in:RoundedRectangle(cornerRadius:12));VStack(alignment:.leading,spacing:4){Text(model.name).font(.headline).lineLimit(2);Text(model.connected ? "연결됨":model.connecting ? "연결 중…":"미연결").font(.caption).foregroundStyle(model.connected ? .green:.secondary)};Spacer()}.padding(18)
                    List(selection:sidebarSelection) {
                        Section("CoolSync") {
                            Label("연결",systemImage:"link").tag("connection")
                            Label("클립보드",systemImage:"clipboard").tag("clipboard")
                            Label("사진첩",systemImage:"photo.on.rectangle").tag("photos")
                        }
                        if model.tab==4 {
                            Section("사진 보관함") {
                                Label("즐겨찾기",systemImage:"heart").tag("photo:favorites")
                                Label("최근 항목",systemImage:"clock").tag("photo:recent")
                                Label("비디오",systemImage:"video").tag("photo:videos")
                                Label("스크린샷",systemImage:"viewfinder").tag("photo:screenshots")
                            }
                            Section("앨범") {ForEach(photos.albums){album in Label(album.name,systemImage:"rectangle.stack").tag("album:"+album.path)}}
                        }
                        Section("휴대폰 저장소") {
                            Label("내부 저장소",systemImage:"internaldrive").tag("folder:")
                            Label("다운로드",systemImage:"arrow.down.circle").tag("folder:Download")
                            Label("문서",systemImage:"doc").tag("folder:Documents")
                            Label("카메라",systemImage:"camera").tag("folder:DCIM")
                            Label("휴지통",systemImage:"trash").tag("trash")
                        }
                        Section { Label("설정",systemImage:"gearshape").tag("settings") }
                    }.listStyle(.sidebar).tint(.accentColor)
                    if !model.model.isEmpty { Text(model.model).font(.caption).foregroundStyle(.secondary).padding(12) }
                }.frame(width:216).background(.ultraThinMaterial)
                Divider()
            }
            VStack(spacing:0) {
                if !model.connected && model.tab != 0 && model.tab != 2 {
                    HStack { Image(systemName:model.connecting ? "antenna.radiowaves.left.and.right":"wifi.exclamationmark");Text(model.tab==4 ? "Mac에 저장된 사진은 계속 볼 수 있습니다. 휴대폰 연결 후 변경분과 삭제 대기를 반영합니다.":(model.connectionIssue.isEmpty ? model.status:model.connectionIssue)).lineLimit(2);Spacer();Button("연결하기"){model.tab=0} }.font(.callout).padding(12).background(.thinMaterial)
                    Divider()
                }
            Group{if model.tab==4{PhotosPane(photos:model.photos,files:model.files,exit:{model.tab=0},trash:{model.tab=1;model.explorer.showTrash()})}else if model.tab==1{ExplorerPane(model:model.explorer,files:model.files)}else if model.tab==0{connection}else if model.tab==3{ClipboardPane(history:model.history,state:model.clipboardState)}else{settings}}.id(model.tab).transition(.opacity.combined(with:.offset(y:reduceMotion ? 0:8)))
            }
        }.background(Color(nsColor:.windowBackgroundColor)).tint(.accentColor)
        .preferredColorScheme(appearance=="light" ? .light:appearance=="dark" ? .dark:nil)
        .onAppear{applyAppearance()}.onChange(of:appearance){_ in applyAppearance()}
        .animation(reduceMotion ? nil:.easeInOut(duration:0.2),value:model.tab).frame(minWidth:900,minHeight:560)
        .alert("연결 확인",isPresented:$model.showConnectionIssue){Button("다시 연결"){model.engine?.reconnect()};Button("닫기",role:.cancel){}}message:{Text((model.connectionIssue.isEmpty ? model.status:model.connectionIssue)+"\n\n휴대폰에서 CoolSync의 연결을 시작하고 주변 기기 권한을 허용하세요. 두 기기의 Bluetooth를 켜고, 인증이 실패하면 현재 QR을 다시 스캔하세요.")}
    }
    private var sidebarSelection:Binding<String?> {
        Binding(get:{
            if model.tab==0{return "connection"};if model.tab==3{return "clipboard"};if model.tab==4{if !photos.album.isEmpty{return "album:"+photos.album};return photos.scope=="all" ? "photos":"photo:"+photos.scope};if model.tab==2{return "settings"}
            return model.explorer.trashMode ? "trash":"folder:"+model.explorer.path
        },set:{ value in
            guard let value else { return }
            switch value {
            case "connection":model.tab=0
            case "clipboard":model.tab=3
            case "photos":photos.choose();model.tab=4
            case "settings":model.tab=2
            case "trash":model.tab=1;model.explorer.showTrash()
            default:if value.hasPrefix("photo:"){photos.choose(String(value.dropFirst(6)));model.tab=4}else if value.hasPrefix("album:"){photos.choose(album:String(value.dropFirst(6)));model.tab=4}else if value.hasPrefix("folder:"){model.tab=1;model.explorer.browse(String(value.dropFirst(7)))}
            }
        })
    }
    private func applyAppearance(){NSApp.appearance=appearance=="dark" ? NSAppearance(named:.darkAqua):appearance=="light" ? NSAppearance(named:.aqua):nil}
    private var connection:some View{
        ScrollView {
            VStack(alignment:.leading,spacing:20) {
                HStack { VStack(alignment:.leading,spacing:5){Text("기기 연결").font(.title2.weight(.semibold));Text("Mac과 휴대폰을 한곳에서 관리하세요.").font(.callout).foregroundStyle(.secondary)}; Spacer();
                    Button { model.engine?.reconnect() } label: { Label("다시 연결",systemImage:"arrow.clockwise") }.buttonStyle(.bordered)
                }
                HStack(alignment:.top,spacing:20) {
                    VStack(alignment:.leading,spacing:16) {
                        HStack(spacing:12) {
                            Image(systemName:"iphone.gen3").font(.system(size:32)).foregroundStyle(.blue)
                            VStack(alignment:.leading,spacing:4) {
                                Text(model.name).font(.title3.bold())
                                Label(model.connected ? "연결됨":"미연결",systemImage:model.connected ? "checkmark.circle.fill":"circle.dashed").font(.subheadline).foregroundStyle(model.connected ? .green:.secondary)
                            }
                        }
                        Divider()
                        HStack(spacing:10){if model.connecting{ProgressView().controlSize(.small)};Text(model.status)}.font(.callout).textSelection(.enabled).fixedSize(horizontal:false,vertical:true)
                        if !model.model.isEmpty { detail("모델",model.model) }
                        if !model.system.isEmpty { detail("Android",model.system) }
                        detail("마지막 복사",model.lastSync.map{DateFormatter.localizedString(from:$0,dateStyle:.none,timeStyle:.short)} ?? "아직 없음")
                        if !model.connectionIssue.isEmpty { Text(model.connectionIssue).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
                        Button("연결 문제 확인"){model.showConnectionIssue=true}.buttonStyle(.bordered)
                        Button("등록 해제 및 새 연결",role:.destructive){model.reset()}.buttonStyle(.borderless)
                    }.padding(20).frame(maxWidth:.infinity,alignment:.leading).background(.regularMaterial,in:RoundedRectangle(cornerRadius:18))
                    if !model.connected || model.pairing {
                        VStack(spacing:14) {
                            Text("QR로 연결").font(.headline)
                            if let image=QRImage.make(model.pairURL) { Image(nsImage:image).interpolation(.none).resizable().frame(width:184,height:184).padding(12).background(.white,in:RoundedRectangle(cornerRadius:18)) }
                            Text("휴대폰 CoolSync에서\n연결 → QR 스캔").font(.callout).multilineTextAlignment(.center).foregroundStyle(.secondary)
                            Button("연결 정보 복사"){NSPasteboard.general.clearContents();NSPasteboard.general.setString(model.pairURL,forType:.string);NSPasteboard.general.setData(Data(),forType:.init("org.nspasteboard.ConcealedType"))}.buttonStyle(.bordered)
                        }.padding(20).frame(width:224).background(.regularMaterial,in:RoundedRectangle(cornerRadius:18))
                    }
                }
                if model.connected {
                    HStack(spacing:12) {
                        Button { model.tab=3 } label: { Label("클립보드",systemImage:"clipboard") }
                        Button { model.tab=1;model.explorer.reload() } label: { Label("파일 탐색",systemImage:"folder") }
                        Button { model.tab=4 } label: { Label("사진첩",systemImage:"photo.on.rectangle") }
                    }.buttonStyle(.borderedProminent).controlSize(.large)
                }
            }.padding(24).frame(maxWidth:.infinity,alignment:.leading)
        }
    }
    private var settings:some View{
        Form{
            Section("화면 모드"){Picker("앱 테마",selection:$appearance){Text("시스템 설정").tag("system");Text("라이트").tag("light");Text("다크").tag("dark")}.pickerStyle(.segmented);Text("모든 화면과 대화상자에 같은 테마를 적용합니다.").foregroundStyle(.secondary)}
            PhotoCacheSettings(photos:photos)
            Section("연결"){LabeledContent("휴대폰",value:model.name);LabeledContent("모델",value:model.model);Button("공유 시작 / 중지"){model.engine?.toggle()};Button("다른 휴대폰 연결"){model.reset()};Button("연결 QR 보기"){model.pairing=true;model.tab=0}}
            Section("파일 탐색"){Text("휴대폰 CoolSync의 권한 설정에서 파일 관리를 허용해야 합니다.");Text("파일과 폴더는 내부 저장소에서 관리합니다. 다른 앱의 전용 데이터와 시스템 보호 폴더는 접근할 수 없습니다.").foregroundStyle(.secondary)}
            Section("클립보드"){Toggle("복사 기록 저장",isOn:Binding(get:{model.history.enabled},set:{model.history.enabled=$0}));Text("이 기기에 최대 200개를 저장합니다. 민감한 내용 표시는 존중합니다. 이미지 한 장은 같은 로컬 네트워크에서 공유합니다.").foregroundStyle(.secondary)}
            Section("앱 업데이트"){Button("업데이트 확인…"){MacUpdates.shared.check()};Text("새 업데이트를 자동 확인합니다. 다운로드 및 설치 방식은 업데이트 창에서 변경할 수 있습니다.").foregroundStyle(.secondary)}
            Section("알림"){LabeledContent("클립보드",value:"배너 없이 반영");LabeledContent("파일 작업",value:"진행 상태 표시");Toggle("휴대폰 알림 표시",isOn:Binding(get:{UserDefaults.standard.object(forKey:"phoneNotifications") as? Bool ?? true},set:{UserDefaults.standard.set($0,forKey:"phoneNotifications")}));Text("휴대폰 설정에서 알림 공유와 알림 접근 권한을 허용하세요.").foregroundStyle(.secondary);LabeledContent("최근 알림 처리",value:model.notificationStatus);if !model.notificationPermissionIssue.isEmpty { Label(model.notificationPermissionIssue,systemImage:"exclamationmark.bubble").foregroundStyle(.orange) };Button("Mac 알림 설정 열기"){if let url=URL(string:"x-apple.systempreferences:com.apple.Notifications-Settings.extension?bundleId=app.coolsync.mac"){NSWorkspace.shared.open(url)}}}
            Section{Text("CoolSync 0.3.0 · 빌드 " + (Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? "—")).foregroundStyle(.secondary)}
        }.formStyle(.grouped).frame(maxWidth:.infinity)
    }
    private func detail(_ title:String,_ value:String)->some View{HStack(alignment:.firstTextBaseline){Text(title).foregroundStyle(.secondary).frame(width:100,alignment:.leading);Text(value).textSelection(.enabled);Spacer()}.font(.system(size:13))}
}
final class ClipboardPaneState:ObservableObject {
    @Published var search=""
    @Published var favorites=false
    @Published var selection:String?
    @Published var confirmClear=false
}
struct ClipboardPane:View {
    @ObservedObject var history:ClipHistory
    @ObservedObject var state:ClipboardPaneState
    private var filtered:[ClipEntry]{history.entries.filter{(!state.favorites || $0.favorite) && (state.search.isEmpty || ($0.text ?? "이미지").localizedCaseInsensitiveContains(state.search))}}
    private var selected:ClipEntry?{filtered.first{$0.id==state.selection}}
    var body:some View{
        VStack(spacing:0){
            HStack{Text("클립보드").font(.system(size:18,weight:.semibold));Spacer();Toggle("즐겨찾기",isOn:$state.favorites).toggleStyle(.button);Button{state.confirmClear=true}label:{Image(systemName:"trash")}.help("모든 기록 삭제");TextField("기록 검색",text:$state.search).textFieldStyle(.roundedBorder).frame(width:170)}.padding(.horizontal,20).padding(.vertical,16).background(.ultraThinMaterial)
            Divider()
            HStack(spacing:0){
                List(filtered,selection:$state.selection){item in
                    HStack(alignment:.top,spacing:12){Image(systemName:item.image==nil ? "text.alignleft":"photo").foregroundStyle(.blue).frame(width:24);VStack(alignment:.leading,spacing:6){Text(item.text ?? "이미지 한 장").lineLimit(2).font(.system(size:13));Text(item.source+" · "+item.time.formatted(date:.abbreviated,time:.shortened)).font(.system(size:10)).foregroundStyle(.secondary)};Spacer();if item.favorite{Image(systemName:"star.fill").font(.system(size:11)).foregroundStyle(.orange)}}.padding(.vertical,8).tag(item.id)
                    .contextMenu{Button("다시 복사"){history.copy(item)};Button(item.favorite ? "즐겨찾기 해제":"즐겨찾기"){history.favorite(item.id)};Button("삭제",role:.destructive){history.remove(item.id)}}
                }.listStyle(.inset).frame(minWidth:220,idealWidth:280,maxWidth:320)
                Divider()
                VStack(alignment:.leading,spacing:18){
                    if let item=selected{
                        HStack{Text(item.image==nil ? "텍스트":"이미지").font(.headline);Spacer();Button{history.favorite(item.id)}label:{Image(systemName:item.favorite ? "star.fill":"star")}.help("즐겨찾기");Button{history.remove(item.id)}label:{Image(systemName:"trash")}.help("기록 삭제")}
                        ScrollView{if let text=item.text{Text(text).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)}else if let name=item.image,let image=NSImage(contentsOf:history.folder.appendingPathComponent(name)){Image(nsImage:image).resizable().scaledToFit().frame(maxWidth:.infinity)}}
                        Text(item.source+" · "+item.time.formatted()).font(.caption).foregroundStyle(.secondary)
                        Button{history.copy(item)}label:{Label("다시 복사",systemImage:"doc.on.doc").frame(maxWidth:.infinity).padding(7)}.buttonStyle(.borderedProminent)
                    }else{Spacer();Image(systemName:"clipboard").font(.system(size:32,weight:.light)).foregroundStyle(.tertiary).frame(maxWidth:.infinity);Text(filtered.isEmpty ? "새로 복사한 내용이 여기에 표시됩니다":"기록을 선택하세요").foregroundStyle(.secondary).font(.system(size:13)).frame(maxWidth:.infinity);Spacer()}
                }.padding(24).frame(maxWidth:.infinity,maxHeight:.infinity).background(.thinMaterial)
            }
            Divider();HStack{Text("\(filtered.count)개 · 이 기기에만 저장");Spacer();Text("민감한 클립보드는 기록하지 않습니다")}.font(.system(size:11)).foregroundStyle(.secondary).padding(12)
        }.alert("기록을 모두 삭제할까요?",isPresented:$state.confirmClear){Button("모두 삭제",role:.destructive){history.clear()};Button("취소",role:.cancel){}}message:{Text("이 Mac의 기록과 즐겨찾기를 삭제합니다. 현재 시스템 클립보드와 휴대폰의 기록은 유지됩니다.")}
    }
}
struct ExplorerPane:View{
    @ObservedObject var model:ExplorerModel
    @ObservedObject var files:FileTransfer
    var body:some View{
        VStack(spacing:0){
            ViewThatFits(in:.horizontal){HStack(spacing:14){
                Button{model.back()}label:{Image(systemName:"chevron.left")}.help("뒤로")
                Button{model.up()}label:{Image(systemName:"arrow.up")}.help("상위 폴더")
                Button{model.reload()}label:{Image(systemName:"arrow.clockwise")}.help("새로 고침")
                Divider().frame(height:18)
                Menu{Button("새 폴더…"){model.newItem(directory:true)};Button("새 파일…"){model.newItem(directory:false)}}label:{Image(systemName:"folder.badge.plus")}.help("새 항목")
                Button{model.copy(cut:false)}label:{Image(systemName:"doc.on.doc")}.disabled(model.selection.isEmpty).help("복사")
                Button{model.copy(cut:true)}label:{Image(systemName:"scissors")}.disabled(model.selection.isEmpty).help("잘라내기")
                Button{model.paste()}label:{Image(systemName:"doc.on.clipboard")}.disabled(!model.hasClipboard).help("현재 폴더에 붙여넣기")
                Button{model.remove()}label:{Image(systemName:"trash")}.disabled(model.selection.isEmpty).help("휴지통으로 이동")
                Spacer()
                Menu("Mac으로"){Button("복사…"){model.download()};Button("이동…"){model.download(move:true)}}.disabled(model.selection.isEmpty)
                Button("Mac에서 가져오기…"){model.chooseUpload()}.disabled(model.trashMode || model.busy)
                TextField("이름으로 검색",text:$model.search).textFieldStyle(.roundedBorder).frame(width:160)
            };compactToolbar}.buttonStyle(.borderless).padding(.horizontal,16).padding(.vertical,15).background(.ultraThinMaterial)
            Divider()
            HStack(spacing:6){Button("내부 저장소"){model.browse("")}.buttonStyle(.borderless)
                if model.trashMode{Image(systemName:"chevron.right").font(.system(size:9));Text("휴지통")}else{ForEach(Array(model.path.split(separator:"/").enumerated()),id:\.offset){i,part in Image(systemName:"chevron.right").font(.system(size:9)).foregroundStyle(.tertiary);Button(String(part)){model.browse(model.path.split(separator:"/").prefix(i+1).joined(separator:"/"))}.buttonStyle(.borderless)}}
                Spacer();if model.busy{ProgressView().controlSize(.small)}
            }.font(.system(size:12)).padding(.horizontal,16).padding(.vertical,9)
            Divider()
            if model.trashMode{
                List(model.trash){item in HStack{Image(systemName:"doc");VStack(alignment:.leading){Text(item.name);Text(item.original).font(.system(size:11)).foregroundStyle(.secondary)};Spacer();Button("복원"){model.restore(item.id)};Button("영구 삭제"){model.permanent(item.id)}}}.listStyle(.inset)
            }else{
                ZStack{
                    RemoteTable(model:model)
                    if model.entries.isEmpty && !model.busy{VStack(spacing:8){Text(model.needsSetup ? "휴대폰 CoolSync에서 파일 관리 권한을 허용하세요":model.error ?? "항목 없음").font(.system(size:13)).foregroundStyle(.secondary);if model.error != nil{Button("다시 확인"){model.reload()}}}.padding(24)}
                }
            }
            Divider()
            if files.hasTransfer || files.incoming != nil{
                HStack{Text(files.summary).lineLimit(1);if files.busy{ProgressView(value:files.progress).frame(width:120)};Spacer();if files.incoming != nil{Button("받기…"){files.accept()}};Button("취소"){model.cancelJobs()}}.font(.system(size:12)).padding(10);Divider()
            }
            HStack{Text(model.status);if !model.selection.isEmpty{Text("· \(model.selection.count)개 선택")};Spacer();if model.available>0{Text("사용 가능 \(ByteCountFormatter.string(fromByteCount:model.available,countStyle:.file))")}}.font(.system(size:11)).foregroundStyle(.secondary).padding(.horizontal,14).padding(.vertical,9)
        }.background(Color(nsColor:.controlBackgroundColor))
        .alert("파일 작업을 완료하지 못했습니다",isPresented:Binding(get:{model.error != nil && !model.busy},set:{if !$0{model.error=nil}})){Button("확인"){model.error=nil}}message:{Text(model.error ?? "")}
    }
    private var compactToolbar:some View{
        HStack(spacing:14){
            Button{model.back()}label:{Image(systemName:"chevron.left")}.help("뒤로")
            Button{model.up()}label:{Image(systemName:"arrow.up")}.help("상위 폴더")
            Button{model.reload()}label:{Image(systemName:"arrow.clockwise")}.help("새로 고침")
            Menu("작업"){
                Button("새 폴더…"){model.newItem(directory:true)};Button("새 파일…"){model.newItem(directory:false)}
                Divider();Button("복사"){model.copy(cut:false)}.disabled(model.selection.isEmpty);Button("잘라내기"){model.copy(cut:true)}.disabled(model.selection.isEmpty);Button("붙여넣기"){model.paste()}.disabled(!model.hasClipboard)
                Button("휴지통으로 이동…"){model.remove()}.disabled(model.selection.isEmpty)
                Divider();Button("Mac으로 복사…"){model.download()}.disabled(model.selection.isEmpty);Button("Mac으로 이동…"){model.download(move:true)}.disabled(model.selection.isEmpty);Button("Mac에서 가져오기…"){model.chooseUpload()}.disabled(model.trashMode||model.busy)
            }
            Spacer();TextField("이름으로 검색",text:$model.search).textFieldStyle(.roundedBorder).frame(width:150)
        }
    }

}
final class AppDelegate:NSObject,NSApplicationDelegate,UNUserNotificationCenterDelegate {
    var model:DashboardModel!
    private var window:NSWindow!
    private var item:NSStatusItem!
    private var statusItem:NSMenuItem!
    func applicationDidFinishLaunching(_ notification:Notification) {
        NSApp.setActivationPolicy(.accessory); model=DashboardModel(preview:CommandLine.arguments.contains("--preview"))
        item=NSStatusBar.system.statusItem(withLength:NSStatusItem.variableLength)
        item.button?.image=NSImage(systemSymbolName:"arrow.triangle.2.circlepath",accessibilityDescription:"CoolSync")
        let menu=NSMenu(); statusItem=NSMenuItem(title:model.status,action:nil,keyEquivalent:""); menu.addItem(statusItem); menu.addItem(.separator())
        let open=NSMenuItem(title:"CoolSync 열기",action:#selector(show),keyEquivalent:""); open.target=self; menu.addItem(open)
        let update=NSMenuItem(title:"업데이트 확인…",action:#selector(checkUpdate),keyEquivalent:"");update.target=self;menu.addItem(update)
        let quit=NSMenuItem(title:"종료",action:#selector(quit),keyEquivalent:"q"); quit.target=self; menu.addItem(quit); item.menu=menu
        model.onStatus={ [weak self] value in guard let self else { return }; self.statusItem.title=self.model.connected ? "\(self.model.name) · 연결됨" : value }
        window=NSWindow(contentRect:NSRect(x:0,y:0,width:1040,height:700),styleMask:[.titled,.closable,.miniaturizable,.resizable,.fullSizeContentView],backing:.buffered,defer:false)
        window.title="CoolSync"; window.titlebarAppearsTransparent=true; window.isReleasedWhenClosed=false; window.minSize=NSSize(width:900,height:560)
        window.contentViewController=NSHostingController(rootView:CoolDashboard(model:model)); window.center(); show()
        if !CommandLine.arguments.contains("--preview"){MacUpdates.shared.start()}
        UNUserNotificationCenter.current().delegate=self
        NotificationCenter.default.addObserver(self,selector:#selector(incoming(_:)),name:.init("CoolSyncIncomingFile"),object:nil)
    }
    func applicationDidBecomeActive(_ notification:Notification) { model?.refreshNotificationPermission() }
    @objc private func checkUpdate(){MacUpdates.shared.check()}
    @objc private func show() { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true) }
    @objc private func quit() { model.files.cancel(); model.engine?.shutdown(); NSApp.terminate(nil) }
    @objc private func incoming(_ notification:Notification) {
        model.tab=1; statusItem.title="파일 수신 요청 · "+model.name
        if NSApp.isActive { show() }
        let center=UNUserNotificationCenter.current()
        let name=notification.userInfo?["name"] as? String ?? "받을 파일을 확인하세요"
        func notify() {
            let content=UNMutableNotificationContent(); content.title="휴대폰에서 파일을 보냈습니다"; content.body=name; content.sound = .default
            center.add(UNNotificationRequest(identifier:UUID().uuidString,content:content,trigger:nil))
        }
        center.getNotificationSettings { [weak self] settings in
            if settings.authorizationStatus == .notDetermined {
                center.requestAuthorization(options:[.alert,.sound]) { allowed,_ in
                    if allowed { notify() } else { DispatchQueue.main.async { self?.show() } }
                }
            } else if settings.authorizationStatus == .authorized { notify() }
            else { DispatchQueue.main.async { self?.show() } }
        }
    }
    func userNotificationCenter(_ center:UNUserNotificationCenter,willPresent notification:UNNotification,withCompletionHandler completionHandler:@escaping(UNNotificationPresentationOptions)->Void) { completionHandler([.banner,.list,.sound]) }
    func userNotificationCenter(_ center:UNUserNotificationCenter,didReceive response:UNNotificationResponse,withCompletionHandler completionHandler:@escaping()->Void) { model.tab=response.notification.request.content.userInfo["kind"] as? String == "phoneNotification" ? 0:1; show(); completionHandler() }
    func applicationWillTerminate(_ notification:Notification) { model.files.cancel(); model.engine?.shutdown() }
}
