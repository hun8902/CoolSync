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
    private var server: BluetoothGattServer? = null
    private var advertiser: BluetoothLeAdvertiser? = null
    private var peer: BluetoothDevice? = null
    private var subscribed = false
    @Volatile var authenticated = false; private set
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
    private val linkTimeout = Runnable { peer?.let { server?.cancelConnection(it) }; resetPeer(); advertise(); update("Mac 인증 시간 초과 · Mac의 현재 QR을 다시 스캔하세요") }
    private val sendTimeout = Runnable { peer?.let { server?.cancelConnection(it) }; resetPeer(); advertise(); update("연결 복구 대기") }
    private val advert = object : AdvertiseCallback() {
        override fun onStartSuccess(settings: AdvertiseSettings?) { main.post { update("Mac 연결 대기 · Mac에서 CoolSync를 열어주세요"); main.removeCallbacks(waitTimeout); main.postDelayed(waitTimeout,30000) } }
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
    private val callback = object : BluetoothGattServerCallback() {
        override fun onServiceAdded(status: Int, service: BluetoothGattService?) { main.post { if(status == BluetoothGatt.GATT_SUCCESS) advertise() else update("BLE 서비스 생성 실패") } }
        override fun onConnectionStateChange(d: BluetoothDevice, status: Int, state: Int) { main.post {
            if (state == BluetoothProfile.STATE_CONNECTED) {
                if (peer != null && peer != d) { server?.cancelConnection(d); return@post }
                resetPeer(); peer = d; main.postDelayed(linkTimeout,15000); update("Mac 인증 중")
            } else if (peer == d) { resetPeer(); advertise(); update("Mac 연결 대기") }
        } }
        override fun onMtuChanged(d: BluetoothDevice, value: Int) { main.post { if(peer == d) mtu = value.coerceIn(23,517) } }
        override fun onDescriptorReadRequest(d: BluetoothDevice, id: Int, offset: Int, desc: BluetoothGattDescriptor) {
            main.post { server?.sendResponse(d,id,if(offset == 0) BluetoothGatt.GATT_SUCCESS else BluetoothGatt.GATT_INVALID_OFFSET,offset,if(subscribed) BluetoothGattDescriptor.ENABLE_INDICATION_VALUE else BluetoothGattDescriptor.DISABLE_NOTIFICATION_VALUE) }
        }
        override fun onDescriptorWriteRequest(d: BluetoothDevice, id: Int, desc: BluetoothGattDescriptor, prepared: Boolean, response: Boolean, offset: Int, value: ByteArray) { main.post {
            val valid = peer == d && desc.uuid.toString() == Protocol.CCC && !prepared && offset == 0 && value.contentEquals(BluetoothGattDescriptor.ENABLE_INDICATION_VALUE)
            if(valid) subscribed = true
            if(response) server?.sendResponse(d,id,if(valid) BluetoothGatt.GATT_SUCCESS else BluetoothGatt.GATT_REQUEST_NOT_SUPPORTED,0,null)
        } }
        override fun onCharacteristicWriteRequest(d: BluetoothDevice, id: Int, characteristic: BluetoothGattCharacteristic, prepared: Boolean, response: Boolean, offset: Int, value: ByteArray) { main.post {
            val valid = peer == d && characteristic.uuid.toString() == Protocol.RX && !prepared && offset == 0 && value.size <= 514
            if(response) server?.sendResponse(d,id,if(valid) BluetoothGatt.GATT_SUCCESS else BluetoothGatt.GATT_REQUEST_NOT_SUPPORTED,0,null)
            if(valid) receive(value)
        } }
        override fun onNotificationSent(d: BluetoothDevice, result: Int) { main.post {
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
            server = manager.openGattServer(this,callback)
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
            advertiser?.startAdvertising(AdvertiseSettings.Builder().setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_POWER).setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_LOW).setConnectable(true).setTimeout(0).build(),AdvertiseData.Builder().addServiceUuid(ParcelUuid(UUID.fromString(Protocol.SERVICE))).setIncludeDeviceName(false).build(),advert)
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
        if(authenticated) send(Protocol.message(type,text,ref))
    }
    private fun receive(bytes: ByteArray) {
        for(b in bytes) {
            if(b == 10.toByte()) {
                val frame = input.toByteArray(); input.reset()
                try { val key = Protocol.key(this) ?: return; handle(Protocol.open(key,frame)) } catch (_: Exception) { update("인증 실패 · 두 기기의 연결 키와 시간을 확인하세요") }
            } else {
                if(input.size() >= Protocol.MAX_FRAME) { sendTimeout.run(); return }
                input.write(b.toInt())
            }
        }
    }
    private fun handle(m: JSONObject) {
        val type = m.getString("type"); val id = m.getString("id")
        if(type == "hello" && subscribed) {
            authenticated = true; main.removeCallbacks(waitTimeout); main.removeCallbacks(linkTimeout); advertiser?.stopAdvertising(advert)
            peerName = try { JSONObject(m.optString("text")).optString("name","Mac").take(80) } catch (_: Exception) { "Mac" }
            val info = JSONObject().put("mtu",(mtu-3).coerceIn(20,180)).put("name", runCatching { android.provider.Settings.Global.getString(contentResolver,"device_name") }.getOrNull() ?: Build.MODEL).put("model",Build.MODEL).put("android",Build.VERSION.RELEASE)
            send(Protocol.message("helloAck",text=info.toString(),ref=id)); update("Mac 연결됨 · 복사 대기"); return
        }
        if(!authenticated) return
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
        peer = null; authenticated = false; subscribed = false; mtu = 23; pending = null
        input.reset(); chunks.clear(); sending = false; inFlightID = null
        main.removeCallbacks(ackTimeout); main.removeCallbacks(linkTimeout); main.removeCallbacks(sendTimeout)
    }
    private fun closeBle() {
        try { advertiser?.stopAdvertising(advert); peer?.let { server?.cancelConnection(it) }; server?.close() } catch (_: Exception) {}
        server = null; advertiser = null; resetPeer()
    }
    override fun onDestroy() { FilesBridge.cancel(); active = null; closeBle(); if(receiverRegistered) unregisterReceiver(bluetoothReceiver); main.removeCallbacksAndMessages(null); sendBroadcast(Intent(STATE).setPackage(packageName)); super.onDestroy() }
    override fun onBind(intent: Intent?) = null
}
