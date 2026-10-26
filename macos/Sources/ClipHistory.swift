import AppKit
import Combine
import CryptoKit

struct ClipEntry:Codable,Identifiable {
    var id=UUID().uuidString
    var text:String?=nil
    var image:String?=nil
    var source:String
    var time=Date()
    var favorite=false
}
final class ClipHistory:ObservableObject {
    static let shared=ClipHistory()
    @Published private(set) var entries:[ClipEntry]=[]
    private var overrideEnabled:Bool?
    let folder:URL
    var enabled:Bool { get{overrideEnabled ?? (UserDefaults.standard.object(forKey:"historyEnabled") as? Bool ?? true)} set{if overrideEnabled != nil{overrideEnabled=newValue;objectWillChange.send();return};UserDefaults.standard.set(newValue,forKey:"historyEnabled");objectWillChange.send()} }
    init(folder:URL?=nil,recording:Bool?=nil){overrideEnabled=recording;self.folder=folder ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("CoolSync/Clipboard");try? FileManager.default.createDirectory(at:self.folder,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700]);if let data=try? Data(contentsOf:self.folder.appendingPathComponent("history.json")){entries=(try? JSONDecoder().decode([ClipEntry].self,from:data)) ?? []}}
    private func save(){if let data=try? JSONEncoder().encode(entries){let u=folder.appendingPathComponent("history.json");try? data.write(to:u,options:.atomic);try? FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:u.path)}}
    func add(text:String,source:String){guard enabled,!text.isEmpty,text.utf8.count<=16384 else{return};var e=ClipEntry(text:text,source:source);if let i=entries.firstIndex(where:{$0.text==text}){e.favorite=entries[i].favorite;entries.remove(at:i)};insert(e)}
    func add(image:URL,source:String){guard enabled else{return};var e=ClipEntry(source:source);e.image=e.id+".png";guard let data=try? Data(contentsOf:image),data.count<=20*1024*1024 else{return};let u=folder.appendingPathComponent(e.image!);do{try data.write(to:u);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:u.path);insert(e);if !entries.contains(where:{$0.id==e.id}){try? FileManager.default.removeItem(at:u)}}catch{}}
    private func insert(_ e:ClipEntry){
        func bytes()->Int64{entries.compactMap{$0.image}.reduce(0){$0+((try? folder.appendingPathComponent($1).resourceValues(forKeys:[.fileSizeKey]).fileSize).map{Int64($0)} ?? 0)}}
        let extra=e.image.flatMap{try? folder.appendingPathComponent($0).resourceValues(forKeys:[.fileSizeKey]).fileSize}.map{Int64($0)} ?? 0
        while bytes()+extra>100*1024*1024{guard let item=entries.last(where:{!$0.favorite && $0.image != nil})else{return};remove(item.id)}
        while entries.count>=200{guard let i=entries.lastIndex(where:{!$0.favorite})else{return};remove(entries[i].id)};entries.insert(e,at:0);save()}
    func favorite(_ id:String){if let i=entries.firstIndex(where:{$0.id==id}){entries[i].favorite.toggle();save()}}
    func remove(_ id:String){if let e=entries.first(where:{$0.id==id}),let image=e.image{try? FileManager.default.removeItem(at:folder.appendingPathComponent(image))};entries.removeAll{$0.id==id};save()}
    func clear(){for e in Array(entries){remove(e.id)}}
    func copy(_ e:ClipEntry){let p=NSPasteboard.general;p.clearContents();if let text=e.text{p.setString(text,forType:.string)}else if let name=e.image,let data=try? Data(contentsOf:folder.appendingPathComponent(name)){p.setData(data,forType:.png)}}
    static func png(_ image:NSImage)throws->Data{guard let tiff=image.tiffRepresentation,let bitmap=NSBitmapImageRep(data:tiff),bitmap.pixelsWide>0,bitmap.pixelsWide*bitmap.pixelsHigh<=16000000,let bytes=bitmap.representation(using:.png,properties:[:]),bytes.count<=20*1024*1024 else{throw CocoaError(.fileReadTooLarge)};return bytes}
}
