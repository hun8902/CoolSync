import Foundation

enum PhotoCaptureMetadata{
    static func verifiedDate(_ values:[String:String])->(time:Int64,source:String)?{
        guard let raw=values["captureTime"],let time=Int64(raw),time>0,let source=values["captureSource"],["exif","video","media-store"].contains(source)else{return nil}
        return(time,source=="media-store" ? "captured":source)
    }
    static func updatedRecord(_ item:[String:Any],metadata:[String:String])->[String:Any]?{
        guard let date=verifiedDate(metadata)else{return nil}
        var value=item;value["date"]=date.time;value["dateSource"]=date.source;return value
    }

}
