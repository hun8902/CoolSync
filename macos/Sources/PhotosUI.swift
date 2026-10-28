import AppKit
import SwiftUI
import AVKit
import MapKit
import UniformTypeIdentifiers

private let photoPathType=NSPasteboard.PasteboardType("app.coolsync.remote-path")

struct PhotosPane:View {
    @ObservedObject var photos:PhotosModel
    @ObservedObject var files:FileTransfer
    var exit:()->Void
    var trash:()->Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body:some View{
        HStack(spacing:0){
            if photos.sidebarShown{sidebar.frame(width:215).background(.ultraThinMaterial);Divider()}
            VStack(spacing:0){toolbar;Divider();
                if !photos.photoSyncActivity.isEmpty{HStack{Image(systemName:"arrow.triangle.2.circlepath");Text(photos.photoSyncActivity);Spacer()}.font(.caption).padding(10).background(.bar)}
                if !photos.pendingDeletes.isEmpty || !photos.deleteActivity.isEmpty{HStack(spacing:10){if photos.deleteInFlight{ProgressView().controlSize(.small)}else{Image(systemName:photos.pendingDeletes.isEmpty ? "checkmark.circle.fill":"clock")};Text(photos.deleteActivity.isEmpty ? "연결되면 삭제 대기를 자동 처리합니다":photos.deleteActivity);Spacer();Button("삭제 상태"){photos.showPendingDeletes=true}}.font(.caption).padding(10).background(.bar)}

                if photos.dateWorkActive{HStack{ProgressView(value:photos.dateWorkProgress).frame(width:140);Text(photos.status).font(.caption);Spacer();Button("중단"){photos.stopDateWork()}}.padding(10)}
                if !photos.dateWorkActive && !photos.dateWorkNotes.isEmpty{HStack{Text("수정일 정리 건너뜀 \(photos.dateWorkNotes.count)개");Menu("원본 촬영일 처리 내역"){ForEach(Array(photos.dateWorkNotes.enumerated()),id:\.offset){Text($0.element)}};Spacer()}.font(.caption).padding(8)}
                if !photos.dateWorkActive && !photos.dateWorkFailures.isEmpty{HStack{Text("수정일 정리 실패 \(photos.dateWorkFailures.count)개");Menu("실패 내역"){ForEach(photos.dateWorkFailures,id:\.self){Text($0)}};Button("실패 항목 재시도…"){photos.retryDateWork()}}.font(.caption).padding(8)}
HStack(spacing:0){ZStack{PhotoGrid(model:photos).opacity(photos.preview==nil ? 1:0).allowsHitTesting(photos.preview==nil).accessibilityHidden(photos.preview != nil);if photos.items.isEmpty && !photos.loading && photos.preview==nil{VStack(spacing:12){Image(systemName:"photo.on.rectangle").font(.system(size:35,weight:.light)).foregroundStyle(.tertiary);Text(photos.connected?()==true ? "사진이나 영상이 없습니다":"휴대폰을 연결하세요").foregroundStyle(.secondary);Button("새로 고침"){photos.reload()}}};if let item=photos.preview{viewer(item)}};if photos.infoShown{Divider();inspector.frame(width:275)}};Divider();footer}
        }.background(Color(nsColor:.textBackgroundColor)).onDrop(of:[UTType.fileURL.identifier,photoPathType.rawValue],isTargeted:nil){drop($0,to:photos.album.isEmpty ? "Pictures/CoolSync":photos.album)}.animation(reduceMotion ? nil:.easeInOut(duration:0.18),value:photos.sidebarShown)
        .onAppear{photos.appear()}.onDisappear{photos.disappear()}
        .sheet(isPresented:$photos.showPendingDeletes){PendingPhotoDeletesPane(photos:photos)}
        .alert("파일 수정일 정리",isPresented:Binding(get:{photos.dateAlignmentResult != nil},set:{if !$0{photos.dateAlignmentResult=nil}})){Button("확인"){photos.dateAlignmentResult=nil}}message:{Text(photos.dateAlignmentResult ?? "")}
        .alert("사진 작업",isPresented:Binding(get:{photos.error != nil},set:{if !$0{photos.error=nil}})){Button("확인"){photos.error=nil}}message:{Text(photos.error ?? "")}
    }
    private var sidebar:some View{
        VStack(alignment:.leading,spacing:0){
            Button{photos.sidebarShown=false}label:{Label("앨범",systemImage:"sidebar.left").font(.system(size:14,weight:.semibold))}.buttonStyle(.plain).padding(.horizontal,18).padding(.vertical,19)
            ScrollView{VStack(alignment:.leading,spacing:3){
                side("보관함","photo.on.rectangle","all")
                Text("고정됨").font(.system(size:11,weight:.semibold)).foregroundStyle(.secondary).padding(.top,23).padding(.bottom,6).padding(.leading,12)
                side("즐겨찾기","heart","favorites");side("최근 저장된 항목","clock","recent");side("비디오","video","videos");side("스크린샷","viewfinder","screenshots")
                Button{photos.infoShown=true;if photos.selection.isEmpty,let item=photos.items.first{photos.select([item.path])}else{photos.loadInfo()}}label:{Label("촬영 위치",systemImage:"map").frame(maxWidth:.infinity,alignment:.leading).padding(10)}.buttonStyle(.plain)
                Button(action:trash){Label("최근 삭제된 항목",systemImage:"trash").frame(maxWidth:.infinity,alignment:.leading).padding(10)}.buttonStyle(.plain)
                HStack{Text("앨범").font(.system(size:11,weight:.semibold)).foregroundStyle(.secondary);Spacer();Button{photos.albumCreate()}label:{Image(systemName:"plus")}.buttonStyle(.borderless).help("새 앨범")}.padding(.horizontal,12).padding(.top,23).padding(.bottom,6)
                ForEach(photos.albums){album in
                    Button{photos.choose(album:album.path)}label:{HStack{Image(systemName:"rectangle.stack").foregroundStyle(.blue);Text(album.name).lineLimit(1);Spacer();Text("\(album.count)").font(.system(size:10)).foregroundStyle(.secondary)}.padding(10).background(photos.album==album.path ? Color.accentColor.opacity(0.17):.clear,in:RoundedRectangle(cornerRadius:8))}.buttonStyle(.plain).help(album.path)
                    .contextMenu{Button("이름 변경…"){photos.album=album.path;photos.albumRename()};Button("앨범을 휴지통으로 이동…"){photos.album=album.path;photos.albumDelete()}}
                    .onDrop(of:[UTType.fileURL.identifier,photoPathType.rawValue],isTargeted:nil){providers in drop(providers,to:album.path)}
                }
            }.padding(.horizontal,10).font(.system(size:13))}
            Text("휴대폰의 실제 사진 폴더").font(.system(size:10)).foregroundStyle(.secondary).padding(15)
        }
    }
    private func side(_ title:String,_ icon:String,_ scope:String)->some View{Button{photos.choose(scope)}label:{Label(title,systemImage:icon).frame(maxWidth:.infinity,alignment:.leading).padding(10).background(photos.album.isEmpty&&photos.scope==scope ? Color.accentColor.opacity(0.17):.clear,in:RoundedRectangle(cornerRadius:8))}.buttonStyle(.plain)}
    private var toolbar:some View{ViewThatFits(in:.horizontal){wideToolbar;compactToolbar}}
    private var compactToolbar:some View{
        HStack(spacing:14){Button{photos.sidebarShown.toggle()}label:{Image(systemName:"sidebar.left")};if photos.preview != nil{Button{photos.closePreview()}label:{Image(systemName:"chevron.left")}};VStack(alignment:.leading,spacing:3){Text(photos.title).font(.system(size:16,weight:.semibold)).lineLimit(1);Text(photos.sortTitle).font(.caption).foregroundStyle(.secondary)};Spacer()
            Button{photos.chooseImport()}label:{Image(systemName:"square.and.arrow.down")}
            Button{photos.toggleInfo()}label:{Image(systemName:"info.circle")}
            Menu{sortCommands;Divider();Picker("보기",selection:$photos.grouping){Text("년").tag("year");Text("월").tag("month");Text("모든 사진").tag("all")};Slider(value:$photos.zoom,in:90...240);Button("변경분 동기화"){photos.reload()};Button("선택 원본 보관"){photos.cacheSelection()};Button("삭제 대기 목록"){photos.showPendingDeletes=true};Button("Mac으로 복사…"){photos.export()};Button("Mac으로 이동…"){photos.export(move:true)};Button("즐겨찾기"){photos.favorite()};Button("휴지통으로 이동…"){photos.remove()};Button("새 앨범…"){photos.albumCreate()};Menu("앨범으로 이동"){ForEach(photos.albums){album in Button(album.name){photos.move(to:album.path)}}}}label:{Image(systemName:"ellipsis.circle")}
        }.buttonStyle(.borderless).padding(16).background(.ultraThinMaterial)
    }
    private var wideToolbar:some View{
        HStack(spacing:14){
            Button{photos.sidebarShown.toggle()}label:{Image(systemName:"sidebar.left")}.help("사이드바")
            if photos.preview != nil{Button{photos.closePreview()}label:{Image(systemName:"chevron.left")}.help("보관함으로")}
            VStack(alignment:.leading,spacing:3){Text(photos.title).font(.system(size:16,weight:.semibold));if photos.preview==nil{Text(photos.sortTitle+" · "+range).font(.system(size:10)).foregroundStyle(.secondary)}}.frame(minWidth:100,alignment:.leading)
            if photos.preview==nil{
                HStack(spacing:6){Image(systemName:"minus").font(.system(size:10));Slider(value:$photos.zoom,in:90...240).frame(width:70);Image(systemName:"plus").font(.system(size:10))}
                    .padding(9).background(.thinMaterial,in:Capsule())
                Picker("보기",selection:$photos.grouping){Text("년").tag("year");Text("월").tag("month");Text("모든 사진").tag("all")}.pickerStyle(.segmented).frame(width:180)
            }
            Spacer(minLength:4)
            HStack(spacing:13){Button{photos.chooseImport()}label:{Image(systemName:"square.and.arrow.down")}.help("Mac에서 사진·영상 가져오기")
                Menu{Button("Mac으로 복사…"){photos.export()};Button("Mac으로 이동…"){photos.export(move:true)}}label:{Image(systemName:"square.and.arrow.up")}.disabled(photos.selection.isEmpty)
                Button{photos.favorite()}label:{Image(systemName:photos.selected.allSatisfy{$0.favorite} && !photos.selection.isEmpty ? "heart.fill":"heart")}.disabled(photos.selection.isEmpty).help("즐겨찾기")
                Button{photos.remove()}label:{Image(systemName:"trash")}.disabled(photos.selection.isEmpty).help("선택 항목 삭제")
                Button{photos.toggleInfo()}label:{Image(systemName:"info.circle")}.help("촬영 정보와 위치")
                Menu{sortCommands;Divider();Button("새 앨범…"){photos.albumCreate()};Menu("선택 항목을 앨범으로 이동"){ForEach(photos.albums){album in Button(album.name){photos.move(to:album.path)}}};Menu("선택 항목을 앨범으로 복사"){ForEach(photos.albums){album in Button(album.name){photos.move(to:album.path,copy:true)}}};Button("선택 원본 보관"){photos.cacheSelection()};Button("삭제 대기 목록"){photos.showPendingDeletes=true};Button("변경분 동기화"){photos.reload()}}label:{Image(systemName:"ellipsis")}
            }.padding(10).background(.thinMaterial,in:Capsule())
            if photos.preview==nil{TextField("검색",text:$photos.search).textFieldStyle(.roundedBorder).frame(width:115)}
        }.buttonStyle(.borderless).padding(.horizontal,16).padding(.vertical,13).background(.ultraThinMaterial)
    }
    private var sortCommands:some View{
        Group{
            if photos.scope=="recent"{Text("최근 항목은 추가일 기준")}else{Picker("날짜 기준",selection:$photos.sortKey){Text("촬영일 · 없으면 추가일").tag("captured");Text("추가일").tag("added")}}
            Picker("정렬 방향",selection:$photos.ascending){Text("최신순").tag(false);Text("오래된순").tag(true)}
            Divider();Menu("원본 촬영일로 파일 수정일 맞추기"){
                Button("선택한 사진·동영상…"){photos.alignModifiedDates()}.disabled(photos.selection.isEmpty)
                Button("현재 앨범 전체…"){photos.alignModifiedDates("album")}.disabled(photos.album.isEmpty)
                Button("사진·동영상 보관함 전체…"){photos.alignModifiedDates("all")}
                Button("실패·중단 항목 재시도…"){photos.retryDateWork()}
            }.disabled(photos.loading || photos.caching || photos.moving)
        }
    }
    private var range:String{let valid=photos.items.filter{photos.orderTime($0)>0};guard let first=valid.first,let last=valid.last else{return photos.loading ? "불러오는 중…":"날짜 없음"};let dates=[photos.orderDate(first),photos.orderDate(last)].sorted();return dates[0].formatted(date:.numeric,time:.omitted)+" – "+dates[1].formatted(date:.numeric,time:.omitted)}
    private func viewer(_ item:PhotoItem)->some View{
        ZStack{Color.black
            if photos.previewLoading{VStack(spacing:14){ProgressView();Text(photos.previewPhase).foregroundStyle(.white);Text("가져온 뒤 사진을 표시하거나 영상을 재생합니다.").font(.system(size:12)).foregroundStyle(.gray)}}
            else if let player=photos.player{VideoPlayer(player:player)}
            else if let image=photos.previewImage{Image(nsImage:image).resizable().scaledToFit()}
            else if !photos.previewError.isEmpty{VStack(spacing:14){Text(photos.previewError).foregroundStyle(.white);Button("다시 열기"){photos.open(item)}}.padding(30)}
            HStack{Button{photos.nextPreview(-1)}label:{Image(systemName:"chevron.left").font(.system(size:20)).padding(14).background(.ultraThinMaterial,in:Circle())}.disabled(!photos.canNavigatePreview(-1)).help("이전 사진 (←)");Spacer();Button{photos.nextPreview(1)}label:{Image(systemName:"chevron.right").font(.system(size:20)).padding(14).background(.ultraThinMaterial,in:Circle())}.disabled(!photos.canNavigatePreview(1)).help("다음 사진 (→)")}.buttonStyle(.plain).padding(15)
            VStack{HStack{
                if photos.motionLoading{HStack(spacing:8){ProgressView().controlSize(.small);Text("모션 포토 확인 중")}.font(.callout).padding(10).background(.ultraThinMaterial,in:Capsule())}
                else if photos.motionAvailable{Button{photos.togglePlayback()}label:{Label(photos.motionPlaying ? "사진 보기":"모션 포토 재생",systemImage:photos.motionPlaying ? "photo":"livephoto.play").padding(10).background(.ultraThinMaterial,in:Capsule())}.buttonStyle(.plain).help("모션 포토 재생 / 사진 보기 (스페이스)")}
                else if !photos.motionError.isEmpty{Text(photos.motionError).font(.caption).padding(10).background(.ultraThinMaterial,in:Capsule())}
                Spacer()
            };Spacer()}.padding(18)
        }.background(PhotoPreviewKeyboard(photos:photos).frame(width:0,height:0))
    }

