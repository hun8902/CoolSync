import AppKit
import SwiftUI
import Combine
import CoreImage
import ImageIO
import Vision
import CryptoKit
import LocalAuthentication
import AVKit
import UniformTypeIdentifiers

struct PhotoAnnotation:Codable,Equatable {
    var title="";var caption="";var keywords:[String]=[]
    var favorite:Bool?;var hidden=false;var date:Double?;var latitude:Double?;var longitude:Double?;var place="";var locationOverridden=false
    var text="";var labels:[String]=[];var people:[String]=[];var fingerprint="";var analyzed=false
    var edit:PhotoAdjustment?;var rendered:String?
}
struct PhotoAlbum:Identifiable,Codable,Equatable {
    var id=UUID().uuidString;var name:String;var paths:[String]=[];var folder:String?;var rule:PhotoAlbumRule?
}
struct PhotoAlbumRule:Codable,Equatable {var field="키워드";var value="";var all=false}
struct PhotoPerson:Identifiable,Codable,Equatable {
    var id=UUID().uuidString;var name="이름 없는 사람";var paths:[String]=[];var portrait:Data?;var feature:Data?
}
struct PhotoLibraryDocument:Codable,Equatable {
    var version=1;var annotations:[String:PhotoAnnotation]=[:];var albums:[PhotoAlbum]=[];var people:[PhotoPerson]=[]
}
struct PhotoRetouch:Codable,Equatable {var x:Double;var y:Double;var radius:Double;var redEye=false}
struct PhotoAdjustment:Codable,Equatable {
    var automatic=false;var exposure=0.0;var brilliance=0.0;var highlights=1.0;var shadows=0.0;var brightness=0.0;var contrast=1.0;var blackPoint=0.0;var saturation=1.0;var vibrance=0.0
    var warmth=0.0;var tint=0.0;var sharpness=0.0;var definition=0.0;var noise=0.0;var vignette=0.0;var gamma=1.0
    var filter="원본";var filterAmount=1.0;var rotation=0;var straighten=0.0;var flip=false
    var cropX=0.0;var cropY=0.0;var cropWidth=1.0;var cropHeight=1.0;var aspect="자유형"
    var retouches:[PhotoRetouch]=[];var marks:[PhotoMarkup]=[]
    var trimStart=0.0;var trimEnd=1.0;var speed=1.0;var muted=false;var liveEffect="LIVE";var keyFrame=0.0
    var isDefault:Bool{self==PhotoAdjustment()}
}
struct PhotoMarkup:Codable,Equatable {var kind="텍스트";var text="";var x=0.5;var y=0.5;var width=0.3;var height=0.1;var color="흰색"}
struct PhotoMemory:Identifiable {let id:String;let title:String;let subtitle:String;let items:[GalleryItem]}
struct PhotoLocation:Identifiable {let id:String;let latitude:Double;let longitude:Double;let item:GalleryItem}

final class PhotoLibraryStore {
    let folder:URL
    var url:URL{folder.appendingPathComponent("library.json")}
    init(folder:URL?=nil){self.folder=folder ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("CoolSync/PhotoLibrary");try?FileManager.default.createDirectory(at:self.folder,withIntermediateDirectories:true)}
    func load()->PhotoLibraryDocument{guard let data=try?Data(contentsOf:url),let value=try?JSONDecoder().decode(PhotoLibraryDocument.self,from:data)else{return PhotoLibraryDocument()};return value}
    func save(_ value:PhotoLibraryDocument)throws{try JSONEncoder().encode(value).write(to:url,options:.atomic)}
    func renderedURL(_ name:String)->URL{folder.appendingPathComponent(name)}
}

