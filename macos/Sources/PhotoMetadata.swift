import Foundation
import ImageIO

enum PhotoMetadata{
    static func image(_ url:URL,location:Bool)throws->[String:String]{
        guard let source=CGImageSourceCreateWithURL(url as CFURL,[kCGImageSourceShouldCache:false]as CFDictionary),let properties=CGImageSourceCopyPropertiesAtIndex(source,0,nil)as?[String:Any]else{throw CocoaError(.fileReadCorruptFile)}
        let exif=properties[kCGImagePropertyExifDictionary as String]as?[String:Any] ?? [:],tiff=properties[kCGImagePropertyTIFFDictionary as String]as?[String:Any] ?? [:]
        var values:[String:String]=["infoSchema":"3"]
        for(target,key)in [("captured","DateTimeOriginal"),("lens","LensModel"),("iso","ISOSpeedRatings"),("exposure","ExposureTime"),("aperture","FNumber"),("focalLength","FocalLength")]{if let value=exif[key]{values[target]=(value as? [Any])?.map{String(describing:$0)}.joined(separator:", ") ?? String(describing:value)}}
        if let text=values["captured"]{
            let formatter=DateFormatter();formatter.locale=Locale(identifier:"en_US_POSIX");formatter.isLenient=false;formatter.dateFormat="yyyy:MM:dd HH:mm:ss"
            if let offset=exif["OffsetTimeOriginal"]as?String{formatter.timeZone=TimeZone(identifier:"GMT"+offset)}
            if let date=formatter.date(from:text),date.timeIntervalSince1970>0{values["captureTime"]=String(Int64(date.timeIntervalSince1970*1000));values["captureSource"]="exif"}
        }
        for(target,key)in [("make","Make"),("camera","Model")]{if let value=tiff[key]{values[target]=String(describing:value)}}
        if location,let gps=properties[kCGImagePropertyGPSDictionary as String]as?[String:Any],let lat=gps["Latitude"]as?Double,let lon=gps["Longitude"]as?Double{values["latitude"]=String(gps["LatitudeRef"]as?String=="S" ? -lat:lat);values["longitude"]=String(gps["LongitudeRef"]as?String=="W" ? -lon:lon)}
        return values
    }
}
