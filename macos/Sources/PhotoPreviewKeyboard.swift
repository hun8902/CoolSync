import AppKit
import SwiftUI

/// Only the active photo viewer's window owns these keys; text fields and sheets keep theirs.
struct PhotoPreviewKeyboard:NSViewRepresentable {
    @ObservedObject var photos:PhotosModel
    func makeCoordinator()->Coordinator{Coordinator(photos)}
    func makeNSView(context:Context)->NSView{let view=NSView();context.coordinator.host=view;context.coordinator.start();return view}
    func updateNSView(_ view:NSView,context:Context){context.coordinator.photos=photos}
    static func dismantleNSView(_ view:NSView,coordinator:Coordinator){coordinator.stop()}
    final class Coordinator {
        weak var host:NSView?
        weak var photos:PhotosModel?
        private var monitor:Any?
        private var lastArrow:TimeInterval=0
        init(_ photos:PhotosModel){self.photos=photos}
        func start(){monitor=NSEvent.addLocalMonitorForEvents(matching:.keyDown){[weak self]event in
            guard let self,let window=self.host?.window,event.window===window,window.isKeyWindow,window.attachedSheet==nil,NSApp.modalWindow==nil,let photos=self.photos,photos.preview != nil,
                  event.modifierFlags.intersection([.command,.control,.option,.shift]).isEmpty,
                  !(window.firstResponder is NSTextView),!(window.firstResponder is NSTextField)else{return event}
            switch event.keyCode {
            case 123,124:
                let now=Date.timeIntervalSinceReferenceDate
                if !event.isARepeat || now-self.lastArrow>0.2{self.lastArrow=now;photos.nextPreview(event.keyCode==123 ? -1:1)}
                return nil
            case 53:photos.closePreview();return nil
            case 49:photos.togglePlayback();return nil
            default:return event
            }
        }}
        func stop(){if let monitor{NSEvent.removeMonitor(monitor)};monitor=nil}
        deinit{stop()}
    }
}
