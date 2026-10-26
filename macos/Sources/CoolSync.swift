import AppKit
import CoreBluetooth
import CryptoKit
import Security
import CoreImage

// CoolSync v1: Android peripheral, Mac central. All content uses AES-GCM.
enum Wire {
    static let service = CBUUID(string: "8d2ec100-45bd-4a5a-9fb6-11e7a189c001")
    static let rx = CBUUID(string: "8d2ec101-45bd-4a5a-9fb6-11e7a189c001")
    static let tx = CBUUID(string: "8d2ec102-45bd-4a5a-9fb6-11e7a189c001")
    static let aad = Data("CoolSync/1".utf8)
    static let maxText = 16384
    static let maxFrame = 140000
    struct Message: Codable {
        var v = 1
        var role = "mac"
        var id = UUID().uuidString
        var time = Int64(Date().timeIntervalSince1970 * 1000)
        var type: String
        var text = ""
        var ref = ""
        var status: String? = nil
    }
    static func seal(_ message: Message, key: Data) throws -> Data {
        let box = try AES.GCM.seal(JSONEncoder().encode(message), using: SymmetricKey(data:key), authenticating: aad)
        guard let data = box.combined else { throw CocoaError(.coderInvalidValue) }
        return Data((data.base64EncodedString() + "\n").utf8)
    }
    static func open(_ data: Data, key: Data) throws -> Message {
        guard let raw = Data(base64Encoded:data) else { throw CocoaError(.coderInvalidValue) }
        let clear = try AES.GCM.open(AES.GCM.SealedBox(combined:raw),using:SymmetricKey(data:key),authenticating:aad)
        let m = try JSONDecoder().decode(Message.self,from:clear)
        guard m.v == 1, m.role == "android", m.id.count <= 64,
              abs(Date().timeIntervalSince1970 * 1000 - Double(m.time)) < 120000 else { throw CocoaError(.coderInvalidValue) }
        return m
    }
}

enum KeyStore {
    static let query: [String:Any] = [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"app.coolsync",kSecAttrAccount as String:"pairing-key"]
    static func load() throws -> Data {
        var q = query; q[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary,&result)
        if status == errSecSuccess, let data = result as? Data, data.count == 32 { return data }
        guard status == errSecItemNotFound else { throw NSError(domain:NSOSStatusErrorDomain,code:Int(status)) }
        return try replace()
    }
    static func replace() throws -> Data {
        var data = Data(count:32)
        let status = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault,32,$0.baseAddress!) }
        guard status == errSecSuccess else { throw NSError(domain:NSOSStatusErrorDomain,code:Int(status)) }
        var q = query; q[kSecValueData as String] = data; q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let add = SecItemAdd(q as CFDictionary,nil)
        if add == errSecDuplicateItem {
            let update = SecItemUpdate(query as CFDictionary,[kSecValueData as String:data] as CFDictionary)
            guard update == errSecSuccess else { throw NSError(domain:NSOSStatusErrorDomain,code:Int(update)) }
        } else if add != errSecSuccess { throw NSError(domain:NSOSStatusErrorDomain,code:Int(add)) }
        return data
    }
}

