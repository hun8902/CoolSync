import AppKit
import SwiftUI
import AVKit
import Photos
import PhotosUI
import MapKit
import Combine
import UniformTypeIdentifiers

final class GalleryLiveCoordinator:NSObject,PHLivePhotoViewDelegate {
    var effect="LIVE"
    func livePhotoView(_ livePhotoView:PHLivePhotoView,didEndPlaybackWith playbackStyle:PHLivePhotoViewPlaybackStyle){if effect=="루프"{livePhotoView.startPlayback(with:.full)}}
}
final class GalleryViewerState:ObservableObject {
    @Published var info=false;@Published var live=false;@Published var zoom=1.0;@Published var player:AVPlayer?
    @Published var rotation=0.0;@Published var square=false;@Published var titles=false;@Published var showSidebar=true
    @Published var editorTab="조절";@Published var editorTool="";@Published var brush=0.04
    @Published var markup="";@Published var markupColor="흰색";@Published var compare=false
    @Published var smartEditing:String?;@Published var smartSheet=false;@Published var smartName="새 스마트 앨범";@Published var smartRule=PhotoAlbumRule()
    @Published var music:AVAudioPlayer?;@Published var slideElapsed=0.0
    @Published var dateSheet=false;@Published var proposedDate=Date()
}
struct LivePhotoSurface:NSViewRepresentable {
    let photo:PHLivePhoto;var effect="LIVE"
    func makeCoordinator()->GalleryLiveCoordinator{let c=GalleryLiveCoordinator();c.effect=effect;return c}
    func makeNSView(context:Context)->PHLivePhotoView{let view=PHLivePhotoView();view.delegate=context.coordinator;view.livePhoto=photo;view.startPlayback(with:.full);return view}
    func updateNSView(_ view:PHLivePhotoView,context:Context){context.coordinator.effect=effect;if view.livePhoto !== photo{view.livePhoto=photo;view.startPlayback(with:.full)}}
}
struct PhotoMapSurface:NSViewRepresentable {
    let points:[PhotoLocation];var open:((GalleryItem)->Void)?
    final class Pin:MKPointAnnotation {var item:GalleryItem?}
    final class Coordinator:NSObject,MKMapViewDelegate {var open:((GalleryItem)->Void)?;func mapView(_ mapView:MKMapView,didSelect view:MKAnnotationView){if let pin=view.annotation as?Pin,let item=pin.item{open?(item)}}}
    func makeCoordinator()->Coordinator{let c=Coordinator();c.open=open;return c}
    func makeNSView(context:Context)->MKMapView{let map=MKMapView();map.delegate=context.coordinator;map.showsZoomControls=true;return map}
    func updateNSView(_ map:MKMapView,context:Context){context.coordinator.open=open;let old=map.annotations.compactMap{annotation->String? in guard let pin=annotation as?Pin,let path=pin.item?.path else{return nil};return path+"|\(pin.coordinate.latitude)|\(pin.coordinate.longitude)"};if Set(old)==Set(points.map{$0.item.path+"|\($0.latitude)|\($0.longitude)"}){return};map.removeAnnotations(map.annotations);let annotations=points.map{point->Pin in let p=Pin();p.coordinate=CLLocationCoordinate2D(latitude:point.latitude,longitude:point.longitude);p.title=point.item.name;p.item=point.item;return p};map.addAnnotations(annotations);if !annotations.isEmpty{map.showAnnotations(annotations,animated:false)}}
}
struct GalleryMap:NSViewRepresentable {
    let coordinate:CLLocationCoordinate2D
    func makeNSView(context:Context)->MKMapView{let map=MKMapView();let pin=MKPointAnnotation();pin.coordinate=coordinate;map.addAnnotation(pin);map.setRegion(MKCoordinateRegion(center:coordinate,latitudinalMeters:4000,longitudinalMeters:4000),animated:false);return map}
    func updateNSView(_ view:MKMapView,context:Context){}
}
struct GalleryPane:View {
    @ObservedObject var model:GalleryModel
    var exit:(()->Void)?
    @StateObject private var viewer=GalleryViewerState()
    init(model:GalleryModel,exit:(()->Void)?=nil,viewer:GalleryViewerState=GalleryViewerState()){self.model=model;self.exit=exit;_viewer=StateObject(wrappedValue:viewer)}
    @Environment(\.colorScheme) private var scheme
    private var name:String{
        if model.category.hasPrefix("사용자앨범:"){return model.libraryDoc.albums.first{$0.id==String(model.category.dropFirst(6))}?.name ?? "앨범"}
        if model.category.hasPrefix("사람:"){return model.libraryDoc.people.first{$0.id==String(model.category.dropFirst(3))}?.name ?? "사람들"}
        return model.category.replacingOccurrences(of:"앨범:",with:"")
    }
    var body:some View{
        HStack(spacing:0){
            if viewer.showSidebar && model.selected==nil && !model.slideshow{sidebar;Divider()}
            VStack(spacing:0){toolbar;Divider();content;footer}
        }.background(Color(nsColor:.windowBackgroundColor))
        .onAppear{if model.items.isEmpty{model.reload()}}
        .onDisappear{viewer.player?.pause();viewer.music?.stop();model.slideshow=false}
        .onChange(of:model.original){_ in configurePlayer()}
        .onChange(of:model.currentURL){_ in if !model.editing{configurePlayer()}}
        .onChange(of:model.selected?.id){_ in viewer.player?.pause();viewer.player=nil;viewer.live=false;viewer.zoom=1;viewer.rotation=0;viewer.slideElapsed=0}
        .onChange(of:model.slideshow){playing in if playing{viewer.info=false;if let url=model.slideshowMusic{viewer.music=try?AVAudioPlayer(contentsOf:url);viewer.music?.numberOfLoops = -1;viewer.music?.play()}}else{viewer.music?.stop()}}
        .onReceive(Timer.publish(every:0.5,on:.main,in:.common).autoconnect()){_ in guard model.slideshow,model.original != nil else{return};viewer.slideElapsed+=0.5;if model.selected?.video==true{if let player=viewer.player,player.currentTime()>=(player.currentItem?.duration ?? .positiveInfinity){advanceMovie()}}else if viewer.slideElapsed>=model.slideshowInterval{model.advanceSlideshow()}}
        .onReceive(NotificationCenter.default.publisher(for:.AVPlayerItemDidPlayToEndTime)){notification in guard let item=notification.object as?AVPlayerItem,item===viewer.player?.currentItem else{return};if model.slideshow{advanceMovie()}else if viewer.live,model.selected.map({model.note($0).edit?.liveEffect=="루프"})==true{viewer.player?.seek(to:.zero);viewer.player?.play()}}
        .onDrop(of:[UTType.fileURL.identifier],isTargeted:nil){providers in importDrop(providers)}
        .sheet(isPresented:$viewer.smartSheet){smartAlbumSheet}
        .sheet(isPresented:$viewer.dateSheet){dateSheet}
        .background(keyboardCommands)
    }
    private func configurePlayer(){viewer.player?.pause();viewer.live=false;viewer.zoom=1;guard let item=model.selected else{return};if item.video,let url=model.currentURL{viewer.player=AVPlayer(url:url);if model.slideshow{viewer.player?.play()}}else{viewer.player=nil}}
    private func advanceMovie(){guard let index=model.slideshowItems.firstIndex(where:{$0.id==model.selected?.id}),index+1<model.slideshowItems.count else{model.slideshow=false;return};model.open(model.slideshowItems[index+1])}
    private var sidebar:some View{
        ScrollView{VStack(alignment:.leading,spacing:4){
            Button{exit?()}label:{HStack{Image(systemName:"chevron.left");Text("CoolSync");Spacer()}}.buttonStyle(.plain).padding(.bottom,12)
            nav("보관함","photo.on.rectangle");nav("모음","rectangle.stack")
            heading("고정됨")
            nav("즐겨찾기","heart");nav("최근 저장된 항목","clock.arrow.circlepath");nav("지도","map");nav("비디오","video");nav("Live Photo","livephoto");nav("스크린샷","viewfinder");nav("최근 삭제된 항목","trash",locked:true);nav("사람들","person.crop.circle");nav("가려진 항목","eye.slash",locked:true)
            heading("미디어 유형")
            nav("셀피","person.crop.square");nav("파노라마","pano");nav("RAW","camera");nav("GIF","photo.stack");nav("중복된 항목","square.on.square");nav("편집됨","slider.horizontal.3")
            HStack{heading("앨범");Spacer();Menu{Button("새 앨범"){model.createAlbum()};Button("새 폴더"){model.createAlbum(folder:true)};Button("새 스마트 앨범"){viewer.smartEditing=nil;viewer.smartSheet=true}}label:{Image(systemName:"plus")}.menuStyle(.borderlessButton).frame(width:20)}
            nav("모든 앨범","rectangle.stack")
            ForEach(model.libraryDoc.albums.filter{$0.folder==nil || $0.folder=="root"}){album in albumRow(album)}
            ForEach(model.albums,id:\.self){album in nav(album,"folder",category:"앨범:"+album)}
            heading("유틸리티")
            nav("추억","sparkles")
            Button{model.analysisRunning ? model.stopAnalysis():model.startAnalysis()}label:{Label(model.analysisRunning ? "분석 중단":"사진 분석",systemImage: model.analysisRunning ? "stop.circle":"sparkle.magnifyingglass")}.buttonStyle(.plain).padding(8)
        }.padding(10)}.frame(width:210).background(.ultraThinMaterial)
    }
    private func heading(_ title:String)->some View{Text(title).font(.system(size:11,weight:.semibold)).foregroundStyle(.secondary).padding(.top,18).padding(.bottom,5).padding(.leading,7)}
    private func nav(_ title:String,_ symbol:String,category:String?=nil,locked:Bool=false)->some View{
        let value=category ?? title
        return Button{viewer.player?.pause();model.choose(value)}label:{HStack(spacing:9){Image(systemName:symbol).foregroundStyle(Color.accentColor).frame(width:22);Text(title).lineLimit(1);Spacer(minLength:0);if locked{Image(systemName:"lock.fill").font(.caption2).foregroundStyle(.secondary)}}}.buttonStyle(.plain).padding(.horizontal,8).padding(.vertical,7).background(model.category==value ? Color.primary.opacity(0.12):Color.clear,in:RoundedRectangle(cornerRadius:7))
    }
    @ViewBuilder private func albumRow(_ album:PhotoAlbum)->some View{
        if album.folder=="root"{
            DisclosureGroup{ForEach(model.libraryDoc.albums.filter{$0.folder==album.id}){child in nav(child.name,child.rule==nil ? "rectangle.stack":"gearshape",category:"사용자앨범:"+child.id).contextMenu{albumMenu(child)}}}label:{Label(album.name,systemImage:"folder").foregroundStyle(Color.accentColor)}.padding(.horizontal,7).contextMenu{albumMenu(album)}
        }else{nav(album.name,album.rule==nil ? "rectangle.stack":"gearshape",category:"사용자앨범:"+album.id).contextMenu{albumMenu(album)}}
    }
    @ViewBuilder private func albumMenu(_ album:PhotoAlbum)->some View{
        Button("이름 변경"){model.renameAlbum(album)};if let rule=album.rule{Button("스마트 앨범 편집"){viewer.smartEditing=album.id;viewer.smartName=album.name;viewer.smartRule=rule;viewer.smartSheet=true}}
        if album.folder != "root"{Menu("폴더로 이동"){Button("최상위"){model.moveAlbum(album,to:nil)};ForEach(model.libraryDoc.albums.filter{$0.folder=="root"}){folder in Button(folder.name){model.moveAlbum(album,to:folder)}}}}
        Button("앨범 삭제",role:.destructive){model.deleteAlbum(album)}
    }
    private var toolbar:some View{
        HStack(spacing:12){
            if model.selected==nil{Button{viewer.showSidebar.toggle()}label:{Image(systemName:"sidebar.left")}.help("사이드바 표시")}
            if let item=model.selected{
                Button{viewer.player?.pause();model.selected=nil;model.editing=false;model.slideshow=false}label:{Image(systemName:"chevron.left").frame(width:30,height:30).background(Color.primary.opacity(0.08),in:Circle())}.keyboardShortcut(.escape,modifiers:[])
                HStack(spacing:7){Button{viewer.zoom=max(1,viewer.zoom-0.25)}label:{Image(systemName:"minus")};Slider(value:$viewer.zoom,in:1...4).tint(.gray).frame(width:80);Button{viewer.zoom=min(4,viewer.zoom+0.25)}label:{Image(systemName:"plus")}}.padding(8).background(Color.primary.opacity(0.08),in:Capsule())
                Spacer(minLength:8)
                VStack(spacing:3){Text(model.title(item)).font(.headline).lineLimit(1);Text((model.captureDate(item)?.formatted(date:.long,time:.standard) ?? "촬영일 없음")+" · "+position(item)).font(.caption).foregroundStyle(.secondary)}
                Spacer(minLength:8)
                HStack(spacing:14){
                Button{viewer.info.toggle()}label:{Image(systemName:"info.circle")}
                Button{model.shareTargets()}label:{Image(systemName:"square.and.arrow.up")}.disabled(model.original==nil)
                Button{model.toggle(item)}label:{Image(systemName:model.favorite(item) ? "heart.fill":"heart")}
                Button{if model.editing{model.cancelEditing()}else{model.beginEditing()}}label:{Text(model.editing ? "취소":"편집")}.disabled(model.original==nil || model.saving)
                Button{model.autoEnhance();if !model.editing{model.beginEditing();model.autoEnhance()}}label:{Image(systemName:"wand.and.stars")}.disabled(item.video || model.original==nil)
                Menu{Button("내보내기…"){model.exportTargets()};Button("수정되지 않은 원본 내보내기…"){model.exportTargets(originals:true)};Button("Mac 사진 앱에 추가…"){model.addToMacPhotos()};Button("편집본을 휴대폰에 저장"){model.saveEditedToPhone()}.disabled(model.note(item).rendered==nil);Divider();Button("사진 복사"){model.copyPhoto()};Button("인쇄…"){model.printPhoto()};Button("슬라이드쇼"){model.startSlideshow()};Button("가리기 / 표시"){model.hideTargets()};Button("삭제",role:.destructive){model.deleteTargets()}}label:{Image(systemName:"ellipsis")}.disabled(model.editing || model.original==nil)
                if model.editing{Button("완료"){model.saveEditing()}.buttonStyle(.borderedProminent).disabled(model.saving)}
                }.padding(.horizontal,12).padding(.vertical,8).background(Color.primary.opacity(0.08),in:Capsule())
            }else{
                VStack(alignment:.leading,spacing:3){Text(name+(model.timelinePrefix.isEmpty ? "":" · "+model.timelinePrefix)).font(.headline);Text(dateRange).font(.caption).foregroundStyle(.secondary).lineLimit(1)}
                Spacer(minLength:6)
                Button{model.tile=max(90,model.tile-20)}label:{Image(systemName:"minus")}
                Button{model.tile=min(300,model.tile+20)}label:{Image(systemName:"plus")}
                if model.category=="보관함" || model.category.hasPrefix("앨범:"){
                    Picker("",selection:$model.grouping){ForEach(["년","월","모든 사진"],id:\.self){Text($0)}}.pickerStyle(.segmented).frame(width:180)
                }
                Menu{Toggle("정사각형 사진",isOn:$viewer.square);Toggle("제목 보기",isOn:$viewer.titles);Divider();Picker("정렬",selection:$model.sort){Text("촬영일").tag("촬영일");Text("제목").tag("제목");Text("파일명").tag("이름")};Toggle("오름차순",isOn:$model.ascending)}label:{Image(systemName:"line.3.horizontal.decrease")}
                actionsMenu
                Button{viewer.info.toggle()}label:{Image(systemName:"info.circle")}.disabled(model.selection.count != 1)
                Button{model.shareTargets()}label:{Image(systemName:"square.and.arrow.up")}.disabled(model.selection.isEmpty)
                Button{for item in model.targets{model.toggle(item)}}label:{Image(systemName:"heart")}.disabled(model.selection.isEmpty)
                TextField("검색",text:$model.search).textFieldStyle(.roundedBorder).frame(minWidth:100,maxWidth:180)
            }
        }.buttonStyle(.borderless).padding(.horizontal,16).frame(height:58).background(.ultraThinMaterial)
    }
    private func position(_ item:GalleryItem)->String{let values=model.slideshow ? model.slideshowItems:model.visible;return "\((values.firstIndex{$0.id==item.id} ?? 0)+1)/\(values.count)"}
    private var dateRange:String{let values=model.visible.compactMap{model.captureDate($0)};guard let first=values.min(),let last=values.max()else{return "\(model.visible.count)개 항목"};return first.formatted(date:.abbreviated,time:.omitted)+"–"+last.formatted(date:.abbreviated,time:.omitted)}
    private var footer:some View{
        VStack(spacing:0){Divider();HStack(spacing:10){if model.loading || model.saving{ProgressView().controlSize(.small)};Text(model.analysisRunning ? model.analysisProgress:model.status).lineLimit(1);Spacer();if !model.selection.isEmpty{Text("\(model.selection.count)개 선택됨")};if model.slideshow{Button("중단"){model.slideshow=false}}}.font(.caption).foregroundStyle(.secondary).padding(8)}
    }
    @ViewBuilder private var content:some View{
        if let item=model.selected{detail(item)}
        else if (model.category=="가려진 항목" || model.category=="최근 삭제된 항목") && !model.unlocked{locked}
        else if model.category=="최근 삭제된 항목"{deletedView}
        else if model.category=="사람들"{peopleView}
        else if model.category=="지도"{mapView}
        else if model.category=="모음" || model.category=="추억"{collections}
        else if model.category=="모든 앨범"{albumsView}
        else if model.category=="중복된 항목"{duplicatesView}
        else{library}
    }
    private var library:some View{ScrollViewReader{proxy in ScrollView{
        if model.grouping != "모든 사진",model.category=="보관함"{timeline}
        else{LazyVGrid(columns:[GridItem(.adaptive(minimum:model.tile),spacing:12)],spacing:16){ForEach(model.visible){item in cell(item)}}.padding(18)}
        if model.visible.isEmpty{empty("표시할 사진이 없습니다",icon:"photo.on.rectangle")}
    }.background(Color(nsColor:.textBackgroundColor)).overlay(alignment:.trailing){if viewer.info,let item=model.targets.first{PhotoInfoPane(model:model,item:item,viewer:viewer).frame(width:300).background(.regularMaterial).padding(12)}}}}
    private var timeline:some View{LazyVGrid(columns:[GridItem(.adaptive(minimum:300),spacing:18)],spacing:20){ForEach(Array(model.sections.enumerated()),id:\.offset){_,section in
        Button{if let item=section.1.first,let date=model.captureDate(item){let f=DateFormatter();f.dateFormat=model.grouping=="년" ? "yyyy":"yyyy-MM";model.timelinePrefix=f.string(from:date)};model.grouping="모든 사진"}label:{ZStack(alignment:.bottomLeading){if let item=section.1.first,let image=model.thumbnails[item.id]{Image(nsImage:image).resizable().scaledToFill().frame(height:250).clipped()}else{Rectangle().fill(.quaternary).frame(height:250)};LinearGradient(colors:[.clear,.black.opacity(0.8)],startPoint:.center,endPoint:.bottom);VStack(alignment:.leading){Text(section.0).font(.title.bold());Text("\(section.1.count)개 항목").font(.caption)}.foregroundStyle(.white).padding(16)}.clipShape(RoundedRectangle(cornerRadius:12))}.buttonStyle(.plain).onAppear{if let item=section.1.first{model.thumb(item)}}
    }}.padding(18)}
    private func cell(_ item:GalleryItem)->some View{
        VStack(spacing:5){ZStack(alignment:.bottomTrailing){
            Group{if let image=model.thumbnails[item.id]{if viewer.square{Image(nsImage:image).resizable().scaledToFill()}else{Image(nsImage:image).resizable().scaledToFit()}}else{RoundedRectangle(cornerRadius:4).fill(.quaternary).overlay{Image(systemName:item.video ? "video":"photo").foregroundStyle(.secondary)}}}.frame(height:model.tile).frame(maxWidth:.infinity).clipped()
            if item.video{Text(String(format:"%d:%02d",item.duration/60000,item.duration/1000%60)).font(.caption.bold()).padding(5).foregroundStyle(.white).shadow(radius:3)}
            HStack{if model.favorite(item){Image(systemName:"heart.fill")};if model.note(item).edit != nil{Image(systemName:"slider.horizontal.3")};Spacer();if item.live==true || model.motionPaths.contains(item.path) || model.note(item).labels.contains("live"){Image(systemName:"livephoto")}}.font(.caption).foregroundStyle(.white).shadow(radius:3).padding(6).frame(maxHeight:.infinity,alignment:.top)
            if model.selection.contains(item.id){RoundedRectangle(cornerRadius:5).stroke(Color.accentColor,lineWidth:4);Image(systemName:"checkmark.circle.fill").symbolRenderingMode(.palette).foregroundStyle(.white,Color.accentColor).padding(6)}
        }.clipShape(RoundedRectangle(cornerRadius:5)).contentShape(Rectangle())
        .onTapGesture(count:2){model.open(item)}.onTapGesture{model.select(item)}
        .onDrag{model.dragProvider(item)}.contextMenu{photoMenu(item)}
        .onAppear{model.thumb(item)}.onDisappear{model.cancelThumb(item)}
        if viewer.titles{Text(model.title(item)).font(.caption).lineLimit(1)}
        }.id(item.id).accessibilityLabel(model.title(item)).accessibilityAddTraits(model.selection.contains(item.id) ? .isSelected:[])
    }
    private func detail(_ item:GalleryItem)->some View{
        HStack(spacing:0){
            ZStack{
                Color(red:0.105,green:0.105,blue:0.105)
                GeometryReader{geometry in
                    ScrollView([.horizontal,.vertical]){Group{
                        if viewer.live,let photo=model.livePhoto{LivePhotoSurface(photo:photo,effect:model.note(item).edit?.liveEffect ?? "LIVE")}
                        else if let player=viewer.player{VideoPlayer(player:player)}
                        else if !model.editing,let url=model.currentURL,url.pathExtension.lowercased()=="gif"{AnimatedPhotoSurface(url:url)}
                        else if model.editing,!viewer.compare,let image=model.editPreview{Image(nsImage:image).resizable().scaledToFit()}
                        else if let url=viewer.compare ? model.original:model.currentURL,let image=NSImage(contentsOf:url){Image(nsImage:image).resizable().scaledToFit()}
                        else{VStack{ProgressView();Text(model.status).foregroundStyle(.white).font(.caption)}}
                    }.rotationEffect(.degrees(viewer.rotation)).frame(width:max(100,geometry.size.width-40)*viewer.zoom,height:max(100,geometry.size.height-40)*viewer.zoom).padding(20)
                    .overlay{if model.editing && !viewer.editorTool.isEmpty{Color.clear.contentShape(Rectangle()).gesture(SpatialTapGesture().onEnded{value in let x=min(1,max(0,value.location.x/max(1,geometry.size.width))),y=min(1,max(0,value.location.y/max(1,geometry.size.height)));if viewer.editorTool=="보정" || viewer.editorTool=="적목"{model.draft.retouches.append(PhotoRetouch(x:x,y:y,radius:viewer.brush,redEye:viewer.editorTool=="적목"))}else{model.draft.marks.append(PhotoMarkup(kind:viewer.editorTool,text:viewer.markup,x:x,y:y,color:viewer.markupColor))}})}}}
                }
                VStack{HStack{
                    if model.motion != nil || model.livePhoto != nil{liveButton(item)}
                    Spacer();if model.editing{Toggle("원본 비교",isOn:$viewer.compare).toggleStyle(.button).tint(.gray)}
                };Spacer();HStack{
                    Button{model.step(-1)}label:{Image(systemName:"chevron.left.circle.fill")}.keyboardShortcut(.leftArrow,modifiers:[]).disabled(model.editing || model.saving);Spacer()
                    if model.slideshow{Text("슬라이드쇼").font(.caption);Button{model.slideshow=false}label:{Image(systemName:"stop.fill")}}
                    Button{NSApp.keyWindow?.toggleFullScreen(nil)}label:{Image(systemName:"arrow.up.left.and.arrow.down.right")};Spacer();Button{model.step(1)}label:{Image(systemName:"chevron.right.circle.fill")}.keyboardShortcut(.rightArrow,modifiers:[]).disabled(model.editing || model.saving)
                }}.buttonStyle(.borderless).foregroundStyle(.white).padding(16)
            }
            if model.editing{PhotoEditorPane(model:model,viewer:viewer).frame(width:290).background(.regularMaterial)}

        }.overlay(alignment:.trailing){if viewer.info && !model.editing{PhotoInfoPane(model:model,item:item,viewer:viewer).frame(width:300).frame(maxHeight:650).background(.regularMaterial,in:RoundedRectangle(cornerRadius:16)).overlay(RoundedRectangle(cornerRadius:16).stroke(Color.primary.opacity(0.12))).shadow(radius:14).padding(20)}}.onChange(of:model.draft){_ in model.recordDraft();model.refreshPreview();if item.video{viewer.player?.isMuted=model.draft.muted;if viewer.player?.rate != 0{viewer.player?.rate=Float(model.draft.speed)};if let player=viewer.player,let current=player.currentItem{let duration=Double(item.duration)/1000;current.forwardPlaybackEndTime=CMTime(seconds:max(0.01,model.draft.trimEnd*duration),preferredTimescale:600);player.seek(to:CMTime(seconds:model.draft.trimStart*duration,preferredTimescale:600))}}}
    }
    private func liveButton(_ item:GalleryItem)->some View{Menu{
        Button(viewer.live ? "재생 중단":"Live Photo 재생"){viewer.live.toggle();viewer.player?.pause();viewer.player=viewer.live ? model.motion.map{AVPlayer(url:$0)}:nil;if viewer.live{viewer.player?.play()}}
        Button("바운스"){model.bounce()}.disabled(model.motion==nil);Button("장노출"){model.longExposure()}.disabled(model.motion==nil);
        ForEach(["LIVE","루프","끔"],id:\.self){effect in Button(effect){model.annotate(item){var edit=$0.edit ?? PhotoAdjustment();edit.liveEffect=effect;$0.edit=edit};viewer.live=effect != "끔";viewer.player=viewer.live ? model.motion.map{AVPlayer(url:$0)}:nil;if viewer.live{viewer.player?.play()}}}
    }label:{Label(viewer.live ? "LIVE 재생 중":"LIVE",systemImage:"livephoto")}.menuStyle(.borderlessButton).frame(width:125).padding(7).background(.black.opacity(0.5),in:Capsule())}
    @ViewBuilder private func photoMenu(_ item:GalleryItem)->some View{
        Button("열기"){model.open(item)}.onAppear{if !model.selection.contains(item.id){model.selection=[item.id]}};Button(model.favorite(item) ? "즐겨찾기에서 제거":"즐겨찾기에 추가"){model.toggle(item)}
        Menu("앨범에 추가"){Button("새 앨범"){model.selection=[item.id];model.createAlbum()};ForEach(model.libraryDoc.albums.filter{$0.folder != "root" && $0.rule==nil}){album in Button(album.name){if model.selection.isEmpty{model.selection=[item.id]};model.addToAlbum(album)}}}
        if model.category.hasPrefix("사용자앨범:"){Button("앨범에서 제거"){if model.selection.isEmpty{model.selection=[item.id]};model.removeFromAlbum()}}
        Button("복제"){model.duplicate(item)};Divider();Button("정보 가져오기"){model.open(item);viewer.info=true};Button("편집"){model.editAfterOpen=true;model.open(item);viewer.info=false}
        Button("사진 가리기 / 표시"){if model.selection.isEmpty{model.selection=[item.id]};model.hideTargets()}
        Button("내보내기"){if model.selection.isEmpty{model.selection=[item.id]};model.exportTargets()};Button("수정되지 않은 원본 내보내기"){if model.selection.isEmpty{model.selection=[item.id]};model.exportTargets(originals:true)}
        Divider();Button("편집 복사"){model.selected=item;model.copyAdjustments();model.selected=nil};Button("편집 붙여넣기"){if model.selection.isEmpty{model.selection=[item.id]};model.pasteAdjustments()}.disabled(model.copiedEdit==nil)
        Button("사진 삭제",role:.destructive){if model.selection.isEmpty{model.selection=[item.id]};model.deleteTargets()}
    }
    private var actionsMenu:some View{Menu{
        Button("새 앨범"){model.createAlbum()};Button("새 스마트 앨범"){viewer.smartEditing=nil;viewer.smartSheet=true};Button("새 폴더"){model.createAlbum(folder:true)};Divider()
        Button("가져오기…"){model.importPhotos()};Button("새로 고침"){model.timelinePrefix="";model.reload()}.disabled(model.loading)
        Button("모두 선택"){model.selection=Set(model.visible.map{$0.id})};Button("선택 해제"){model.selection=[]}
        Button("내보내기…"){model.exportTargets()}.disabled(model.selection.isEmpty);Button("Mac 사진 앱에 추가…"){model.addToMacPhotos()}.disabled(model.selection.isEmpty);Button("수정되지 않은 원본 내보내기…"){model.exportTargets(originals:true)}.disabled(model.selection.isEmpty)
        Divider();Button("슬라이드쇼 재생"){model.startSlideshow()};Menu("슬라이드 간격"){ForEach([3.0,5.0,8.0,12.0],id:\.self){seconds in Button("\(Int(seconds))초"){model.slideshowInterval=seconds}}};Button("슬라이드쇼 음악 선택…"){model.chooseMusic()}
        Button(model.analysisRunning ? "분석 중단":"사람·텍스트·장소·중복 분석"){model.analysisRunning ? model.stopAnalysis():model.startAnalysis()}
        Divider();Button("실행 취소"){model.undoLibrary()}.disabled(model.undoDocuments.isEmpty);Button("다시 실행"){model.redoLibrary()}.disabled(model.redoDocuments.isEmpty)
        Button("가리기 / 표시"){model.hideTargets()}.disabled(model.selection.isEmpty);Button("삭제",role:.destructive){model.deleteTargets()}.disabled(model.selection.isEmpty)
    }label:{Image(systemName:"ellipsis")}}
    private var locked:some View{VStack(spacing:18){Image(systemName:"lock.fill").font(.system(size:45));Text("이 앨범은 잠겨 있습니다").font(.title2);Button("앨범 보기"){model.unlock{if model.category=="최근 삭제된 항목"{model.loadDeleted()}}}.buttonStyle(.borderedProminent)}.frame(maxWidth:.infinity,maxHeight:.infinity)}
    private var deletedView:some View{VStack{HStack{Text("휴대폰 휴지통 · 시스템 항목은 휴대폰 승인 필요").foregroundStyle(.secondary);Spacer();Button("모두 선택"){model.deletedSelection=Set(model.deleted.map{$0.id})};Button("복원"){model.restoreDeleted()}.disabled(model.deletedSelection.isEmpty);Button("영구 삭제",role:.destructive){model.restoreDeleted(permanent:true)}.disabled(model.deletedSelection.isEmpty)}.padding(16);List(model.deleted,selection:$model.deletedSelection){item in HStack{Image(systemName:"photo.on.rectangle").font(.title);VStack(alignment:.leading){Text(item.name);Text(item.original).font(.caption).foregroundStyle(.secondary)};Spacer();Text(item.expires.map{"남은 \(max(0,Int(ceil((Double($0)/1000-Date().timeIntervalSince1970)/86400))))일"} ?? Date(timeIntervalSince1970:Double(item.deleted)/1000).formatted(date:.abbreviated,time:.shortened)).font(.caption)}.tag(item.id)};if model.deleted.isEmpty{empty("최근 삭제된 항목이 없습니다",icon:"trash")}}}
    private var peopleView:some View{ScrollView{LazyVGrid(columns:[GridItem(.adaptive(minimum:150),spacing:24)],spacing:24){ForEach(model.peopleVisible){person in Button{model.choose("사람:"+person.id)}label:{VStack{Group{if let data=person.portrait,let image=NSImage(data:data){Image(nsImage:image).resizable().scaledToFill()}else{Image(systemName:"person.crop.circle.fill").resizable()}}.frame(width:120,height:120).clipShape(Circle());Text(person.name);Text("\(person.paths.count)개 사진").font(.caption).foregroundStyle(.secondary)}}.buttonStyle(.plain).contextMenu{Button("이름 변경"){model.renamePerson(person)};Menu("동일 인물로 병합"){ForEach(model.libraryDoc.people.filter{$0.id != person.id}){target in Button(target.name){model.mergePerson(person,into:target)}}}}}}.padding(25);if model.peopleVisible.isEmpty{analysisEmpty("사람들","person.crop.circle")}}}
    private var mapView:some View{Group{if model.locations.isEmpty{analysisEmpty("지도에 표시할 위치가 없습니다","map")}else{PhotoMapSurface(points:model.locations,open:{model.open($0)}).overlay(alignment:.bottom){Text("사진 위치를 선택하면 원본을 엽니다").font(.caption).padding(10).background(.regularMaterial,in:Capsule()).padding()}}}}
    private var collections:some View{ScrollView{VStack(alignment:.leading,spacing:24){Text(model.category=="추억" ? "추억":"모음").font(.largeTitle.bold());if model.category=="모음"{HStack(spacing:16){collectionShortcut("최근 저장된 항목","clock");collectionShortcut("즐겨찾기","heart");collectionShortcut("사람들","person.crop.circle");collectionShortcut("지도","map")}};Text("추억").font(.title2.bold());LazyVGrid(columns:[GridItem(.adaptive(minimum:260),spacing:20)],spacing:20){ForEach(model.memories){memory in Button{model.startSlideshow(memory.items)}label:{ZStack(alignment:.bottomLeading){if let item=memory.items.first,let image=model.thumbnails[item.id]{Image(nsImage:image).resizable().scaledToFill().frame(height:220).clipped()}else{Rectangle().fill(.quaternary).frame(height:220)};LinearGradient(colors:[.clear,.black.opacity(0.8)],startPoint:.top,endPoint:.bottom);VStack(alignment:.leading){Text(memory.title).font(.title2.bold());Text(memory.subtitle)}.padding(16).foregroundStyle(.white)}.clipShape(RoundedRectangle(cornerRadius:14))}.buttonStyle(.plain).onAppear{if let item=memory.items.first{model.thumb(item)}}}};if model.memories.isEmpty{empty("촬영일이 있는 사진에서 추억이 표시됩니다",icon:"sparkles")}}.padding(24)}}
    private func collectionShortcut(_ title:String,_ symbol:String)->some View{Button{model.choose(title)}label:{VStack{Image(systemName:symbol).font(.largeTitle).foregroundStyle(Color.accentColor);Text(title)}.frame(maxWidth:.infinity).padding(20).background(.quaternary,in:RoundedRectangle(cornerRadius:12))}.buttonStyle(.plain)}
    private var albumsView:some View{ScrollView{LazyVGrid(columns:[GridItem(.adaptive(minimum:180),spacing:20)],spacing:24){ForEach(model.libraryDoc.albums.filter{$0.folder != "root"}){album in albumCard(album.name,category:"사용자앨범:"+album.id,values:model.items.filter{model.matches($0,"사용자앨범:"+album.id)}).contextMenu{albumMenu(album)}};ForEach(model.albums,id:\.self){album in albumCard(album,category:"앨범:"+album,values:model.items.filter{$0.album==album})}}.padding(24)}}
    private func albumCard(_ title:String,category:String,values:[GalleryItem])->some View{Button{model.choose(category)}label:{VStack(alignment:.leading){ZStack{RoundedRectangle(cornerRadius:12).fill(.quaternary);if let item=values.first,let image=model.thumbnails[item.id]{Image(nsImage:image).resizable().scaledToFill().frame(height:150).clipped().clipShape(RoundedRectangle(cornerRadius:12))}else{Image(systemName:"rectangle.stack").font(.largeTitle)}}.frame(height:150);Text(title).font(.headline);Text("\(values.count)개 항목").font(.caption).foregroundStyle(.secondary)}}.buttonStyle(.plain).onAppear{if let item=values.first{model.thumb(item)}}}
    private var duplicatesView:some View{ScrollView{LazyVStack(alignment:.leading,spacing:20){ForEach(Array(model.duplicateGroups.enumerated()),id:\.offset){_,values in VStack(alignment:.leading){HStack{Text("\(values.count)개 동일한 항목").font(.headline);Spacer();Button("병합"){model.mergeDuplicates(values)}};LazyVGrid(columns:[GridItem(.adaptive(minimum:160),spacing:12)]){ForEach(values){item in cell(item)}}}.padding().background(.quaternary,in:RoundedRectangle(cornerRadius:12))}}.padding(20);if model.duplicateGroups.isEmpty{analysisEmpty("중복된 항목이 없습니다","square.on.square")}}}
    private func analysisEmpty(_ title:String,_ symbol:String)->some View{VStack(spacing:16){Image(systemName:symbol).font(.system(size:40));Text(title).font(.title2);Text("사진 원본에서 사람, 텍스트, 위치와 중복을 분석합니다.").font(.callout).foregroundStyle(.secondary);Button(model.analysisRunning ? "분석 중단":"분석 시작"){model.analysisRunning ? model.stopAnalysis():model.startAnalysis()}.buttonStyle(.borderedProminent)}.frame(maxWidth:.infinity,minHeight:350)}
    private func empty(_ title:String,icon:String)->some View{VStack(spacing:15){Image(systemName:icon).font(.largeTitle).foregroundStyle(.secondary);Text(title).foregroundStyle(.secondary)}.frame(maxWidth:.infinity,minHeight:200)}
    private var smartAlbumSheet:some View{VStack(alignment:.leading,spacing:20){Text("새 스마트 앨범").font(.title2);TextField("앨범 이름",text:$viewer.smartName);Picker("조건",selection:$viewer.smartRule.field){ForEach(["키워드","제목","촬영 연도","미디어 유형","카메라 앨범","즐겨찾기","편집됨"],id:\.self){Text($0)}};TextField("포함하는 값",text:$viewer.smartRule.value);HStack{Button("취소"){viewer.smartSheet=false};Spacer();Button("확인"){let album=PhotoAlbum(id:viewer.smartEditing ?? UUID().uuidString,name:viewer.smartName,rule:viewer.smartRule);model.change{if let index=$0.albums.firstIndex(where:{$0.id==album.id}){$0.albums[index]=album}else{$0.albums.append(album)}};model.choose("사용자앨범:"+album.id);viewer.smartSheet=false}.buttonStyle(.borderedProminent)}}.padding(24).frame(width:420)}
    private var dateSheet:some View{VStack(alignment:.leading,spacing:20){Text("날짜 및 시간 조정").font(.title2);DatePicker("촬영일",selection:$viewer.proposedDate);Text("CoolSync 보관함의 표시 날짜를 변경합니다. 휴대폰 원본은 보존됩니다.").font(.caption).foregroundStyle(.secondary);HStack{Button("취소"){viewer.dateSheet=false};Spacer();Button("조정"){if let item=model.selected{model.annotate(item){$0.date=viewer.proposedDate.timeIntervalSince1970}};viewer.dateSheet=false}.buttonStyle(.borderedProminent)}}.padding(24).frame(width:420)}
    private var keyboardCommands:some View{Group{
        Button(""){if model.selected==nil{model.selection=Set(model.visible.map{$0.id})}}.keyboardShortcut("a",modifiers:.command)
        Button(""){if !model.editing{if let item=model.targets.first{model.open(item)}}}.keyboardShortcut(.space,modifiers:[])
        Button(""){if !model.editing{model.deleteTargets()}}.keyboardShortcut(.delete,modifiers:[])
        Button(""){model.editing ? model.undoEdit():model.undoLibrary()}.keyboardShortcut("z",modifiers:.command)
        Button(""){model.editing ? model.redoEdit():model.redoLibrary()}.keyboardShortcut("z",modifiers:[.command,.shift])
        Button(""){model.importPhotos()}.keyboardShortcut("i",modifiers:[.command,.shift])
        Button(""){model.exportTargets()}.keyboardShortcut("e",modifiers:[.command,.shift])
    }.hidden().frame(width:0,height:0)}
    private func importDrop(_ providers:[NSItemProvider])->Bool{let group=DispatchGroup();var urls:[URL]=[];let lock=NSLock();for provider in providers{group.enter();provider.loadItem(forTypeIdentifier:UTType.fileURL.identifier,options:nil){value,_ in defer{group.leave()};let url=(value as?URL) ?? (value as?Data).flatMap{URL(dataRepresentation:$0,relativeTo:nil)};if let url{lock.lock();urls.append(url);lock.unlock()}}};group.notify(queue:.main){model.importPhotos(urls)};return !providers.isEmpty}
}