enum PhotoRendering {
    static let context=CIContext(options:[.cacheIntermediates:false])
    static let filters=["원본","선명하게","선명하게 따뜻한","선명하게 차가운","드라마틱","드라마틱 따뜻한","드라마틱 차가운","모노","실버톤","느와르","세피아"]
    static func apply(_ source:CIImage,_ edit:PhotoAdjustment,geometry:Bool=true)->CIImage{
        var image=source
        if edit.automatic{for filter in source.autoAdjustmentFilters(options:[.enhance:true,.redEye:false]){filter.setValue(image,forKey:kCIInputImageKey);image=filter.outputImage ?? image}}
        func filter(_ name:String,_ parameters:[String:Any]=[:]){image=image.applyingFilter(name,parameters:parameters)}
        filter("CIExposureAdjust",[kCIInputEVKey:edit.exposure])
        filter("CIHighlightShadowAdjust",["inputHighlightAmount":edit.highlights,"inputShadowAmount":edit.shadows])
        filter("CIColorControls",[kCIInputBrightnessKey:edit.brightness,kCIInputContrastKey:edit.contrast,kCIInputSaturationKey:edit.saturation])
        filter("CIVibrance",["inputAmount":edit.vibrance+edit.brilliance*0.35])
        if edit.blackPoint != 0{filter("CIColorMatrix",["inputBiasVector":CIVector(x:-edit.blackPoint,y:-edit.blackPoint,z:-edit.blackPoint,w:0)])}
        filter("CITemperatureAndTint",["inputNeutral":CIVector(x:6500,y:0),"inputTargetNeutral":CIVector(x:6500+edit.warmth*2500,y:edit.tint*100)])
        filter("CIGammaAdjust",["inputPower":edit.gamma])
        if edit.sharpness>0{filter("CISharpenLuminance",[kCIInputSharpnessKey:edit.sharpness])}
        if edit.definition>0{filter("CIUnsharpMask",[kCIInputRadiusKey:2.5,kCIInputIntensityKey:edit.definition])}
        if edit.noise>0{filter("CINoiseReduction",["inputNoiseLevel":edit.noise*0.1,"inputSharpness":0.4])}
        if edit.vignette>0{filter("CIVignette",[kCIInputIntensityKey:edit.vignette*2,kCIInputRadiusKey:1])}
        if edit.filter != "원본"{
            let before=image
            switch edit.filter{
            case "선명하게","선명하게 따뜻한","선명하게 차가운":filter("CIPhotoEffectChrome")
            case "드라마틱","드라마틱 따뜻한","드라마틱 차가운":filter("CIPhotoEffectProcess");filter("CIColorControls",[kCIInputSaturationKey:0.75,kCIInputContrastKey:1.2])
            case "모노":filter("CIPhotoEffectMono")
            case "실버톤":filter("CIPhotoEffectTonal")
            case "느와르":filter("CIPhotoEffectNoir")
            case "세피아":filter("CISepiaTone",[kCIInputIntensityKey:0.85])
            default:break
            }
            if edit.filter.contains("따뜻한"){filter("CITemperatureAndTint",["inputNeutral":CIVector(x:6500,y:0),"inputTargetNeutral":CIVector(x:8000,y:0)])}
            if edit.filter.contains("차가운"){filter("CITemperatureAndTint",["inputNeutral":CIVector(x:6500,y:0),"inputTargetNeutral":CIVector(x:4800,y:0)])}
            image=image.applyingFilter("CIDissolveTransition",parameters:[kCIInputTargetImageKey:before,kCIInputTimeKey:1-edit.filterAmount])
        }
        for spot in edit.retouches{
            let rect=image.extent;let center=CIVector(x:rect.minX+spot.x*rect.width,y:rect.minY+(1-spot.y)*rect.height)
            let radius=max(2,spot.radius*min(rect.width,rect.height))
            let mask=CIFilter(name:"CIRadialGradient",parameters:["inputCenter":center,"inputRadius0":radius*0.65,"inputRadius1":radius,"inputColor0":CIColor.white,"inputColor1":CIColor.clear])!.outputImage!.cropped(to:rect)
            let fixed=spot.redEye ? image.applyingFilter("CIColorMatrix",parameters:["inputRVector":CIVector(x:0.15,y:0.5,z:0.35,w:0)]):image.clampedToExtent().applyingFilter("CIGaussianBlur",parameters:[kCIInputRadiusKey:radius*0.45]).cropped(to:rect)
            image=fixed.applyingFilter("CIBlendWithMask",parameters:[kCIInputBackgroundImageKey:image,kCIInputMaskImageKey:mask])
        }
        if geometry{
            if edit.flip{image=image.transformed(by:CGAffineTransform(scaleX:-1,y:1));image=image.transformed(by:CGAffineTransform(translationX:-image.extent.minX,y:-image.extent.minY))}
            let angle=Double(edit.rotation)*Double.pi/2+edit.straighten*Double.pi/180
            if angle != 0{image=image.transformed(by:CGAffineTransform(rotationAngle:angle));image=image.transformed(by:CGAffineTransform(translationX:-image.extent.minX,y:-image.extent.minY))}
            let rect=image.extent
            let width=max(0.05,min(1,edit.cropWidth)),height=max(0.05,min(1,edit.cropHeight))
            let crop=CGRect(x:rect.minX+min(max(0,edit.cropX),1-width)*rect.width,y:rect.minY+min(max(0,edit.cropY),1-height)*rect.height,width:rect.width*width,height:rect.height*height)
            image=image.cropped(to:crop).transformed(by:CGAffineTransform(translationX:-crop.minX,y:-crop.minY))
        }
        return image
    }
    static func image(_ url:URL,_ edit:PhotoAdjustment,maxDimension:CGFloat?=nil)throws->NSImage{
        guard var source=CIImage(contentsOf:url,options:[.applyOrientationProperty:true])else{throw CocoaError(.fileReadCorruptFile)}
        if let maxDimension{let scale=min(1,maxDimension/max(source.extent.width,source.extent.height));source=source.transformed(by:CGAffineTransform(scaleX:scale,y:scale))}
        let output=apply(source,edit)
        guard let cg=context.createCGImage(output,from:output.extent)else{throw CocoaError(.fileReadCorruptFile)}
        var result=NSImage(cgImage:cg,size:NSSize(width:cg.width,height:cg.height))
        if !edit.marks.isEmpty{result=markup(result,edit.marks)}
        return result
    }
    static func markup(_ original:NSImage,_ marks:[PhotoMarkup])->NSImage{
        let output=NSImage(size:original.size);output.lockFocus();original.draw(at:.zero,from:.zero,operation:.copy,fraction:1)
        for mark in marks{
            let color:NSColor=mark.color=="검정" ? .black:mark.color=="빨강" ? .systemRed:mark.color=="노랑" ? .systemYellow:.white
            let rect=NSRect(x:mark.x*original.size.width,y:(1-mark.y-mark.height)*original.size.height,width:mark.width*original.size.width,height:mark.height*original.size.height)
            color.setStroke();let path:NSBezierPath
            switch mark.kind{
            case "사각형":path=NSBezierPath(rect:rect)
            case "원":path=NSBezierPath(ovalIn:rect)
            case "화살표":path=NSBezierPath();path.move(to:rect.origin);path.line(to:NSPoint(x:rect.maxX,y:rect.maxY));path.move(to:NSPoint(x:rect.maxX-rect.width*0.25,y:rect.maxY));path.line(to:NSPoint(x:rect.maxX,y:rect.maxY));path.line(to:NSPoint(x:rect.maxX,y:rect.maxY-rect.height*0.5))
            default:(mark.text as NSString).draw(in:rect,withAttributes:[.foregroundColor:color,.font:NSFont.systemFont(ofSize:max(12,rect.height*0.7),weight:.semibold)]);continue
            }
            path.lineWidth=max(2,original.size.width/300);path.stroke()
        }
        output.unlockFocus();return output
    }
    static func save(_ image:NSImage,to url:URL,format:String="JPEG",quality:Double=0.95)throws{
        guard let data=image.tiffRepresentation,let bitmap=NSBitmapImageRep(data:data)else{throw CocoaError(.fileWriteUnknown)}
        let type:NSBitmapImageRep.FileType=format=="PNG" ? .png:format=="TIFF" ? .tiff:.jpeg
        guard let output=bitmap.representation(using:type,properties:[.compressionFactor:quality])else{throw CocoaError(.fileWriteUnknown)};try output.write(to:url,options:.atomic)
    }
}

enum PhotoBatches {
    static func paths(_ values:[String])->[[String]]{var result:[[String]]=[];var batch:[String]=[];for value in values{let candidate=batch+[value];let bytes=(try?JSONSerialization.data(withJSONObject:["paths":candidate]).count) ?? Int.max;if !batch.isEmpty && (candidate.count>35 || bytes>12000){result.append(batch);batch=[]};batch.append(value)};if !batch.isEmpty{result.append(batch)};return result}
}
