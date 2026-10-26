import AppKit
import SwiftUI
import UniformTypeIdentifiers

private let remotePathType=NSPasteboard.PasteboardType("app.coolsync.remote-path")
final class RemotePromise:NSFilePromiseProvider {
    var remotePath=""
    var keeper:AnyObject?
    override func writableTypes(for pasteboard:NSPasteboard)->[NSPasteboard.PasteboardType]{super.writableTypes(for:pasteboard)+[remotePathType]}
    override func pasteboardPropertyList(forType type:NSPasteboard.PasteboardType)->Any?{type==remotePathType ? remotePath:super.pasteboardPropertyList(forType:type)}
}
final class ExplorerTable:NSTableView {
    var command:((String)->Void)?
    override func menu(for event:NSEvent)->NSMenu?{
        let position=convert(event.locationInWindow,from:nil);let row=row(at:position)
        if row>=0 && !selectedRowIndexes.contains(row){selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false)}
        return super.menu(for:event)
    }
    override func keyDown(with event:NSEvent){
        if event.modifierFlags.contains(.command),let key=event.charactersIgnoringModifiers?.lowercased(),["c","x","v","a"].contains(key){if key=="a"{selectAll(nil)}else{command?(key)};return}
        if event.keyCode==51 || event.keyCode==117{command?("delete");return}
        super.keyDown(with:event)
    }
}
struct RemoteTable:NSViewRepresentable {
    @ObservedObject var model:ExplorerModel
    func makeCoordinator()->Coordinator{Coordinator(model)}
    func makeNSView(context:Context)->NSScrollView{
        let table=ExplorerTable();context.coordinator.table=table
        for(id,title,width)in [("name","이름",310.0),("modified","수정일",160.0),("size","크기",100.0)]{
            let column=NSTableColumn(identifier:.init(id));column.title=title;column.width=width;column.minWidth=80;table.addTableColumn(column)
        }
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle;table.rowHeight=26;table.intercellSpacing=NSSize(width:12,height:2);table.allowsMultipleSelection=true;table.usesAlternatingRowBackgroundColors=false;table.style = .fullWidth
        table.delegate=context.coordinator;table.dataSource=context.coordinator;table.target=context.coordinator;table.doubleAction=#selector(Coordinator.open)
        table.registerForDraggedTypes([.fileURL,remotePathType]);table.setDraggingSourceOperationMask([.copy,.move],forLocal:true);table.setDraggingSourceOperationMask(.copy,forLocal:false)
        let menu=NSMenu()
        for(title,action,key)in [("Mac으로 복사",#selector(Coordinator.download),""),("이름 변경…",#selector(Coordinator.rename),""),("복사",#selector(Coordinator.copyItems),"c"),("잘라내기",#selector(Coordinator.cutItems),"x"),("붙여넣기",#selector(Coordinator.pasteItems),"v"),("휴지통으로 이동",#selector(Coordinator.remove),"")]{let item=NSMenuItem(title:title,action:action,keyEquivalent:key);item.target=context.coordinator;menu.addItem(item)}
        table.menu=menu
        table.command={ [weak m=model] key in switch key{case "c":m?.copy(cut:false);case "x":m?.copy(cut:true);case "v":m?.paste();case "delete":m?.remove();default:break} }
        let scroll=NSScrollView();scroll.hasVerticalScroller=true;scroll.hasHorizontalScroller=true;scroll.documentView=table;scroll.borderType = .noBorder;return scroll
    }
    func updateNSView(_ scroll:NSScrollView,context:Context){
        context.coordinator.model=model
        let rows=model.visible
        guard let table=context.coordinator.table else{return}
        context.coordinator.refreshing=true;context.coordinator.rows=rows;table.reloadData()
        table.selectRowIndexes(IndexSet(rows.indices.filter{model.selection.contains(rows[$0].path)}),byExtendingSelection:false)
        context.coordinator.refreshing=false
    }
    final class Coordinator:NSObject,NSTableViewDataSource,NSTableViewDelegate,NSFilePromiseProviderDelegate{
        var model:ExplorerModel;weak var table:ExplorerTable?;var rows:[RemoteEntry]=[];var refreshing=false
        init(_ model:ExplorerModel){self.model=model}
        func numberOfRows(in tableView:NSTableView)->Int{rows.count}
        func tableViewSelectionDidChange(_ notification:Notification){guard !refreshing,let table else{return};model.selection=Set(table.selectedRowIndexes.compactMap{rows.indices.contains($0) ? rows[$0].path:nil})}
        func tableView(_ tableView:NSTableView,viewFor column:NSTableColumn?,row:Int)->NSView?{
            guard rows.indices.contains(row),let column else{return nil};let item=rows[row]
            let cell=NSTableCellView();let text=NSTextField(labelWithString:"");text.font = .systemFont(ofSize:13);text.lineBreakMode = .byTruncatingMiddle;text.translatesAutoresizingMaskIntoConstraints=false;cell.addSubview(text);cell.textField=text
            var lead:CGFloat=0
            if column.identifier.rawValue=="name"{
                let icon=NSImageView();icon.image=NSImage(systemSymbolName:item.directory ? "folder.fill":"doc",accessibilityDescription:item.directory ? "폴더":"파일");icon.contentTintColor=item.directory ? .systemBlue:.secondaryLabelColor;icon.translatesAutoresizingMaskIntoConstraints=false;cell.addSubview(icon)
                NSLayoutConstraint.activate([icon.leadingAnchor.constraint(equalTo:cell.leadingAnchor),icon.centerYAnchor.constraint(equalTo:cell.centerYAnchor),icon.widthAnchor.constraint(equalToConstant:18),icon.heightAnchor.constraint(equalToConstant:18)]);lead=26;text.stringValue=item.name
            }else if column.identifier.rawValue=="size"{text.stringValue=item.directory ? "—":ByteCountFormatter.string(fromByteCount:item.size,countStyle:.file);text.textColor = .secondaryLabelColor}
            else{text.stringValue=DateFormatter.localizedString(from:Date(timeIntervalSince1970:Double(item.modified)/1000),dateStyle:.short,timeStyle:.short);text.textColor = .secondaryLabelColor}
            NSLayoutConstraint.activate([text.leadingAnchor.constraint(equalTo:cell.leadingAnchor,constant:lead),text.trailingAnchor.constraint(equalTo:cell.trailingAnchor,constant:-6),text.centerYAnchor.constraint(equalTo:cell.centerYAnchor)]);return cell
        }
        func tableView(_ tableView:NSTableView,didClick tableColumn:NSTableColumn){let key=tableColumn.identifier.rawValue;if model.sort==key{model.ascending.toggle()}else{model.sort=key;model.ascending=true}}
        @objc func open(){guard let table,rows.indices.contains(table.clickedRow)else{return};let item=rows[table.clickedRow];if item.directory{model.browse(item.path)}else{model.selection=[item.path];model.download()}}
        @objc func download(){model.download()}
        @objc func rename(){model.rename()}
        @objc func copyItems(){model.copy(cut:false)}
        @objc func cutItems(){model.copy(cut:true)}
        @objc func pasteItems(){model.paste()}
        @objc func remove(){model.remove()}
        func tableView(_ tableView:NSTableView,pasteboardWriterForRow row:Int)->NSPasteboardWriting?{
            guard rows.indices.contains(row)else{return nil};let item=rows[row]
            let provider=RemotePromise(fileType:item.directory ? UTType.folder.identifier:UTType.data.identifier,delegate:self);provider.remotePath=item.path;provider.keeper=self;provider.userInfo=item;return provider
        }
        func filePromiseProvider(_ provider:NSFilePromiseProvider,fileNameForType type:String)->String{(provider.userInfo as? RemoteEntry)?.name ?? "파일"}
        func filePromiseProvider(_ provider:NSFilePromiseProvider,writePromiseTo url:URL,completionHandler:@escaping(Error?)->Void){guard let item=provider.userInfo as? RemoteEntry else{completionHandler(CocoaError(.fileReadUnknown));return};DispatchQueue.main.async{self.model.promise(item,to:url,completion:completionHandler)}}
        func operationQueue(for provider:NSFilePromiseProvider)->OperationQueue{.main}
        private func destination(_ row:Int)->String{rows.indices.contains(row)&&rows[row].directory ? rows[row].path:model.path}
        func tableView(_ tableView:NSTableView,validateDrop info:NSDraggingInfo,proposedRow row:Int,proposedDropOperation operation:NSTableView.DropOperation)->NSDragOperation{
            let local=info.draggingPasteboard.availableType(from:[remotePathType]) != nil
            tableView.setDropRow(rows.indices.contains(row)&&rows[row].directory ? row:-1,dropOperation:rows.indices.contains(row)&&rows[row].directory ? .on:.above)
            return local ? .move:.copy
        }
        func tableView(_ tableView:NSTableView,acceptDrop info:NSDraggingInfo,row:Int,dropOperation operation:NSTableView.DropOperation)->Bool{
            let target=destination(row)
            let paths=info.draggingPasteboard.pasteboardItems?.compactMap{$0.string(forType:remotePathType)} ?? []
            if !paths.isEmpty{model.move(paths,to:target,copy:info.draggingSourceOperationMask.contains(.copy)&&NSEvent.modifierFlags.contains(.option));return true}
            let urls=info.draggingPasteboard.readObjects(forClasses:[NSURL.self],options:[.urlReadingFileURLsOnly:true])as?[URL] ?? []
            if !urls.isEmpty{model.upload(urls,to:target);return true};return false
        }
    }
}
