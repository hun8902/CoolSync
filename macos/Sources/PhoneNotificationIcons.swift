import Foundation
import UserNotifications
import ImageIO

/// Cache only small app icons, never notification contents.
final class PhoneNotificationIcons {
    static let shared=PhoneNotificationIcons()
    private let icons=NSCache<NSString,NSData>()
    init(){icons.countLimit=128;icons.totalCostLimit=512*1024}
    func cache(package:String,encodedIcon:String){
        guard !encodedIcon.isEmpty,let data=Data(base64Encoded:encodedIcon),data.count<=4096,
              let source=CGImageSourceCreateWithData(data as CFData,nil),
              let properties=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
              let width=properties[kCGImagePropertyPixelWidth] as? Int,let height=properties[kCGImagePropertyPixelHeight] as? Int,
              width>0,height>0,width<=128,height<=128 else{return}
        icons.setObject(data as NSData,forKey:package as NSString,cost:data.count)
    }
    func decorate(_ content:UNMutableNotificationContent,package:String)->()->Void {
        guard let data=icons.object(forKey:package as NSString) else {return {}}
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent("CoolSyncNotification-"+UUID().uuidString,isDirectory:true)
        do {
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            let file=folder.appendingPathComponent("app-icon.png")
            try (data as Data).write(to:file,options:.atomic)
            let attachment=try UNNotificationAttachment(identifier:"sourceAppIcon",url:file,options:[UNNotificationAttachmentOptionsTypeHintKey:"public.png",UNNotificationAttachmentOptionsThumbnailHiddenKey:false])
            content.attachments=[attachment]
        } catch {try? FileManager.default.removeItem(at:folder)}
        return {try? FileManager.default.removeItem(at:folder)}
    }
}
