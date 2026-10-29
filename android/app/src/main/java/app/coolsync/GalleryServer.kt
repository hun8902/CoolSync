package app.coolsync

import org.json.*
import java.net.*
import java.io.*
import java.security.SecureRandom
import java.util.concurrent.*
import javax.crypto.Cipher
import javax.crypto.spec.*

/** On-demand encrypted thumbnail endpoint. Idle accept closes after 60 seconds. */
object GalleryServer {
 @Volatile private var server:ServerSocket?=null
 @Volatile private var token=""
 private val activeRequests=java.util.concurrent.atomic.AtomicInteger()
 private val acceptor=Executors.newSingleThreadExecutor()
 private val clients=ThreadPoolExecutor(2,2,0L,TimeUnit.SECONDS,ArrayBlockingQueue<Runnable>(8),ThreadPoolExecutor.AbortPolicy())
 @Synchronized fun close(){runCatching{server?.close()};server=null;token=""}
 @Synchronized fun open(service:SyncService):JSONObject{
  if(server==null||server?.isClosed==true){val socket=ServerSocket(0,8);socket.soTimeout=60000;server=socket;token=java.util.UUID.randomUUID().toString()+java.util.UUID.randomUUID().toString();val expected=token
   acceptor.execute{try{while(!socket.isClosed){val client=try{socket.accept()}catch(_:SocketTimeoutException){if(activeRequests.get()==0)break else continue};client.soTimeout=15000;activeRequests.incrementAndGet();try{clients.execute{try{serve(service,client,expected)}finally{activeRequests.decrementAndGet()}}}catch(_:RejectedExecutionException){activeRequests.decrementAndGet();client.close()}}}catch(_:Exception){}finally{synchronized(this){if(server===socket)close()};runCatching{socket.close()}}}
  }
  val hosts=java.util.Collections.list(NetworkInterface.getNetworkInterfaces()).sortedBy{when{it.name.startsWith("wlan")->0;it.name.startsWith("eth")->1;else->2}}.flatMap{java.util.Collections.list(it.inetAddresses)}.filter{it is Inet4Address&&(it.isSiteLocalAddress||it.isLinkLocalAddress)&&!it.isLoopbackAddress}.map{it.hostAddress}.distinct().take(8)
  if(hosts.isEmpty()){close();throw StorageFault("wifi","휴대폰과 Mac을 같은 Wi-Fi에 연결하세요")}
  return JSONObject().put("catalogAPI",1).put("state",state(service)).put("build",service.packageManager.getPackageInfo(service.packageName,0).longVersionCode).put("hosts",JSONArray(hosts)).put("port",server!!.localPort).put("token",token)
 }
 fun state(c:android.content.Context):JSONObject {val power=c.getSystemService(android.os.PowerManager::class.java);return JSONObject().put("interactive",power.isInteractive).put("locked",c.getSystemService(android.app.KeyguardManager::class.java).isDeviceLocked).put("userUnlocked",c.getSystemService(android.os.UserManager::class.java).isUserUnlocked).put("storage",android.os.Environment.isExternalStorageManager()).put("batteryExempt",power.isIgnoringBatteryOptimizations(c.packageName)).put("powerSave",power.isPowerSaveMode).put("build",c.packageManager.getPackageInfo(c.packageName,0).longVersionCode)}
 private fun serve(service:SyncService,socket:Socket,expected:String){val power=TransferPower.acquire(service,timeoutMillis=45000);try{socket.use{try{
  val input=BufferedInputStream(it.getInputStream());val output=it.getOutputStream()
  fun line():String{val out=ByteArrayOutputStream();while(true){val b=input.read();if(b<0)throw EOFException();if(b==10)break;if(b!=13)out.write(b);require(out.size()<4096)};return out.toString("US-ASCII")}
  val request=line();val catalog=request.startsWith("POST /catalog ");require(catalog||request.startsWith("POST /thumbnail "));var length=0;var headers=0
  while(true){val l=line();if(l.isEmpty())break;require(++headers<=32);if(l.startsWith("Content-Length:",true))length=l.substringAfter(':').trim().toInt()}
  require(length in 1..65536 && SyncService.active===service&&service.authenticated&&expected==token)
  val body=ByteArray(length);DataInputStream(input).readFully(body);val key=Protocol.key(service) ?: error("No key");val message=Protocol.open(key,body);require(message.optString("type")==if(catalog)"mediaCatalog"else"mediaThumb");val q=JSONObject(message.getString("text"));require(q.getString("token")==expected)
  val clear=if(catalog){val response=JSONObject().put("ok",true);q.put("fast",true);try{StorageBridge.engine(service);if(q.optString("op")=="galleryState")response.put("state",state(service))else GalleryMedia.list(service,q,response)}catch(e:StorageFault){response.put("ok",false).put("code",e.code).put("error",e.message)}catch(_:SecurityException){response.put("ok",false).put("code","permission").put("error","휴대폰 사진 접근 권한을 확인하세요")}catch(e:Exception){response.put("ok",false).put("code","media").put("error","사진 목록 조회 실패: "+e.javaClass.simpleName)};response.toString().toByteArray()}else GalleryMedia.thumbnail(service,q.getString("path"));require(service.authenticated&&expected==token)
  val nonce=ByteArray(12).also{SecureRandom().nextBytes(it)};val cipher=Cipher.getInstance("AES/GCM/NoPadding");cipher.init(Cipher.ENCRYPT_MODE,SecretKeySpec(key,"AES"),GCMParameterSpec(128,nonce));cipher.updateAAD("CoolSync/media/1|${message.getString("id")}".toByteArray());val bytes=nonce+cipher.doFinal(clear)
  output.write("HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: ${bytes.size}\r\nConnection: close\r\n\r\n".toByteArray());output.write(bytes);output.flush()
 }catch(e:Exception){val code=when(e){is SecurityException->403;is FileNotFoundException->404;is StorageFault->when(e.code){"missing"->404;"permission","setup"->403;"conflict"->409;else->500};else->401};runCatching{it.getOutputStream().write("HTTP/1.1 $code Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".toByteArray())}}}}finally{power.close()}}
}
