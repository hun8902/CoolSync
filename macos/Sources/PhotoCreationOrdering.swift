import Foundation

/// Samsung Gallery AbsSecFilesTable.addOrderByDate / getAlbumOrderByQuery:
/// ORDER BY datetime DESC, _id DESC (both ASC for oldest first).
/// The supplied timeline value is used unchanged; its source is not a filter.
enum PhotoCreationOrdering {
    static func precedes(date leftDate:Int64,id leftID:Int64,
                         date rightDate:Int64,id rightID:Int64,ascending:Bool)->Bool {
        if leftDate != rightDate{return ascending ? leftDate<rightDate:leftDate>rightDate}
        return ascending ? leftID<rightID:leftID>rightID
    }
}
