import SwiftUI
import AppKit

struct PhotoLoadingPanel:View {
    @ObservedObject var model:GalleryModel
    var body:some View{VStack(alignment:.leading,spacing:10){
        HStack(alignment:.top,spacing:12){
            if model.sync.busy{ProgressView().controlSize(.small).padding(.top,2)}else{Image(systemName:model.sync.phase == .failed ? "exclamationmark.triangle.fill":model.sync.phase == .disconnected ? "iphone.slash":"checkmark.circle").foregroundStyle(model.sync.phase == .failed ? Color.red:Color.accentColor)}
            VStack(alignment:.leading,spacing:5){
                Text(model.sync.message).font(.callout.weight(.semibold))
                if let issue=model.sync.issue{Text(issue).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)}
                if model.loading{TimelineView(.periodic(from:.now,by:1)){context in Text("경과 \(Int(context.date.timeIntervalSince(model.sync.started ?? context.date)))초 · 목록 \(model.sync.received)개 · 완료한 페이지 \(model.sync.pages)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)}}
                else if model.sync.previewRequested>0{Text("미리보기 \(model.sync.previewFinished)/\(model.sync.previewRequested)개 · 실패 \(model.sync.previewFailed)개").font(.caption.monospacedDigit()).foregroundStyle(.secondary)}
                if let device=model.sync.device{Text(device.interactive ? "휴대폰 화면 켜짐 · 암호화 Wi-Fi 전송":"휴대폰 화면 꺼짐 · 화면을 켜지 않고 암호화 Wi-Fi 전송").font(.caption).foregroundStyle(.secondary)}
                if model.sync.cached,let updated=model.sync.updated{Text("저장된 목록: "+updated.formatted(date:.abbreviated,time:.shortened)).font(.caption).foregroundStyle(.secondary)}
            };Spacer()
            if model.loading{Button("중단"){model.cancelPhotoLoad()}}
            else if model.sync.phase == .failed || model.sync.phase == .canceled || model.sync.phase == .disconnected{if model.sync.nextOffset>0{Button("계속 받기"){model.resumePhotoLoad()}};Button("다시 시도"){model.retryPhotoLoad()}.buttonStyle(.borderedProminent)}
            if model.sync.previewFailed>0{Button("미리보기 재시도"){model.retryFailedPreviews()}}
            Menu{Button("진단 정보 복사"){model.copySyncDiagnostics()};Button("처음부터 새로 받기"){model.retryPhotoLoad()}}label:{Image(systemName:"ellipsis.circle")}.menuStyle(.borderlessButton).frame(width:24)
        }
        if model.loading{if let progress=model.sync.fraction{ProgressView(value:progress).tint(.accentColor)}else{ProgressView().progressViewStyle(.linear)}}
        if let device=model.sync.device,device.powerSave && !device.batteryExempt{HStack(spacing:8){Image(systemName:"battery.50percent");Text("휴대폰이 절전 모드입니다. Android가 통신을 일시 중지하면 진행 상황과 재시도를 표시합니다.").font(.caption)}.foregroundStyle(.secondary)}
    }.padding(14).background(model.sync.phase == .failed ? Color.red.opacity(0.07):Color.accentColor.opacity(0.055)).overlay(alignment:.bottom){Divider()}}
}
struct PhotoLoadingEmpty:View {
    @ObservedObject var model:GalleryModel
    var body:some View{VStack(spacing:18){
        if model.loading{ProgressView().controlSize(.large);Text("휴대폰 사진 목록을 불러오고 있습니다").font(.title2);Text("목록을 받은 뒤 사진과 동영상의 미리보기가 표시됩니다.").foregroundStyle(.secondary)}
        else if model.sync.phase == .failed{Image(systemName:"exclamationmark.triangle").font(.system(size:44)).foregroundStyle(.orange);Text("사진 불러오기에 실패했습니다").font(.title2);Text(model.sync.issue ?? "아래 진단 정보를 확인하고 다시 시도하세요.").foregroundStyle(.secondary).multilineTextAlignment(.center);Button("다시 시도"){model.retryPhotoLoad()}.buttonStyle(.borderedProminent)}
        else if model.sync.phase == .disconnected{Image(systemName:"iphone.slash").font(.system(size:44));Text("휴대폰 연결을 기다리는 중").font(.title2);Text("연결되면 사진 목록을 다시 요청합니다.").foregroundStyle(.secondary)}
        else if model.sync.phase == .canceled{Image(systemName:"pause.circle").font(.system(size:44));Text("사진 불러오기를 중단했습니다").font(.title2);Button("계속 받기"){model.resumePhotoLoad()}.buttonStyle(.borderedProminent)}
        else{Image(systemName:"photo.on.rectangle").font(.system(size:44));Text("휴대폰 사진 보관함").font(.title2);Button("사진 불러오기"){model.retryPhotoLoad()}.buttonStyle(.borderedProminent)}
        if !model.loading{Button("진단 정보 복사"){model.copySyncDiagnostics()}.buttonStyle(.borderless)}
    }.padding(35).frame(maxWidth:.infinity,maxHeight:.infinity)}
}
struct PhotoOriginalLoading:View {
    @ObservedObject var model:GalleryModel
    @ObservedObject var files:FileTransfer
    let item:GalleryItem
    var body:some View{VStack(spacing:15){
        if let issue=model.originalIssue{Image(systemName:"exclamationmark.triangle").font(.largeTitle).foregroundStyle(.orange);Text("원본을 불러오지 못했습니다").font(.headline);Text(issue).font(.caption).multilineTextAlignment(.center);Button("다시 시도"){model.open(item)}.buttonStyle(.borderedProminent)}
        else{ProgressView();Text(item.video ? "동영상 원본을 받는 중":"사진 원본을 받는 중").font(.headline);if files.busy{ProgressView(value:files.progress).frame(width:260);Text(files.summary).font(.caption)}else{Text("휴대폰 응답과 Wi-Fi 파일 전송을 기다립니다").font(.caption)}}
    }.foregroundStyle(.white).padding(25)}
}
