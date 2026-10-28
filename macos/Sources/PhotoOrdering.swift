import Foundation

enum PhotoOrdering{
    static func filenameDate(_ name:String)->Int64?{
        guard name.range(of:#"^[0-9]{8}_[0-9]{6}(?:\([0-9]+\))?\.[^.]+$"#,options:.regularExpression) != nil else{return nil}
        let stamp=String(name.prefix(15)).replacingOccurrences(of:"_",with:"")
        let formatter=DateFormatter();formatter.locale=Locale(identifier:"en_US_POSIX");formatter.calendar=Calendar(identifier:.gregorian);formatter.timeZone = .current;formatter.dateFormat="yyyyMMddHHmmss";formatter.isLenient=false
        guard let date=formatter.date(from:stamp),formatter.string(from:date)==stamp else{return nil}
        return Int64((date.timeIntervalSince1970*1000).rounded())
    }

    static func identifier(_ left:String,_ right:String,ascending:Bool)->Bool{
        if let a=Int64(left),let b=Int64(right){return ascending ? a<b:a>b}
        return ascending ? left<right:left>right
    }
    static func filename(_ left:String,path leftPath:String,id leftID:String,_ right:String,path rightPath:String,id rightID:String,ascending:Bool)->Bool{
        let result=left.compare(right,options:[.numeric,.caseInsensitive],locale:Locale(identifier:"en_US_POSIX"))
        let comparison:ComparisonResult
        if result != .orderedSame{comparison=result}
        else if left != right{comparison=left < right ? .orderedAscending:.orderedDescending}
        else if leftPath != rightPath{comparison=leftPath < rightPath ? .orderedAscending:.orderedDescending}
        else if leftID != rightID{comparison=leftID < rightID ? .orderedAscending:.orderedDescending}
        else{return false}
        return comparison == (ascending ? .orderedAscending:.orderedDescending)
    }
}
