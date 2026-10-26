package app.coolsync

import android.content.Context
import android.net.Uri
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import android.util.Base64
import org.json.JSONObject
import java.io.*
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.UUID
import java.util.concurrent.Executors
import android.os.Handler
import android.os.Looper
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/** Wi-Fi is used only for explicit file transfers. No polling, discovery, cloud, or wake lock. */
object FilesBridge {
    const val LIMIT = 268435456L
    var offer: JSONObject? = null; private set
    var selected: Uri? = null; private set
    var destination: Uri? = null; private set
    var progress = 0; private set
    var busy = false; private set
    var summary = "보낼 파일을 선택하세요"; private set
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    @Volatile private var epoch = 0
    @Volatile private var socket: Socket? = null
    private var expiry: Runnable? = null
    private var managedUpload: StorageBridge.Upload? = null
    private fun state(c: Context, text: String) { main.post { summary=text; SyncService.active?.publish(text); c.sendBroadcast(android.content.Intent(SyncService.STATE).setPackage(c.packageName)) } }
    fun cancel() {
        if(!busy) managedUpload?.temporary?.delete()
        managedUpload=null
        epoch++; try { socket?.close() } catch (_: Exception) {}; socket=null
        expiry?.let(main::removeCallbacks); expiry=null
        offer=null; selected=null; destination=null; progress=0; busy=false; summary="전송 취소됨"
    }
    private fun arm(c: Context) {
        expiry?.let(main::removeCallbacks)
        expiry=Runnable { if(!busy) { cancel(); state(c,"파일 요청이 만료됐습니다") } }.also { main.postDelayed(it,120000) }
    }
    fun select(c: Context, uri: Uri, remotePath: String? = null) {
        if(SyncService.active?.authenticated != true) { state(c,"Mac에 먼저 연결하세요"); return }
        cancel(); selected=uri; busy=true; val generation=epoch
        state(c,"파일 확인 중")
        worker.execute {
            try {
                var name="공유 파일"
                if(uri.scheme=="file") name=java.io.File(uri.path!!).name else c.contentResolver.query(uri,arrayOf(OpenableColumns.DISPLAY_NAME),null,null,null)?.use { if(it.moveToFirst()) name=it.getString(0).take(180) }
                val digest=MessageDigest.getInstance("SHA-256"); var size=0L
                c.contentResolver.openInputStream(uri)!!.use { input ->
                    val buffer=ByteArray(65536)
                    while(true) { if(epoch!=generation) return@execute; val n=input.read(buffer); if(n<0) break; size+=n; require(size<=LIMIT) { "파일은 256 MB 이하만 보낼 수 있습니다" }; digest.update(buffer,0,n) }
                }
                val meta=JSONObject().put("id",UUID.randomUUID().toString()).put("name",name).put("size",size).put("sha",digest.digest().joinToString("") { "%02x".format(it) }).put("flow","upload")
                if(remotePath!=null) meta.put("remote",remotePath)
                main.post { if(epoch==generation) { offer=meta; busy=false; SyncService.active?.sendControl("fileOffer",meta.toString(),meta.getString("id")); arm(c); state(c,"Mac에서 수신을 승인해 주세요") } }
            } catch(e: Exception) { main.post { if(epoch==generation) { busy=false; state(c,e.message ?: "파일을 읽지 못했습니다") } } }
        }
    }
    fun handle(c: Context, message: JSONObject) {
        when(message.optString("type")) {
            "fileOffer" -> {
                if(busy || offer!=null) { SyncService.active?.sendControl("fileReject",ref=message.optString("ref")); return }
                try {
                    val m=JSONObject(message.getString("text")); require(m.getString("flow")=="download" && m.getLong("size") in 0..LIMIT && m.getString("sha").matches(Regex("[a-f0-9]{64}")))
                    if(m.has("path") && !m.isNull("path")) {
                        val upload=StorageBridge.prepareUpload(c,m.getString("path"),m.getString("name"))
                        managedUpload=upload; offer=m; destination=Uri.fromFile(upload.temporary); arm(c)
                        SyncService.active?.sendControl("fileAccept",ref=m.getString("id")); state(c,"Mac에서 파일 저장 중"); return
                    }
                    offer=m; state(c,"${m.getString("name")} · 수신 대기"); arm(c)
                    val open=android.app.PendingIntent.getActivity(c,20,android.content.Intent(c,MainActivity::class.java),android.app.PendingIntent.FLAG_IMMUTABLE or android.app.PendingIntent.FLAG_UPDATE_CURRENT)
                    val manager=c.getSystemService(android.app.NotificationManager::class.java)
                    manager.createNotificationChannel(android.app.NotificationChannel("files","파일 수신",android.app.NotificationManager.IMPORTANCE_DEFAULT))
                    manager.notify(20,android.app.Notification.Builder(c,"files").setSmallIcon(R.drawable.notification_icon).setContentTitle("Mac에서 파일을 보냈습니다").setContentText(m.getString("name")).setContentIntent(open).setAutoCancel(true).build())
                } catch (e: Exception) { SyncService.active?.sendControl("fileReject",text=e.message ?: "파일을 저장하지 못했습니다",ref=message.optString("ref")); state(c,e.message ?: "올바르지 않은 파일 요청입니다") }
            }
            "fileReady" -> {
                val m=offer ?: return
                if(message.optString("ref")!=m.optString("id") || busy) return
                if(m.optString("flow")=="download" && destination==null) return
                val generation=epoch
                expiry?.let(main::removeCallbacks); busy=true; progress=0
                worker.execute { transfer(c,m,JSONObject(message.getString("text")),generation) }
            }
            "fileReject" -> { cancel(); state(c,"상대 기기에서 전송을 취소했습니다") }
        }
    }
    fun accept(c: Context, uri: Uri) { val m=offer ?: return; destination=uri; SyncService.active?.sendControl("fileAccept",ref=m.getString("id")); state(c,"파일 연결 준비 중"); arm(c) }
    fun reject(c: Context) { offer?.let { SyncService.active?.sendControl("fileReject",ref=it.optString("id")) }; cancel(); c.getSystemService(android.app.NotificationManager::class.java).cancel(20); state(c,"파일 요청을 거절했습니다") }
    private fun transfer(c: Context, meta: JSONObject, endpoint: JSONObject, generation: Int) {
        var success=false
        val target=destination
        val managed=managedUpload
        try {
            val key=Protocol.key(c) ?: error("연결 키가 없습니다")
            val id=meta.getString("id"); val size=meta.getLong("size"); val token=endpoint.getString("token")
            var connected: Socket?=null
            val hosts=endpoint.getJSONArray("hosts"); val port=endpoint.getInt("port"); require(port in 1..65535)
            for(i in 0 until hosts.length().coerceAtMost(8)) {
                if(epoch!=generation) error("전송 취소됨")
                val address=InetAddress.getByName(hosts.getString(i))
                require(address.isSiteLocalAddress || address.isLinkLocalAddress) { "로컬 네트워크 주소가 아닙니다" }
                val s=Socket(); socket=s
                try { s.connect(InetSocketAddress(address,port),3000); s.soTimeout=30000; connected=s; break } catch (_: Exception) { s.close() }
            }
            val s=connected ?: error("같은 Wi-Fi에 연결했는지 확인하세요")
            s.use {
                val input=DataInputStream(BufferedInputStream(s.getInputStream())); val output=DataOutputStream(BufferedOutputStream(s.getOutputStream()))
                writeFrame(output,Protocol.seal(key,Protocol.message("fileAuth",token,id)).dropLast(1).toByteArray())
                val start=Protocol.open(key,readFrame(input)); require(start.optString("type")=="fileStart" && start.optString("ref")==id)
                var total=0L; var index=0; var lastUi=0L; val hash=MessageDigest.getInstance("SHA-256")
                fun update(n: Int) {
                    total+=n; require(total<=size && total<=LIMIT)
                    val now=android.os.SystemClock.elapsedRealtime()
                    if(now-lastUi>200 || total==size) { lastUi=now; progress=if(size==0L) 100 else (total*100/size).toInt(); state(c,"파일 전송 중 · $progress%") }
                }
                if(meta.getString("flow")=="upload") {
                    c.contentResolver.openInputStream(selected ?: error("선택한 파일이 없습니다"))!!.use { source ->
                        val buffer=ByteArray(65536)
                        while(true) { if(epoch!=generation) error("전송 취소됨"); val n=source.read(buffer); if(n<0) break; hash.update(buffer,0,n); update(n); writeFrame(output,crypt(true,key,id,index++,buffer.copyOf(n))) }
                    }
                    require(total==size && hash.digest().joinToString("") { "%02x".format(it) }==meta.getString("sha")) { "전송 중 원본 파일이 변경됐습니다" }
                    val done=Protocol.open(key,readFrame(input)); require(done.optString("type")=="fileDone" && done.optString("ref")==id)
                } else {
                    c.contentResolver.openOutputStream(target ?: error("저장 위치가 없습니다"),"wt")!!.use { sink ->
                        while(total<size) { if(epoch!=generation) error("전송 취소됨"); val clear=crypt(false,key,id,index++,readFrame(input)); require(clear.isNotEmpty() && clear.size<=65536); update(clear.size); hash.update(clear); sink.write(clear) }
                    }
                    require(hash.digest().joinToString("") { "%02x".format(it) }==meta.getString("sha")) { "파일 무결성 확인에 실패했습니다" }
                    if(managed!=null) { require(!managed.final.exists() && managed.temporary.renameTo(managed.final)) { "파일을 저장하지 못했습니다" } }
                    writeFrame(output,Protocol.seal(key,Protocol.message("fileDone",ref=id)).dropLast(1).toByteArray())
                }
                success=true
            }
            if(epoch==generation) state(c,"${meta.getString("name")} · 전송 완료")
        } catch(e: Exception) { if(epoch==generation) state(c,e.message ?: "파일 전송 실패") }
        finally {
            if(!success && target!=null) { if(managed!=null) managed.temporary.delete() else try { DocumentsContract.deleteDocument(c.contentResolver,target) } catch (_: Exception) {} }
            if(epoch==generation) main.post { if(epoch!=generation) return@post; socket=null; busy=false; offer=null; selected=null; destination=null; managedUpload=null; progress=if(success) 100 else 0; c.sendBroadcast(android.content.Intent(SyncService.STATE).setPackage(c.packageName)) }
        }
    }
    private fun writeFrame(output: DataOutputStream, bytes: ByteArray) { require(bytes.size in 1..100000); output.writeInt(bytes.size); output.write(bytes); output.flush() }
    private fun readFrame(input: DataInputStream): ByteArray { val size=input.readInt(); require(size in 1..100000); return ByteArray(size).also { input.readFully(it) } }
    private fun crypt(encrypt: Boolean, key: ByteArray, id: String, index: Int, data: ByteArray): ByteArray {
        val cipher=Cipher.getInstance("AES/GCM/NoPadding")
        val nonce=if(encrypt) ByteArray(12).also { SecureRandom().nextBytes(it) } else data.copyOfRange(0,12)
        cipher.init(if(encrypt) Cipher.ENCRYPT_MODE else Cipher.DECRYPT_MODE,SecretKeySpec(key,"AES"),GCMParameterSpec(128,nonce)); cipher.updateAAD("CoolSync/file/1|$id|$index".toByteArray())
        val clear=cipher.doFinal(if(encrypt) data else data.copyOfRange(12,data.size))
        return if(encrypt) nonce+clear else clear
    }
}
