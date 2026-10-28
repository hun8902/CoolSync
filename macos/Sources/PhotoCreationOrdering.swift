import Foundation

enum PhotoCreationOrdering {
    static func time(_ date:Int64,source:String?)->Int64 {
        guard date>0,let source,["captured","exif","video"].contains(source) else{return 0}
        return date
    }
}