final class SyncEngine: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var changed: ((String)->Void)?
    var phoneNotification: ((String,String,String,@escaping(String)->Void)->Void)?
    var fileMessage: ((Wire.Message)->Void)?
    var imageCopied:((URL,Int64)->Void)?
    var filesystemMessage: ((Wire.Message)->Void)?
    private(set) var peerName = UserDefaults.standard.string(forKey:"peerName") ?? "연결된 휴대폰 없음"
    private(set) var peerModel = UserDefaults.standard.string(forKey:"peerModel") ?? ""
    private(set) var peerOS = ""
    private(set) var lastSync: Date?
    private(set) var key: Data
    private var central: CBCentralManager!
    private var peer: CBPeripheral?
    private var disconnecting = Set<UUID>()
    private var rx: CBCharacteristic?
    private var input = Data()
    private struct Chunk { let bytes: Data; let clipID: String? }
    private var outgoing: [Chunk] = []
    private var inFlightID: String?
    private var retries = 0
    private var writing = false
    private(set) var authenticated = false
    private(set) var connecting=false
    private var enabled = true
    private var locked = false
    private var sleeping = false
    private var clipboardTimer: Timer?
    private var lastChange = NSPasteboard.general.changeCount
    private var pending: Wire.Message?
    private var ackTask: DispatchWorkItem?
    private var connectionTask: DispatchWorkItem?
    private var serviceChangeTask: DispatchWorkItem?
    private var writeTask: DispatchWorkItem?
    private var retryTask: DispatchWorkItem?
    private var session = UUID()
    private var seen = UserDefaults.standard.stringArray(forKey:"receivedIDs") ?? []
    private var failedCandidates: [UUID:Date] = [:]
    private var negotiatedWriteSize = 20
    private var helloID = ""
    private var readyID=""
    private var connectionIssue: String?
    private func failConnection(_ message: String) { connecting=false;connectionIssue=message; status(message); if let p=peer { central.cancelPeripheralConnection(p) } }
    private func authProgress(_ stage: String) {
        guard !authenticated, let p=peer else { return }; connectionTask?.cancel();connecting=true; status("휴대폰 연결 중 · " + stage)
        let token=session
        let task=DispatchWorkItem { [weak self] in guard let self, self.session==token, !self.authenticated else { return }; self.failedCandidates[p.identifier]=Date(); self.failConnection("연결 시간 초과 · " + stage + " 단계에서 응답이 없습니다") }
        connectionTask=task; DispatchQueue.main.asyncAfter(deadline:.now()+30,execute:task)
    }
    private var versionTime: Int64 = 0
    private var versionID = ""
    init(key: Data) {
        self.key = key; super.init()
        central = CBCentralManager(delegate:self,queue:.main)
        startClipboardMonitor()
        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(self,selector:#selector(screenLocked),name:NSNotification.Name("com.apple.screenIsLocked"),object:nil)
        distributed.addObserver(self,selector:#selector(screenUnlocked),name:NSNotification.Name("com.apple.screenIsUnlocked"),object:nil)
        NSWorkspace.shared.notificationCenter.addObserver(self,selector:#selector(willSleep),name:NSWorkspace.willSleepNotification,object:nil)
        NSWorkspace.shared.notificationCenter.addObserver(self,selector:#selector(didWake),name:NSWorkspace.didWakeNotification,object:nil)
    }
    private func status(_ s: String) { changed?(s) }
    @objc private func screenLocked() { locked = true; pending = nil; ackTask?.cancel() }
    @objc private func screenUnlocked() { locked = false; lastChange = NSPasteboard.general.changeCount }
    @objc private func willSleep() { sleeping = true; disconnect(); status("Mac 잠자기") }
    @objc private func didWake() { sleeping = false; scan() }
    func reconnect() { connectionIssue=nil; enabled = true; disconnect(); failedCandidates = [:]; centralManagerDidUpdateState(central) }
    func toggle() { enabled.toggle(); if enabled { scan() } else { disconnect(); status("공유 중지됨") } }
    func replaceKey(_ value: Data) { disconnect(); enabled=true; connectionIssue=nil; peerName="연결된 휴대폰 없음";peerModel="";peerOS=""; key = value; versionTime = 0; versionID = ""; seen = []; UserDefaults.standard.removeObject(forKey:"receivedIDs"); failedCandidates = [:]; scan() }
    func sendControl(_ type: String,_ text: String,_ ref: String) { guard authenticated else { return }; var m=Wire.Message(type:type); m.text=text; m.ref=ref; send(m) }
    func shutdown() { enabled = false; clipboardTimer?.invalidate();clipboardTimer=nil;disconnect() }
    private func disconnect() {
        central.stopScan(); retryTask?.cancel()
        if let p = peer { disconnecting.insert(p.identifier); central.cancelPeripheralConnection(p) }
        clearSession()
    }
    private func clearSession() {
        ackTask?.cancel(); connectionTask?.cancel(); writeTask?.cancel(); serviceChangeTask?.cancel()
        peer?.delegate = nil; peer = nil; rx = nil; authenticated = false;connecting=false
        readyID=""; writing = false; negotiatedWriteSize = 20; inFlightID = nil; input = Data(); outgoing = []; pending = nil; session = UUID()
    }
    private func scan() {
        guard enabled, !sleeping, central.state == .poweredOn, peer == nil, disconnecting.isEmpty else { return }
        connecting=connectionIssue==nil;status(connectionIssue ?? "휴대폰 연결 대기")
        central.scanForPeripherals(withServices:[Wire.service],options:[CBCentralManagerScanOptionAllowDuplicatesKey:false])
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn { scan() }
        else { disconnecting.removeAll(); clearSession(); status(central.state == .unauthorized ? "시스템 설정에서 Bluetooth 권한을 허용하세요" : "블루투스를 켜주세요") }
    }
    func centralManager(_ central: CBCentralManager,didDiscover peripheral: CBPeripheral,advertisementData: [String:Any],rssi RSSI: NSNumber) {
        guard peer == nil, enabled, !sleeping, disconnecting.isEmpty else { return }
        if let values=advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID:Data], let identity=values[Wire.service], identity != Data(SHA256.hash(data:key).prefix(8)) { return }
        if let failed = failedCandidates[peripheral.identifier], Date().timeIntervalSince(failed) < 60 { return }
        central.stopScan(); peer = peripheral; peripheral.delegate = self
        if peripheral.state == .connected {
            authProgress("서비스 검색"); peripheral.discoverServices([Wire.service])
        } else {
            central.connect(peripheral,options:nil); authProgress("Bluetooth 연결")
        }
    }
    func centralManager(_ central: CBCentralManager,didConnect peripheral: CBPeripheral) { guard peer?.identifier==peripheral.identifier else { return }; authProgress("서비스 검색"); peripheral.discoverServices([Wire.service]) }
    func centralManager(_ central: CBCentralManager,didFailToConnect peripheral: CBPeripheral,error: Error?) { if disconnecting.remove(peripheral.identifier) != nil { scan(); return }; if let error { connectionIssue="Bluetooth 연결 실패 · " + error.localizedDescription }; lost(peripheral) }
    func centralManager(_ central: CBCentralManager,didDisconnectPeripheral peripheral: CBPeripheral,error: Error?) { if disconnecting.remove(peripheral.identifier) != nil { scan(); return }; if let error { connectionIssue="Bluetooth 연결 해제 · " + error.localizedDescription }; lost(peripheral) }
    private func lost(_ peripheral: CBPeripheral) {
        guard peer?.identifier == peripheral.identifier else { return }
        clearSession(); status(connectionIssue ?? "연결 끊김 · 다시 찾는 중")
        let task = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.scan()
            if !self.failedCandidates.isEmpty {
                let cooldown = DispatchWorkItem { [weak self] in
                    guard let self, self.peer == nil else { return }
                    self.central.stopScan(); self.failedCandidates = [:]; self.scan()
                }
                self.retryTask = cooldown; DispatchQueue.main.asyncAfter(deadline:.now()+60,execute:cooldown)
            }
        }
        retryTask = task; DispatchQueue.main.asyncAfter(deadline:.now()+2,execute:task)
    }
    func peripheral(_ peripheral: CBPeripheral,didModifyServices invalidatedServices:[CBService]) {
        guard peer?.identifier==peripheral.identifier, invalidatedServices.contains(where:{$0.uuid==Wire.service}) else { return }
        // Android replaces its GATT service after app/service restart. Old handles cannot be reused.
        ackTask?.cancel(); connectionTask?.cancel(); writeTask?.cancel(); serviceChangeTask?.cancel()
        authenticated=false; rx=nil; pending=nil; outgoing=[]; input=Data(); writing=false; inFlightID=nil; helloID=""; readyID=""; session=UUID()
        status("휴대폰 서비스 변경 · 연결 채널 다시 설정 중")
        let epoch=session
        let task=DispatchWorkItem { [weak self,weak peripheral] in
            guard let self,let peripheral,self.session==epoch,self.peer?.identifier==peripheral.identifier else { return }
            if peripheral.state == .connected { self.authProgress("서비스 다시 검색");peripheral.discoverServices([Wire.service]) }
            else { self.authProgress("Bluetooth 재연결");self.central.connect(peripheral,options:nil) }
        }
        serviceChangeTask=task;DispatchQueue.main.asyncAfter(deadline:.now()+0.3,execute:task)
    }
    func peripheral(_ peripheral: CBPeripheral,didDiscoverServices error: Error?) {
        guard peer?.identifier==peripheral.identifier else { return }
        guard error == nil, let service = peripheral.services?.first(where:{$0.uuid == Wire.service}) else { failConnection("서비스 검색 실패 · " + (error?.localizedDescription ?? "휴대폰의 CoolSync 서비스를 찾지 못했습니다")); return }
        authProgress("연결 채널 검색"); peripheral.discoverCharacteristics([Wire.rx,Wire.tx],for:service)
    }
    func peripheral(_ peripheral: CBPeripheral,didDiscoverCharacteristicsFor service: CBService,error: Error?) {
        rx = service.characteristics?.first(where:{$0.uuid == Wire.rx})
        guard peer?.identifier==peripheral.identifier else { return }
        guard error == nil, rx != nil, let tx = service.characteristics?.first(where:{$0.uuid == Wire.tx}) else { failConnection("연결 채널 검색 실패 · " + (error?.localizedDescription ?? "휴대폰에서 연결을 다시 시작하세요")); return }
        authProgress("응답 채널 설정"); peripheral.setNotifyValue(true,for:tx)
    }
    func peripheral(_ peripheral: CBPeripheral,didUpdateNotificationStateFor characteristic: CBCharacteristic,error: Error?) {
        guard peer?.identifier==peripheral.identifier, characteristic.uuid == Wire.tx else { return }
        guard error == nil, characteristic.isNotifying else { failConnection("응답 채널 설정 실패 · " + (error?.localizedDescription ?? "휴대폰이 응답 수신을 허용하지 않았습니다")); return }
        negotiatedWriteSize=max(20,min(180,peripheral.maximumWriteValueLength(for:.withResponse)))
        authProgress("인증 응답 대기")
        var m = Wire.Message(type:"hello"); m.text = String(data:(try? JSONSerialization.data(withJSONObject:["name":Host.current().localizedName ?? "Mac","confirm":true])) ?? Data(),encoding:.utf8) ?? ""; helloID = m.id; send(m)
    }
    private func send(_ message: Wire.Message) {
        guard let p = peer, rx != nil, let data = try? Wire.seal(message,key:key) else { return }
        guard outgoing.reduce(0,{$0+$1.bytes.count}) + data.count <= 280000 else {
            status("전송 대기량 초과 · 다시 연결합니다"); central.cancelPeripheralConnection(p); return
        }
        let size = min(negotiatedWriteSize,p.maximumWriteValueLength(for:.withResponse))
        guard size > 0 else { return }
        var offset = 0
        while offset < data.count {
            let end = min(offset+size,data.count)
            outgoing.append(Chunk(bytes:data.subdata(in:offset..<end),clipID:end == data.count && message.type == "clip" ? message.id : nil)); offset = end
        }
        pump()
    }
    private func pump() {
        guard !writing, !outgoing.isEmpty, let p = peer, let c = rx else { return }
        let chunk = outgoing.removeFirst(); inFlightID = chunk.clipID
        writing = true; p.writeValue(chunk.bytes,for:c,type:.withResponse)
        let task = DispatchWorkItem { [weak self, weak p] in if let self, let p, self.peer?.identifier==p.identifier { self.failConnection("Bluetooth 전송 시간 초과 · 휴대폰의 수신 응답이 없습니다") } }
        writeTask?.cancel(); writeTask = task; DispatchQueue.main.asyncAfter(deadline:.now()+8,execute:task)
    }
    func peripheral(_ peripheral: CBPeripheral,didWriteValueFor characteristic: CBCharacteristic,error: Error?) {
        guard peer?.identifier==peripheral.identifier, characteristic.uuid==Wire.rx else { return }
        writeTask?.cancel()
        if let error { failConnection("Bluetooth 전송 실패 · " + error.localizedDescription); return }
        if let id = inFlightID, let m = pending, m.id == id { awaitAck(m,retry:retries == 0) }
        inFlightID = nil; writing = false; pump()
    }
    func peripheral(_ peripheral: CBPeripheral,didUpdateValueFor characteristic: CBCharacteristic,error: Error?) {
        guard peer?.identifier==peripheral.identifier, error == nil, characteristic.uuid == Wire.tx, let bytes = characteristic.value else { return }
        for b in bytes {
            if b == 10 {
                let frame = input; input = Data()
                do { try handle(Wire.open(frame,key:key)) }
                catch { failedCandidates[peripheral.identifier] = Date(); failConnection("인증 실패 · 현재 QR로 다시 연결하고 두 기기의 자동 날짜·시간을 확인하세요"); return }
            } else {
                guard input.count < Wire.maxFrame else { central.cancelPeripheralConnection(peripheral); return }
                input.append(b)
            }
        }
    }
    private func completeConnection(){
        authenticated=true;connecting=false;connectionIssue=nil;connectionTask?.cancel();failedCandidates=[:]
        UserDefaults.standard.set(peer?.identifier.uuidString,forKey:"peer")
        status("연결됨 · 복사 대기");startClipboardMonitor()
    }
    private func handle(_ m: Wire.Message) throws {
        if m.type == "helloAck", m.ref == helloID {
            if let info = try? JSONSerialization.jsonObject(with:Data(m.text.utf8)) as? [String:Any] {
                negotiatedWriteSize = max(20,min(180,info["mtu"] as? Int ?? 20))
                peerName = String((info["name"] as? String ?? "Android").prefix(80))
                peerModel = String((info["model"] as? String ?? "").prefix(80))
                peerOS = String((info["android"] as? String ?? "").prefix(24))
                UserDefaults.standard.set(peerName,forKey:"peerName"); UserDefaults.standard.set(peerModel,forKey:"peerModel")
            } else { negotiatedWriteSize = max(20,min(180,Int(m.text) ?? 20)) }
            if let info=try? JSONSerialization.jsonObject(with:Data(m.text.utf8)) as? [String:Any],info["confirm"] as? Bool == true {
                var ready=Wire.Message(type:"ready");ready.ref=m.id;readyID=ready.id;authProgress("양방향 연결 최종 확인");send(ready)
            } else { completeConnection() }
            return
        }
        if m.type=="readyAck",!readyID.isEmpty,m.ref==readyID {readyID="";completeConnection();return}
        guard authenticated else { return }
        if m.type=="phoneNotification" {
            guard let data=m.text.data(using:.utf8),let value=try?JSONSerialization.jsonObject(with:data) as? [String:String] else{return}
            let token=session
            phoneNotification?(String((value["app"] ?? "휴대폰").prefix(100)),String((value["title"] ?? "").prefix(160)),String((value["body"] ?? "").prefix(1200))){[weak self]result in
                DispatchQueue.main.async { guard let self,self.session==token,self.authenticated else{return};var ack=Wire.Message(type:"notificationAck");ack.ref=m.id;ack.text=result;self.send(ack) }
            }
            return
        }
        if m.type=="fsResponse" { filesystemMessage?(m); return }
        if m.type.hasPrefix("file") { fileMessage?(m); return }
        if m.type == "ack", m.ref == pending?.id {
            lastSync = Date(); pending = nil; ackTask?.cancel(); status(m.status == "ok" ? "휴대폰에 복사됨" : m.status == "superseded" ? "휴대폰의 최신 복사 유지" : "휴대폰에서 반영하지 못했습니다"); return
        }
        guard m.type == "clip" else { return }
        var ack = Wire.Message(type:"ack"); ack.ref = m.id; ack.status = "ok"
        if seen.contains(m.id) { send(ack); return }
        guard !locked, m.text.utf8.count <= Wire.maxText else { ack.status = "rejected"; send(ack); return }
        checkClipboard() // Account for a new local copy before resolving concurrent changes.
        if m.time < versionTime || (m.time == versionTime && m.id <= versionID) {
            ack.status = "superseded"; send(ack); return
        }
        pending = nil; ackTask?.cancel() // Never retry an older local copy over a new remote copy.
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(m.text,forType:.string) else { ack.status = "rejected"; send(ack); return }
        lastChange = pasteboard.changeCount; versionTime = m.time; versionID = m.id
        seen.append(m.id); seen = Array(seen.suffix(256)); UserDefaults.standard.set(seen,forKey:"receivedIDs")
        ClipHistory.shared.add(text:m.text,source:"휴대폰")
        lastSync = Date(); send(ack); status("휴대폰에서 복사됨")
    }
    private func startClipboardMonitor() {
        clipboardTimer?.invalidate(); lastChange = NSPasteboard.general.changeCount
        // macOS has no general pasteboard notification. Monitor only on Mac while sharing/history is enabled.
        let timer = Timer(timeInterval:0.6,repeats:true) { [weak self] _ in self?.checkClipboard() }
        timer.tolerance = 0.2; RunLoop.main.add(timer,forMode:.common); clipboardTimer = timer
    }
    private func checkClipboard() {
        guard !locked,!sleeping,(enabled || ClipHistory.shared.enabled) else { return }
        let p = NSPasteboard.general
        guard p.changeCount != lastChange else { return }; lastChange = p.changeCount
        // Honor common password-manager markers; there is no universal sensitivity flag on macOS.
        let privateTypes = ["org.nspasteboard.ConcealedType","org.nspasteboard.TransientType","org.nspasteboard.AutoGeneratedType"]
        guard !privateTypes.contains(where:{p.types?.contains(NSPasteboard.PasteboardType($0)) == true}),
              true else { return }
        if p.types?.contains(.png)==true || p.types?.contains(.tiff)==true {
            guard let image=NSImage(pasteboard:p)else{return}
            do{let bytes=try ClipHistory.png(image);let dir=FileManager.default.temporaryDirectory.appendingPathComponent("CoolSyncClipboard",isDirectory:true);try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700]);let url=dir.appendingPathComponent(UUID().uuidString+".png");try bytes.write(to:url);ClipHistory.shared.add(image:url,source:"Mac");let time=Int64(Date().timeIntervalSince1970*1000);versionTime=time;versionID="image";pending=nil;ackTask?.cancel();if authenticated{imageCopied?(url,time)}else{try? FileManager.default.removeItem(at:url)}}catch{status("이미지는 20 MB, 1600만 화소 이하만 공유합니다")};return
        }
        guard let text=p.string(forType:.string),!text.isEmpty else{return}
        guard text.utf8.count <= Wire.maxText else { status("16 KiB를 넘는 텍스트는 보내지 않습니다"); return }
        ClipHistory.shared.add(text:text,source:"Mac")
        guard authenticated else{return}
        var m = Wire.Message(type:"clip"); m.text = text; pending = m; retries = 0; versionTime = m.time; versionID = m.id
        ackTask?.cancel(); send(m)
    }
    func canApplyImage(_ time:Int64)->Bool{authenticated && !locked && time>=versionTime && abs(Date().timeIntervalSince1970*1000-Double(time))<120000}
    func applyImage(_ url:URL,time:Int64){
        checkClipboard()
        guard canApplyImage(time),let image=NSImage(contentsOf:url),let data=try? ClipHistory.png(image)else{status("이미지를 적용하지 못했거나 더 최신 복사가 있습니다");return}
        let p=NSPasteboard.general;p.clearContents();guard p.setData(data,forType:.png)else{return};if let tiff=image.tiffRepresentation{p.setData(tiff,forType:.tiff)};lastChange=p.changeCount;versionTime=time;versionID="image";pending=nil;ackTask?.cancel();ClipHistory.shared.add(image:url,source:"휴대폰");lastSync=Date();status("휴대폰에서 이미지 복사됨")
    }
    private func awaitAck(_ message: Wire.Message,retry: Bool) {
        let token = session
        let task = DispatchWorkItem { [weak self] in
            guard let self, self.session == token, self.pending?.id == message.id else { return }
            if retry { self.retries = 1; self.send(message) }
            else { self.pending = nil; self.status("전송 확인 실패 · 다음 복사 때 재시도") }
        }
        ackTask = task; DispatchQueue.main.asyncAfter(deadline:.now()+8,execute:task)
    }
}

