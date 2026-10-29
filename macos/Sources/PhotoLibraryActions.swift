import AppKit
import SwiftUI
import Combine
import AVKit
import Vision
import ImageIO
import CryptoKit
import LocalAuthentication
import UniformTypeIdentifiers
import MapKit

extension GalleryModel {
    func useLibrary(identity:String){let key=SHA256.hash(data:Data(identity.utf8)).map{String(format:"%02x",$0)}.joined();guard libraryIdentity != key else{return};libraryIdentity=key;if UserDefaults.standard.string(forKey:"galleryFavoriteOwner")==nil{UserDefaults.standard.set(key,forKey:"galleryFavoriteOwner")};if UserDefaults.standard.string(forKey:"galleryFavoriteOwner") != key{favorites=[]};librarySession=UUID();analysisStop=true;analysisRunning=false;store=PhotoLibraryStore(folder:FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("CoolSync/PhotoLibrary/"+key));libraryDoc=store.load();undoDocuments=[];redoDocuments=[];unlocked=false}

    func note(_ item:GalleryItem)->PhotoAnnotation{libraryDoc.annotations[item.path] ?? PhotoAnnotation()}
    func title(_ item:GalleryItem)->String{let value=note(item).title;return value.isEmpty ? item.name:value}
    func captureDate(_ item:GalleryItem)->Date?{note(item).date.map{Date(timeIntervalSince1970:$0)} ?? item.date}
    func change(_ block:(inout PhotoLibraryDocument)->Void){
        undoDocuments.append(libraryDoc);if undoDocuments.count>30{undoDocuments.removeFirst()};redoDocuments=[];let prior=libraryDoc;block(&libraryDoc);refreshChangedThumbnails(prior);persist()
    }
    func annotate(_ item:GalleryItem,_ block:(inout PhotoAnnotation)->Void){change{document in var value=document.annotations[item.path] ?? PhotoAnnotation();block(&value);document.annotations[item.path]=value}}
    func persist(){do{try store.save(libraryDoc)}catch{status="보관함 저장 실패: "+error.localizedDescription}}
    func undoLibrary(){guard let last=undoDocuments.popLast()else{return};redoDocuments.append(libraryDoc);let prior=libraryDoc;libraryDoc=last;refreshChangedThumbnails(prior);persist()}
    func redoLibrary(){guard let next=redoDocuments.popLast()else{return};undoDocuments.append(libraryDoc);let prior=libraryDoc;libraryDoc=next;refreshChangedThumbnails(prior);persist()}
    func matches(_ item:GalleryItem,_ category:String)->Bool{
        let annotation=note(item)
        if annotation.hidden && category != "가려진 항목"{return false}
        switch category{
        case "보관함","모음","지도","모든 앨범","추억":return true
        case "최근 저장된 항목":return true
        case "즐겨찾기":return favorite(item)
        case "가려진 항목":return annotation.hidden && unlocked
        case "비디오":return item.video
        case "Live Photo":return annotation.edit?.liveEffect != "끔" && (item.live==true || motionPaths.contains(item.path) || annotation.labels.contains("live"))
        case "스크린샷":return item.path.localizedCaseInsensitiveContains("screenshot") || item.album.localizedCaseInsensitiveContains("스크린샷")
        case "셀피":return item.path.localizedCaseInsensitiveContains("selfie") || annotation.labels.contains("selfie")
        case "RAW":return ["dng","raw","cr2","cr3","nef","arw","raf","orf","rw2"].contains((item.name as NSString).pathExtension.lowercased())
        case "GIF":return item.mime=="image/gif"
        case "파노라마":return item.width>item.height*2
        case "중복된 항목":return !annotation.fingerprint.isEmpty && duplicatePaths.contains(item.path)
        case "편집됨":return annotation.edit != nil
        case "사람들":return !annotation.people.isEmpty
        default:
            if category.hasPrefix("사람:"){return annotation.people.contains(String(category.dropFirst(3)))}
            if category.hasPrefix("사용자앨범:"){guard let album=libraryDoc.albums.first(where:{$0.id==String(category.dropFirst(6))})else{return false};return album.rule.map{matchesRule(item,$0)} ?? album.paths.contains(item.path)}
            return category=="앨범:"+item.album
        }
    }
    func matchesRule(_ item:GalleryItem,_ rule:PhotoAlbumRule)->Bool{
        let value=rule.value.lowercased(),annotation=note(item)
        switch rule.field{
        case "미디어 유형":return value=="비디오" ? item.video:value=="사진" ? !item.video:matches(item,rule.value)
        case "즐겨찾기":return favorite(item)
        case "편집됨":return annotation.edit != nil
        case "촬영 연도":return captureDate(item).map{String(Calendar.current.component(.year,from:$0))==rule.value} ?? false
        case "카메라 앨범":return item.album.localizedCaseInsensitiveContains(rule.value)
        case "제목":return title(item).localizedCaseInsensitiveContains(rule.value)
        default:return annotation.keywords.contains{ $0.localizedCaseInsensitiveContains(rule.value)}
        }
    }
    var peopleVisible:[PhotoPerson]{libraryDoc.people.compactMap{person in let paths=person.paths.filter{path in items.contains{$0.path==path && !note($0).hidden}};guard !paths.isEmpty else{return nil};var value=person;value.paths=paths;return value}}
    var duplicateGroups:[[GalleryItem]]{Dictionary(grouping:items.filter{!note($0).fingerprint.isEmpty && !note($0).hidden},by:{note($0).fingerprint}).values.filter{$0.count>1}.map{$0.sorted{(captureDate($0) ?? .distantPast)>(captureDate($1) ?? .distantPast)}}.sorted{$0[0].name<$1[0].name}}
    var duplicatePaths:Set<String>{Set(duplicateGroups.flatMap{$0.map{$0.path}})}
    var locations:[PhotoLocation]{visible.compactMap{item in let a=note(item);guard let lat=a.latitude,let lon=a.longitude else{return nil};return PhotoLocation(id:item.path,latitude:lat,longitude:lon,item:item)}}
    var memories:[PhotoMemory]{
        let usable=items.filter{!note($0).hidden && captureDate($0) != nil};let formatter=DateFormatter();formatter.dateFormat="yyyy년 M월"
        return Dictionary(grouping:usable,by:{formatter.string(from:captureDate($0)!)}).map{key,values in PhotoMemory(id:key,title:key,subtitle:"\(values.count)개의 추억",items:values.sorted{captureDate($0)!<captureDate($1)!})}.sorted{($0.items.first.flatMap{captureDate($0)} ?? .distantPast)>($1.items.first.flatMap{captureDate($0)} ?? .distantPast)}
    }
    func searchMatch(_ item:GalleryItem)->Bool{
        if search.isEmpty{return true};let a=note(item),people=libraryDoc.people.filter{a.people.contains($0.id)}.map{$0.name}.joined(separator:" ")
        let text=[item.name,item.album,a.title,a.caption,a.keywords.joined(separator:" "),a.text,a.labels.joined(separator:" "),people,captureDate(item)?.formatted(date:.long,time:.omitted) ?? "",a.place].joined(separator:" ")
        return search.split(separator:" ").allSatisfy{text.localizedCaseInsensitiveContains(String($0))}
    }
    var targets:[GalleryItem]{if let selected{return [selected]};return visible.filter{selection.contains($0.id)}}
    func select(_ item:GalleryItem){
        let flags=NSEvent.modifierFlags
        if flags.contains(.shift),let anchor=selectionAnchor,let from=visible.firstIndex(where:{$0.id==anchor}),let to=visible.firstIndex(where:{$0.id==item.id}){selection.formUnion(visible[min(from,to)...max(from,to)].map{$0.id})}
        else if flags.contains(.command){if selection.contains(item.id){selection.remove(item.id)}else{selection.insert(item.id)}}else{selection=[item.id];selectionAnchor=item.id}
    }
    func choose(_ value:String){selected=nil;selection=[];timelinePrefix="";category=value;if value=="최근 삭제된 항목"{unlock{self.loadDeleted()}}else if value=="가려진 항목"{unlock{}}}
    func unlock(_ done:@escaping()->Void){
        if unlocked{done();return};let context=LAContext();var error:NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication,error:&error)else{status=error?.localizedDescription ?? "Mac 로그인 인증을 사용할 수 없습니다";return}
        context.evaluatePolicy(.deviceOwnerAuthentication,localizedReason:"가려진 사진과 최근 삭제된 항목을 표시합니다"){[weak self]ok,error in DispatchQueue.main.async{guard let self else{return};self.unlocked=ok;if ok{done()}else{self.status=error?.localizedDescription ?? "인증을 취소했습니다"}}}
    }
    func hideTargets(){let values=targets;guard !values.isEmpty else{return};let hide = !values.allSatisfy{note($0).hidden};change{doc in for item in values{var a=doc.annotations[item.path] ?? PhotoAnnotation();a.hidden=hide;doc.annotations[item.path]=a}};selected=nil;selection=[]}
    func prompt(_ title:String,value:String="",done:@escaping(String)->Void){let alert=NSAlert();alert.messageText=title;let field=NSTextField(string:value);field.frame=NSRect(x:0,y:0,width:300,height:24);alert.accessoryView=field;alert.addButton(withTitle:"확인");alert.addButton(withTitle:"취소");alert.window.initialFirstResponder=field;if alert.runModal() == .alertFirstButtonReturn,!field.stringValue.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty{done(field.stringValue)}}
    func createAlbum(folder:Bool=false,smart:PhotoAlbumRule?=nil){let values=targets;prompt(folder ? "새 폴더":"새 앨범",value:folder ? "새 폴더":"새 앨범"){name in let album=PhotoAlbum(name:name,paths:values.map{$0.path},folder:folder ? "root":nil,rule:smart);self.change{$0.albums.append(album)};self.choose("사용자앨범:"+album.id)}}
    func renameAlbum(_ album:PhotoAlbum){prompt("앨범 이름 변경",value:album.name){name in self.change{if let index=$0.albums.firstIndex(where:{$0.id==album.id}){$0.albums[index].name=name}}}}
    func deleteAlbum(_ album:PhotoAlbum){let alert=NSAlert();alert.messageText="‘\(album.name)’ 앨범을 삭제할까요?";alert.informativeText="앨범 구성만 삭제하며 사진과 영상은 보관함에 유지됩니다.";alert.addButton(withTitle:"앨범 삭제");alert.addButton(withTitle:"취소");guard alert.runModal() == .alertFirstButtonReturn else{return};change{$0.albums.removeAll{$0.id==album.id};for i in $0.albums.indices where $0.albums[i].folder==album.id{$0.albums[i].folder=nil}};choose("보관함")}
    func addToAlbum(_ album:PhotoAlbum){let paths=targets.map{$0.path};change{if let i=$0.albums.firstIndex(where:{$0.id==album.id}){for path in paths where !$0.albums[i].paths.contains(path){$0.albums[i].paths.append(path)}}}}
    func removeFromAlbum(){guard category.hasPrefix("사용자앨범:")else{return};let id=String(category.dropFirst(6)),paths=Set(targets.map{$0.path});change{if let i=$0.albums.firstIndex(where:{$0.id==id}){$0.albums[i].paths.removeAll{paths.contains($0)}}};selection=[]}
    func moveAlbum(_ album:PhotoAlbum,to folder:PhotoAlbum?){change{if let index=$0.albums.firstIndex(where:{$0.id==album.id}){$0.albums[index].folder=folder?.id}}}
    func renamePerson(_ person:PhotoPerson){prompt("이름 추가",value:person.name){name in self.change{if let i=$0.people.firstIndex(where:{$0.id==person.id}){$0.people[i].name=name}}}}
    func mergePerson(_ person:PhotoPerson,into target:PhotoPerson){guard person.id != target.id else{return};change{doc in
        for key in Array(doc.annotations.keys){guard var a=doc.annotations[key],a.people.contains(person.id)else{continue};a.people.removeAll{$0==person.id};if !a.people.contains(target.id){a.people.append(target.id)};doc.annotations[key]=a}
        if let i=doc.people.firstIndex(where:{$0.id==target.id}){doc.people[i].paths=Array(Set(doc.people[i].paths+person.paths))};doc.people.removeAll{$0.id==person.id}
    }}
    func removePerson(_ person:PhotoPerson,from item:GalleryItem){annotate(item){$0.people.removeAll{$0==person.id}};change{if let i=$0.people.firstIndex(where:{$0.id==person.id}){$0.people[i].paths.removeAll{$0==item.path}}}}
    func loadDeleted(offset:Int=0,values:[RemoteTrash]=[]){guard unlocked else{return};explorer.call("listTrash",["offset":offset],quiet:true){[weak self]r in guard let self else{return};guard r["ok"]as?Bool==true,let rows=r["trash"],let data=try?JSONSerialization.data(withJSONObject:rows),let page=try?JSONDecoder().decode([RemoteTrash].self,from:data)else{self.status=r["error"]as?String ?? "휴지통을 읽지 못했습니다";return};let all=values+page,next=r["next"]as?Int ?? 0,total=r["total"]as?Int ?? 0;if next<total && next>offset{self.loadDeleted(offset:next,values:all)}else{let types=Set(["jpg","jpeg","heic","heif","png","webp","gif","dng","mp4","mov","mkv","3gp","avi","m4v","raw","tiff","tif"]);self.deleted=all.filter{types.contains(($0.name as NSString).pathExtension.lowercased())};self.status="최근 삭제된 항목 \(self.deleted.count)개";self.loadSystemDeleted()}}}
    func deleteTargets(){let values=targets;guard !values.isEmpty else{return};let alert=NSAlert();alert.messageText="\(values.count)개 항목을 삭제할까요?";alert.informativeText="휴대폰의 CoolSync 휴지통으로 이동합니다. ‘최근 삭제된 항목’에서 복원할 수 있습니다.";alert.addButton(withTitle:"삭제");alert.addButton(withTitle:"취소");guard alert.runModal() == .alertFirstButtonReturn else{return}
        let batches=PhotoBatches.paths(values.map{$0.path})
        func step(_ index:Int){guard index<batches.count else{self.status="\(values.count)개 삭제됨";return};let paths=Set(batches[index]);self.explorer.call("trash",["paths":Array(paths)]){[weak self]r in guard let self else{return};if r["ok"]as?Bool==true{let ids=Set(self.items.filter{paths.contains($0.path)}.map{$0.id});self.items.removeAll{paths.contains($0.path)};self.selection.subtract(ids);if let selected=self.selected,paths.contains(selected.path){self.selected=nil};self.status="삭제 중 \(index+1)/\(batches.count)";step(index+1)}else{self.status=r["error"]as?String ?? "삭제 실패"}}}
        step(0)
    }
    func restoreDeleted(permanent:Bool=false){let all=deleted.filter{deletedSelection.contains($0.id)};let values=all.filter{!$0.id.hasPrefix("native:")};let native=all.filter{$0.id.hasPrefix("native:")};guard !all.isEmpty else{return};let alert=NSAlert();alert.messageText="\(all.count)개 항목을 \(permanent ? "영구 삭제":"복원")할까요?";alert.informativeText=permanent ? "휴대폰에서 영구 삭제하며 되돌릴 수 없습니다.":"휴대폰의 원래 앨범과 위치로 복원합니다.";alert.addButton(withTitle:permanent ? "영구 삭제":"복원");alert.addButton(withTitle:"취소");guard alert.runModal() == .alertFirstButtonReturn else{return}
        func step(_ remaining:[RemoteTrash]){guard let item=remaining.first else{self.deletedSelection=[];self.reload();if !native.isEmpty{self.explorer.call("gallerySystemAction",["ids":native.map{$0.id},"action":permanent ? "delete":"restore"],quiet:true){result in self.status=result["message"]as?String ?? result["error"]as?String ?? "휴대폰에서 사진 작업을 승인하세요"}};return};self.explorer.call(permanent ? "deletePermanent":"restore",["id":item.id]){r in if r["ok"]as?Bool==true{self.deleted.removeAll{$0.id==item.id};step(Array(remaining.dropFirst()))}else{self.status=r["error"]as?String ?? "작업 실패"}}};step(values)
    }
    func importPhotos(_ urls:[URL]?=nil){
        if let urls{guard !urls.isEmpty else{return};explorer.call("list",["path":"Pictures/CoolSync","offset":0],quiet:true){[weak self]r in guard let self else{return};if r["ok"]as?Bool==true{self.explorer.upload(urls,to:"Pictures/CoolSync",completion:{[weak self]in self?.reload()});self.status="가져오는 중"}else{self.explorer.call("mkdir",["path":"Pictures","name":"CoolSync"],quiet:true){result in if result["ok"]as?Bool==true{self.explorer.upload(urls,to:"Pictures/CoolSync",completion:{[weak self]in self?.reload()})}else{self.status=result["error"]as?String ?? "휴대폰 Pictures 폴더를 확인하세요"}}}};return}
        let panel=NSOpenPanel();panel.allowsMultipleSelection=true;panel.allowedContentTypes=[.image,.movie];if panel.runModal() == .OK{importPhotos(panel.urls)}
    }
    func fetch(_ item:GalleryItem,valid:(()->Bool)?=nil,completion:@escaping(Result<URL,Error>)->Void){
        guard valid?() != false else{completion(.failure(CocoaError(.userCancelled)));return}
        if let existing=downloaded[item.path],FileManager.default.fileExists(atPath:existing.path){completion(.success(existing));return}
        if selected?.id==item.id,let original{completion(.success(original));return}
        let url=cache.appendingPathComponent(UUID().uuidString+"."+(item.name as NSString).pathExtension)
        let token=librarySession
        explorer.promise(item.remote,to:url,quiet:true,valid:valid){[weak self]error in guard let self,self.librarySession==token else{completion(.failure(CocoaError(.userCancelled)));return};if let error{completion(.failure(error))}else{self.downloaded[item.path]=url;completion(.success(url))}}
    }
    func exportTargets(originals:Bool=false){
        let values=targets;guard !values.isEmpty else{return};let panel=NSOpenPanel();panel.canChooseDirectories=true;panel.canChooseFiles=false;panel.prompt="내보내기"
        let formats=NSPopUpButton();formats.addItems(withTitles:["원래 포맷","JPEG","PNG","TIFF"]);formats.selectItem(withTitle:exportFormat)
        let quality=NSSlider(value:exportQuality,minValue:0.1,maxValue:1,target:nil,action:nil);quality.frame.size.width=160
        let controls=NSStackView(views:[NSTextField(labelWithString:"사진 포맷"),formats,NSTextField(labelWithString:"품질"),quality]);controls.spacing=10;panel.accessoryView=controls;controls.isHidden=originals
        guard panel.runModal() == .OK,let folder=panel.url else{return};exportFormat=formats.titleOfSelectedItem ?? "원래 포맷";exportQuality=quality.doubleValue;exportBatch(values,to:folder,originals:originals)
    }
    func exportBatch(_ values:[GalleryItem],to folder:URL,originals:Bool,index:Int=0){
        guard index<values.count else{status="\(values.count)개 내보내기 완료";return};let item=values[index];status="내보내는 중 \(index+1)/\(values.count)"
        fetch(item){[weak self]result in guard let self else{return};do{let source=try result.get();let annotation=self.note(item);let chosen = !originals ? annotation.rendered.map{self.store.renderedURL($0)} ?? source:source;let convert = !originals && !item.video && self.exportFormat != "원래 포맷";let ext=convert ? (self.exportFormat=="JPEG" ? "jpg":self.exportFormat.lowercased()):chosen.pathExtension;var name=(item.name as NSString).deletingPathExtension+"."+ext;var target=folder.appendingPathComponent(name);var n=2;while FileManager.default.fileExists(atPath:target.path){name=(item.name as NSString).deletingPathExtension+" (\(n))."+ext;target=folder.appendingPathComponent(name);n+=1};if convert,let image=NSImage(contentsOf:chosen){try PhotoRendering.save(image,to:target,format:self.exportFormat,quality:self.exportQuality)}else{try FileManager.default.copyItem(at:chosen,to:target)};if originals,let companion=self.items.first(where:{$0.video && ($0.path as NSString).deletingPathExtension==(item.path as NSString).deletingPathExtension}),!item.video,!values.contains(where:{$0.id==companion.id}){self.fetch(companion){video in if case .success(let url)=video{let dest=folder.appendingPathComponent(companion.name);if !FileManager.default.fileExists(atPath:dest.path){try?FileManager.default.copyItem(at:url,to:dest)}}}};DispatchQueue.main.async{self.exportBatch(values,to:folder,originals:originals,index:index+1)}}catch{self.status="내보내기 실패: "+error.localizedDescription}}
    }
    var currentURL:URL?{guard let selected else{return original};if let name=note(selected).rendered{let url=store.renderedURL(name);if FileManager.default.fileExists(atPath:url.path){return url}};return original}
    func shareTargets(){let values=targets;guard !values.isEmpty else{return};var urls:[URL]=[];func next(_ index:Int){guard index<values.count else{if let view=NSApp.keyWindow?.contentView{NSSharingServicePicker(items:urls).show(relativeTo:.zero,of:view,preferredEdge:.minY)};return};self.fetch(values[index]){result in if case .success(let url)=result{urls.append(self.note(values[index]).rendered.map{self.store.renderedURL($0)} ?? url)};next(index+1)}};next(0)}
    func copyPhoto(){guard let url=currentURL,let image=NSImage(contentsOf:url)else{return};NSPasteboard.general.clearContents();NSPasteboard.general.writeObjects([image]);status="사진 복사됨"}
    func printPhoto(){guard let url=currentURL,let image=NSImage(contentsOf:url)else{return};let view=NSImageView(frame:NSRect(x:0,y:0,width:720,height:720));view.image=image;view.imageScaling = .scaleProportionallyUpOrDown;NSPrintOperation(view:view).run()}
    func dragProvider(_ item:GalleryItem)->NSItemProvider{let provider=NSItemProvider();provider.suggestedName=item.name;provider.registerFileRepresentation(forTypeIdentifier:item.video ? UTType.movie.identifier:UTType.image.identifier,fileOptions:[],visibility:.all){completion in let progress=Progress(totalUnitCount:1);DispatchQueue.main.async{self.fetch(item){result in switch result{case .success(let url):completion(url,false,nil);case .failure(let error):completion(nil,false,error)};progress.completedUnitCount=1}};return progress};return provider}
    func locate(_ query:String,item:GalleryItem){let request=MKLocalSearch.Request();request.naturalLanguageQuery=query;MKLocalSearch(request:request).start{[weak self]response,error in DispatchQueue.main.async{guard let self else{return};if let place=response?.mapItems.first{self.annotate(item){$0.latitude=place.placemark.coordinate.latitude;$0.longitude=place.placemark.coordinate.longitude;$0.place=place.name ?? query;$0.locationOverridden=true}}else{self.status=error?.localizedDescription ?? "위치를 찾지 못했습니다"}}}}
}

