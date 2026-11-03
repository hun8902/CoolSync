import AppKit

class CoolSyncWindow:NSWindow {
    func isTitlebarDoubleClick(_ event:NSEvent)->Bool {
        guard event.type == .leftMouseDown,event.clickCount==2,styleMask.contains(.titled),styleMask.contains(.resizable),!styleMask.contains(.fullScreen) else{return false}
        let point=event.locationInWindow
        guard point.y>=contentLayoutRect.maxY,point.y<=frame.height,point.x>=0,point.x<=frame.width else{return false}
        for kind in [NSWindow.ButtonType.closeButton,.miniaturizeButton,.zoomButton]{
            if let button=standardWindowButton(kind),!button.isHidden,button.convert(button.bounds,to:nil).insetBy(dx:-3,dy:-3).contains(point){return false}
        }
        return true
    }
    override func sendEvent(_ event:NSEvent){
        if isTitlebarDoubleClick(event){performZoom(nil);return}
        super.sendEvent(event)
    }
}