    private var footer:some View{HStack{if photos.loading || photos.caching{ProgressView().controlSize(.small)};Text(photos.status).lineLimit(1);if !photos.pendingDeletes.isEmpty{Button("삭제 대기 \(photos.pendingDeletes.count)"){photos.showPendingDeletes=true}.buttonStyle(.borderless)};if !photos.selection.isEmpty{Text("· \(photos.selection.count)개 선택")};Spacer();if photos.caching{ProgressView(value:photos.originalProgress).frame(width:85);Button("보관 취소"){photos.cancelCache()}};if files.hasTransfer{Text(files.summary).lineLimit(1);if files.busy{ProgressView(value:files.progress).frame(width:95)};Button("취소"){photos.rpc?.cancelJobs()}}}.font(.system(size:11)).foregroundStyle(.secondary).padding(.horizontal,18).padding(.vertical,11).background(.ultraThinMaterial)}
    private var inspector:some View{
        ScrollView{VStack(alignment:.leading,spacing:17){
            Text("정보").font(.system(size:17,weight:.semibold))
            if let item=photos.selected.first,photos.selected.count==1{
                Text(item.name).font(.system(size:13,weight:.semibold)).textSelection(.enabled)
                Text(photos.info["captured"] ?? (item.date>0 ? item.timestamp.formatted():"날짜 없음")).font(.system(size:12)).foregroundStyle(.secondary);Text(photos.info["captured"] == nil ? photos.dateSourceTitle(item):"원본 촬영정보").font(.caption).foregroundStyle(.secondary);if let added=item.added,added>0{Text("추가일 · "+Date(timeIntervalSince1970:Double(added)/1000).formatted()).font(.caption).foregroundStyle(.secondary)}
                HStack{Text("\(item.width) × \(item.height)");Spacer();Text(ByteCountFormatter.string(fromByteCount:item.size,countStyle:.file))}.font(.system(size:11)).foregroundStyle(.secondary)
                Divider()
                HStack{Button("휴대폰 원본에서 다시 조회"){photos.refreshInfoOriginal()}.disabled(photos.infoRefreshing || photos.connected?()==false);if photos.infoRefreshing{ProgressView().controlSize(.small)}}
                Text(photos.infoStatus).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                ForEach([("make","제조사"),("camera","카메라"),("lens","렌즈"),("iso","ISO"),("aperture","조리개"),("exposure","노출 시간"),("focalLength","초점 거리"),("captured","촬영 일시"),("codec","형식")],id:\.0){key,title in if let value=photos.info[key],!value.isEmpty{VStack(alignment:.leading,spacing:4){Text(title).font(.system(size:10)).foregroundStyle(.secondary);Text(value).font(.system(size:12)).textSelection(.enabled)}}}
                if item.video{Text("재생 시간 \(item.durationText)").font(.system(size:12))}
                Divider();Text("촬영 위치").font(.system(size:13,weight:.semibold))
                if let a=photos.latitude,let b=photos.longitude{
                    Map(coordinateRegion:$photos.region,annotationItems:[PhotoPin(coordinate:CLLocationCoordinate2D(latitude:a,longitude:b))]){MapMarker(coordinate:$0.coordinate)}.frame(height:190).clipShape(RoundedRectangle(cornerRadius:10))
                    Text(String(format:"%.6f, %.6f",a,b)).font(.system(size:11)).textSelection(.enabled)
                    Button("지도에서 열기"){if let url=URL(string:"https://maps.apple.com/?ll=\(a),\(b)&q=Photo"){NSWorkspace.shared.open(url)}}
                }else{Text(photos.info["locationAllowed"]=="false"||photos.info["locationAllowed"]=="0" ? "휴대폰 CoolSync 권한 설정에서 사진 촬영 위치를 허용하세요.":"저장된 촬영 위치가 없습니다.").font(.system(size:12)).foregroundStyle(.secondary)}
                Divider();Text(item.album).font(.system(size:11)).foregroundStyle(.secondary).textSelection(.enabled)
            }else{Text(photos.selection.isEmpty ? "사진이나 영상을 선택하세요":"\(photos.selection.count)개 항목을 선택했습니다").foregroundStyle(.secondary)}
        }.padding(19)}.background(.thinMaterial)
    }
    private func drop(_ providers:[NSItemProvider],to folder:String)->Bool{
        let group=DispatchGroup();let lock=NSLock();var paths:[String]=[];var urls:[URL]=[];var accepted=false
        for provider in providers{
            if provider.hasItemConformingToTypeIdentifier(photoPathType.rawValue){accepted=true;group.enter();provider.loadItem(forTypeIdentifier:photoPathType.rawValue,options:nil){item,_ in defer{group.leave()};let path=(item as?String) ?? (item as?Data).flatMap{String(data:$0,encoding:.utf8)};if let path{lock.lock();paths.append(path);lock.unlock()}}}
            else if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier){accepted=true;group.enter();provider.loadItem(forTypeIdentifier:UTType.fileURL.identifier,options:nil){item,_ in defer{group.leave()};let url=(item as?URL) ?? (item as?Data).flatMap{URL(dataRepresentation:$0,relativeTo:nil)};if let url{lock.lock();urls.append(url);lock.unlock()}}}
        }
        group.notify(queue:.main){if !paths.isEmpty{photos.move(to:folder,paths:paths)}else if !urls.isEmpty{photos.upload(urls,to:folder)}};return accepted
    }

}

