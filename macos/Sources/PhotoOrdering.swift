import Foundation

enum PhotoOrdering{
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
