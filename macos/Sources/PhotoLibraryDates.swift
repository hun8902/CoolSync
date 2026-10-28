import Foundation
import SQLite3

/// Reads only date records; never changes Photos databases or any media file.
enum PhotoLibraryDates {
    struct Record {let identity:String;let name:String;let size:Int64;let width:Int;let height:Int}
    static func read(_ records:[Record],libraries:[URL]?=nil)->[String:Int64]{
        guard !records.isEmpty else{return [:]}
        let pictures=FileManager.default.urls(for:.picturesDirectory,in:.userDomainMask)[0]
        let roots=libraries ?? ((try?FileManager.default.contentsOfDirectory(at:pictures,includingPropertiesForKeys:nil)) ?? []).filter{$0.pathExtension=="photoslibrary"}
        struct Key:Hashable{let name:String;let size:Int64;let short:Int;let long:Int}
        func key(_ name:String,_ size:Int64,_ width:Int,_ height:Int)->Key{Key(name:name.lowercased(),size:size,short:min(width,height),long:max(width,height))}
        let wanted=Dictionary(grouping:records.filter{$0.size>0 && $0.width>0 && $0.height>0},by:{key($0.name,$0.size,$0.width,$0.height)})
        var found:[String:Set<Int64>]=[:]
        for root in roots{
            var database:OpaquePointer?
            guard sqlite3_open_v2(root.appendingPathComponent("database/Photos.sqlite").path,&database,SQLITE_OPEN_READONLY|SQLITE_OPEN_FULLMUTEX,nil)==SQLITE_OK else{if let database{sqlite3_close(database)};continue}
            defer{sqlite3_close(database)}
            sqlite3_busy_timeout(database,1000)
            // One streaming metadata pass per library, rather than a database scan per photo.
            let sql="SELECT x.ZORIGINALFILENAME,x.ZORIGINALFILESIZE,a.ZWIDTH,a.ZHEIGHT,a.ZDATECREATED FROM ZASSET a JOIN ZADDITIONALASSETATTRIBUTES x ON x.ZASSET=a.Z_PK WHERE a.ZDATECREATED IS NOT NULL"
            var statement:OpaquePointer?
            guard sqlite3_prepare_v2(database,sql,-1,&statement,nil)==SQLITE_OK else{continue}
            defer{sqlite3_finalize(statement)}
            while sqlite3_step(statement)==SQLITE_ROW{
                guard let raw=sqlite3_column_text(statement,0)else{continue}
                let signature=key(String(cString:raw),sqlite3_column_int64(statement,1),Int(sqlite3_column_int(statement,2)),Int(sqlite3_column_int(statement,3)))
                guard let matches=wanted[signature]else{continue}
                let seconds=sqlite3_column_double(statement,4)+978307200
                guard seconds>0,seconds<=Date().timeIntervalSince1970+86400 else{continue}
                for record in matches{found[record.identity,default:[]].insert(Int64((seconds*1000).rounded()))}
            }
        }
        return found.compactMapValues{$0.count==1 ? $0.first:nil}
    }
    static func applyExportDate(_ milliseconds:Int64,to copy:URL)throws{
        guard milliseconds>0 else{return}
        let date=Date(timeIntervalSince1970:Double(milliseconds)/1000)
        try FileManager.default.setAttributes([.creationDate:date],ofItemAtPath:copy.path)
    }
}
