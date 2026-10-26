import SwiftUI
struct TrashPane:View{
    @ObservedObject var model:ExplorerModel
    var body:some View{
        VStack(spacing:0){
            HStack{
                Menu("선택"){Button("검색 결과 모두 선택"){model.trashSelection=Set(model.visibleTrash.map{$0.id})};Button("선택 해제"){model.trashSelection=[]}}
                Button("복원"){model.runTrash(model.trash.filter{model.trashSelection.contains($0.id)},action:"restore")}.disabled(model.trashSelection.isEmpty)
                Button("영구 삭제…",role:.destructive){model.runTrash(model.trash.filter{model.trashSelection.contains($0.id)},action:"deletePermanent")}.disabled(model.trashSelection.isEmpty)
                Spacer();Button("휴지통 비우기…",role:.destructive){model.runTrash(model.trash,action:"deletePermanent")}.disabled(model.trash.isEmpty)
                Button{model.reload()}label:{Image(systemName:"arrow.clockwise")}
                TextField("휴지통 검색",text:$model.search).textFieldStyle(.roundedBorder).frame(width:160)
            }.disabled(model.busy).padding(12)
            if model.trashWorking{HStack{ProgressView(value:model.trashProgress).frame(width:140);Text(model.status).lineLimit(1);Spacer();Button("중단"){model.stopTrashWork()}}.font(.caption).padding(10)}
            if !model.trashWorking{HStack{Text("\(model.trash.count)개 · \(model.trashSelection.count)개 선택");Spacer();Button("실패·중단 항목 재시도…"){model.retryTrashWork()}}.font(.caption).padding(.horizontal,12)}
            List(selection:$model.trashSelection){ForEach(model.visibleTrash){item in
                HStack(spacing:12){Image(systemName:"doc").foregroundStyle(.secondary);VStack(alignment:.leading,spacing:4){Text(item.name);Text(item.original).font(.caption).foregroundStyle(.secondary)};Spacer();Text(Date(timeIntervalSince1970:Double(item.deleted)/1000),style:.date).font(.caption).foregroundStyle(.secondary)}.padding(.vertical,5).tag(item.id)
            }}.listStyle(.inset).disabled(model.trashWorking)
            if !model.trashFailures.isEmpty{DisclosureGroup("실패 내역 \(model.trashFailures.count)개"){ScrollView{VStack(alignment:.leading){ForEach(Array(model.trashFailures.enumerated()),id:\.offset){Text($0.element).font(.caption)}}.frame(maxWidth:.infinity,alignment:.leading)}.frame(maxHeight:130)}.padding(12)}
        }
    }
}
