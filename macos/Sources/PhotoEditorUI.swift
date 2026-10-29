import AppKit
import SwiftUI
import AVKit
import ImageIO
import MapKit

final class PhotoInspectorState:ObservableObject{@Published var url:URL?;var id=""}
struct PhotoInfoPane:View {
    @ObservedObject var model:GalleryModel;let item:GalleryItem;@ObservedObject var viewer:GalleryViewerState
    @StateObject private var inspector=PhotoInspectorState()
    private func load(){inspector.id=item.id;inspector.url=nil;model.fetch(item){result in if inspector.id==item.id,case .success(let url)=result{inspector.url=url;model.readMetadata(url,item:item)}}}
    private func binding(_ key:WritableKeyPath<PhotoAnnotation,String>)->Binding<String>{Binding(get:{model.note(item)[keyPath:key]},set:{value in model.annotate(item){$0[keyPath:key]=value}})}
    var body:some View{
        ScrollView{VStack(alignment:.leading,spacing:16){
            HStack{Text("정보").font(.headline);Spacer();Button{viewer.info=false}label:{Image(systemName:"xmark.circle.fill")}.buttonStyle(.plain).foregroundStyle(.secondary)}
            TextField("제목 추가",text:binding(\.title)).font(.headline).textFieldStyle(.plain)
            Text(item.name).textSelection(.enabled)
            HStack{Text(model.captureDate(item)?.formatted(date:.long,time:.standard) ?? "촬영일 없음");Spacer();Button("조정"){viewer.proposedDate=model.captureDate(item) ?? Date();viewer.dateSheet=true}}.font(.caption)
            Divider();cameraInfo
            Divider();TextField("캡션 추가",text:binding(\.caption),axis:.vertical).lineLimit(2...5).textFieldStyle(.plain)
            TextField("키워드 추가 (쉼표로 구분)",text:Binding(get:{model.note(item).keywords.joined(separator:", ")},set:{value in model.annotate(item){$0.keywords=value.split(separator:",").map{$0.trimmingCharacters(in:.whitespaces)}.filter{!$0.isEmpty}}})).textFieldStyle(.plain)
            Divider();Text("사람들").font(.caption).foregroundStyle(.secondary)
            ForEach(model.libraryDoc.people.filter{model.note(item).people.contains($0.id)}){person in HStack{if let data=person.portrait,let image=NSImage(data:data){Image(nsImage:image).resizable().scaledToFill().frame(width:32,height:32).clipShape(Circle())};Button(person.name){model.renamePerson(person)}.buttonStyle(.plain);Spacer();Button{model.removePerson(person,from:item)}label:{Image(systemName:"minus.circle")}.buttonStyle(.plain)}}
            Button("얼굴 이름 추가"){model.prompt("이름 추가"){name in var person=PhotoPerson();person.name=name;person.paths=[item.path];model.change{$0.people.append(person);var a=$0.annotations[item.path] ?? PhotoAnnotation();a.people.append(person.id);$0.annotations[item.path]=a}}}
            Divider()
            if let lat=model.note(item).latitude,let lon=model.note(item).longitude{
                Text(model.note(item).place.isEmpty ? String(format:"%.5f, %.5f",lat,lon):model.note(item).place).font(.caption)
                GalleryMap(coordinate:CLLocationCoordinate2D(latitude:lat,longitude:lon)).frame(height:180).clipShape(RoundedRectangle(cornerRadius:8))
                Button("위치 제거"){model.annotate(item){$0.latitude=nil;$0.longitude=nil;$0.place="";$0.locationOverridden=true}}
            }
            Button("위치 추가 / 변경"){model.prompt("위치 검색",value:model.note(item).place){model.locate($0,item:item)}}
            if !model.note(item).text.isEmpty{Divider();Text("사진 속 텍스트").font(.caption).foregroundStyle(.secondary);Text(model.note(item).text).font(.caption).textSelection(.enabled);Button("텍스트 복사"){NSPasteboard.general.clearContents();NSPasteboard.general.setString(model.note(item).text,forType:.string)}}
            Divider();Text(item.path).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
            HStack{Button("인쇄…"){model.printPhoto()};Button("복사"){model.copyPhoto()};Spacer();Button{model.deleteTargets()}label:{Image(systemName:"trash")}}
        }.padding(18)}.onAppear{load()}.onChange(of:item.id){_ in load()}
    }
    private var cameraInfo:some View{
        let source=inspector.url.flatMap{CGImageSourceCreateWithURL($0 as CFURL,nil)}
        let properties=source.flatMap{CGImageSourceCopyPropertiesAtIndex($0,0,nil)as?[String:Any]} ?? [:]
        let tiff=properties[kCGImagePropertyTIFFDictionary as String]as?[String:Any] ?? [:],exif=properties[kCGImagePropertyExifDictionary as String]as?[String:Any] ?? [:]
        return VStack(alignment:.leading,spacing:8){
            Text([tiff["Make"],tiff["Model"]].compactMap{$0 as?String}.joined(separator:" ")).font(.headline)
            if let lens=exif["LensModel"]as?String{Text(lens).font(.caption)}
            HStack{Text("\(item.width) × \(item.height)");Spacer();Text(ByteCountFormatter.string(fromByteCount:item.size,countStyle:.file))}.font(.caption)
            Text(item.mime).font(.caption2).foregroundStyle(.secondary)
            HStack{if let iso=(exif["ISOSpeedRatings"]as?[Int])?.first{Text("ISO \(iso)")};if let focal=exif["FocalLength"]as?Double{Text(String(format:"%.0f mm",focal))};if let aperture=exif["FNumber"]as?Double{Text(String(format:"ƒ%.1f",aperture))};if let exposure=exif["ExposureTime"]as?Double{Text(exposure<1 ? "1/\(Int((1/exposure).rounded())) s":String(format:"%.1f s",exposure))}}.font(.caption2)
            if item.video{Text("길이 \(item.duration/1000)초").font(.caption)}
            if model.note(item).edit != nil{Button("원본으로 복귀"){model.revert()}}
        }.padding(12).background(.quaternary,in:RoundedRectangle(cornerRadius:8))
    }
}

