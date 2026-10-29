import AppKit
import Vision
import ImageIO
import CryptoKit
import AVKit
import CoreImage

private struct AnalyzedFace {let data:Data?;let feature:Data?}
private struct PhotoAnalysisResult {var text="";var labels:[String]=[];var faces:[AnalyzedFace]=[];var hash="";var latitude:Double?;var longitude:Double?}

extension GalleryModel {
    func startAnalysis(){guard !analysisRunning else{return};analysisStop=false;analysisRunning=true;let values=items.filter{!note($0).analyzed && !note($0).hidden};analyzeNext(values,total:values.count,token:librarySession)}
    func stopAnalysis(){analysisStop=true;analysisProgress="현재 사진 분석 후 중단합니다"}
    private func analyzeNext(_ remaining:[GalleryItem],total:Int,token:UUID){
        guard token==librarySession else{return};guard !analysisStop,let item=remaining.first else{analysisRunning=false;analysisProgress="분석 완료 · \(total-remaining.count)/\(total)";persist();return}
        analysisProgress="사진 분석 \(total-remaining.count+1)/\(total) · \(item.name)"
        fetch(item){[weak self]response in guard let self,self.librarySession==token else{return};switch response{
        case .failure(let error):self.analysisProgress="\(item.name): \(error.localizedDescription)";self.analyzeNext(Array(remaining.dropFirst()),total:total,token:token)
        case .success(let url):self.analysisWorker.async{
            var result=PhotoAnalysisResult()
            if let stream=InputStream(url:url){stream.open();var hash=SHA256();let buffer=UnsafeMutablePointer<UInt8>.allocate(capacity:262144);defer{stream.close();buffer.deallocate()};while stream.hasBytesAvailable{let count=stream.read(buffer,maxLength:262144);if count<=0{break};hash.update(data:Data(bytes:buffer,count:count))};result.hash=hash.finalize().map{String(format:"%02x",$0)}.joined()}
            var cg:CGImage?
            if item.video{let generator=AVAssetImageGenerator(asset:AVURLAsset(url:url));generator.appliesPreferredTrackTransform=true;generator.maximumSize=CGSize(width:1600,height:1600);cg=try?generator.copyCGImage(at:CMTime(seconds:0.1,preferredTimescale:600),actualTime:nil)}
            else if let source=CGImageSourceCreateWithURL(url as CFURL,nil){
                cg=CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceThumbnailMaxPixelSize:1800,kCGImageSourceCreateThumbnailWithTransform:true] as CFDictionary)
                let properties=CGImageSourceCopyPropertiesAtIndex(source,0,nil)as?[String:Any] ?? [:]
                if let gps=properties[kCGImagePropertyGPSDictionary as String]as?[String:Any],let lat=gps["Latitude"]as?Double,let lon=gps["Longitude"]as?Double{result.latitude=lat*(gps["LatitudeRef"]as?String=="S" ? -1:1);result.longitude=lon*(gps["LongitudeRef"]as?String=="W" ? -1:1)}
            }
            if let cg{
                let text=VNRecognizeTextRequest();text.recognitionLevel = .accurate;text.usesLanguageCorrection=true;text.recognitionLanguages=["ko-KR","en-US"]
                let faces=VNDetectFaceRectanglesRequest(),labels=VNClassifyImageRequest()
                try?VNImageRequestHandler(cgImage:cg).perform([text,faces,labels])
                result.text=(text.results ?? []).compactMap{$0.topCandidates(1).first?.string}.joined(separator:"\n")
                result.labels=(labels.results ?? []).filter{$0.confidence>0.2}.prefix(12).map{$0.identifier}
                for face in faces.results ?? []{
                    let rect=VNImageRectForNormalizedRect(face.boundingBox,cg.width,cg.height).insetBy(dx:-12,dy:-12).intersection(CGRect(x:0,y:0,width:cg.width,height:cg.height))
                    let topRect=CGRect(x:rect.minX,y:CGFloat(cg.height)-rect.maxY,width:rect.width,height:rect.height)
                    guard let crop=cg.cropping(to:topRect)else{continue};let printRequest=VNGenerateImageFeaturePrintRequest();printRequest.revision=VNGenerateImageFeaturePrintRequestRevision1
                    try?VNImageRequestHandler(cgImage:crop).perform([printRequest])
                    let feature=printRequest.results?.first.flatMap{try?NSKeyedArchiver.archivedData(withRootObject:$0,requiringSecureCoding:true)}
                    let bitmap=NSBitmapImageRep(cgImage:crop);let portrait=bitmap.representation(using:.jpeg,properties:[.compressionFactor:0.65])
                    result.faces.append(AnalyzedFace(data:portrait,feature:feature))
                }
            }
            let output=result
            DispatchQueue.main.async{guard self.librarySession==token else{return};var annotation=self.note(item);annotation.text=output.text;annotation.labels=Array(Set(annotation.labels+output.labels));annotation.fingerprint=output.hash;annotation.analyzed=true
                if annotation.latitude==nil && !annotation.locationOverridden{annotation.latitude=output.latitude;annotation.longitude=output.longitude}
                for face in output.faces{
                    var match:Int?
                    if let data=face.feature,let observation=try?NSKeyedUnarchiver.unarchivedObject(ofClass:VNFeaturePrintObservation.self,from:data){var closest:Float=8
                        for (index,person) in self.libraryDoc.people.enumerated(){guard let saved=person.feature,let other=try?NSKeyedUnarchiver.unarchivedObject(ofClass:VNFeaturePrintObservation.self,from:saved)else{continue};var distance:Float=0;if (try?observation.computeDistance(&distance,to:other)) != nil,distance<closest{closest=distance;match=index}}
                    }
                    if let index=match{let id=self.libraryDoc.people[index].id;if !annotation.people.contains(id){annotation.people.append(id)};if !self.libraryDoc.people[index].paths.contains(item.path){self.libraryDoc.people[index].paths.append(item.path)}}else{var person=PhotoPerson();person.paths=[item.path];person.portrait=face.data;person.feature=face.feature;self.libraryDoc.people.append(person);annotation.people.append(person.id)}
                }
                self.libraryDoc.annotations[item.path]=annotation;self.persist();self.analyzeNext(Array(remaining.dropFirst()),total:total,token:token)
            }
        }
        }}
    }
    func beginEditing(){guard let selected,original != nil else{return};draft=note(selected).edit ?? PhotoAdjustment();lastDraft=draft;draftHistory=[];draftFuture=[];suppressDraft=false;editing=true;refreshPreview()}
    func cancelEditing(){editing=false;previewWork?.cancel();editPreview=nil}
    func refreshPreview(){guard editing,let original else{return};previewWork?.cancel();let edit=draft,id=selected?.id,token=librarySession
        let work=DispatchWorkItem{[weak self]in guard let self else{return};let image=try?PhotoRendering.image(original,edit,maxDimension:1600);DispatchQueue.main.async{if self.librarySession==token,self.editing,self.selected?.id==id,self.draft==edit{self.editPreview=image}}};previewWork=work;DispatchQueue.global(qos:.userInitiated).asyncAfter(deadline:.now()+0.12,execute:work)
    }
    func autoEnhance(){guard original != nil else{return};draft.automatic.toggle();refreshPreview()}
    func revert(){guard let selected else{return};annotate(selected){$0.edit=nil;$0.rendered=nil};draft=PhotoAdjustment();editPreview=nil;status="원본으로 복귀했습니다"}
    func saveEditing(){guard let item=selected,let original,!saving else{return};saving=true;let edit=draft,token=librarySession
        if item.video{saveVideo(original,item:item,edit:edit);return}
        let target=store.renderedURL(UUID().uuidString+".jpg")
        DispatchQueue.global(qos:.userInitiated).async{[weak self]in do{let image=try PhotoRendering.image(original,edit);try PhotoRendering.save(image,to:target);DispatchQueue.main.async{guard let self,self.librarySession==token else{return};self.annotate(item){$0.edit=edit;$0.rendered=target.lastPathComponent};self.editing=false;self.editPreview=nil;self.saving=false;self.status="편집 저장됨 · 원본으로 복귀 가능"}}catch{DispatchQueue.main.async{self?.saving=false;self?.status="저장 실패: "+error.localizedDescription}}}
    }
    private func saveVideo(_ url:URL,item:GalleryItem,edit:PhotoAdjustment){let token=librarySession;
        let source=AVURLAsset(url:url),composition=AVMutableComposition();let duration=CMTimeGetSeconds(source.duration)
        guard duration.isFinite,duration>0,let video=source.tracks(withMediaType:.video).first,let target=composition.addMutableTrack(withMediaType:.video,preferredTrackID:kCMPersistentTrackID_Invalid)else{saving=false;status="영상 트랙을 읽지 못했습니다";return}
        let start=max(0,min(duration-0.01,edit.trimStart*duration)),end=max(start+0.01,min(duration,edit.trimEnd*duration));let range=CMTimeRange(start:CMTime(seconds:start,preferredTimescale:600),end:CMTime(seconds:end,preferredTimescale:600))
        do{try target.insertTimeRange(range,of:video,at:.zero);target.preferredTransform=video.preferredTransform;if !edit.muted,let audio=source.tracks(withMediaType:.audio).first,let track=composition.addMutableTrack(withMediaType:.audio,preferredTrackID:kCMPersistentTrackID_Invalid){try track.insertTimeRange(range,of:audio,at:.zero)};composition.scaleTimeRange(CMTimeRange(start:.zero,duration:range.duration),toDuration:CMTimeMultiplyByFloat64(range.duration,multiplier:1/max(0.25,edit.speed)))}catch{saving=false;status=error.localizedDescription;return}
        let filters=AVMutableVideoComposition(asset:composition){request in let source=request.sourceImage.clampedToExtent();let result=PhotoRendering.apply(source.cropped(to:request.sourceImage.extent),edit);request.finish(with:result,context:PhotoRendering.context)}
        let transformed=video.naturalSize.applying(video.preferredTransform);var size=CGSize(width:abs(transformed.width),height:abs(transformed.height));if edit.rotation%2 != 0{size=CGSize(width:size.height,height:size.width)};size.width=max(2,floor(size.width*max(0.05,edit.cropWidth)/2)*2);size.height=max(2,floor(size.height*max(0.05,edit.cropHeight)/2)*2);filters.renderSize=size
        guard let exporter=AVAssetExportSession(asset:composition,presetName:AVAssetExportPresetHighestQuality)else{saving=false;status="영상 내보내기를 시작하지 못했습니다";return}
        let output=store.renderedURL(UUID().uuidString+".mp4");exporter.outputURL=output;exporter.outputFileType = .mp4;exporter.videoComposition=filters;exporter.shouldOptimizeForNetworkUse=true;activeExport=exporter
        exporter.exportAsynchronously{[weak self]in DispatchQueue.main.async{guard let self,self.librarySession==token else{return};self.saving=false;self.activeExport=nil;if exporter.status == .completed{self.annotate(item){$0.edit=edit;$0.rendered=output.lastPathComponent};self.editing=false;self.status="영상 편집 저장됨"}else{self.status=exporter.error?.localizedDescription ?? "영상 저장을 취소했습니다";try?FileManager.default.removeItem(at:output)}}}
    }
    func copyAdjustments(){guard let selected else{return};copiedEdit=note(selected).edit;status="편집 내용 복사됨"}
    func pasteAdjustments(){guard let edit=copiedEdit else{return};let values=targets.filter{!$0.video};guard !values.isEmpty else{return};func next(_ index:Int){guard index<values.count else{self.status="\(values.count)개 항목에 편집 적용됨";return};let item=values[index];self.fetch(item){result in do{let source=try result.get();let output=self.store.renderedURL(UUID().uuidString+".jpg");let image=try PhotoRendering.image(source,edit);try PhotoRendering.save(image,to:output);self.annotate(item){$0.edit=edit;$0.rendered=output.lastPathComponent};next(index+1)}catch{self.status=error.localizedDescription}}};next(0)}
    func startSlideshow(_ values:[GalleryItem]?=nil){slideshowItems=values ?? (selection.isEmpty ? visible:targets);guard let first=slideshowItems.first else{return};slideshow=true;open(first)}
    func advanceSlideshow(){guard slideshow,!editing else{return};if selected?.video==true{return};if let index=slideshowItems.firstIndex(where:{$0.id==selected?.id}),index+1<slideshowItems.count{open(slideshowItems[index+1])}else{slideshow=false}}
    func chooseMusic(){let panel=NSOpenPanel();panel.allowedContentTypes=[.audio];if panel.runModal() == .OK{slideshowMusic=panel.url}}
}
