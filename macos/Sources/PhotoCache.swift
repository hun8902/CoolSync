import Foundation
import CryptoKit

extension GalleryModel {
    func originalCacheURL(_ item:GalleryItem)->URL {
        let key=SHA256.hash(data:Data((store.folder.path+"|"+item.cacheVersion).utf8)).map{String(format:"%02x",$0)}.joined()
        let suffix=(item.name as NSString).pathExtension
        return cache.appendingPathComponent(key+(suffix.isEmpty ? "":"."+suffix))
    }
    func validOriginalCache(_ url:URL,_ item:GalleryItem)->Bool {
        guard let values=try?url.resourceValues(forKeys:[.isRegularFileKey,.fileSizeKey]),values.isRegularFile==true,let bytes=values.fileSize else{return false}
        return item.size>0 ? Int64(bytes)==item.size:bytes>0
    }
}