struct PhotoEditorPane:View {
    @ObservedObject var model:GalleryModel;@ObservedObject var viewer:GalleryViewerState
    private var video:Bool{model.selected?.video==true}
    var body:some View{VStack(spacing:0){
        Picker("편집 도구",selection:$viewer.editorTab){Text("조절").tag("조절");Text("필터").tag("필터");Text("자르기").tag("자르기");if !video{Text("마크업").tag("마크업")}}.pickerStyle(.segmented).padding(12)
        ScrollView{VStack(alignment:.leading,spacing:18){
            if video{videoControls;Divider()}else if model.motion != nil{Text("Live Photo 대표 사진").font(.headline);slider("프레임",$model.draft.keyFrame,0...1);Button("대표 사진으로 선택"){model.selectKeyPhoto()};Divider()}
            if viewer.editorTab=="조절"{adjustments}
            else if viewer.editorTab=="필터"{filters}
            else if viewer.editorTab=="자르기"{crop}
            else{markup}
            Divider();HStack{Button("모두 재설정"){model.draft=PhotoAdjustment();viewer.editorTool=""};Spacer();Button("원본으로 복귀"){model.revert()}}
            if model.saving{ProgressView("편집본 저장 중…");Button("저장 취소"){model.activeExport?.cancelExport()}}
        }.padding(16)}
    }}
    private func slider(_ name:String,_ value:Binding<Double>,_ range:ClosedRange<Double>)->some View{VStack(spacing:5){HStack{Text(name);Spacer();Text(String(format:"%.2f",value.wrappedValue)).monospacedDigit().foregroundStyle(.secondary)}.font(.caption);Slider(value:value,in:range)}}
    private var adjustments:some View{Group{
        HStack{Text("빛").font(.headline);Spacer();Button("자동"){model.autoEnhance()}}
        slider("노출",$model.draft.exposure,-3...3);slider("휘도",$model.draft.brilliance,-1...1);slider("하이라이트",$model.draft.highlights,0...2);slider("그림자",$model.draft.shadows,-1...1);slider("밝기",$model.draft.brightness,-0.5...0.5);slider("대비",$model.draft.contrast,0.5...1.5);slider("블랙 포인트",$model.draft.blackPoint,-0.2...0.2)
        Divider();Text("색상").font(.headline)
        slider("채도",$model.draft.saturation,0...2);slider("생동감",$model.draft.vibrance,-1...1);slider("따뜻함",$model.draft.warmth,-1...1);slider("색조",$model.draft.tint,-1...1);slider("감마",$model.draft.gamma,0.3...2)
        Divider();Text("세부사항").font(.headline)
        slider("선명도",$model.draft.sharpness,0...2);slider("윤곽",$model.draft.definition,0...2);slider("노이즈 감소",$model.draft.noise,0...1);slider("비네트",$model.draft.vignette,0...1)
        if !video{Divider();Text("보정").font(.headline);HStack{Button("보정 브러시"){viewer.editorTool=viewer.editorTool=="보정" ? "":"보정"};Button("적목 수정"){viewer.editorTool=viewer.editorTool=="적목" ? "":"적목"}};slider("브러시 크기",$viewer.brush,0.01...0.15);if !viewer.editorTool.isEmpty{Text("사진에서 보정할 부분을 클릭하세요.").font(.caption).foregroundStyle(.secondary)};Button("마지막 보정 취소"){_ = model.draft.retouches.popLast()}.disabled(model.draft.retouches.isEmpty)}
    }}
    private var filters:some View{VStack(alignment:.leading,spacing:15){Text("필터").font(.headline);LazyVGrid(columns:[GridItem(.flexible()),GridItem(.flexible())],spacing:10){ForEach(PhotoRendering.filters,id:\.self){name in Button{model.draft.filter=name}label:{VStack{Image(systemName:name=="원본" ? "photo":"camera.filters").font(.title2).frame(height:42);Text(name).font(.caption).lineLimit(2)}.frame(maxWidth:.infinity,minHeight:80).background(model.draft.filter==name ? Color.accentColor.opacity(0.25):Color.primary.opacity(0.06),in:RoundedRectangle(cornerRadius:8))}.buttonStyle(.plain)}};slider("강도",$model.draft.filterAmount,0...1)}}
    private var crop:some View{VStack(alignment:.leading,spacing:18){
        HStack{Button{model.draft.rotation=(model.draft.rotation+3)%4}label:{Label("회전",systemImage:"rotate.left")};Button{model.draft.flip.toggle()}label:{Label("뒤집기",systemImage:"arrow.left.and.right.righttriangle.left.righttriangle.right")}}
        slider("수평 맞추기",$model.draft.straighten,-45...45)
        Picker("종횡비",selection:$model.draft.aspect){ForEach(["자유형","원본","정사각형","16:9","4:3","3:2","5:4","9:16"],id:\.self){Text($0)}}.onChange(of:model.draft.aspect){value in aspect(value)}
        slider("자르기 너비",$model.draft.cropWidth,0.05...1);slider("자르기 높이",$model.draft.cropHeight,0.05...1);slider("가로 위치",$model.draft.cropX,0...1);slider("세로 위치",$model.draft.cropY,0...1)
        Button("자르기 재설정"){model.draft.cropWidth=1;model.draft.cropHeight=1;model.draft.cropX=0;model.draft.cropY=0;model.draft.straighten=0;model.draft.rotation=0;model.draft.flip=false}
    }}
    private func aspect(_ name:String){guard let item=model.selected else{return};if name=="자유형"{return};let raw=Double(item.width)/Double(max(1,item.height));var original=raw;if model.draft.rotation%2 != 0{original=1/raw};let values=name.split(separator:":").compactMap{Double($0)};let target=name=="정사각형" ? 1.0:values.count==2 ? values[0]/values[1]:original
        if target>original{model.draft.cropWidth=1;model.draft.cropHeight=original/target}else{model.draft.cropHeight=1;model.draft.cropWidth=target/original};model.draft.cropX=(1-model.draft.cropWidth)/2;model.draft.cropY=(1-model.draft.cropHeight)/2
    }
    private var markup:some View{VStack(alignment:.leading,spacing:18){Text("마크업").font(.headline);Picker("도구",selection:$viewer.editorTool){Text("선택 안 함").tag("");ForEach(["텍스트","사각형","원","화살표"],id:\.self){Text($0)}};TextField("추가할 텍스트",text:$viewer.markup);Picker("색상",selection:$viewer.markupColor){ForEach(["흰색","검정","빨강","노랑"],id:\.self){Text($0)}};Text("사진에서 추가할 위치를 클릭하세요.").font(.caption).foregroundStyle(.secondary);Button("마지막 마크업 취소"){_ = model.draft.marks.popLast()}.disabled(model.draft.marks.isEmpty)}}
    private var videoControls:some View{VStack(alignment:.leading,spacing:14){Text("비디오").font(.headline);slider("시작",$model.draft.trimStart,0...0.99);slider("끝",$model.draft.trimEnd,0.01...1);let duration=Double(model.selected?.duration ?? 0)/1000;Text(String(format:"%.1f초 – %.1f초",model.draft.trimStart*duration,model.draft.trimEnd*duration)).font(.caption);Picker("재생 속도",selection:$model.draft.speed){ForEach([0.25,0.5,1,1.5,2,4],id:\.self){value in Text(String(format:"%.2g×",value)).tag(value)}};Toggle("소리 끄기",isOn:$model.draft.muted)}}
}
