import Foundation
import SQLite3

@main struct Check {
    struct Row:Equatable{let id:Int64;let date:Int64}
    static func main(){
        var db:OpaquePointer?
        precondition(sqlite3_open(":memory:",&db)==SQLITE_OK)
        defer{sqlite3_close(db)}
        precondition(sqlite3_exec(db,"CREATE TABLE files (_id INTEGER PRIMARY KEY, datetime INTEGER)",nil,nil,nil)==SQLITE_OK)
        // Repeated dates, numeric IDs, zero and pre-1970 values exercise the SQL contract.
        let dates:[Int64]=[-1,0,1163494500000,1782160858534]
        let rows=(1...200).map{Row(id:Int64($0),date:dates[$0%dates.count])}
        for row in rows{precondition(sqlite3_exec(db,"INSERT INTO files VALUES (\(row.id),\(row.date))",nil,nil,nil)==SQLITE_OK)}
        for ascending in [false,true]{
            let direction=ascending ? "ASC":"DESC"
            var statement:OpaquePointer?
            precondition(sqlite3_prepare_v2(db,"SELECT _id FROM files ORDER BY datetime \(direction), _id \(direction)",-1,&statement,nil)==SQLITE_OK)
            var expected:[Int64]=[]
            while sqlite3_step(statement)==SQLITE_ROW{expected.append(sqlite3_column_int64(statement,0))}
            sqlite3_finalize(statement)
            for _ in 0..<30{
                let actual=rows.shuffled().sorted{PhotoCreationOrdering.precedes(date:$0.date,id:$0.id,date:$1.date,id:$1.id,ascending:ascending)}.map(\.id)
                precondition(actual==expected,"Must match Samsung Gallery SQL, including ties")
            }
            for row in rows{precondition(!PhotoCreationOrdering.precedes(date:row.date,id:row.id,date:row.date,id:row.id,ascending:ascending))}
        }
        print("PASS: both directions exactly match Samsung's date/ID SQL on 60 shuffled snapshots")
    }
}
