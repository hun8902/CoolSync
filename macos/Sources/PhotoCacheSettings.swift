import AppKit
import SwiftUI

struct PhotoCacheSettings:View {
    @ObservedObject var photos:PhotosModel
    @AppStorage("photoCacheGB") private var limit=2
    var body:some View {
        Section("사진 보관함 · Mac 캐시") {
            LabeledContent("저장 용량",value:photos.cacheSummary)
            Picker("최대 보관 용량",selection:$limit){Text("1 GB").tag(1);Text("2 GB").tag(2);Text("5 GB").tag(5);Text("10 GB").tag(10)}
            Text("목록·썸네일을 저장하고 열어본 원본을 보관합니다. 오래된 캐시는 용량 한도에 따라 정리하며, 휴대폰에는 변경된 항목만 요청합니다.").foregroundStyle(.secondary)
            HStack{Button("Mac 캐시만 비우기…"){photos.clearCache()};Button("삭제 대기 \(photos.pendingDeletes.count)개"){photos.showPendingDeletes=true}}
            if let date=photos.disk?.catalog.synced{LabeledContent("마지막 동기화",value:date.formatted(date:.abbreviated,time:.shortened))}
        }.onAppear{photos.refreshCacheUsage()}.onChange(of:limit){_ in photos.disk?.prune(excluding:Set(photos.preview.flatMap{item in photos.disk.map{[$0.originalURL(item)]}} ?? []));photos.refreshCacheUsage()}
        .sheet(isPresented:$photos.showPendingDeletes){PendingPhotoDeletesPane(photos:photos)}
    }
}
struct PendingPhotoDeletesPane:View {
    @ObservedObject var photos:PhotosModel
    @Environment(\.dismiss) private var dismiss
    var body:some View {
        VStack(alignment:.leading,spacing:0){
            HStack{VStack(alignment:.leading,spacing:5){Text("삭제 대기").font(.title2.weight(.semibold));Text("휴대폰 처리 확인 후 Mac 캐시를 휴지통으로 옮깁니다.").foregroundStyle(.secondary)};Spacer();Button("닫기"){dismiss()}.keyboardShortcut(.cancelAction)}.padding(24)
            Divider()
            if photos.pendingDeletes.isEmpty{VStack(spacing:12){Image(systemName:"checkmark.circle").font(.largeTitle).foregroundStyle(.secondary);Text("대기 중인 삭제가 없습니다")}.frame(maxWidth:.infinity,maxHeight:.infinity)}else{
                List(photos.pendingDeletes){value in HStack(spacing:12){Image(systemName:value.item.video ? "video":"photo").foregroundStyle(Color.accentColor);VStack(alignment:.leading,spacing:5){Text(value.item.name).font(.headline);Text(value.error ?? (value.phoneDeleted ? "휴대폰 처리 완료 · Mac 정리 대기":"휴대폰 연결 후 삭제 확인")).font(.caption).foregroundStyle(value.error==nil ? Color.secondary:Color.orange).fixedSize(horizontal:false,vertical:true)};Spacer();Button("대기 취소"){photos.cancelDelete(value.id)}.disabled(!photos.canCancelDelete(value))}.padding(.vertical,6)}.listStyle(.inset)
            }
            Divider();HStack{Text("\(photos.pendingDeletes.count)개 대기").foregroundStyle(.secondary);Spacer();Button("다시 시도"){photos.retryDeletes()}.disabled(photos.pendingDeletes.isEmpty)}.padding(20)
        }.frame(width:620,height:440).background(Color(nsColor:.windowBackgroundColor))
    }
}
