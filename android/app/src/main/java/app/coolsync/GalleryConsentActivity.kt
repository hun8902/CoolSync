package app.coolsync

import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.provider.MediaStore
import android.content.ContentUris
import org.json.JSONObject

/** System MediaStore trash changes always use Android's own on-phone consent sheet. */
object GalleryConsent {
    private fun prefs(c:Context)=c.getSharedPreferences("gallery-consent",0)
    private fun key(c:Context)=Protocol.key(c)?.let{java.security.MessageDigest.getInstance("SHA-256").digest(it).joinToString(""){b->"%02x".format(b)}} ?: ""
    fun request(c:Context,q:JSONObject,out:JSONObject){
        val action=q.getString("action");require(action in setOf("restore","delete"))
        val values=q.getJSONArray("ids");require(values.length() in 1..1000)
        val ids=(0 until values.length()).map{values.getString(it).removePrefix("native:").toLong().also{id->require(id>=0)}}.distinct()
        val p=prefs(c);if(p.getLong("expires",0)>System.currentTimeMillis())throw StorageFault("busy","휴대폰에서 이전 사진 작업을 먼저 승인하거나 취소하세요")
        p.edit().clear().putString("action",action).putString("ids",ids.joinToString(",")).putString("key",key(c)).putLong("expires",System.currentTimeMillis()+120000).commit()
        val manager=c.getSystemService(NotificationManager::class.java);manager.createNotificationChannel(NotificationChannel("gallery-actions","사진 작업 승인",NotificationManager.IMPORTANCE_DEFAULT))
        val intent=PendingIntent.getActivity(c,72,Intent(c,GalleryConsentActivity::class.java),PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        manager.notify(72,Notification.Builder(c,"gallery-actions").setSmallIcon(R.drawable.notification_icon).setContentTitle("Mac에서 사진 ${if(action=="restore")"복원" else "영구 삭제"} 요청").setContentText("눌러서 Android 확인 화면을 여세요").setContentIntent(intent).setAutoCancel(true).build())
        out.put("pending",true).put("message","휴대폰에서 CoolSync를 열거나 사진 작업 알림을 눌러 승인하세요")
    }
    fun launchPending(activity:Activity){val p=prefs(activity);if(valid(activity) && !p.getBoolean("launched",false)){activity.startActivity(Intent(activity,GalleryConsentActivity::class.java))}}
    fun valid(c:Context):Boolean{val p=prefs(c);return p.getLong("expires",0)>System.currentTimeMillis() && p.getString("key","")==key(c) && key(c).isNotEmpty()}
    fun launch(activity:Activity){require(valid(activity)){"사진 요청이 만료됐습니다"};val p=prefs(activity);p.edit().putBoolean("launched",true).commit();val uris=p.getString("ids","")!!.split(',').map{ContentUris.withAppendedId(MediaStore.Files.getContentUri("external"),it.toLong())};val pending=if(p.getString("action","")=="restore")MediaStore.createTrashRequest(activity.contentResolver,uris,false)else MediaStore.createDeleteRequest(activity.contentResolver,uris);activity.startIntentSenderForResult(pending.intentSender,72,null,0,0,0)}
    fun finish(c:Context,success:Boolean){prefs(c).edit().clear().apply();c.getSystemService(NotificationManager::class.java).cancel(72);SyncService.active?.takeIf{it.authenticated}?.sendControl("galleryChanged",JSONObject().put("ok",success).toString(),"")}
}
class GalleryConsentActivity:Activity(){
    override fun onCreate(state:Bundle?){super.onCreate(state);if(state==null)try{GalleryConsent.launch(this)}catch(e:Exception){android.widget.Toast.makeText(this,e.message ?: "사진 작업을 시작하지 못했습니다",android.widget.Toast.LENGTH_LONG).show();GalleryConsent.finish(this,false);finish()}}
    @Deprecated("Android consent result callback")
    override fun onActivityResult(requestCode:Int,resultCode:Int,data:Intent?){super.onActivityResult(requestCode,resultCode,data);if(requestCode==72){GalleryConsent.finish(this,resultCode==RESULT_OK);finish()}}
}
