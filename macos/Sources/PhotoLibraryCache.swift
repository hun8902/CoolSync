import Foundation
import CryptoKit

struct PhotoCatalog:Codable {
    var revision=""
    var dateSchema:Int?
    var items:[PhotoItem]=[]
    var albums:[PhotoAlbum]=[]
    var synced:Date?
}
struct PendingPhotoDelete:Codable,Identifiable {
    var id=UUID().uuidString
    var item:PhotoItem
    var phoneDeleted=false
    var errorCode:String?
    var error:String?
}

/// Private per-pair cache. Exported Finder copies are never tracked or removed.
final class PhotoLibraryCache {
    let folder:URL
    private(set) var catalog=PhotoCatalog()
    private(set) var pending:[PendingPhotoDelete]=[]
    private(set) var refreshPaths=Set<String>()
    private(set) var metadataPaths=Set<String>()
    private let fm=FileManager.default
    var protected=Set<URL>()
    private var thumbnailWrites=0
    var budget:Int64{Int64(UserDefaults.standard.integer(forKey:"photoCacheGB").clamped(to:1...10,default:2))*1024*1024*1024}
    init(identity:Data){
        let namespace=SHA256.hash(data:identity).map{String(format:"%02x",$0)}.joined()
        folder=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("CoolSync/Photos/"+namespace,isDirectory:true)
        for name in ["","thumbnails","originals","details","motion"]{try? fm.createDirectory(at:folder.appendingPathComponent(name),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])}
        var url=folder;var values=URLResourceValues();values.isExcludedFromBackup=true;try? url.setResourceValues(values)
        if let data=try?Data(contentsOf:folder.appendingPathComponent("catalog.json")){catalog=(try?JSONDecoder().decode(PhotoCatalog.self,from:data)) ?? PhotoCatalog()}
        if let data=try?Data(contentsOf:folder.appendingPathComponent("pending-deletes.json")){pending=(try?JSONDecoder().decode([PendingPhotoDelete].self,from:data)) ?? []}
        if let data=try?Data(contentsOf:folder.appendingPathComponent("refresh-originals.json")){refreshPaths=(try?JSONDecoder().decode(Set<String>.self,from:data)) ?? []}
        if let data=try?Data(contentsOf:folder.appendingPathComponent("metadata-refresh.json")){metadataPaths=(try?JSONDecoder().decode(Set<String>.self,from:data)) ?? []}
    }
    private func save<T:Encodable>(_ value:T,_ name:String)throws{
        let target=folder.appendingPathComponent(name);try JSONEncoder().encode(value).write(to:target,options:.atomic);try fm.setAttributes([.posixPermissions:0o600],ofItemAtPath:target.path)
    }
    func commit(_ value:PhotoCatalog)throws{try save(value,"catalog.json");catalog=value}
    func setMetadataPaths(_ paths:Set<String>,checkpoint:Bool=true)throws{if checkpoint{try save(paths,"metadata-refresh.json")};metadataPaths=paths}
    func hasAnyCache(_ item:PhotoItem)->Bool{[originalURL(item),thumbnailURL(item),folder.appendingPathComponent("details/"+digest(item)+".json")].contains{fm.fileExists(atPath:$0.path)}}
    func setRefreshPaths(_ paths:Set<String>)throws{try save(paths,"refresh-originals.json");refreshPaths=paths}
    func setPending(_ values:[PendingPhotoDelete])throws{try save(values,"pending-deletes.json");pending=values}
    private func digest(_ item:PhotoItem)->String{SHA256.hash(data:Data("\(item.id)|\(item.path)|\(item.modified)|\(item.size)|\(item.generation ?? 0)".utf8)).map{String(format:"%02x",$0)}.joined()}
    func thumbnailURL(_ item:PhotoItem)->URL{folder.appendingPathComponent("thumbnails/"+digest(item)+".jpg")}
    func originalURL(_ item:PhotoItem)->URL{
        let ext=URL(fileURLWithPath:item.name).pathExtension.filter{$0.isLetter||$0.isNumber}.prefix(12)
        return folder.appendingPathComponent("originals/"+digest(item)+(ext.isEmpty ? "":"."+ext))
    }
    func motionURL(_ item:PhotoItem)->URL{folder.appendingPathComponent("motion/"+digest(item)+".mp4")}
    func original(_ item:PhotoItem,touch shouldTouch:Bool=true)->URL?{let url=originalURL(item);guard let size=(try?url.resourceValues(forKeys:[.fileSizeKey]).fileSize),Int64(size)==item.size else{return nil};if shouldTouch{touch(url)};return url}
    func thumbnail(_ item:PhotoItem)->Data?{let url=thumbnailURL(item);guard let data=try?Data(contentsOf:url),data.count<=128000 else{return nil};touch(url);return data}
    func putThumbnail(_ data:Data,_ item:PhotoItem){guard data.count<=128000 else{return};let url=thumbnailURL(item);try?data.write(to:url,options:.atomic);try?fm.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path);thumbnailWrites+=1;if thumbnailWrites%40==0{prune()}}
    func details(_ item:PhotoItem)->[String:String]?{
        guard let data=try?Data(contentsOf:folder.appendingPathComponent("details/"+digest(item)+".json")),let values=try?JSONDecoder().decode([String:String].self,from:data),["captured","camera","lens","make"].contains(where:{!(values[$0] ?? "").isEmpty})else{return nil};return values
    }
    func putDetails(_ values:[String:String],_ item:PhotoItem){
        let name="details/"+digest(item)+".json"
        if ["captured","camera","lens","make"].contains(where:{!(values[$0] ?? "").isEmpty}){try?save(values,name)}else{try?fm.removeItem(at:folder.appendingPathComponent(name))}
    }
    func touch(_ url:URL){try?fm.setAttributes([.modificationDate:Date()],ofItemAtPath:url.path)}
    private var files:[URL]{["thumbnails","originals","details","motion"].flatMap{(try?fm.contentsOfDirectory(at:folder.appendingPathComponent($0),includingPropertiesForKeys:[.fileSizeKey,.contentModificationDateKey])) ?? []}.filter{!$0.lastPathComponent.hasPrefix(".")}}
    var bytes:Int64{files.reduce(0){$0+Int64((try?$1.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0)}}
    func prune(excluding:Set<URL>=[]){
        let rows=files.compactMap{url->(URL,Int64,Date)? in guard let v=try?url.resourceValues(forKeys:[.fileSizeKey,.contentModificationDateKey])else{return nil};return(url,Int64(v.fileSize ?? 0),v.contentModificationDate ?? .distantPast)}
        var total=rows.reduce(Int64(0)){$0+$1.1}
        for(url,size,_)in rows.sorted(by:{a,b in let am=a.0.deletingLastPathComponent().lastPathComponent=="motion",bm=b.0.deletingLastPathComponent().lastPathComponent=="motion";return am != bm ? am:a.2<b.2}) where total>budget && !excluding.union(protected).contains(url){if (try?fm.removeItem(at:url)) != nil{total-=size}}
    }
    func rekey(_ old:PhotoItem,_ new:PhotoItem)throws{
        guard old.path==new.path,old.size==new.size,old.cacheIdentity != new.cacheIdentity else{return}
        let pairs=[(originalURL(old),originalURL(new)),(thumbnailURL(old),thumbnailURL(new)),(motionURL(old),motionURL(new)),(folder.appendingPathComponent("details/"+digest(old)+".json"),folder.appendingPathComponent("details/"+digest(new)+".json"))]
        for(source,target)in pairs where fm.fileExists(atPath:source.path) && !fm.fileExists(atPath:target.path){try fm.moveItem(at:source,to:target)}
    }
    func discard(_ item:PhotoItem,trashOriginal:Bool)throws{
        let original=originalURL(item)
        if fm.fileExists(atPath:original.path){if trashOriginal{try fm.trashItem(at:original,resultingItemURL:nil)}else{try fm.removeItem(at:original)}}
        let motion=motionURL(item);if fm.fileExists(atPath:motion.path){try fm.removeItem(at:motion)}
        let details=folder.appendingPathComponent("details/"+digest(item)+".json");if fm.fileExists(atPath:details.path){try fm.removeItem(at:details)}
        let thumb=thumbnailURL(item);if fm.fileExists(atPath:thumb.path){try fm.removeItem(at:thumb)}
    }
    func clearFiles()throws{for url in files{try fm.removeItem(at:url)}}
}
private extension Int {
    func clamped(to range:ClosedRange<Int>,default fallback:Int)->Int{self==0 ? fallback:Swift.min(range.upperBound,Swift.max(range.lowerBound,self))}
}
