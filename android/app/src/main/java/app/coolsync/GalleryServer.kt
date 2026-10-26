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
 private val acceptor=Executors.newSingleThreadExecutor()
 private val clients=ThreadPoolExecutor(2,2,0L,TimeUnit.SECONDS,ArrayBlockingQueue<Runnable>(8),ThreadPoolExecutor.AbortPolicy())
 @Synchronized fun close(){runCatching{server?.close()};server=null;token=""}
 @Synchronized fun open(service:SyncService):JSONObject{
  if(server==null||server?.isClosed==true){val socket=ServerSocket(0,8);socket.soTimeout=60000;server=socket;token=java.util.UUID.randomUUID().toString()+java.util.UUID.randomUUID().toString();val expected=token
   acceptor.execute{try{while(!socket.isClosed){val client=socket.accept();client.soTimeout=15000;try{clients.execute{serve(service,client,expected)}}catch(_:RejectedExecutionException){client.close()}}}catch(_:Exception){}finally{synchronized(this){if(server===socket)close()};runCatching{socket.close()}}}
  }
  val hosts=java.util.Collections.list(NetworkInterface.getNetworkInterfaces()).sortedBy{when{it.name.startsWith("wlan")->0;it.name.startsWith("eth")->1;else->2}}.flatMap{java.util.Collections.list(it.inetAddresses)}.filter{it is Inet4Address&&(it.isSiteLocalAddress||it.isLinkLocalAddress)&&!it.isLoopbackAddress}.map{it.hostAddress}.distinct().take(8)
  if(hosts.isEmpty()){close();throw StorageFault("wifi","휴대폰과 Mac을 같은 Wi-Fi에 연결하세요")}
  return JSONObject().put("hosts",JSONArray(hosts)).put("port",server!!.localPort).put("token",token)
 }
 private fun serve(service:SyncService,socket:Socket,expected:String){socket.use{try{
  val input=BufferedInputStream(it.getInputStream());val output=it.getOutputStream()
  fun line():String{val out=ByteArrayOutputStream();while(true){val b=input.read();if(b<0)throw EOFException();if(b==10)break;if(b!=13)out.write(b);require(out.size()<4096)};return out.toString("US-ASCII")}
  require(line().startsWith("POST /thumbnail "));var length=0;var headers=0
  while(true){val l=line();if(l.isEmpty())break;require(++headers<=32);if(l.startsWith("Content-Length:",true))length=l.substringAfter(':').trim().toInt()}
  require(length in 1..65536 && SyncService.active===service&&service.authenticated&&expected==token)
  val body=ByteArray(length);DataInputStream(input).readFully(body);val key=Protocol.key(service) ?: error("No key");val message=Protocol.open(key,body);require(message.optString("type")=="mediaThumb");val q=JSONObject(message.getString("text"));require(q.getString("token")==expected)
  val clear=GalleryMedia.thumbnail(service,q.getString("path"));require(service.authenticated&&expected==token)
  val nonce=ByteArray(12).also{SecureRandom().nextBytes(it)};val cipher=Cipher.getInstance("AES/GCM/NoPadding");cipher.init(Cipher.ENCRYPT_MODE,SecretKeySpec(key,"AES"),GCMParameterSpec(128,nonce));cipher.updateAAD("CoolSync/media/1|${message.getString("id")}".toByteArray());val bytes=nonce+cipher.doFinal(clear)
  output.write("HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: ${bytes.size}\r\nConnection: close\r\n\r\n".toByteArray());output.write(bytes);output.flush()
 }catch(_:Exception){runCatching{it.getOutputStream().write("HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".toByteArray())}}}}
}