private final class PhotoTile:NSCollectionViewItem {
    let badge=NSTextField(labelWithString:"")
    override func loadView(){let box=NSView();box.wantsLayer=true;box.layer?.cornerRadius=7;view=box;let image=NSImageView();image.imageScaling = .scaleProportionallyUpOrDown;image.translatesAutoresizingMaskIntoConstraints=false;box.addSubview(image);imageView=image;badge.translatesAutoresizingMaskIntoConstraints=false;badge.font = .monospacedDigitSystemFont(ofSize:11,weight:.semibold);badge.textColor = .white;badge.backgroundColor=NSColor.black.withAlphaComponent(0.55);badge.drawsBackground=true;box.addSubview(badge);NSLayoutConstraint.activate([image.leadingAnchor.constraint(equalTo:box.leadingAnchor,constant:4),image.trailingAnchor.constraint(equalTo:box.trailingAnchor,constant:-4),image.topAnchor.constraint(equalTo:box.topAnchor,constant:4),image.bottomAnchor.constraint(equalTo:box.bottomAnchor,constant:-4),badge.trailingAnchor.constraint(equalTo:box.trailingAnchor,constant:-9),badge.bottomAnchor.constraint(equalTo:box.bottomAnchor,constant:-8)])}
    override var isSelected:Bool{didSet{view.layer?.borderWidth=isSelected ? 3:0;view.layer?.borderColor=NSColor.controlAccentColor.cgColor;view.layer?.backgroundColor=isSelected ? NSColor.controlAccentColor.withAlphaComponent(0.10).cgColor:NSColor.clear.cgColor}}
}
private final class PhotoHeader:NSView {
    let label=NSTextField(labelWithString:"")
    override init(frame:NSRect){super.init(frame:frame);label.font = .systemFont(ofSize:20,weight:.semibold);label.translatesAutoresizingMaskIntoConstraints=false;addSubview(label);NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo:leadingAnchor,constant:12),label.centerYAnchor.constraint(equalTo:centerYAnchor)])}
    required init?(coder:NSCoder){fatalError()}
}
private final class PhotosCollection:NSCollectionView {
    var command:((String)->Void)?
    var contextSelection:(()->Void)?
    override func menu(for event:NSEvent)->NSMenu?{let point=convert(event.locationInWindow,from:nil);if let index=indexPathForItem(at:point),!selectionIndexPaths.contains(index){selectionIndexPaths=[index];contextSelection?()};return super.menu(for:event)}
    override func keyDown(with event:NSEvent){if event.modifierFlags.contains(.command),event.charactersIgnoringModifiers?.lowercased()=="a"{command?("all");return};if event.keyCode==51||event.keyCode==117{command?("delete");return};if event.keyCode==49||event.keyCode==36{command?("open");return};super.keyDown(with:event)}
}
struct PhotoGrid:NSViewRepresentable {
    @ObservedObject var model:PhotosModel
    func makeCoordinator()->Coordinator{Coordinator(model)}
    func makeNSView(context:Context)->NSScrollView{
        let collection=PhotosCollection(frame:NSRect(x:0,y:0,width:800,height:600));collection.autoresizingMask=[.width];collection.isSelectable=true;collection.allowsMultipleSelection=true;collection.backgroundColors=[.clear];collection.delegate=context.coordinator;collection.dataSource=context.coordinator;context.coordinator.collection=collection
        let flow=NSCollectionViewFlowLayout();flow.minimumInteritemSpacing=8;flow.minimumLineSpacing=12;flow.sectionInset=NSEdgeInsets(top:12,left:18,bottom:20,right:18);collection.collectionViewLayout=flow
        collection.register(PhotoTile.self,forItemWithIdentifier:.init("photo"));collection.register(PhotoHeader.self,forSupplementaryViewOfKind:NSCollectionView.elementKindSectionHeader,withIdentifier:.init("header"));collection.setDraggingSourceOperationMask(.copy,forLocal:false);collection.setDraggingSourceOperationMask([.copy,.move],forLocal:true)
        let click=NSClickGestureRecognizer(target:context.coordinator,action:#selector(Coordinator.open));click.numberOfClicksRequired=2;collection.addGestureRecognizer(click)
        collection.contextSelection={ [weak coordinator=context.coordinator,weak collection] in if let collection{coordinator?.sync(collection)}}
        collection.command={[weak model]command in
            if let model,let preview=model.preview{if command=="delete"{model.select([preview.path]);model.remove()}else if command=="open"{model.togglePlayback()};return}
            if command=="all"{if let model{model.select(Set(model.filtered.map{$0.path}))}}else if command=="delete"{model?.remove()}else if let item=model?.selected.first{model?.open(item)}}
        let menu=NSMenu();for(title,action)in[("열기",#selector(Coordinator.openSelected)),("Mac으로 복사…",#selector(Coordinator.exportCopy)),("Mac으로 이동…",#selector(Coordinator.exportMove)),("즐겨찾기",#selector(Coordinator.favorite)),("휴지통으로 이동",#selector(Coordinator.remove))]{let item=NSMenuItem(title:title,action:action,keyEquivalent:"");item.target=context.coordinator;menu.addItem(item)};collection.menu=menu
        let scroll=NSScrollView();scroll.documentView=collection;scroll.hasVerticalScroller=true;scroll.drawsBackground=false;return scroll
    }
    func updateNSView(_ scroll:NSScrollView,context:Context){
        let c=context.coordinator;c.model=model
        let order="\(model.scope)|\(model.album)|\(model.sortKey)|\(model.ascending)|\(model.grouping)"
        let changed=order != c.order;c.order=order
        let fingerprint="\(model.revision)|\(model.search)|\(model.grouping)";let wanted=model.selection
        c.syncing=true
        if fingerprint != c.fingerprint{c.fingerprint=fingerprint;c.sections=model.sections;c.collection?.reloadData()}
        if let layout=c.collection?.collectionViewLayout as?NSCollectionViewFlowLayout{layout.itemSize=NSSize(width:model.zoom,height:model.zoom);layout.headerReferenceSize=NSSize(width:1,height:model.grouping=="all" ? 0:48);if changed{layout.invalidateLayout()}}
        let selected=Set(c.sections.enumerated().flatMap{s,section in section.items.enumerated().compactMap{i,item in wanted.contains(item.path) ? IndexPath(item:i,section:s):nil}})
        if c.collection?.selectionIndexPaths != selected{c.collection?.selectionIndexPaths=selected}
        c.syncing=false
        if changed{scroll.layoutSubtreeIfNeeded();scroll.contentView.scroll(to:.zero);scroll.reflectScrolledClipView(scroll.contentView)}
    }

    final class Coordinator:NSObject,NSCollectionViewDataSource,NSCollectionViewDelegate,NSFilePromiseProviderDelegate {
        var model:PhotosModel;weak var collection:NSCollectionView?;var sections:[PhotoSection]=[];var fingerprint="";var order="";var syncing=false
        init(_ model:PhotosModel){self.model=model}
        func numberOfSections(in collectionView:NSCollectionView)->Int{sections.count}
        func collectionView(_ collectionView:NSCollectionView,numberOfItemsInSection section:Int)->Int{sections[section].items.count}
        func collectionView(_ collectionView:NSCollectionView,itemForRepresentedObjectAt indexPath:IndexPath)->NSCollectionViewItem{let tile=collectionView.makeItem(withIdentifier:.init("photo"),for:indexPath)as!PhotoTile;let item=sections[indexPath.section].items[indexPath.item];tile.representedObject=item.cacheIdentity;tile.imageView?.image=NSImage(systemSymbolName:item.video ? "video":"photo",accessibilityDescription:nil);tile.imageView?.contentTintColor = .tertiaryLabelColor;tile.badge.stringValue=item.video ? item.durationText:(model.hasMotion(item) ? "◉ 모션":(item.favorite ? "♥":""));tile.badge.isHidden = !item.video && !item.favorite && !model.hasMotion(item);tile.view.toolTip=item.name;model.thumbnails.load(item){[weak tile]image in guard let tile,tile.representedObject as?String==item.cacheIdentity,let image else{return};tile.imageView?.image=image;tile.imageView?.contentTintColor=nil};return tile}
        func collectionView(_ collectionView:NSCollectionView,viewForSupplementaryElementOfKind kind:NSCollectionView.SupplementaryElementKind,at indexPath:IndexPath)->NSView{let view=collectionView.makeSupplementaryView(ofKind:kind,withIdentifier:.init("header"),for:indexPath)as!PhotoHeader;view.label.stringValue=sections[indexPath.section].title;return view}
        func collectionView(_ collectionView:NSCollectionView,didSelectItemsAt indexPaths:Set<IndexPath>){sync(collectionView)}
        func collectionView(_ collectionView:NSCollectionView,didDeselectItemsAt indexPaths:Set<IndexPath>){sync(collectionView)}
        func sync(_ collection:NSCollectionView){if syncing{return};let paths=collection.selectionIndexPaths.compactMap{p in sections.indices.contains(p.section)&&sections[p.section].items.indices.contains(p.item) ? sections[p.section].items[p.item].path:nil};model.select(Set(paths))}
        @objc func open(_ gesture:NSClickGestureRecognizer){guard let collection,let p=collection.indexPathForItem(at:gesture.location(in:collection)),sections.indices.contains(p.section),sections[p.section].items.indices.contains(p.item)else{return};model.open(sections[p.section].items[p.item])}
        @objc func openSelected(){if let item=model.selected.first{model.open(item)}}
        @objc func exportCopy(){model.export()};@objc func exportMove(){model.export(move:true)};@objc func favorite(){model.favorite()};@objc func remove(){model.remove()}
        func collectionView(_ collectionView:NSCollectionView,canDragItemsAt indexPaths:Set<IndexPath>,with event:NSEvent)->Bool{model.files?.hasTransfer != true && (model.connected?()==true || model.selected.allSatisfy{model.isCached($0)})}
        func collectionView(_ collectionView:NSCollectionView,pasteboardWriterForItemAt indexPath:IndexPath)->NSPasteboardWriting?{let item=sections[indexPath.section].items[indexPath.item];let provider=RemotePromise(fileType:UTType(filenameExtension:URL(fileURLWithPath:item.name).pathExtension)?.identifier ?? UTType.data.identifier,delegate:self);provider.remotePath=item.path;provider.keeper=self;provider.userInfo=item.remote;return provider}
        func filePromiseProvider(_ provider:NSFilePromiseProvider,fileNameForType type:String)->String{(provider.userInfo as?RemoteEntry)?.name ?? "사진"}
        func filePromiseProvider(_ provider:NSFilePromiseProvider,writePromiseTo url:URL,completionHandler:@escaping(Error?)->Void){guard let item=provider.userInfo as?RemoteEntry else{completionHandler(CocoaError(.fileReadUnknown));return};DispatchQueue.main.async{guard let photo=self.model.items.first(where:{$0.path==item.path})else{completionHandler(CocoaError(.fileReadNoSuchFile));return};self.model.promiseExport(photo,to:url,completion:completionHandler)}}
        func operationQueue(for provider:NSFilePromiseProvider)->OperationQueue{.main}
    }
}
