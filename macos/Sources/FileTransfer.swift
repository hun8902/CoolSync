import AppKit
import CryptoKit
import Darwin
import Combine
import ImageIO

struct FileMeta: Codable {
    let id: String
    let name: String
    let size: Int64
    let sha: String
    let flow: String
    var path: String? = nil
    var remote: String? = nil
    var clipboard:Bool? = nil
    var clipTime:Int64? = nil
}
struct FileEndpoint: Codable { let hosts: [String]; let port: Int; let token: String }

private final class TransferSession {
    private let lock=NSLock()
    private var fds=Set<Int32>()
    private var stopped=false
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    func track(_ fd: Int32) throws { lock.lock(); defer { lock.unlock() }; if stopped { Darwin.close(fd); throw CocoaError(.userCancelled) }; fds.insert(fd) }
    func close(_ fd: Int32) { lock.lock(); let exists=fds.remove(fd) != nil; lock.unlock(); if exists { Darwin.close(fd) } }
    func finish() { lock.lock(); let open=fds; fds=[]; lock.unlock(); for fd in open { Darwin.close(fd) } }
    func cancel() { lock.lock(); stopped=true; let open=fds; fds=[]; lock.unlock(); for fd in open { Darwin.shutdown(fd,SHUT_RDWR); Darwin.close(fd) } }
}

