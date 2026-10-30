import Foundation
import SwiftUI

struct GalleryDaySection:Identifiable {
    let id:String
    let date:Date?
    let title:String
    var items:[GalleryItem]
}
extension GalleryModel {
    func daySections(now:Date=Date(),calendar:Calendar = .current)->[GalleryDaySection]{
        var grouped:[Date:[GalleryItem]]=[:];var unknown:[GalleryItem]=[]
        for item in visible{if let date=captureDate(item){grouped[calendar.startOfDay(for:date),default:[]].append(item)}else{unknown.append(item)}}
        let formatter=DateFormatter();formatter.locale=Locale(identifier:"ko_KR");formatter.calendar=calendar;formatter.timeZone=calendar.timeZone
        let today=calendar.startOfDay(for:now),yesterday=calendar.date(byAdding:.day,value:-1,to:today)
        var result=grouped.keys.sorted(by:>).map{day->GalleryDaySection in
            let title:String
            if day==today{title="오늘"}else if day==yesterday{title="어제"}else{formatter.dateFormat=calendar.component(.year,from:day)==calendar.component(.year,from:now) ? "M월 d일":"yyyy년 M월 d일";title=formatter.string(from:day)}
            let values=grouped[day,default:[]].sorted{left,right in let a=captureDate(left)!,b=captureDate(right)!;if a != b{return a>b};return left.orderingID>right.orderingID}
            return GalleryDaySection(id:String(day.timeIntervalSince1970),date:day,title:title,items:values)
        }
        if !unknown.isEmpty{unknown.sort{$0.orderingID>$1.orderingID};result.append(GalleryDaySection(id:"unknown",date:nil,title:"촬영일 없음",items:unknown))}
        return result
    }
}
struct GalleryDailyGrid<Cell:View>:View {
    @ObservedObject var model:GalleryModel
    @ViewBuilder var cell:(GalleryItem,Double)->Cell
    var body:some View{GeometryReader{geometry in
        let width=max(1,Double(geometry.size.width)-44),side=min(model.tile,width),count=max(1,Int((width+1)/(side+1)))
        ScrollView{
            LazyVStack(alignment:.leading,spacing:30){
                ForEach(model.daySections()){section in VStack(alignment:.leading,spacing:14){
                    Text(section.title).font(.system(size:22,weight:.bold)).foregroundStyle(.white).frame(maxWidth:.infinity,alignment:.leading)
                    LazyVGrid(columns:Array(repeating:GridItem(.fixed(side),spacing:1,alignment:.leading),count:count),alignment:.leading,spacing:1){ForEach(section.items){item in cell(item,side)}}.frame(maxWidth:.infinity,alignment:.leading)
                }}
                if model.visible.isEmpty{Text(model.items.isEmpty ? "사진과 동영상이 없습니다":"선택한 조건과 일치하는 사진이 없습니다").foregroundStyle(.secondary).frame(maxWidth:.infinity).padding(40)}
            }.padding(.horizontal,22).padding(.top,24).padding(.bottom,30)
        }.background(Color.black)
    }.background(Color.black)}
}
