package app.coolsync

import android.Manifest
import android.app.*
import android.bluetooth.*
import android.bluetooth.le.*
import android.content.*
import android.content.pm.PackageManager
import android.os.*
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.util.UUID

@Suppress("MissingPermission", "DEPRECATION")
class SyncService : Service() {
    companion object { var active: SyncService? = null; private set
        const val STATE = "app.coolsync.STATE" }
    private val main = Handler(Looper.getMainLooper())
    private val prefs by lazy { getSharedPreferences("sync",0) }
    private var receiverRegistered = false
    private val mediaChanged=Runnable{if(authenticated)sendControl("mediaChanged")}
    private val mediaObserver=object:android.database.ContentObserver(main){override fun onChange(selfChange:Boolean){getSharedPreferences("gallery",0).edit().putString("syncChange",java.util.UUID.randomUUID().toString()).apply();main.removeCallbacks(mediaChanged);main.postDelayed(mediaChanged,1200)}}
    private var server: BluetoothGattServer? = null
    private var bleGeneration=0
    private var advertiser: BluetoothLeAdvertiser? = null
    private var peer: BluetoothDevice? = null
    private var subscribed = false
    private var pendingHello:JSONObject?=null
    private var handshakeAck=""
    var notificationResult="아직 테스트하지 않았습니다";private set
    private val notificationIconsSent=HashSet<String>()
    private var testNotificationID=""
    private val notificationTimeout=Runnable{if(testNotificationID.isNotEmpty()){testNotificationID="";notificationResult="Mac의 알림 수신 확인이 없습니다. 연결 상태를 확인하세요";update(notificationResult)}}
    private var handshakeStage = "Bluetooth 연결"
    @Volatile var authenticated = false; private set
    var connecting=false;private set
    private var mtu = 23
    var status = "시작 중"; private set
    var peerName = "Mac"; private set
    var lastSync = 0L; private set
    private var tx: BluetoothGattCharacteristic? = null
    private val input = ByteArrayOutputStream()
    private data class Chunk(val bytes: ByteArray, val clipID: String? = null)
    private val chunks = ArrayDeque<Chunk>()
    private var inFlightID: String? = null
    private var sending = false
    private var pending: JSONObject? = null
    private var retries = 0
    private var versionTime = 0L
    private var versionID = ""
    private var lastRemote = ""
    private var suppressRemoteUntil = 0L
    private var lastLocal = ""
    private var lastLocalAt = 0L
    private val seen = LinkedHashSet<String>()
    private val ackTimeout = Runnable {
        val m = pending
        if (m != null && authenticated && retries++ == 0) { send(m) }
        else { pending = null; update("전송 확인 실패 · 다음 복사 때 재시도") }
    }
    private val waitTimeout = Runnable { if(!authenticated) update("Mac을 찾지 못했습니다 · Mac 앱 실행과 Bluetooth 권한을 확인하고 다시 연결하세요") }
    private val linkTimeout = Runnable { failLink("연결 시간 초과 · $handshakeStage 단계에서 응답이 없습니다") }
    private fun failLink(reason: String) { val d=peer; resetPeer(); update(reason); d?.let { server?.cancelConnection(it) }; advertise() }
    private fun authProgress(stage: String) { if(authenticated)return; connecting=true;handshakeStage=stage; main.removeCallbacks(linkTimeout); main.postDelayed(linkTimeout,30000); update("Mac 연결 중 · $stage") }
    private val sendTimeout = Runnable { peer?.let { server?.cancelConnection(it) }; resetPeer(); advertise(); update("연결 복구 대기") }
    private val advert = object : AdvertiseCallback() {
        override fun onStartSuccess(settings: AdvertiseSettings?) { main.post { if(peer==null && prefs.getString("connectionIssue",null)==null) { connecting=true;update("Mac 연결 대기 · Mac에서 CoolSync를 열어주세요"); main.removeCallbacks(waitTimeout); main.postDelayed(waitTimeout,30000) } } }
        override fun onStartFailure(code: Int) { main.post { if (code != ADVERTISE_FAILED_ALREADY_STARTED) update(when(code){ADVERTISE_FAILED_TOO_MANY_ADVERTISERS->"BLE 광고 실패 · 사용 중인 Bluetooth 앱을 닫고 다시 연결하세요";ADVERTISE_FAILED_FEATURE_UNSUPPORTED->"BLE 광고 미지원 · 이 기기의 Bluetooth 기능을 확인하세요";else->"BLE 광고 실패 ($code) · Bluetooth를 껐다 켜고 다시 연결하세요"}) } }
    }
    private val bluetoothReceiver = object : BroadcastReceiver() {
        override fun onReceive(c: Context?, i: Intent?) {
            when(i?.getIntExtra(BluetoothAdapter.EXTRA_STATE,-1)) {
                BluetoothAdapter.STATE_OFF -> { closeBle(); update("블루투스 꺼짐") }
                BluetoothAdapter.STATE_ON -> openBle()
            }
        }
    }
    private fun callback(epoch:Int) = object : BluetoothGattServerCallback() {
        override fun onServiceAdded(status: Int, service: BluetoothGattService?) { main.post { if(epoch!=bleGeneration)return@post; if(status == BluetoothGatt.GATT_SUCCESS) advertise() else update("BLE 서비스 생성 실패") } }
        override fun onConnectionStateChange(d: BluetoothDevice, status: Int, state: Int) { main.post { if(epoch!=bleGeneration)return@post;
            if (state == BluetoothProfile.STATE_CONNECTED) {
                if (peer != null && peer != d) { server?.cancelConnection(d); return@post }
                resetPeer(); peer = d; main.removeCallbacks(waitTimeout); authProgress("응답 채널 설정")
            } else if (peer == d) { resetPeer(); advertise(); update(prefs.getString("connectionIssue",null) ?: "Mac 연결 대기") }
        } }
        override fun onMtuChanged(d: BluetoothDevice, value: Int) { main.post { if(epoch!=bleGeneration)return@post; if(peer == d) mtu = value.coerceIn(23,517) } }
        override fun onDescriptorReadRequest(d: BluetoothDevice, id: Int, offset: Int, desc: BluetoothGattDescriptor) {
            main.post { if(epoch!=bleGeneration)return@post; server?.sendResponse(d,id,if(offset == 0) BluetoothGatt.GATT_SUCCESS else BluetoothGatt.GATT_INVALID_OFFSET,offset,if(subscribed) BluetoothGattDescriptor.ENABLE_INDICATION_VALUE else BluetoothGattDescriptor.DISABLE_NOTIFICATION_VALUE) }
        }
        override fun onDescriptorWriteRequest(d: BluetoothDevice, id: Int, desc: BluetoothGattDescriptor, prepared: Boolean, response: Boolean, offset: Int, value: ByteArray) { main.post { if(epoch!=bleGeneration)return@post;
            val valid = peer == d && desc.uuid.toString() == Protocol.CCC && !prepared && offset == 0 && value.contentEquals(BluetoothGattDescriptor.ENABLE_INDICATION_VALUE)
            if(valid) { subscribed = true; authProgress("Mac 인증 요청 대기") }
            if(response) server?.sendResponse(d,id,if(valid) BluetoothGatt.GATT_SUCCESS else BluetoothGatt.GATT_REQUEST_NOT_SUPPORTED,0,null)
            if(valid)pendingHello?.let{pendingHello=null;handle(it)}
        } }
        override fun onCharacteristicWriteRequest(d: BluetoothDevice, id: Int, characteristic: BluetoothGattCharacteristic, prepared: Boolean, response: Boolean, offset: Int, value: ByteArray) { main.post { if(epoch!=bleGeneration)return@post;
            val valid = peer == d && characteristic.uuid.toString() == Protocol.RX && !prepared && offset == 0 && value.size <= 514
            if(response) server?.sendResponse(d,id,if(valid) BluetoothGatt.GATT_SUCCESS else BluetoothGatt.GATT_REQUEST_NOT_SUPPORTED,0,null)
            if(valid) { authProgress("인증 요청 수신"); receive(value) }
        } }
        override fun onNotificationSent(d: BluetoothDevice, result: Int) { main.post { if(epoch!=bleGeneration)return@post;
            if (peer != d) return@post
            main.removeCallbacks(sendTimeout)
            if(result != BluetoothGatt.GATT_SUCCESS) { sendTimeout.run(); return@post }
            if(inFlightID != null && pending?.optString("id") == inFlightID) { main.removeCallbacks(ackTimeout); main.postDelayed(ackTimeout,8000) }
            inFlightID = null; sending = false; pump()
        } }
    }
    override fun onCreate() {
        super.onCreate()
        if(checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) != PackageManager.PERMISSION_GRANTED || checkSelfPermission(Manifest.permission.BLUETOOTH_ADVERTISE) != PackageManager.PERMISSION_GRANTED) { stopSelf(); return }
        active = this
        // Gallery restore notifications can use image/video or per-volume URIs.
        val mediaVolumes=runCatching{android.provider.MediaStore.getExternalVolumeNames(this)}.getOrDefault(emptySet())+"external"
        for(volume in mediaVolumes){
            val uris=listOf(android.provider.MediaStore.Files.getContentUri(volume),android.provider.MediaStore.Images.Media.getContentUri(volume),android.provider.MediaStore.Video.Media.getContentUri(volume))
            for(uri in uris)runCatching{contentResolver.registerContentObserver(uri,true,mediaObserver)}
        }
        seen.addAll(prefs.getStringSet("seen",emptySet()) ?: emptySet())
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(NotificationChannel("sync","CoolSync 연결",NotificationManager.IMPORTANCE_LOW))
        startForeground(1,notification("Mac 연결 대기"))
        registerReceiver(bluetoothReceiver,IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED)); receiverRegistered = true
    }
    override fun onStartCommand(i: Intent?, flags: Int, id: Int): Int {
        if(i?.action == "stop") { prefs.edit().putBoolean("enabled",false).apply(); stopSelf(); return START_NOT_STICKY }
        if(!prefs.getBoolean("enabled",false) || Protocol.key(this) == null || checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) != PackageManager.PERMISSION_GRANTED || checkSelfPermission(Manifest.permission.BLUETOOTH_ADVERTISE) != PackageManager.PERMISSION_GRANTED) { stopSelf(); return START_NOT_STICKY }
        if(server == null) openBle()
        return START_STICKY
    }
    private fun openBle() {
        closeBle()
        try {
            val manager = getSystemService(BluetoothManager::class.java)
            if(manager.adapter?.isEnabled != true) { update("블루투스를 켜주세요"); return }
            advertiser = manager.adapter.bluetoothLeAdvertiser
            if(advertiser == null) { update("이 기기는 BLE 광고를 지원하지 않습니다"); return }
            server = manager.openGattServer(this,callback(bleGeneration))
            if(server==null){update("BLE 서비스 시작 실패 · Bluetooth를 껐다 켜고 다시 연결하세요");return}
            val s = BluetoothGattService(UUID.fromString(Protocol.SERVICE),BluetoothGattService.SERVICE_TYPE_PRIMARY)
            s.addCharacteristic(BluetoothGattCharacteristic(UUID.fromString(Protocol.RX),BluetoothGattCharacteristic.PROPERTY_WRITE,BluetoothGattCharacteristic.PERMISSION_WRITE))
            tx = BluetoothGattCharacteristic(UUID.fromString(Protocol.TX),BluetoothGattCharacteristic.PROPERTY_INDICATE,0).apply {
                addDescriptor(BluetoothGattDescriptor(UUID.fromString(Protocol.CCC),BluetoothGattDescriptor.PERMISSION_READ or BluetoothGattDescriptor.PERMISSION_WRITE))
            }
            s.addCharacteristic(tx); server?.addService(s)
        } catch (_: Exception) { update("블루투스 초기화 실패 · 권한을 확인하세요") }
    }
    private fun advertise() {
        if(!prefs.getBoolean("enabled",false) || authenticated) return
        try {
            val identity=java.security.MessageDigest.getInstance("SHA-256").digest(Protocol.key(this) ?: return).copyOf(8)
            advertiser?.startAdvertising(AdvertiseSettings.Builder().setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_POWER).setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_LOW).setConnectable(true).setTimeout(0).build(),AdvertiseData.Builder().addServiceUuid(ParcelUuid(UUID.fromString(Protocol.SERVICE))).setIncludeDeviceName(false).build(),AdvertiseData.Builder().addServiceData(ParcelUuid(UUID.fromString(Protocol.SERVICE)),identity).build(),advert)
        } catch (_: Exception) { update("광고를 시작하지 못했습니다") }
    }
    private fun notification(text: String): Notification {
        val open = PendingIntent.getActivity(this,0,Intent(this,MainActivity::class.java),PendingIntent.FLAG_IMMUTABLE)
        val stop = PendingIntent.getService(this,1,Intent(this,SyncService::class.java).setAction("stop"),PendingIntent.FLAG_IMMUTABLE)
        return Notification.Builder(this,"sync").setSmallIcon(R.drawable.notification_icon).setContentTitle("CoolSync").setContentText(text).setContentIntent(open).setOngoing(true).addAction(Notification.Action.Builder(null,"중지",stop).build()).build()
    }
    fun publish(s: String) { update(s) }
    private fun update(s: String) {
        status = s
        if(listOf("실패","시간 초과","못했습니다","미지원","꺼짐","켜주세요").any{s.contains(it)})prefs.edit().putString("connectionIssue",s).apply()
        if(authenticated)prefs.edit().remove("connectionIssue").apply()
        getSystemService(NotificationManager::class.java).notify(1,notification(s))
        sendBroadcast(Intent(STATE).setPackage(packageName))
    }
    fun sendControl(type: String, text: String = "", ref: String = "") {
        main.post { if(authenticated) send(Protocol.message(type,text,ref)) }
    }
    fun sendPhoneNotification(packageName:String,app:String,title:String,body:String,icon:String){main.post{
        if(!authenticated)return@post
        val payload=JSONObject().put("package",packageName).put("app",app).put("title",title).put("body",body)
        if(icon.isNotEmpty() && notificationIconsSent.add(packageName))payload.put("icon",icon)
        send(Protocol.message("phoneNotification",payload.toString()))
    }}
    fun sendInboxEntry(row:JSONObject){main.post{
        if(!authenticated)return@post
        if(!MessageInbox.allowed(this,row))return@post
        val payload=MessageInbox.shared(this,row);val packageName=payload.optString("package")
        if(payload.has("icon")&&!notificationIconsSent.add(packageName))payload.remove("icon")
        send(Protocol.message("phoneNotification",payload.toString()))
    }}
    private val inboxWorker=java.util.concurrent.Executors.newSingleThreadExecutor()
    fun testNotification(){main.post{
        if(!authenticated)return@post
        val text=JSONObject().put("app","CoolSync").put("title","푸시 알림 테스트").put("body","휴대폰에서 보낸 테스트 알림입니다.").toString()
        val m=Protocol.message("phoneNotification",text);testNotificationID=m.getString("id");notificationResult="Mac 알림 수신 확인 중…";main.removeCallbacks(notificationTimeout);main.postDelayed(notificationTimeout,20000);send(m);update(notificationResult)
    }}
    private fun receive(bytes: ByteArray) {
        for(b in bytes) {
            if(b == 10.toByte()) {
                val frame = input.toByteArray(); input.reset()
                try { val key = Protocol.key(this) ?: return; handle(Protocol.open(key,frame)) } catch (_: Exception) { failLink("인증 실패 · Mac의 현재 QR로 다시 연결하고 두 기기의 자동 날짜·시간을 확인하세요"); return }
            } else {
                if(input.size() >= Protocol.MAX_FRAME) { sendTimeout.run(); return }
                input.write(b.toInt())
            }
        }
    }
    private fun handle(m: JSONObject) {
        val type = m.getString("type"); val id = m.getString("id")
        if(type=="hello" && !subscribed){pendingHello=m;return}
        if(type == "hello" && subscribed) {
            val confirm = runCatching { JSONObject(m.optString("text")).optBoolean("confirm") }.getOrDefault(false)
            authenticated = false; main.removeCallbacks(waitTimeout); authProgress("Mac의 최종 연결 확인 대기")
            peerName = try { JSONObject(m.optString("text")).optString("name","Mac").take(80) } catch (_: Exception) { "Mac" }
            val info = JSONObject().put("mtu",(mtu-3).coerceIn(20,180)).put("name", runCatching { android.provider.Settings.Global.getString(contentResolver,"device_name") }.getOrNull() ?: Build.MODEL).put("model",Build.MODEL).put("android",Build.VERSION.RELEASE).put("confirm",confirm)
            val ack=Protocol.message("helloAck",text=info.toString(),ref=id);handshakeAck=ack.getString("id");send(ack)
            if(!confirm){authenticated=true;connecting=false;main.removeCallbacks(linkTimeout);advertiser?.stopAdvertising(advert);update("Mac 연결됨 · 복사 대기")}
            return
        }
        if(type=="ready" && handshakeAck.isNotEmpty() && m.optString("ref")==handshakeAck){
            authenticated=true;connecting=false;main.removeCallbacks(linkTimeout);main.removeCallbacks(waitTimeout);advertiser?.stopAdvertising(advert)
            send(Protocol.message("readyAck",ref=id));update("Mac 연결됨 · 복사 대기");return
        }
        if(!authenticated) return
        if(type=="notificationHistory"){
            val request=runCatching{JSONObject(m.optString("text"))}.getOrDefault(JSONObject())
            val sessionKey=Protocol.key(this)?.clone()
            inboxWorker.execute{
                val page=runCatching{MessageInbox.page(this,request.optInt("offset"))}.getOrElse{JSONObject().put("error","알림함을 읽지 못했습니다")}
                main.post{if(authenticated && sessionKey!=null && sessionKey.contentEquals(Protocol.key(this) ?: byteArrayOf()))send(Protocol.message("notificationHistoryPage",page.toString(),id))}
            };return
        }
        if(type=="notificationAck"){
            notificationResult=m.optString("text","Mac 알림 처리 결과 없음")
            if(m.optString("ref")==testNotificationID){testNotificationID="";main.removeCallbacks(notificationTimeout)}
            update(notificationResult);return
        }
        if(type=="fsRequest") { StorageBridge.handle(this,m); return }
        if(type.startsWith("file")) { FilesBridge.handle(this,m); return }
        if(type == "ack" && m.optString("ref") == pending?.optString("id")) {
            lastSync = System.currentTimeMillis(); pending = null; main.removeCallbacks(ackTimeout); update(when(m.optString("status")) { "ok" -> "Mac에 복사됨"; "superseded" -> "Mac의 최신 복사 유지"; else -> "Mac에서 반영하지 못했습니다" }); return
        }
        if(type != "clip") return
        if(seen.contains(id)) { send(Protocol.message("ack",ref=id).put("status","ok")); return }
        val text = m.getString("text")
        if(text.toByteArray().size > Protocol.MAX_TEXT || locked()) { send(Protocol.message("ack",ref=id).put("status","rejected")); return }
        val time = m.getLong("time")
        if(time < versionTime || (time == versionTime && id <= versionID)) {
            send(Protocol.message("ack",ref=id).put("status","superseded")); return
        }
        pending = null; main.removeCallbacks(ackTimeout)
        try {
            val clipboard = getSystemService(android.content.ClipboardManager::class.java)
            val clip = ClipData.newPlainText("CoolSync",text)
            clip.description.extras = PersistableBundle().apply { putBoolean("android.content.extra.IS_SENSITIVE",true) }
            clipboard.setPrimaryClip(clip)
            ClipHistory.text(this,text,"Mac")
            versionTime = time; versionID = id
            lastRemote = text; suppressRemoteUntil = SystemClock.elapsedRealtime() + 5000
            lastSync = System.currentTimeMillis(); remember(id); send(Protocol.message("ack",ref=id).put("status","ok")); update("Mac에서 복사됨")
        } catch (_: Exception) { send(Protocol.message("ack",ref=id).put("status","rejected")) }
    }
    fun locked(): Boolean = getSystemService(KeyguardManager::class.java).isDeviceLocked
    fun localCopy(text: String) {
        if(!authenticated || locked() || text.isEmpty()) return
        if(text.toByteArray().size > Protocol.MAX_TEXT) { update("16 KiB를 넘는 텍스트는 보내지 않습니다"); return }
        val now = SystemClock.elapsedRealtime()
        if((text == lastRemote && now < suppressRemoteUntil) || (text == lastLocal && now-lastLocalAt < 2000)) return
        lastLocal = text; lastLocalAt = now
        ClipHistory.text(this,text,"휴대폰")
        // Supersede older local copies. No offline clipboard is retained.
        pending = Protocol.message("clip",text); retries = 0
        versionTime = pending!!.getLong("time"); versionID = pending!!.getString("id")
        main.removeCallbacks(ackTimeout); send(pending!!)
    }
    fun canApplyImage(time:Long)=authenticated && !locked() && time>=versionTime && kotlin.math.abs(System.currentTimeMillis()-time)<120000
    fun imageApplied(time:Long){versionTime=time;versionID="image";lastSync=System.currentTimeMillis();update("Mac에서 이미지 복사됨")}
    fun localImage(uri:android.net.Uri,record:Boolean=true){
        if(!authenticated||locked())return
        if(FilesBridge.busy||FilesBridge.offer!=null){update("진행 중인 파일 전송을 마친 뒤 이미지를 다시 복사하세요");return}
        FilesBridge.select(this,uri,clipboardImage=true,recordImage=record)
    }
    private fun remember(id: String) { seen.add(id); while(seen.size > 256) seen.remove(seen.first()); prefs.edit().putStringSet("seen",HashSet(seen)).apply() }
    private fun send(m: JSONObject) {
        val d = peer ?: return; if(!subscribed) return
        val key = Protocol.key(this) ?: return
        val bytes = Protocol.seal(key,m)
        if(chunks.sumOf { it.bytes.size } + bytes.size > 280000) { server?.cancelConnection(d); return }
        val split = bytes.asList().chunked((mtu-3).coerceAtMost(180))
        split.forEachIndexed { index, part -> chunks.addLast(Chunk(part.toByteArray(),if(index == split.lastIndex && m.optString("type") == "clip") m.optString("id") else null)) }; pump()
    }
    private fun pump() {
        if(sending || chunks.isEmpty()) return
        val d = peer ?: return; val c = tx ?: return
        val chunk = chunks.removeFirst(); c.value = chunk.bytes; inFlightID = chunk.clipID; sending = true
        if(server?.notifyCharacteristicChanged(d,c,true) != true) { sending = false; sendTimeout.run() }
        else main.postDelayed(sendTimeout,8000)
    }
    private fun resetPeer() {
        GalleryServer.close()
        peer = null; authenticated = false;connecting=false; subscribed = false; pendingHello=null;handshakeAck=""; mtu = 23; pending = null
        input.reset(); chunks.clear(); sending = false; inFlightID = null
        notificationIconsSent.clear();main.removeCallbacks(ackTimeout); main.removeCallbacks(linkTimeout); main.removeCallbacks(sendTimeout);main.removeCallbacks(notificationTimeout);if(testNotificationID.isNotEmpty()){testNotificationID="";notificationResult="연결이 끊겨 테스트를 완료하지 못했습니다"}
    }
    private fun closeBle() {
        bleGeneration++
        try { advertiser?.stopAdvertising(advert); peer?.let { server?.cancelConnection(it) }; server?.close() } catch (_: Exception) {}
        server = null; advertiser = null; resetPeer()
    }
    override fun onDestroy() {
        main.removeCallbacks(mediaChanged);runCatching{contentResolver.unregisterContentObserver(mediaObserver)}; FilesBridge.cancel(); active = null; closeBle(); if(receiverRegistered) unregisterReceiver(bluetoothReceiver); main.removeCallbacksAndMessages(null); sendBroadcast(Intent(STATE).setPackage(packageName)); super.onDestroy() }
    override fun onBind(intent: Intent?) = null
}