final class FileTransfer: ObservableObject {
    static let limit: Int64=268435456
    @Published var summary="보낼 파일을 선택하세요"
    @Published var progress: Double=0
    @Published var busy=false
    @Published var incoming: FileMeta?
    var sendControl: ((String,String,String)->Void)?
    var key: (()->Data)?
    var connected: (()->Bool)?
    var onCompletion: ((Bool)->Void)?
    var imageReceived:((URL,Int64)->Void)?
    var canReceiveImage:((Int64)->Bool)?
    var expectedDownloads: [String:URL] = [:]
    var hasTransfer: Bool { meta != nil || busy }
    private var meta: FileMeta?
    private var source: URL?
    private var session: TransferSession?
    private var expiry: DispatchWorkItem?
    private let worker=DispatchQueue(label:"app.coolsync.files",qos:.utility)
    func cancel(notify: Bool=true) {
        if meta?.clipboard==true,let source{try? FileManager.default.removeItem(at:source)}
        if notify, let m=meta { sendControl?("fileReject","",m.id) }
        expiry?.cancel(); session?.cancel(); session=nil; meta=nil; source=nil; incoming=nil; busy=false; progress=0; summary="전송 취소됨"
    }
    func chooseFile() {
        guard connected?()==true else { summary="휴대폰에 먼저 연결하세요"; return }
        guard meta==nil, !busy else { summary="진행 중인 전송을 마치거나 취소하세요"; return }
        let panel=NSOpenPanel(); panel.canChooseDirectories=false; panel.allowsMultipleSelection=false
        guard panel.runModal() == .OK, let url=panel.url else { return }
        stage(url,folder:nil)
    }
    func stage(_ url:URL,folder:String?,clipboard:Bool=false,clipTime:Int64?=nil) {
        guard connected?()==true, meta==nil, !busy else { summary="기기 연결 또는 진행 중인 작업을 확인하세요";if clipboard{try? FileManager.default.removeItem(at:url)}else{onCompletion?(false)};return }
        busy=true; summary="파일 확인 중"; let task=TransferSession(); session=task
        worker.async { [weak self] in
            do {
                let info=try url.resourceValues(forKeys:[.fileSizeKey,.isRegularFileKey]); guard info.isRegularFile==true, let size=info.fileSize, size<=Self.limit else { throw self?.failure("일반 파일 256 MB 이하만 보낼 수 있습니다") ?? CocoaError(.fileReadUnknown) }
                let hash=try Self.hash(url,session:task)
                var m=FileMeta(id:UUID().uuidString,name:url.lastPathComponent,size:Int64(size),sha:hash,flow:"download")
                m.path=folder;m.clipboard=clipboard ? true:nil;m.clipTime=clipTime
                DispatchQueue.main.async { guard let self, !task.cancelled else { return }; self.busy=false; self.meta=m; self.source=url; self.summary="휴대폰에서 수신을 승인해 주세요"; self.sendControl?("fileOffer",self.json(m),m.id); self.arm() }
            } catch { DispatchQueue.main.async { guard let self, !task.cancelled else { return }; self.busy=false; self.meta=nil; self.summary=error.localizedDescription;if clipboard{try? FileManager.default.removeItem(at:url)}else{self.onCompletion?(false)} } }
        }
    }
    func handle(_ message: Wire.Message) {
        switch message.type {
        case "fileOffer":
            guard meta==nil, !busy else { sendControl?("fileReject","",message.ref); return }
            guard let m=try? JSONDecoder().decode(FileMeta.self,from:Data(message.text.utf8)), m.flow=="upload", m.size>=0, m.size<=Self.limit, m.sha.count==64, UUID(uuidString:m.id) != nil else { summary="올바르지 않은 파일 요청입니다"; return }
            if m.clipboard==true {
                guard m.size<=20*1024*1024,let time=m.clipTime,canReceiveImage?(time)==true else{sendControl?("fileReject","이미지 수신 조건을 확인하세요",m.id);return}
                let dir=FileManager.default.temporaryDirectory.appendingPathComponent("CoolSyncClipboard",isDirectory:true);try? FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
                meta=m;serve(m,source:nil,destination:dir.appendingPathComponent(UUID().uuidString+".png"));return
            }
            meta=m
            if let remote=m.remote,let target=expectedDownloads.removeValue(forKey:remote) { incoming=nil;serve(m,source:nil,destination:target);return }
            incoming=m; summary="휴대폰에서 파일을 보냈습니다"; arm()
            NotificationCenter.default.post(name:.init("CoolSyncIncomingFile"),object:nil,userInfo:["name":m.name])
        case "fileAccept":
            guard let m=meta, m.flow=="download", message.ref==m.id, let source else { return }
            serve(m,source:source,destination:nil)
        case "fileReject": if message.ref==meta?.id { cancel(notify:false); summary=message.text.isEmpty ? "상대 기기에서 전송을 취소했습니다":message.text; onCompletion?(false) }
        default: break
        }
    }
    func accept() {
        guard let m=incoming, m.id==meta?.id else { return }
        let panel=NSSavePanel(); panel.nameFieldStringValue=URL(fileURLWithPath:m.name).lastPathComponent; panel.canCreateDirectories=true; panel.title="받을 파일 저장"
        guard panel.runModal() == .OK, let destination=panel.url else { return }
        incoming=nil; serve(m,source:nil,destination:destination)
    }
    #if COOLSYNC_TESTING
    func startTest(_ value: FileMeta, source: URL?, destination: URL?) { meta=value; self.source=source; serve(value,source:source,destination:destination) }
    #endif
    private func arm() {
        expiry?.cancel(); let task=DispatchWorkItem { [weak self] in guard let self, !self.busy else { return }; let image=self.meta?.clipboard==true;self.cancel(); self.summary="파일 요청이 만료됐습니다";if !image{self.onCompletion?(false)} }
        expiry=task; DispatchQueue.main.asyncAfter(deadline:.now()+120,execute:task)
    }
    private func serve(_ m: FileMeta,source: URL?,destination: URL?) {
        guard !busy, let key=key?(), connected?()==true else { summary="휴대폰 연결을 확인하세요"; return }
        expiry?.cancel(); let task=TransferSession(); session?.cancel(); session=task; busy=true; progress=0; summary="같은 Wi-Fi로 연결하는 중"
        worker.async { [weak self] in
            var temporary: URL?
            do {
                guard let self else { return }
                let server=Darwin.socket(AF_INET,SOCK_STREAM,0); guard server>=0 else { throw self.failure("파일 연결을 열지 못했습니다") }; try task.track(server)
                var yes:Int32=1; setsockopt(server,SOL_SOCKET,SO_REUSEADDR,&yes,socklen_t(MemoryLayout.size(ofValue:yes)))
                var address=sockaddr_in(); address.sin_len=UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family=sa_family_t(AF_INET); address.sin_port=0; address.sin_addr=in_addr(s_addr:INADDR_ANY)
                #if COOLSYNC_TESTING
                address.sin_addr=in_addr(s_addr:inet_addr("127.0.0.1"))
                #endif
                let bound=withUnsafePointer(to:&address) { $0.withMemoryRebound(to:sockaddr.self,capacity:1) { Darwin.bind(server,$0,socklen_t(MemoryLayout<sockaddr_in>.size)) } }
                guard bound==0, Darwin.listen(server,4)==0 else { throw self.failure("파일 수신 포트를 열지 못했습니다") }
                var length=socklen_t(MemoryLayout<sockaddr_in>.size)
                _=withUnsafeMutablePointer(to:&address) { $0.withMemoryRebound(to:sockaddr.self,capacity:1) { getsockname(server,$0,&length) } }
                let hosts=Self.localAddresses(); guard !hosts.isEmpty else { throw self.failure("Mac을 Wi-Fi 또는 로컬 네트워크에 연결하세요") }
                var tokenData=Data(count:32); let random=tokenData.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault,32,$0.baseAddress!) }; guard random==errSecSuccess else { throw self.failure("인증 정보를 만들지 못했습니다") }
                let token=tokenData.base64EncodedString(); let endpoint=FileEndpoint(hosts:hosts,port:Int(UInt16(bigEndian:address.sin_port)),token:token)
                DispatchQueue.main.async { guard !task.cancelled else { return }; self.sendControl?("fileReady",self.json(endpoint),m.id) }
                // No permanent network listener: one transfer, at most 45 seconds to connect.
                var client:Int32 = -1
                let deadline=Date().addingTimeInterval(45)
                while Date()<deadline && !task.cancelled {
                    var pollfd=pollfd(fd:server,events:Int16(POLLIN),revents:0)
                    let remaining=Int32(max(1,deadline.timeIntervalSinceNow*1000))
                    if Darwin.poll(&pollfd,1,remaining)<=0 { break }
                    let fd=Darwin.accept(server,nil,nil); if fd<0 { break }; try task.track(fd)
                    var timeout=timeval(tv_sec:5,tv_usec:0); setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&timeout,socklen_t(MemoryLayout<timeval>.size)); setsockopt(fd,SOL_SOCKET,SO_SNDTIMEO,&timeout,socklen_t(MemoryLayout<timeval>.size)); setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&yes,socklen_t(MemoryLayout.size(ofValue:yes)))
                    do {
                        let auth=try Wire.open(Self.readFrame(fd,task:task),key:key)
                        guard auth.type=="fileAuth", auth.ref==m.id, auth.text==token else { throw self.failure("파일 인증 실패") }
                        client=fd; break
                    } catch { task.close(fd) }
                }
                task.close(server); guard client>=0, !task.cancelled else { throw self.failure("파일 연결 시간이 지났습니다. 같은 Wi-Fi인지 확인하세요.") }
                var timeout=timeval(tv_sec:30,tv_usec:0); setsockopt(client,SOL_SOCKET,SO_RCVTIMEO,&timeout,socklen_t(MemoryLayout<timeval>.size)); setsockopt(client,SOL_SOCKET,SO_SNDTIMEO,&timeout,socklen_t(MemoryLayout<timeval>.size))
                var start=Wire.Message(type:"fileStart"); start.ref=m.id; try Self.writeFrame(client,data:Data(try Wire.seal(start,key:key).dropLast()),task:task)
                var total:Int64=0; var index=0; var hash=SHA256(); var lastUi=Date.distantPast
                func update(_ n: Int) throws {
                    total+=Int64(n); guard total<=m.size, total<=Self.limit else { throw self.failure("파일 크기가 다릅니다") }
                    if Date().timeIntervalSince(lastUi)>0.2 || total==m.size { lastUi=Date(); let value=m.size==0 ? 1 : Double(total)/Double(m.size); DispatchQueue.main.async { guard !task.cancelled else { return }; self.progress=value; self.summary="파일 전송 중 · \(Int(value*100))%" } }
                }
                if let source {
                    let file=try FileHandle(forReadingFrom:source); defer { try? file.close() }
                    while let chunk=try file.read(upToCount:65536), !chunk.isEmpty { if task.cancelled { throw CocoaError(.userCancelled) }; try update(chunk.count); hash.update(data:chunk); try Self.writeFrame(client,data:Self.crypt(chunk,key:key,id:m.id,index:index,encrypt:true),task:task); index+=1 }
                    guard total==m.size, hash.finalize().map({String(format:"%02x",$0)}).joined()==m.sha else { throw self.failure("전송 중 원본 파일이 변경됐습니다") }
                    let done=try Wire.open(Self.readFrame(client,task:task),key:key); guard done.type=="fileDone", done.ref==m.id else { throw self.failure("저장 확인을 받지 못했습니다") }
                } else if let destination {
                    let temp=destination.deletingLastPathComponent().appendingPathComponent(".coolsync-\(UUID().uuidString).partial"); temporary=temp
                    guard FileManager.default.createFile(atPath:temp.path,contents:nil) else { throw self.failure("파일을 저장하지 못했습니다") }
                    let file=try FileHandle(forWritingTo:temp)
                    do {
                        while total<m.size { let clear=try Self.crypt(Self.readFrame(client,task:task),key:key,id:m.id,index:index,encrypt:false); index+=1; guard !clear.isEmpty, clear.count<=65536 else { throw self.failure("올바르지 않은 파일 조각입니다") }; try update(clear.count); hash.update(data:clear); try file.write(contentsOf:clear) }
                        try file.close()
                    } catch { try? file.close(); throw error }
                    guard hash.finalize().map({String(format:"%02x",$0)}).joined()==m.sha else { throw self.failure("파일 무결성 확인에 실패했습니다") }
                    if FileManager.default.fileExists(atPath:destination.path) { _=try FileManager.default.replaceItemAt(destination,withItemAt:temp) } else { try FileManager.default.moveItem(at:temp,to:destination) }; temporary=nil
                    if m.clipboard==true { guard let image=CGImageSourceCreateWithURL(destination as CFURL,nil),let properties=CGImageSourceCopyPropertiesAtIndex(image,0,nil)as? [CFString:Any],let width=properties[kCGImagePropertyPixelWidth]as? Int,let height=properties[kCGImagePropertyPixelHeight]as? Int,width>0,height>0,width<=16000000/height else{try? FileManager.default.removeItem(at:destination);throw self.failure("올바른 단일 이미지가 아닙니다")} }
                    var done=Wire.Message(type:"fileDone"); done.ref=m.id; try Self.writeFrame(client,data:Data(try Wire.seal(done,key:key).dropLast()),task:task)
                }
                task.close(client)
                DispatchQueue.main.async { guard !task.cancelled else { return }; self.busy=false; self.meta=nil; self.source=nil; self.summary="\(m.name) · 전송 완료"; self.progress=1; self.session=nil;if m.clipboard==true{if let destination{self.imageReceived?(destination,m.clipTime ?? 0);try? FileManager.default.removeItem(at:destination)};if let source{try? FileManager.default.removeItem(at:source)}}else{self.onCompletion?(true)} }
            } catch {
                if let temporary { try? FileManager.default.removeItem(at:temporary) }
                DispatchQueue.main.async { guard let self, !task.cancelled else { return }; self.busy=false; self.meta=nil; self.source=nil; self.incoming=nil; self.summary=error.localizedDescription; self.progress=0; self.session=nil;if m.clipboard != true{self.onCompletion?(false)} }
            }
            task.finish()
        }
    }
    private func json<T: Encodable>(_ value:T)->String { String(data:(try? JSONEncoder().encode(value)) ?? Data(),encoding:.utf8) ?? "" }
    private func failure(_ message:String)->NSError { NSError(domain:"CoolSync",code:1,userInfo:[NSLocalizedDescriptionKey:message]) }
    private static func hash(_ url:URL,session:TransferSession) throws ->String {
        var hash=SHA256(); var size:Int64=0; let file=try FileHandle(forReadingFrom:url); defer { try? file.close() }
        while let bytes=try file.read(upToCount:65536), !bytes.isEmpty { if session.cancelled { throw CocoaError(.userCancelled) }; size+=Int64(bytes.count); guard size<=limit else { throw CocoaError(.fileReadTooLarge) }; hash.update(data:bytes) }
        return hash.finalize().map { String(format:"%02x",$0) }.joined()
    }
    private static func localAddresses()->[String] {
        #if COOLSYNC_TESTING
        return ["127.0.0.1"]
        #else
        var head:UnsafeMutablePointer<ifaddrs>?; guard getifaddrs(&head)==0, let first=head else { return [] }; defer { freeifaddrs(head) }
        var result:[String]=[]; var p:UnsafeMutablePointer<ifaddrs>?=first
        while let item=p { defer { p=item.pointee.ifa_next }; guard let addr=item.pointee.ifa_addr, addr.pointee.sa_family==UInt8(AF_INET), item.pointee.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
            var host=[CChar](repeating:0,count:Int(NI_MAXHOST)); guard getnameinfo(addr,socklen_t(addr.pointee.sa_len),&host,socklen_t(host.count),nil,0,NI_NUMERICHOST)==0 else { continue }
            let s=String(cString:host); let pieces=s.split(separator:".").compactMap{Int($0)}
            if pieces.count==4 && (pieces[0]==10 || (pieces[0]==192 && pieces[1]==168) || (pieces[0]==172 && (16...31).contains(pieces[1])) || (pieces[0]==169 && pieces[1]==254)) { result.append(s) }
        }
        return Array(Set(result)).sorted().prefix(8).map{$0}
        #endif
    }
    private static func readExactly(_ fd:Int32,_ count:Int,task:TransferSession) throws ->Data {
        var data=Data(count:count); var offset=0
        while offset<count { if task.cancelled { throw CocoaError(.userCancelled) }; let n=data.withUnsafeMutableBytes { Darwin.recv(fd,$0.baseAddress!.advanced(by:offset),count-offset,0) }; guard n>0 else { throw CocoaError(.fileReadUnknown) }; offset+=n }
        return data
    }
    private static func readFrame(_ fd:Int32,task:TransferSession) throws ->Data { let h=try readExactly(fd,4,task:task); let n=h.reduce(0){($0<<8)|Int($1)}; guard n>0, n<=100000 else { throw CocoaError(.fileReadCorruptFile) }; return try readExactly(fd,n,task:task) }
    private static func writeFrame(_ fd:Int32,data:Data,task:TransferSession) throws {
        guard !data.isEmpty, data.count<=100000 else { throw CocoaError(.fileWriteUnknown) }
        var n=UInt32(data.count).bigEndian; var packet=withUnsafeBytes(of:&n){Data($0)}; packet.append(data); var offset=0
        while offset<packet.count { if task.cancelled { throw CocoaError(.userCancelled) }; let sent=packet.withUnsafeBytes { Darwin.send(fd,$0.baseAddress!.advanced(by:offset),packet.count-offset,0) }; guard sent>0 else { throw CocoaError(.fileWriteUnknown) }; offset+=sent }
    }
    private static func crypt(_ data:Data,key:Data,id:String,index:Int,encrypt:Bool) throws ->Data {
        let aad=Data("CoolSync/file/1|\(id)|\(index)".utf8); let k=SymmetricKey(data:key)
        if encrypt { guard let combined=try AES.GCM.seal(data,using:k,authenticating:aad).combined else { throw CocoaError(.coderInvalidValue) }; return combined }
        return try AES.GCM.open(AES.GCM.SealedBox(combined:data),using:k,authenticating:aad)
    }
}
