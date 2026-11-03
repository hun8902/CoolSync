package app.coolsync

import android.content.Context
import android.database.ContentObserver
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore

/** No polling or delayed debounce: only MediaStore notifications enqueue a single main-queue flush. */
class GalleryChangeObserver(private val context:Context,private val connected:()->Boolean,private val notify:()->Unit) {
 private val main=Handler(Looper.getMainLooper())
 private var registered=false
 private var pending=false
 private val flush=Runnable{pending=false;if(registered&&connected())notify()}
 private val observer=object:ContentObserver(main){
  override fun onChange(selfChange:Boolean){changed()}
  override fun onChange(selfChange:Boolean,uri:Uri?){changed()}
  override fun onChange(selfChange:Boolean,uris:Collection<Uri>,flags:Int){changed()}
 }
 internal fun changed(){if(!registered||!connected()||pending)return;pending=true;main.post(flush)}
 fun start(){
  if(registered)return
  registered=true
  try{
   val volumes=runCatching{MediaStore.getExternalVolumeNames(context)}.getOrDefault(emptySet())+"external"
   for(volume in volumes){
    context.contentResolver.registerContentObserver(MediaStore.Images.Media.getContentUri(volume),true,observer)
    context.contentResolver.registerContentObserver(MediaStore.Video.Media.getContentUri(volume),true,observer)
   }
  }catch(e:Exception){stop();android.util.Log.w("CoolSyncGallery","MediaStore observer registration failed",e)}
 }
 fun stop(){registered=false;pending=false;main.removeCallbacks(flush);runCatching{context.contentResolver.unregisterContentObserver(observer)}}
}
