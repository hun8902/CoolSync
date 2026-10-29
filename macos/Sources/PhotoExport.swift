import AppKit
import Photos
import AVKit
import ImageIO
import CoreImage
import CoreLocation
import SwiftUI

extension GalleryModel {
    func duplicate(_ item:GalleryItem){explorer.call("galleryDuplicate",["path":item.path]){[weak self]result in guard let self else{return};if result["ok"]as?Bool==true,let path=result["path"]as?String{let annotation=self.note(item);self.change{$0.annotations[path]=annotation};self.reload()}else{self.status=result["error"]as?String ?? "복제 실패"}}}
    func addToMacPhotos(){let values=targets;guard !values.isEmpty else{return};PHPhotoLibrary.requestAuthorization(for:.addOnly){[weak self]permission in DispatchQueue.main.async{guard let self else{return};guard permission == .authorized || permission == .limited else{self.status="시스템 설정에서 사진 추가 권한을 허용하세요";return};self.addToPhotos(values,index:0)}}}
    private func addToPhotos(_ values:[GalleryItem],index:Int){guard index<values.count else{status="Mac 사진 보관함에 \(values.count)개 추가됨";return};let item=values[index];status="Mac 사진 앱에 추가 중 \(index+1)/\(values.count)";fetch(item){[weak self]result in guard let self else{return};do{let source=try result.get();let output=self.note(item).rendered.map{self.store.renderedURL($0)} ?? source
        let capturedDate=self.captureDate(item),annotation=self.note(item),favorite=self.favorite(item),token=self.librarySession
        func save(_ movie:URL?){PHPhotoLibrary.shared().performChanges({let request=PHAssetCreationRequest.forAsset();request.addResource(with:item.video ? .video:.photo,fileURL:output,options:nil);if let movie{request.addResource(with:.pairedVideo,fileURL:movie,options:nil)};request.creationDate=capturedDate;if let lat=annotation.latitude,let lon=annotation.longitude{request.location=CLLocation(latitude:lat,longitude:lon)};request.isFavorite=favorite},completionHandler:{success,error in DispatchQueue.main.async{guard self.librarySession==token else{return};if success{self.addToPhotos(values,index:index+1)}else{self.status=error?.localizedDescription ?? "사진 보관함 저장 실패"}}})}
        if !item.video,self.note(item).rendered==nil,let companion=self.items.first(where:{$0.video && ($0.path as NSString).deletingPathExtension==(item.path as NSString).deletingPathExtension && ($0.path as NSString).pathExtension.lowercased()=="mov"}){self.fetch(companion){result in if case .success(let movie)=result{PHLivePhoto.request(withResourceFileURLs:[source,movie],placeholderImage:nil,targetSize:.zero,contentMode:.aspectFit){photo,info in if info[PHLivePhotoInfoIsDegradedKey]as?Bool==true{return};DispatchQueue.main.async{save(photo==nil ? nil:movie)}}}else{save(nil)}}}else{save(nil)}
    }catch{self.status=error.localizedDescription}}}
    func selectKeyPhoto(){guard let item=selected,let movie=motion else{return};let generator=AVAssetImageGenerator(asset:AVURLAsset(url:movie));generator.appliesPreferredTrackTransform=true;let duration=CMTimeGetSeconds(generator.asset.duration),time=max(0,min(duration-0.01,draft.keyFrame*duration));do{let cg=try generator.copyCGImage(at:CMTime(seconds:time,preferredTimescale:600),actualTime:nil);let image=NSImage(cgImage:cg,size:NSSize(width:cg.width,height:cg.height));let url=store.renderedURL(UUID().uuidString+".jpg");try PhotoRendering.save(image,to:url);let edit=draft;annotate(item){$0.rendered=url.lastPathComponent;$0.edit=edit};status="대표 사진이 저장되었습니다"}catch{status=error.localizedDescription}}
    func longExposure(){guard let item=selected,let movie=motion else{return};saving=true;let token=librarySession;let target=store.renderedURL(UUID().uuidString+".jpg")
        DispatchQueue.global(qos:.userInitiated).async{[weak self]in guard let self else{return};let generator=AVAssetImageGenerator(asset:AVURLAsset(url:movie));generator.appliesPreferredTrackTransform=true;generator.maximumSize=CGSize(width:2400,height:2400);let duration=CMTimeGetSeconds(generator.asset.duration);guard duration.isFinite,duration>0 else{DispatchQueue.main.async{guard self.librarySession==token else{return};self.saving=false;self.status="모션 영상 길이를 읽지 못했습니다"};return};var frames:[CIImage]=[]
            for index in 0..<16{if let cg=try?generator.copyCGImage(at:CMTime(seconds:duration*Double(index)/16,preferredTimescale:600),actualTime:nil){frames.append(CIImage(cgImage:cg))}}
            guard let first=frames.first else{DispatchQueue.main.async{guard self.librarySession==token else{return};self.saving=false;self.status="모션 프레임을 읽지 못했습니다"};return};let weight=1/Double(frames.count)
            func weighted(_ image:CIImage)->CIImage{image.applyingFilter("CIColorMatrix",parameters:["inputRVector":CIVector(x:weight,y:0,z:0,w:0),"inputGVector":CIVector(x:0,y:weight,z:0,w:0),"inputBVector":CIVector(x:0,y:0,z:weight,w:0),"inputAVector":CIVector(x:0,y:0,z:0,w:weight)])}
            var result=weighted(first);for frame in frames.dropFirst(){result=weighted(frame).applyingFilter("CIAdditionCompositing",parameters:[kCIInputBackgroundImageKey:result])};do{guard let cg=PhotoRendering.context.createCGImage(result,from:result.extent)else{throw CocoaError(.fileWriteUnknown)};try PhotoRendering.save(NSImage(cgImage:cg,size:NSSize(width:cg.width,height:cg.height)),to:target);DispatchQueue.main.async{guard self.librarySession==token else{return};self.annotate(item){var edit=$0.edit ?? PhotoAdjustment();edit.liveEffect="장노출";$0.edit=edit;$0.rendered=target.lastPathComponent};self.saving=false;self.status="장노출 효과 저장됨"}}catch{DispatchQueue.main.async{guard self.librarySession==token else{return};self.saving=false;self.status=error.localizedDescription}}
        }
    }
    func bounce(){guard let item=selected,let movie=motion else{return};saving=true;let token=librarySession;let target=store.renderedURL(UUID().uuidString+".gif")
        DispatchQueue.global(qos:.userInitiated).async{[weak self]in guard let self else{return};let generator=AVAssetImageGenerator(asset:AVURLAsset(url:movie));generator.appliesPreferredTrackTransform=true;generator.maximumSize=CGSize(width:960,height:960);let duration=CMTimeGetSeconds(generator.asset.duration);guard duration.isFinite,duration>0 else{DispatchQueue.main.async{self.saving=false};return};var frames:[CGImage]=[];let count=min(90,max(12,Int(duration*20)))
            for index in 0..<count{if let frame=try?generator.copyCGImage(at:CMTime(seconds:duration*Double(index)/Double(count),preferredTimescale:600),actualTime:nil){frames.append(frame)}}
            guard !frames.isEmpty,let destination=CGImageDestinationCreateWithURL(target as CFURL,"com.compuserve.gif" as CFString,frames.count*2,nil)else{DispatchQueue.main.async{guard self.librarySession==token else{return};self.saving=false;self.status="바운스 프레임 생성 실패"};return}
            CGImageDestinationSetProperties(destination,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFLoopCount:0]]as CFDictionary)
            for frame in frames+Array(frames.reversed()){CGImageDestinationAddImage(destination,frame,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFDelayTime:duration/Double(count)]]as CFDictionary)}
            let ok=CGImageDestinationFinalize(destination);DispatchQueue.main.async{guard self.librarySession==token else{return};self.saving=false;if ok{self.annotate(item){var edit=$0.edit ?? PhotoAdjustment();edit.liveEffect="바운스";$0.edit=edit;$0.rendered=target.lastPathComponent};self.status="바운스 효과 저장됨"}else{self.status="바운스 저장 실패"}}
        }
    }
}
struct AnimatedPhotoSurface:NSViewRepresentable {
    let url:URL
    func makeNSView(context:Context)->NSImageView{let view=NSImageView();view.imageScaling = .scaleProportionallyUpOrDown;view.animates=true;view.image=NSImage(contentsOf:url);return view}
    func updateNSView(_ view:NSImageView,context:Context){view.image=NSImage(contentsOf:url);view.animates=true}
}

