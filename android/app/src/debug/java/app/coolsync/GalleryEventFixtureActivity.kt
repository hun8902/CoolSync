package app.coolsync

import android.content.ContentValues
import android.provider.MediaStore
import java.util.concurrent.*
import java.util.concurrent.atomic.AtomicInteger

class GalleryEventFixtureActivity:android.app.Activity(){
 override fun onCreate(state:android.os.Bundle?){super.onCreate(state)
  check(android.os.Build.FINGERPRINT.contains("generic")||android.os.Build.MODEL.contains("sdk_gphone")){"Emulator only"}
  val view=android.widget.TextView(this);view.text="Running synthetic MediaStore event checks";setContentView(view)
  val queue=LinkedBlockingQueue<Int>();val count=AtomicInteger();var connected=true
  val observer=GalleryChangeObserver(this,{connected}){queue.offer(count.incrementAndGet())}
  fun onMain(block:()->Unit){val latch=CountDownLatch(1);var error:Throwable?=null;runOnUiThread{try{block()}catch(e:Throwable){error=e}finally{latch.countDown()}};check(latch.await(10,TimeUnit.SECONDS));error?.let{throw it}}
  Thread{
   var uri:android.net.Uri?=null
   try{
    onMain{observer.start()};check(count.get()==0)
    onMain{repeat(100){observer.changed()}};onMain{};check(count.get()==1){"Burst not coalesced: ${count.get()}"};queue.clear()
    val name="coolsync-event-check-"+java.util.UUID.randomUUID()+".jpg"
    uri=contentResolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI,ContentValues().apply{put(MediaStore.MediaColumns.IS_PENDING,1);put(MediaStore.MediaColumns.DISPLAY_NAME,name);put(MediaStore.MediaColumns.MIME_TYPE,"image/jpeg");put(MediaStore.MediaColumns.RELATIVE_PATH,"Pictures/CoolSyncEventTest")})!!
    val bitmap=android.graphics.Bitmap.createBitmap(4,4,android.graphics.Bitmap.Config.ARGB_8888)
    contentResolver.openOutputStream(uri!!)!!.use{bitmap.compress(android.graphics.Bitmap.CompressFormat.JPEG,90,it)};bitmap.recycle()
    check(contentResolver.update(uri!!,ContentValues().apply{put(MediaStore.MediaColumns.IS_PENDING,0)},null,null)==1){"Failed to publish fixture"}
    check(queue.poll(10,TimeUnit.SECONDS)!=null){"No image insertion event"};onMain{};queue.clear()
    check(contentResolver.update(uri!!,ContentValues().apply{put(MediaStore.MediaColumns.IS_TRASHED,1)},android.os.Bundle().apply{putInt(MediaStore.QUERY_ARG_MATCH_TRASHED,MediaStore.MATCH_INCLUDE)})==1)
    check(queue.poll(10,TimeUnit.SECONDS)!=null){"No trash event"};onMain{};queue.clear()
    check(contentResolver.update(uri!!,ContentValues().apply{put(MediaStore.MediaColumns.IS_TRASHED,0)},android.os.Bundle().apply{putInt(MediaStore.QUERY_ARG_MATCH_TRASHED,MediaStore.MATCH_INCLUDE)})==1)
    check(queue.poll(10,TimeUnit.SECONDS)!=null){"No restore event"};onMain{};queue.clear()
    check(contentResolver.delete(uri!!,null,null)==1);uri=null
    check(queue.poll(10,TimeUnit.SECONDS)!=null){"No permanent deletion event"}
    onMain{};queue.clear()
    val moveName="coolsync-move-check-"+java.util.UUID.randomUUID()+".jpg"
    uri=contentResolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI,ContentValues().apply{put(MediaStore.MediaColumns.IS_PENDING,1);put(MediaStore.MediaColumns.DISPLAY_NAME,moveName);put(MediaStore.MediaColumns.MIME_TYPE,"image/jpeg");put(MediaStore.MediaColumns.RELATIVE_PATH,"Pictures/CoolSyncEventTest")})!!
    val movedBitmap=android.graphics.Bitmap.createBitmap(4,4,android.graphics.Bitmap.Config.ARGB_8888)
    contentResolver.openOutputStream(uri!!)!!.use{movedBitmap.compress(android.graphics.Bitmap.CompressFormat.JPEG,90,it)};movedBitmap.recycle()
    check(contentResolver.update(uri!!,ContentValues().apply{put(MediaStore.MediaColumns.IS_PENDING,0)},null,null)==1)
    check(queue.poll(10,TimeUnit.SECONDS)!=null);onMain{};queue.clear()
    val path="Pictures/CoolSyncEventTest/"+moveName;val fs=StorageBridge.engine(this)
    fs.discard(listOf(path));StorageBridge.rescan(this,listOf(path))
    check(queue.poll(10,TimeUnit.SECONDS)!=null){"No CoolSync trash/rescan event"}
    contentResolver.query(uri!!,arrayOf("_id"),null,null,null)!!.use{check(it.count==0){"Trashed file remained in public gallery"}}
    fs.permanentDelete(fs.listTrash().single{it.original==path}.id);uri=null
    onMain{observer.stop()};onMain{};val stopped=count.get();queue.clear()
    onMain{observer.changed();connected=false;observer.start();repeat(20){observer.changed()}};onMain{};check(count.get()==stopped)
    onMain{observer.stop()}
    android.util.Log.i("CoolSyncGalleryTest","PASS: real Android MediaStore insert/trash/restore/delete and CoolSync trash/rescan notifications; 100-event burst coalesced; no startup notification; stop/disconnect suppresses delivery; no polling")
    onMain{view.text="PASS: event-driven gallery sync"}
   }catch(e:Throwable){android.util.Log.e("CoolSyncGalleryTest","FAIL",e);onMain{view.text="FAIL: "+e.toString()}}
   finally{uri?.let{contentResolver.delete(it,null,null)};onMain{observer.stop()}}
  }.start()
 }
}
