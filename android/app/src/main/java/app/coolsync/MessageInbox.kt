package app.coolsync

import android.Manifest
import android.content.*
import android.content.pm.PackageManager
import android.provider.Telephony
import android.util.AtomicFile
import org.json.*
import java.io.File

/** Bounded local inbox; content never enters diagnostic logs or backups. */
object MessageInbox {
 private fun file(c:Context)=AtomicFile(File(c.filesDir,"message-inbox.json"))
 @Synchronized fun rows(c:Context):List<JSONObject> = runCatching{val a=JSONArray(String(file(c).readFully(),Charsets.UTF_8));(0 until a.length()).map{a.getJSONObject(it)}}.getOrDefault(emptyList())
 @Synchronized fun add(c:Context,row:JSONObject){
  val values=(rows(c).filter{it.optString("eventID")!=row.optString("eventID")}+row).sortedByDescending{it.optString("postedAt").toLongOrNull() ?: 0L}.take(500)
  val f=file(c);val stream=f.startWrite();try{stream.write(JSONArray(values).toString().toByteArray());f.finishWrite(stream)}catch(e:Exception){f.failWrite(stream);throw e}
 }
 fun code(text:String):String?{
  if(!Regex("인증|확인.?코드|일회용|verification|verify|one.time|security code|\\bOTP\\b|\\bcode\\b",RegexOption.IGNORE_CASE).containsMatchIn(text))return null
  return Regex("(?<![0-9])[0-9]{4,8}(?![0-9])").find(text)?.value
 }
 fun hidden(c:Context,row:JSONObject):Boolean=c.getSharedPreferences("sync",0).getBoolean("hideSensitiveNotifications",true)&&(row.optString("sensitive")=="true"||code(row.optString("title")+" "+row.optString("body"))!=null)
 fun shared(c:Context,row:JSONObject):JSONObject=JSONObject(row.toString()).apply{if(hidden(c,row)&&optString("redacted")!="true"){put("title",if(optString("kind")=="sms")optString("title")else "민감한 알림");put("body","민감한 내용이 숨겨져 있습니다");put("redacted","true");if(optString("kind")!="sms"){val hash=java.security.MessageDigest.getInstance("SHA-256").digest(optString("thread").toByteArray()).joinToString(""){"%02x".format(it)};put("thread",optString("package")+":"+hash)}}}
 fun allowed(c:Context,row:JSONObject):Boolean=c.getSharedPreferences("sync",0).getBoolean(if(row.optString("package")=="sms")"forwardSMS"else"forwardNotifications",false)
 fun capture(c:Context,row:JSONObject,live:Boolean=true){if(!allowed(c,row))return;add(c,row);if(live)SyncService.active?.sendInboxEntry(shared(c,row));c.sendBroadcast(Intent(SyncService.STATE).setPackage(c.packageName))}
 fun sms(c:Context,id:String,address:String,body:String,time:Long,live:Boolean=true){capture(c,JSONObject().put("eventID",id).put("kind","sms").put("package","sms").put("app","문자 메시지").put("title",address.take(160)).put("thread","sms:"+address).put("body",body.take(1200)).put("postedAt",time.toString()).put("sensitive",(code(body)!=null).toString()),live)}
 fun importSMS(c:Context):Int{
  if(c.checkSelfPermission(Manifest.permission.READ_SMS)!=PackageManager.PERMISSION_GRANTED)throw SecurityException("문자 읽기 권한이 필요합니다")
  var count=0
  c.contentResolver.query(Telephony.Sms.CONTENT_URI,arrayOf("_id","address","body","date","type"),"type IN (1,2)",null,"date DESC")?.use{cursor->while(cursor.moveToNext()&&count<500){val id=cursor.getString(0);val address=cursor.getString(1) ?: "알 수 없는 발신자";val body=cursor.getString(2) ?: "";val row=JSONObject().put("eventID","sms-db:"+id).put("kind","sms").put("package","sms").put("app","문자 메시지").put("title",address.take(160)).put("thread","sms:"+address).put("body",body.take(1200)).put("postedAt",cursor.getLong(3).toString()).put("outgoing",(cursor.getInt(4)==2).toString()).put("sensitive",(code(body)!=null).toString());add(c,row);count++}}
  return count
 }
 fun page(c:Context,offset:Int):JSONObject{
  val rows=rows(c).filter{allowed(c,it)};val start=offset.coerceIn(0,rows.size);val page=rows.drop(start).take(8).map{shared(c,it)}
  return JSONObject().put("items",JSONArray(page)).put("next",start+page.size).put("total",rows.size)
 }
}
class SmsReceiver:BroadcastReceiver(){
 override fun onReceive(c:Context,intent:Intent){
  if(intent.action!=Telephony.Sms.Intents.SMS_RECEIVED_ACTION||!c.getSharedPreferences("sync",0).getBoolean("forwardSMS",false))return
  val pending=goAsync();Thread{try{val parts=Telephony.Sms.Intents.getMessagesFromIntent(intent);if(parts.isNotEmpty()){val first=parts.first();val address=first.originatingAddress ?: "알 수 없는 발신자";val body=parts.joinToString(""){it.messageBody ?: ""};MessageInbox.sms(c,"sms-live:${first.timestampMillis}:$address",address,body,first.timestampMillis)}}finally{pending.finish()}}.start()
 }
}
