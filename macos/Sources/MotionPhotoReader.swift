import Foundation
import ImageIO

/// Reads embedded movies without modifying or re-encoding the still image.
/// Supports Samsung SEF/mpv2, ISO-BMFF mpvd and Google XMP motion-photo containers.
enum MotionPhotoReader {
    private final class Reader {
        let file:FileHandle
        let size:Int64
        init(_ url:URL)throws{file=try FileHandle(forReadingFrom:url);size=Int64(try file.seekToEnd())}
        deinit{try?file.close()}
        func read(_ position:Int64,_ count:Int)->Data?{
            guard position>=0,count>=0,count<=2*1024*1024,position<=size,Int64(count)<=size-position else{return nil}
            do{try file.seek(toOffset:UInt64(position));let bytes=try file.read(upToCount:count);return bytes?.count==count ? bytes:nil}catch{return nil}
        }
        func box(_ position:Int64,_ limit:Int64)->(String,Int64,Int64)?{
            guard limit<=size,position<=limit-8,let h=read(position,8)else{return nil}
            let type=String(decoding:h[4..<8],as:UTF8.self);var length=Int64(h.integer(0,big:true));var header:Int64=8
            if length==1{guard let extended=read(position+8,8)else{return nil};let n=extended.reduce(UInt64(0)){($0<<8)|UInt64($1)};guard n<=UInt64(Int64.max)else{return nil};length=Int64(n);header=16}
            if length==0{length=limit-position}
            guard length>=header,length<=limit-position else{return nil};return(type,length,header)
        }
        func movie(_ start:Int64,_ limit:Int64)->Range<Int64>?{
            guard start>=0,limit<=size,start<limit,let first=box(start,limit),first.0=="ftyp",first.1>=16,first.1<=4096 else{return nil}
            let types:Set<String>=["ftyp","moov","mdat","free","skip","wide","uuid","meta","mfra","styp","sidx","moof","emsg","prft","pdin"]
            var position=start;var metadata=false;var media=false
            for _ in 0..<8192{
                guard let b=box(position,limit),types.contains(b.0)else{break}
                if b.0=="moov"{metadata=true};if b.0=="mdat"{media=true};position+=b.1
                if position==limit{break}
            }
            return metadata && media && position>start ? start..<position:nil
        }
        func samsung()->Range<Int64>?{
            let count=Int(min(size,Int64(128*1024)));let base=size-Int64(count)
            guard let tail=read(base,count)else{return nil}
            var search=0..<tail.count
            while let marker=tail.range(of:Data("SEFT".utf8),options:.backwards,in:search){
                let end=base+Int64(marker.upperBound)
                if marker.lowerBound>=4{
                    let length=Int64(tail.integer(marker.lowerBound-4,big:false));let directory=end-8-length
                    if length>=12,length<=65536,directory>=0,let index=read(directory,Int(length)),index.prefix(4)==Data("SEFH".utf8){
                        let entries=Int(index.integer(8,big:false))
                        if entries<=(index.count-12)/12{
                            for i in 0..<entries{
                                let p=12+i*12;let back=Int64(index.integer(p+4,big:false));let bytes=Int64(index.integer(p+8,big:false));let block=directory-back
                                guard back<=directory,bytes>=8,bytes<=back,let header=read(block,8)else{continue}
                                let nameLength=Int(header.integer(4,big:false));guard nameLength>0,nameLength<=128,Int64(nameLength)<=bytes-8,let name=read(block+8,nameLength),name==Data("MotionPhoto_Data".utf8)else{continue}
                                let payload=block+8+Int64(nameLength);let payloadSize=bytes-8-Int64(nameLength)
                                if payloadSize==12,let pointer=read(payload,12),pointer.prefix(4)==Data("mpv2".utf8){
                                    let offset=Int64(pointer.integer(4,big:true)),size=Int64(pointer.integer(8,big:true))
                                    if size>0,offset<=self.size-size,let range=movie(offset,offset+size){return range}
                                }else if let range=movie(payload,payload+payloadSize){return range}
                            }
                        }
                    }
                }
                guard marker.lowerBound>0 else{break};search=0..<marker.lowerBound
            }
            return nil
        }
        func isoContainer()->Range<Int64>?{
            guard let first=box(0,size),first.0=="ftyp"else{return nil}
            var position:Int64=0
            for _ in 0..<8192{
                guard let b=box(position,size)else{return nil}
                if b.0=="mpvd",let range=movie(position+b.2,position+b.1){return range}
                position+=b.1;if position==size{break}
            }
            return nil
        }
    }
    static func extract(from source:URL,to destination:URL)throws->URL?{
        try Task.checkCancellation()
        if let size=(try?destination.resourceValues(forKeys:[.fileSizeKey]).fileSize),size>0{return destination}
        let r=try Reader(source);guard r.size>16 else{return nil}
        let xmp=MotionXMP()
        if let image=CGImageSourceCreateWithURL(source as CFURL,nil),let metadata=CGImageSourceCopyMetadataAtIndex(image,0,nil),let data=CGImageMetadataCreateXMPData(metadata,nil){xmp.parse(data as Data)}
        if xmp.enabled==false{return nil}
        var range=r.samsung() ?? r.isoContainer()
        if range==nil,let length=xmp.videoLength,length>0,length<r.size{range=r.movie(r.size-length,r.size)}
        if range==nil,let offset=xmp.legacyOffset,offset>0,offset<r.size{range=r.movie(r.size-offset,r.size)}
        guard let movie=range,movie.count>0,movie.count<=512*1024*1024 else{return nil}
        let temporary=destination.deletingLastPathComponent().appendingPathComponent(".motion-"+UUID().uuidString+".partial")
        guard FileManager.default.createFile(atPath:temporary.path,contents:nil,attributes:[.posixPermissions:0o600])else{throw CocoaError(.fileWriteUnknown)}
        do{
            let output=try FileHandle(forWritingTo:temporary);defer{try?output.close()}
            var position=movie.lowerBound
            while position<movie.upperBound{try Task.checkCancellation();let count=Int(min(Int64(1024*1024),movie.upperBound-position));guard let data=r.read(position,count)else{throw CocoaError(.fileReadCorruptFile)};try output.write(contentsOf:data);position+=Int64(count)}
            try output.synchronize();try FileManager.default.moveItem(at:temporary,to:destination);return destination
        }catch{try?FileManager.default.removeItem(at:temporary);throw error}
    }
}
private extension Data {
    func integer(_ offset:Int,big:Bool)->UInt32{
        guard offset>=0,offset<=count-4 else{return 0}
        let bytes=Array(self[offset..<offset+4]);let ordered=big ? bytes:Array(bytes.reversed())
        return ordered.reduce(UInt32(0)){($0<<8)|UInt32($1)}
    }
}
private final class MotionXMP:NSObject,XMLParserDelegate {
    var enabled:Bool?
    var legacyOffset:Int64?
    var videoLength:Int64?
    private var current:[String:String]?
    private var leaf=""
    private var text=""
    func parse(_ data:Data){let parser=XMLParser(data:data);parser.shouldProcessNamespaces=true;parser.shouldResolveExternalEntities=false;parser.delegate=self;_ = parser.parse()}
    private func value(_ key:String,_ value:String){if key=="MotionPhoto"{enabled=value=="1"};if key=="MicroVideoOffset"{legacyOffset=Int64(value)}}
    func parser(_ parser:XMLParser,didStartElement elementName:String,namespaceURI:String?,qualifiedName qName:String?,attributes:[String:String]){
        leaf=elementName.components(separatedBy:":").last ?? elementName;text=""
        let fields=Dictionary(attributes.map{(($0.key.components(separatedBy:":").last ?? $0.key),$0.value)},uniquingKeysWith:{_,last in last})
        for(key,v)in fields{value(key,v)}
        if leaf=="Item"{current=fields}
    }
    func parser(_ parser:XMLParser,foundCharacters string:String){if text.utf8.count<4096{text+=string}}
    func parser(_ parser:XMLParser,didEndElement elementName:String,namespaceURI:String?,qualifiedName qName:String?){
        let name=elementName.components(separatedBy:":").last ?? elementName
        let string=text.trimmingCharacters(in:.whitespacesAndNewlines);value(name,string)
        if name=="Item"{if current?["Semantic"]=="MotionPhoto",let length=current?["Length"].flatMap(Int64.init),length>0{videoLength=length};current=nil}
        else if current != nil,["Mime","Semantic","Length"].contains(name),!string.isEmpty{current?[name]=string}
        text=""
    }
}
