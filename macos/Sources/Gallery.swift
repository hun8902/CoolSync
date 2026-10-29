import AppKit
import SwiftUI
import AVKit
import ImageIO
import Combine
import Photos
import PhotosUI
import MapKit

struct GalleryItem:Identifiable,Decodable {
    let id:String;let name:String;let path:String;let size:Int64;let mime:String;let taken:Int64;let duration:Int64;let width:Int;let height:Int;let album:String;let favorite:Bool
    var video:Bool{mime.hasPrefix("video/")}
    var date:Date?{taken>0 ? Date(timeIntervalSince1970:Double(taken)/1000):nil}
    var remote:RemoteEntry{RemoteEntry(name:name,path:path,directory:false,size:size,modified:0)}
}
final class GalleryModel:ObservableObject {
    let explorer:ExplorerModel
    @Published var items:[GalleryItem]=[]
    @Published var thumbnails:[String:NSImage]=[:]
    @Published var selected:GalleryItem?
    @Published var original:URL?
    @Published var motion:URL?
    @Published var livePhoto:PHLivePhoto?
    @Published var loading=false
    @Published var status="휴대폰을 연결하세요"
    @Published var search=""
    @Published var category="보관함"
    @Published var ascending=false
    @Published var sort="촬영일"
    @Published var grouping="모든 사진"
    @Published var tile:Double=160
    @Published var favorites=Set(UserDefaults.standard.stringArray(forKey:"galleryFavorites") ?? [])
    private var generation=UUID()
    private var waiting=Set<String>()
    private var queue:[GalleryItem]=[]
    private var fetching=false
    let cache=FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask)[0].appendingPathComponent("CoolSync/Gallery",isDirectory:true)
    init(explorer:ExplorerModel){self.explorer=explorer;try? FileManager.default.createDirectory(at:cache,withIntermediateDirectories:true)}
    var albums:[String]{Array(Set(items.map{$0.album})).sorted{$0.localizedStandardCompare($1) == .orderedAscending}}
    func favorite(_ item:GalleryItem)->Bool{item.favorite || favorites.contains(item.path)}
    func toggle(_ item:GalleryItem){if favorites.contains(item.path){favorites.remove(item.path)}else{favorites.insert(item.path)};UserDefaults.standard.set(Array(favorites),forKey:"galleryFavorites")}
    var visible:[GalleryItem]{items.filter{item in
        (category=="보관함" || category=="비디오" && item.video || category=="즐겨찾기" && favorite(item) || category=="스크린샷" && item.path.localizedCaseInsensitiveContains("screenshot") || category=="앨범:"+item.album) && (search.isEmpty || (item.name+" "+item.album).localizedCaseInsensitiveContains(search))
    }.sorted{a,b in
        if sort=="이름"{let c=a.name.localizedStandardCompare(b.name);if c != .orderedSame{return ascending ? c == .orderedAscending:c == .orderedDescending}}
        else if a.taken != b.taken {if a.taken==0{return false};if b.taken==0{return true};return ascending ? a.taken<b.taken:a.taken>b.taken}
        return ascending ? (Int64(a.id) ?? 0)<(Int64(b.id) ?? 0):(Int64(a.id) ?? 0)>(Int64(b.id) ?? 0)
    }}
    var sections:[(String,[GalleryItem])]{
        if grouping=="모든 사진"{return [("",visible)]}
        let formatter=DateFormatter();formatter.dateFormat=grouping=="년" ? "yyyy년":"yyyy년 M월"
        var result:[(String,[GalleryItem])]=[]
        for item in visible{let key=item.date.map{formatter.string(from:$0)} ?? "촬영일 없음";if result.last?.0==key{result[result.count-1].1.append(item)}else{result.append((key,[item]))}}
        return result
    }
    func reload(){guard !loading else{return};guard explorer.connected?()==true else{status="휴대폰 연결 후 새로 고침하세요";return};generation=UUID();queue=[];waiting=[];items=[];loading=true;page(0,generation)}
    private func page(_ offset:Int,_ token:UUID){explorer.call("gallery",["offset":offset],quiet:true){[weak self]r in
        guard let self,self.generation==token else{return}
        guard r["ok"]as?Bool==true,let rows=r["items"],let data=try?JSONSerialization.data(withJSONObject:rows),let values=try?JSONDecoder().decode([GalleryItem].self,from:data) else{self.loading=false;self.status=r["error"]as?String ?? "휴대폰 앱도 업데이트하세요";return}
        self.items+=values;let next=r["next"]as?Int ?? offset,total=r["total"]as?Int ?? 0;self.status="\(self.items.count) / \(total)개"
        if next<total && next>offset{self.page(next,token)}else{self.loading=false;self.status="\(self.items.count)개 항목"}
    }}
    func thumb(_ item:GalleryItem){guard thumbnails[item.id]==nil,!waiting.contains(item.id) else{return};waiting.insert(item.id);queue.append(item);pump()}
    func cancelThumb(_ item:GalleryItem){queue.removeAll{$0.id==item.id};waiting.remove(item.id)}
    private func pump(){guard !fetching,!queue.isEmpty else{return};fetching=true;let item=queue.removeFirst(),token=generation
        explorer.call("galleryThumb",["id":item.id],quiet:true){[weak self]r in guard let self else{return};self.fetching=false;self.waiting.remove(item.id);if token==self.generation,let text=r["image"]as?String,let data=Data(base64Encoded:text),let image=NSImage(data:data){if self.thumbnails.count>600,let first=self.thumbnails.keys.first{self.thumbnails.removeValue(forKey:first)};self.thumbnails[item.id]=image};self.pump()}
    }
    func open(_ item:GalleryItem){
        // Keep downloaded originals bounded; only CoolSync's own cache is touched.
        if let urls=try?FileManager.default.contentsOfDirectory(at:cache,includingPropertiesForKeys:[.fileSizeKey,.contentModificationDateKey]){
            let ordered=urls.sorted{((try?$0.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate) ?? .distantPast)<((try?$1.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate) ?? .distantPast)}
            var bytes=ordered.reduce(Int64(0)){$0+Int64((try?$1.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0)}
            for url in ordered where bytes>1_000_000_000{let size=Int64((try?url.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0);if url != original && url != motion{try?FileManager.default.removeItem(at:url);bytes-=size}}
        }
        selected=item;original=nil;motion=nil;livePhoto=nil;status="원본 불러오는 중…"
        let target=cache.appendingPathComponent(UUID().uuidString+"."+(item.name as NSString).pathExtension)
        explorer.promise(item.remote,to:target,quiet:true,valid:{[weak self] in self?.selected?.id==item.id}){[weak self]error in
            guard let self,self.selected?.id==item.id else{return};if let error{self.status=error.localizedDescription;return};self.original=target;self.status=item.name
            if !item.video{self.extractMotion(target,item.id);self.loadLivePair(item,target)}
        }
    }
    private func loadLivePair(_ item:GalleryItem,_ still:URL){
        let base=(item.path as NSString).deletingPathExtension
        guard let companion=items.first(where:{$0.video && ($0.path as NSString).deletingPathExtension==base && ($0.path as NSString).pathExtension.lowercased()=="mov"}) else{return}
        let video=cache.appendingPathComponent(UUID().uuidString+".mov")
        explorer.promise(companion.remote,to:video,quiet:true,valid:{[weak self] in self?.selected?.id==item.id}){[weak self] error in
            guard let self,error==nil,self.selected?.id==item.id else{return}
            // Photos validates the embedded asset identifiers; filenames alone do not establish a Live Photo.
            PHLivePhoto.request(withResourceFileURLs:[still,video],placeholderImage:nil,targetSize:.zero,contentMode:.aspectFit){[weak self] photo,_ in
                DispatchQueue.main.async{guard self?.selected?.id==item.id else{return};self?.livePhoto=photo}
            }
        }
    }
    private func extractMotion(_ url:URL,_ id:String){DispatchQueue.global(qos:.utility).async{[weak self] in
        // Samsung/Google Motion Photo embeds a complete ISO BMFF movie after the still image.
        guard let self,let data=try?Data(contentsOf:url,options:.mappedIfSafe) else{return}
        let marker=Data("ftyp".utf8);var found:URL?
        var start=0
        while start<data.count,let range=data.range(of:marker,options:[],in:start..<data.count){start=range.upperBound;let pos=range.lowerBound;guard pos>=4,pos+8<data.count else{continue}
            let brand=String(data:data[(pos+4)..<(pos+8)],encoding:.ascii) ?? ""
            guard ["isom","mp42","mp41","qt  ","3gp4"].contains(brand) else{continue}
            let out=url.deletingPathExtension().appendingPathExtension("motion.mp4")
            do{try data[(pos-4)...].write(to:out);if AVURLAsset(url:out).tracks(withMediaType:.video).isEmpty{try?FileManager.default.removeItem(at:out)}else{found=out;break}}catch{}
        }
        DispatchQueue.main.async{if self.selected?.id==id{self.motion=found}}
    }}
    func step(_ delta:Int){let list=visible;guard let id=selected?.id,let index=list.firstIndex(where:{$0.id==id}),list.indices.contains(index+delta)else{return};open(list[index+delta])}
    func disconnect(){generation=UUID();loading=false;selected=nil;original=nil;motion=nil;livePhoto=nil;items=[];queue=[];waiting=[];thumbnails=[:];status="휴대폰 연결이 끊겼습니다"}
    func export(){guard let original,let selected else{return};let panel=NSSavePanel();panel.nameFieldStringValue=selected.name;if panel.runModal() == .OK,let url=panel.url{do{if FileManager.default.fileExists(atPath:url.path){try FileManager.default.removeItem(at:url)};try FileManager.default.copyItem(at:original,to:url)}catch{status=error.localizedDescription}}}
}
final class GalleryViewerState:ObservableObject {
    @Published var info=false
    @Published var live=false
    @Published var zoom:Double=1
    @Published var player:AVPlayer?
    @Published var rotation:Double=0
}
struct LivePhotoSurface:NSViewRepresentable {
    let photo:PHLivePhoto
    func makeNSView(context:Context)->PHLivePhotoView{let view=PHLivePhotoView();view.livePhoto=photo;view.startPlayback(with:.full);return view}
    func updateNSView(_ view:PHLivePhotoView,context:Context){if view.livePhoto !== photo{view.livePhoto=photo;view.startPlayback(with:.full)}}
}
struct GalleryMap:NSViewRepresentable {
    let coordinate:CLLocationCoordinate2D
    func makeNSView(context:Context)->MKMapView{let map=MKMapView();let pin=MKPointAnnotation();pin.coordinate=coordinate;map.addAnnotation(pin);map.setRegion(MKCoordinateRegion(center:coordinate,latitudinalMeters:4000,longitudinalMeters:4000),animated:false);return map}
    func updateNSView(_ view:MKMapView,context:Context){}
}
struct GalleryPane:View {
    @ObservedObject var model:GalleryModel
    @Environment(\.colorScheme) private var scheme
    var exit:(()->Void)?
    @StateObject private var viewer=GalleryViewerState()
    private func choose(_ category:String){model.category=category;model.selected=nil;viewer.player?.pause();viewer.player=nil}
    var body:some View{
        HStack(spacing:0){
            List{
                Button{exit?()}label:{Label("CoolSync",systemImage:"chevron.left")}

                Button{choose("보관함")}label:{Label("보관함",systemImage:"photo.on.rectangle")}
                Section("고정됨"){
                    Button{choose("즐겨찾기")}label:{Label("즐겨찾기",systemImage:"heart")}
                    Button{choose("비디오")}label:{Label("비디오",systemImage:"video")}
                    Button{choose("스크린샷")}label:{Label("스크린샷",systemImage:"viewfinder")}
                }
                Section("앨범"){ForEach(model.albums,id:\.self){album in Button{choose("앨범:"+album)}label:{Label(album,systemImage:"rectangle.stack")}}}
            }.listStyle(.sidebar).buttonStyle(.plain).foregroundStyle(scheme == .dark ? Color.white:Color.black).frame(width:200)
            Divider()
            VStack(spacing:0){toolbar;Divider();if let item=model.selected{detail(item)}else{library};Divider();HStack{Text(model.status);Spacer();if model.loading{ProgressView().controlSize(.small)}}.font(.caption).foregroundStyle(.secondary).padding(8)}
        }.onAppear{if model.items.isEmpty{model.reload()}}.onDisappear{viewer.player?.pause()}
        .onChange(of:model.original){url in viewer.player?.pause();viewer.live=false;viewer.zoom=1;viewer.rotation=0;viewer.player=url.flatMap{model.selected?.video==true ? AVPlayer(url:$0):nil}}
        .onChange(of:model.selected?.id){_ in viewer.player?.pause();viewer.player=nil;viewer.live=false}
    }
    private var toolbar:some View{HStack(spacing:14){
        if model.selected != nil{
            Button{viewer.player?.pause();viewer.player=nil;model.selected=nil}label:{Image(systemName:"chevron.left")}.keyboardShortcut(.escape,modifiers:[])
            Slider(value:$viewer.zoom,in:1...4).frame(width:90)
            Spacer();VStack{Text(model.selected?.name ?? "").font(.headline);Text(model.selected?.date?.formatted(date:.long,time:.standard) ?? "촬영일 없음").font(.caption).foregroundStyle(.secondary)};Spacer()
            Button{model.step(-1)}label:{Image(systemName:"chevron.left")}.keyboardShortcut(.leftArrow,modifiers:[])
            Button{model.step(1)}label:{Image(systemName:"chevron.right")}.keyboardShortcut(.rightArrow,modifiers:[])
            Button{viewer.info.toggle()}label:{Image(systemName:"info.circle")}
            Button{if let item=model.selected{model.toggle(item)}}label:{Image(systemName:model.selected.map{model.favorite($0)}==true ? "heart.fill":"heart")}
            Button{viewer.rotation+=90}label:{Image(systemName:"rotate.left")}.help("미리보기 회전")
            Button{NSApp.keyWindow?.toggleFullScreen(nil)}label:{Image(systemName:"arrow.up.left.and.arrow.down.right")}
            Button{if let url=model.original{let picker=NSSharingServicePicker(items:[url]);if let view=NSApp.keyWindow?.contentView{picker.show(relativeTo:.zero,of:view,preferredEdge:.minY)}}}label:{Image(systemName:"square.and.arrow.up")}.disabled(model.original==nil)
            Button{model.export()}label:{Image(systemName:"square.and.arrow.down")}.disabled(model.original==nil)
        }else{
            Text(model.category.replacingOccurrences(of:"앨범:",with:"")).font(.headline);Spacer()
            Slider(value:$model.tile,in:90...280).frame(width:100)
            Picker("보기",selection:$model.grouping){ForEach(["년","월","모든 사진"],id:\.self){Text($0)}}.pickerStyle(.segmented).frame(width:190)
            Menu{Picker("정렬",selection:$model.sort){Text("촬영일").tag("촬영일");Text("이름").tag("이름")};Toggle("오름차순",isOn:$model.ascending)}label:{Image(systemName:"line.3.horizontal.decrease")}
            TextField("검색",text:$model.search).textFieldStyle(.roundedBorder).frame(width:140)
            Button{model.reload()}label:{Image(systemName:"arrow.clockwise")}.disabled(model.loading)
        }
    }.buttonStyle(.borderless).padding(12)}
    private var library:some View{ScrollView{
        LazyVStack(alignment:.leading,spacing:16){ForEach(Array(model.sections.enumerated()),id:\.offset){_,section in
            if !section.0.isEmpty{Text(section.0).font(.title2.bold()).padding(.top,16)}
            LazyVGrid(columns:[GridItem(.adaptive(minimum:model.tile),spacing:12)],spacing:16){ForEach(section.1){item in
                VStack(spacing:4){ZStack(alignment:.bottomTrailing){
                    Group{if let image=model.thumbnails[item.id]{Image(nsImage:image).resizable().scaledToFit()}else{Rectangle().fill(.quaternary).overlay{Image(systemName:item.video ? "video":"photo").foregroundStyle(.secondary)}}}.frame(height:model.tile).frame(maxWidth:.infinity)
                    if item.video{Text(String(format:"%d:%02d",item.duration/60000,(item.duration/1000)%60)).font(.caption.bold()).padding(5).background(.black.opacity(0.65),in:Capsule()).foregroundStyle(.white).padding(5)}
                    if model.favorite(item){Image(systemName:"heart.fill").foregroundStyle(.white).padding(5).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)}
                }.clipShape(RoundedRectangle(cornerRadius:5)).contentShape(Rectangle()).onTapGesture(count:2){model.open(item)}.contextMenu{Button("열기"){model.open(item)};Button("즐겨찾기 전환 (Mac)"){model.toggle(item)}}.onAppear{model.thumb(item)}.onDisappear{model.cancelThumb(item)}
                }.accessibilityLabel(item.name)
            }}
        }}.padding(16)
        if model.visible.isEmpty{VStack(spacing:12){Image(systemName:"photo.on.rectangle").font(.largeTitle);Text(model.loading ? "사진 목록을 불러오는 중…":"표시할 사진이 없습니다");Text(model.status).font(.caption).foregroundStyle(.secondary)}.frame(maxWidth:.infinity).padding(60)}
    }}
    private func detail(_ item:GalleryItem)->some View{HStack(spacing:0){
        ZStack(alignment:.topLeading){Color.black.opacity(0.92)
            GeometryReader{geometry in ScrollView([.horizontal,.vertical]){Group{if viewer.live,let photo=model.livePhoto{LivePhotoSurface(photo:photo)}else if let player=viewer.player{VideoPlayer(player:player)}else if let url=model.original,let image=NSImage(contentsOf:url){Image(nsImage:image).resizable().scaledToFit()}else{ProgressView().padding(60)}}.rotationEffect(.degrees(viewer.rotation)).frame(width:max(100,geometry.size.width-40)*viewer.zoom,height:max(100,geometry.size.height-40)*viewer.zoom).padding(20)}}
            if model.motion != nil || model.livePhoto != nil{Button{viewer.live.toggle();viewer.player?.pause();viewer.player=viewer.live ? model.motion.map{AVPlayer(url:$0)}:nil;if viewer.live{viewer.player?.play()}}label:{Label("LIVE",systemImage:viewer.live ? "pause.circle":"play.circle")}.buttonStyle(.borderedProminent).tint(.gray).padding(14)}
        }
        if viewer.info{VStack(alignment:.leading,spacing:14){Text("정보").font(.headline);Text(item.name).textSelection(.enabled);Text(item.date?.formatted(date:.long,time:.standard) ?? "촬영일 없음");Divider();Text("\(item.width) × \(item.height)");Text(ByteCountFormatter.string(fromByteCount:item.size,countStyle:.file));Text(item.mime);Text(item.album);if item.video{Text("\(item.duration/1000)초")};Divider();Text(item.path).font(.caption).textSelection(.enabled);if let url=model.original{metadata(url)};Spacer()}.padding(18).frame(width:240).background(.regularMaterial)}
    }}
    private func metadata(_ url:URL)->some View{let source=CGImageSourceCreateWithURL(url as CFURL,nil);let properties=source.flatMap{CGImageSourceCopyPropertiesAtIndex($0,0,nil)as?[String:Any]} ?? [:];let tiff=properties[kCGImagePropertyTIFFDictionary as String]as?[String:Any] ?? [:];let exif=properties[kCGImagePropertyExifDictionary as String]as?[String:Any] ?? [:]
        return VStack(alignment:.leading,spacing:8){Text([tiff["Make"],tiff["Model"]].compactMap{$0 as?String}.joined(separator:" "));if let lens=exif["LensModel"]as?String{Text(lens)};if let f=exif["FNumber"]{Text("ƒ"+String(describing:f))};if let exposure=exif["ExposureTime"]{Text("노출 "+String(describing:exposure)+"초")};if let gps=properties[kCGImagePropertyGPSDictionary as String]as?[String:Any],let lat=gps["Latitude"]as?Double,let lon=gps["Longitude"]as?Double{GalleryMap(coordinate:CLLocationCoordinate2D(latitude:lat*(gps["LatitudeRef"]as?String == "S" ? -1:1),longitude:lon*(gps["LongitudeRef"]as?String == "W" ? -1:1))).frame(height:180)}}.font(.caption)
    }
}