extension GalleryModel {
    func mergeDuplicates(_ values:[GalleryItem]){
        guard let keep=values.first,values.count>1 else{return};let rest=Array(values.dropFirst());let alert=NSAlert();alert.messageText="동일한 항목 \(values.count)개를 병합할까요?";alert.informativeText="원본 하나를 보존하고 키워드·앨범·즐겨찾기를 합칩니다. 나머지 원본은 휴대폰 CoolSync 휴지통으로 이동합니다.";alert.addButton(withTitle:"병합");alert.addButton(withTitle:"취소");guard alert.runModal() == .alertFirstButtonReturn else{return}
        explorer.call("galleryMerge",["paths":values.map{$0.path}]){[weak self]result in guard let self else{return};guard result["ok"]as?Bool==true else{self.status=result["error"]as?String ?? "병합 실패";return};self.change{doc in var annotation=doc.annotations[keep.path] ?? PhotoAnnotation();for item in rest{let other=doc.annotations[item.path] ?? PhotoAnnotation();annotation.keywords=Array(Set(annotation.keywords+other.keywords));annotation.people=Array(Set(annotation.people+other.people));if other.favorite==true{annotation.favorite=true};if annotation.caption.isEmpty{annotation.caption=other.caption};for i in doc.albums.indices where doc.albums[i].paths.contains(item.path){doc.albums[i].paths.removeAll{$0==item.path};if !doc.albums[i].paths.contains(keep.path){doc.albums[i].paths.append(keep.path)}}};doc.annotations[keep.path]=annotation};let paths=Set(rest.map{$0.path});self.items.removeAll{paths.contains($0.path)};self.status="중복 항목 병합 완료"}
    }
}

extension GalleryModel {
    func loadSystemDeleted(offset:Int=0,values:[RemoteTrash]=[]){guard unlocked else{return};explorer.call("gallerySystemTrash",["offset":offset],quiet:true){[weak self]result in guard let self else{return};guard result["ok"]as?Bool==true,let rows=result["trash"],let data=try?JSONSerialization.data(withJSONObject:rows),let page=try?JSONDecoder().decode([RemoteTrash].self,from:data)else{self.status="CoolSync 휴지통 \(self.deleted.count)개 · 시스템 휴지통 접근 상태를 확인하세요";return};let all=values+page,next=result["next"]as?Int ?? 0,total=result["total"]as?Int ?? 0;if next<total && next>offset{self.loadSystemDeleted(offset:next,values:all)}else{self.deleted.removeAll{$0.id.hasPrefix("native:")};self.deleted+=all;self.status="최근 삭제된 항목 \(self.deleted.count)개"}}}
}
