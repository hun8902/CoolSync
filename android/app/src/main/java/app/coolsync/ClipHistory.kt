package app.coolsync

import android.content.*
import android.database.*
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.provider.OpenableColumns
import android.graphics.BitmapFactory
import android.graphics.Bitmap
import org.json.*
import java.io.File
import java.util.UUID

/** App-private local history; no content logging or cloud history. */
object ClipHistory {
    @Volatile var revision=0;private set
    const val IMAGE_LIMIT=20*1024*1024
    private fun folder(c:Context)=File(c.filesDir,"clipboard").apply{mkdirs()}
    fun enabled(c:Context)=c.getSharedPreferences("clipboard",0).getBoolean("history",true)
    @Synchronized fun entries(c:Context):List<JSONObject> = runCatching { val a=JSONArray(File(folder(c),"history.json").readText());(0 until a.length()).map{a.getJSONObject(it)} }.getOrDefault(emptyList())
    @Synchronized private fun write(c:Context,items:List<JSONObject>){val f=File(folder(c),"history.json");val t=File(folder(c),"history.tmp");t.writeText(JSONArray(items).toString());check(t.renameTo(f));revision++}
    @Synchronized private fun add(c:Context,item:JSONObject){
        if(!enabled(c))return
        val items=entries(c).toMutableList()
        val duplicate=items.firstOrNull{it.optString("text").isNotEmpty()&&it.optString("text")==item.optString("text")}
        if(duplicate!=null){item.put("id",duplicate.getString("id"));item.put("favorite",duplicate.optBoolean("favorite"));items.remove(duplicate)}
        while(items.size>=200){val old=items.lastOrNull{!it.optBoolean("favorite")} ?: return;items.remove(old);old.optString("image").takeIf{it.isNotEmpty()}?.let{File(folder(c),it).delete()}}
        fun bytes()=items.sumOf{it.optString("image").takeIf{n->n.isNotEmpty()}?.let{n->File(folder(c),n).length()} ?: 0L}
        val added=item.optString("image").takeIf{it.isNotEmpty()}?.let{File(folder(c),it).length()} ?: 0L
        while(bytes()+added>100L*1024*1024){val old=items.lastOrNull{!it.optBoolean("favorite")&&it.has("image")} ?: return;items.remove(old);File(folder(c),old.getString("image")).delete()}
        items.add(0,item);write(c,items)
    }
    fun text(c:Context,text:String,source:String){if(text.isNotEmpty()&&text.toByteArray().size<=16384)add(c,JSONObject().put("id",UUID.randomUUID().toString()).put("text",text).put("source",source).put("time",System.currentTimeMillis()).put("favorite",false))}
    fun image(c:Context,file:File,source:String){if(!enabled(c))return;val id=UUID.randomUUID().toString();val dest=File(folder(c),"$id.png");file.copyTo(dest);add(c,JSONObject().put("id",id).put("image",dest.name).put("source",source).put("time",System.currentTimeMillis()).put("favorite",false));if(entries(c).none{it.optString("id")==id})dest.delete()}
    @Synchronized fun favorite(c:Context,id:String){write(c,entries(c).map{if(it.optString("id")==id)it.put("favorite",!it.optBoolean("favorite"))else it})}
    @Synchronized fun remove(c:Context,id:String){val items=entries(c);items.firstOrNull{it.optString("id")==id}?.optString("image")?.takeIf{it.isNotEmpty()}?.let{File(folder(c),it).delete()};write(c,items.filter{it.optString("id")!=id})}
    @Synchronized fun clear(c:Context){folder(c).listFiles()?.filter{!it.name.startsWith("current-")}?.forEach{it.delete()};revision++}
    fun file(c:Context,item:JSONObject)=File(folder(c),item.getString("image"))
    fun uri(c:Context,file:File):Uri=Uri.parse("content://${c.packageName}.clipboard/${file.name}")
    fun copy(c:Context,item:JSONObject){val manager=c.getSystemService(ClipboardManager::class.java);if(item.has("image")){manager.setPrimaryClip(ClipData.newUri(c.contentResolver,"CoolSync image",uri(c,current(c,file(c,item)))));SyncService.active?.localImage(uri(c,file(c,item)),false)}else{val text=item.optString("text");manager.setPrimaryClip(ClipData.newPlainText("CoolSync",text));SyncService.active?.localCopy(text)}}
    fun normalized(c:Context,uri:Uri):File {
        val bytes=c.contentResolver.openInputStream(uri)!!.use{input->val out=java.io.ByteArrayOutputStream();val buf=ByteArray(65536);while(true){val n=input.read(buf);if(n<0)break;require(out.size()+n<=IMAGE_LIMIT){"이미지는 20 MB 이하만 공유합니다"};out.write(buf,0,n)};out.toByteArray()}
        val bounds=BitmapFactory.Options().apply{inJustDecodeBounds=true};BitmapFactory.decodeByteArray(bytes,0,bytes.size,bounds)
        require(bounds.outWidth>0&&bounds.outHeight>0&&bounds.outWidth.toLong()*bounds.outHeight<=16000000){"이미지는 1600만 화소 이하만 공유합니다"}
        val bitmap=BitmapFactory.decodeByteArray(bytes,0,bytes.size) ?: error("이미지를 읽지 못했습니다")
        val dir=File(c.cacheDir,"clip-staging").apply{mkdirs()};val file=File(dir,UUID.randomUUID().toString()+".png")
        try{file.outputStream().use{check(bitmap.compress(Bitmap.CompressFormat.PNG,100,it))};require(file.length()<=IMAGE_LIMIT){"변환된 이미지가 너무 큽니다"};return file}catch(e:Exception){file.delete();throw e}finally{bitmap.recycle()}
    }
    private fun current(c:Context,file:File):File{val saved=File(folder(c),"current-${UUID.randomUUID()}.png");file.copyTo(saved);folder(c).listFiles()?.filter{it.name.startsWith("current-")}?.sortedByDescending{it.lastModified()}?.drop(2)?.forEach{it.delete()};return saved}
    fun receive(c:Context,file:File,time:Long):Boolean{
        val sync=SyncService.active ?: return false
        if(!sync.canApplyImage(time))return false
        val normalized=normalized(c,Uri.fromFile(file));val saved=current(c,normalized)
        try{val apply=java.util.concurrent.FutureTask<Boolean>{if(SyncService.active!==sync||!sync.canApplyImage(time))false else{c.getSystemService(ClipboardManager::class.java).setPrimaryClip(ClipData.newUri(c.contentResolver,"CoolSync image",uri(c,saved)));image(c,saved,"Mac");sync.imageApplied(time);true}};android.os.Handler(android.os.Looper.getMainLooper()).post(apply);return try{apply.get(5,java.util.concurrent.TimeUnit.SECONDS)}catch(e:Exception){apply.cancel(false);throw e}}finally{normalized.delete()}
    }
}
class ClipboardImageProvider:ContentProvider(){
    override fun onCreate()=true
    private fun file(uri:Uri):File{val name=uri.lastPathSegment ?: error("Missing image");require(name.matches(Regex("(?:current-)?[a-fA-F0-9-]{36}\\.png")));return File(context!!.filesDir,"clipboard/$name")}
    override fun getType(uri:Uri)="image/png"
    override fun getStreamTypes(uri:Uri,mimeTypeFilter:String)=if(mimeTypeFilter in listOf("image/png","image/*","*/*"))arrayOf("image/png")else null
    override fun openFile(uri:Uri,mode:String):ParcelFileDescriptor{require(mode=="r");return ParcelFileDescriptor.open(file(uri),ParcelFileDescriptor.MODE_READ_ONLY)}
    override fun query(uri:Uri,projection:Array<out String>?,selection:String?,args:Array<out String>?,sort:String?):Cursor{val f=file(uri);val cols=projection ?: arrayOf(OpenableColumns.DISPLAY_NAME,OpenableColumns.SIZE);return MatrixCursor(cols).apply{addRow(cols.map{when(it){OpenableColumns.DISPLAY_NAME->"CoolSync.png";OpenableColumns.SIZE->f.length();else->null}})}}
    override fun insert(uri:Uri,values:ContentValues?):Uri?=throw UnsupportedOperationException()
    override fun update(uri:Uri,values:ContentValues?,selection:String?,args:Array<out String>?)=0
    override fun delete(uri:Uri,selection:String?,args:Array<out String>?)=0
}