extension GalleryModel {
    func readMetadata(_ url:URL,item:GalleryItem){
        guard !item.video,let source=CGImageSourceCreateWithURL(url as CFURL,nil),let properties=CGImageSourceCopyPropertiesAtIndex(source,0,nil)as?[String:Any],let gps=properties[kCGImagePropertyGPSDictionary as String]as?[String:Any],let lat=gps["Latitude"]as?Double,let lon=gps["Longitude"]as?Double else{return}
        var a=note(item);if a.latitude==nil && !a.locationOverridden{a.latitude=lat*(gps["LatitudeRef"]as?String=="S" ? -1:1);a.longitude=lon*(gps["LongitudeRef"]as?String=="W" ? -1:1);libraryDoc.annotations[item.path]=a;persist()}
    }
}

extension GalleryModel {
    func recordDraft(){guard editing else{return};if suppressDraft{suppressDraft=false;lastDraft=draft;return};guard lastDraft != draft else{return};draftHistory.append(lastDraft);if draftHistory.count>80{draftHistory.removeFirst()};draftFuture=[];lastDraft=draft}
    func undoEdit(){guard let previous=draftHistory.popLast()else{return};draftFuture.append(draft);suppressDraft=true;draft=previous;lastDraft=previous;refreshPreview()}
    func redoEdit(){guard let next=draftFuture.popLast()else{return};draftHistory.append(draft);suppressDraft=true;draft=next;lastDraft=next;refreshPreview()}
    func saveEditedToPhone(){guard let item=selected,let source=currentURL,note(item).rendered != nil else{return};let folder=cache.appendingPathComponent(UUID().uuidString);do{try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true);let destination=folder.appendingPathComponent((item.name as NSString).deletingPathExtension+"-편집-"+String(Int(Date().timeIntervalSince1970))+"."+source.pathExtension);try FileManager.default.copyItem(at:source,to:destination);importPhotos([destination])}catch{status=error.localizedDescription}}
}

extension GalleryModel {
    func refreshChangedThumbnails(_ prior:PhotoLibraryDocument){for item in items where prior.annotations[item.path]?.rendered != libraryDoc.annotations[item.path]?.rendered{refreshEditedThumbnail(item)}}
    func refreshEditedThumbnail(_ item:GalleryItem){
        let url=note(item).rendered.map{store.renderedURL($0)} ?? downloaded[item.path]
        guard let url else{thumbnails.removeValue(forKey:item.id);thumb(item);return}
        if item.video{let generator=AVAssetImageGenerator(asset:AVURLAsset(url:url));generator.appliesPreferredTrackTransform=true;generator.maximumSize=CGSize(width:320,height:320);if let cg=try?generator.copyCGImage(at:.zero,actualTime:nil){thumbnails[item.id]=NSImage(cgImage:cg,size:NSSize(width:cg.width,height:cg.height))}}
        else if let source=CGImageSourceCreateWithURL(url as CFURL,nil),let cg=CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceCreateThumbnailWithTransform:true,kCGImageSourceThumbnailMaxPixelSize:320]as CFDictionary){thumbnails[item.id]=NSImage(cgImage:cg,size:NSSize(width:cg.width,height:cg.height))}
    }
}
