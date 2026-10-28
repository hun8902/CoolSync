package app.coolsync

import android.Manifest
import android.content.*
import android.content.pm.PackageManager
import android.graphics.*
import android.media.MediaMetadataRetriever
import android.media.MediaScannerConnection
import android.provider.MediaStore
import android.net.Uri
import android.os.Environment
import android.util.Size
import android.util.Base64
import androidx.exifinterface.media.ExifInterface
import org.json.*
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** MediaStore metadata only; originals are read only on explicit preview/export. */
object GalleryMedia {
 data class Item(val id:Long,val path:String,val name:String,val album:String,val mime:String,val size:Long,val date:Long,val modified:Long,val width:Int,val height:Int,val duration:Long,val generation:Long,val added:Long,val dateSource:String){
  fun json(favorites:Set<String>)=JSONObject().put("id",id.toString()).put("path",path).put("name",name).put("album",album).put("mime",mime).put("size",size).put("date",date).put("modified",modified).put("width",width).put("height",height).put("duration",duration).put("favorite",path in favorites).put("generation",generation).put("added",added).put("dateSource",dateSource)
 }
 private fun filenameDate(name:String):Long{
  if(!Regex("^[0-9]{8}_[0-9]{6}(?:\\([0-9]+\\))?\\.[^.]+$").matches(name))return 0L
  return runCatching{java.time.LocalDateTime.parse(name.take(15).replace("_",""),java.time.format.DateTimeFormatter.ofPattern("uuuuMMddHHmmss").withResolverStyle(java.time.format.ResolverStyle.STRICT)).atZone(java.time.ZoneId.systemDefault()).toInstant().toEpochMilli()}.getOrDefault(0L)
 }
 private var cached:List<Item>?=null
 private var cachedAt=0L
 private fun prefs(c:Context)=c.getSharedPreferences("gallery",0)
 private fun favorites(c:Context)=prefs(c).getStringSet("favorites",emptySet()) ?: emptySet()
 @Synchronized fun invalidate(){cached=null}
 @Synchronized private fun items(c:Context):List<Item>{
  if(cached!=null&&System.currentTimeMillis()-cachedAt<15000)return cached!!
  val fs=StorageBridge.engine(c);val root=Environment.getExternalStorageDirectory().canonicalFile
  val columns=arrayOf(MediaStore.Files.FileColumns._ID,MediaStore.Files.FileColumns.DATA,MediaStore.Files.FileColumns.DISPLAY_NAME,MediaStore.Files.FileColumns.MIME_TYPE,MediaStore.Files.FileColumns.SIZE,MediaStore.Files.FileColumns.DATE_MODIFIED,MediaStore.Images.ImageColumns.DATE_TAKEN,MediaStore.Images.ImageColumns.WIDTH,MediaStore.Images.ImageColumns.HEIGHT,MediaStore.Video.VideoColumns.DURATION,MediaStore.MediaColumns.GENERATION_MODIFIED,MediaStore.MediaColumns.DATE_ADDED)
  val result=mutableListOf<Item>()
  c.contentResolver.query(MediaStore.Files.getContentUri("external"),columns,"media_type IN (?,?) AND is_pending=0 AND is_trashed=0",arrayOf("1","3"),"datetaken DESC, _id DESC")?.use{cursor->
   fun str(i:Int)=if(cursor.isNull(i))""else cursor.getString(i)
   fun long(i:Int)=if(cursor.isNull(i))0L else cursor.getLong(i)
   while(cursor.moveToNext()){
    val file=File(str(1));if(!file.exists()||!file.path.startsWith(root.path+"/"))continue
    val path=file.relativeTo(root).invariantSeparatorsPath
    if(path.split('/').any{it.startsWith('.')})continue
    if(runCatching{fs.resolve(path)}.isFailure)continue
    val mime=str(3);if(!mime.startsWith("image/")&&!mime.startsWith("video/"))continue
    val taken=long(6)
    val added=long(11)*1000;val modified=(file.lastModified()/1000)*1000
    // Files.creationTime() may return mtime on Android; never label it as creation time.
    val original=if(taken<=0)CaptureDates.read(c,file,mime)else CaptureDates.Result(0L,"")
    val namedDate=if(taken<=0 && original.time<=0)filenameDate(str(2))else 0L
    val date=when{taken>0->taken;original.time>0->original.time;namedDate>0->namedDate;else->0L}
    val source=when{taken>0->"captured";original.time>0->original.source;namedDate>0->"filename";else->"unknown"}
    result.add(Item(long(0),path,str(2),path.substringBeforeLast('/',""),mime,long(4),date,modified,long(7).toInt(),long(8).toInt(),long(9),long(10),added,source))
   }
  }
  CaptureDates.flush(c)
  result.sortWith(compareByDescending<Item>{it.date}.thenByDescending{it.id});cached=result;cachedAt=System.currentTimeMillis();return result
 }
 fun syncRows(c:Context):List<JSONObject>{invalidate();val favorite=favorites(c);return items(c).map{it.json(favorite)}}
 fun file(c:Context,path:String):File{val f=StorageBridge.engine(c).resolve(path);val mime=android.webkit.MimeTypeMap.getSingleton().getMimeTypeFromExtension(f.extension.lowercase()) ?: "";if(!f.isFile||(!mime.startsWith("image/")&&!mime.startsWith("video/")))throw StorageFault("media","사진 또는 영상 파일이 아닙니다");return f}
 private fun remapFavorites(c:Context,mapping:Map<String,String>,copy:Boolean=false){val values=favorites(c).toMutableSet();mapping.forEach{(old,new)->if(old in values){if(!copy)values.remove(old);values.add(new)}};prefs(c).edit().putStringSet("favorites",values).commit()}
 fun rescan(c:Context,paths:List<String>){
  invalidate();val root=Environment.getExternalStorageDirectory();val valid=paths.distinct().take(20000).map{File(root,it).path};if(valid.isEmpty())return
  prefs(c).edit().putString("syncChange",java.util.UUID.randomUUID().toString()).commit()
  val latch=CountDownLatch(valid.size);MediaScannerConnection.scanFile(c,valid.toTypedArray(),null){_,_->latch.countDown()};latch.await(20,TimeUnit.SECONDS);c.contentResolver.notifyChange(MediaStore.Files.getContentUri("external"),null);invalidate()
 }
 fun handle(c:Context,q:JSONObject,out:JSONObject){
  when(q.getString("op")){
   "mediaSync"->GallerySync.sync(c,q,out)
   "mediaTrashChecked"->GallerySync.trash(c,q,out)
   "mediaAlignDates"->alignDates(c,q,out)
   "mediaSession"->out.put("endpoint",GalleryServer.open(c as SyncService))
   "mediaClose"->GalleryServer.close()
   "mediaAlbums"->{
    if(q.optBoolean("refresh"))invalidate()
    val grouped=items(c).groupBy{it.album};val paths=(grouped.keys+(prefs(c).getStringSet("albums",emptySet()) ?: emptySet())).filter{it.isNotEmpty()&&runCatching{StorageBridge.engine(c).resolve(it).isDirectory}.getOrDefault(false)}.sorted()
    out.put("albums",JSONArray(paths.map{path->val list=grouped[path] ?: emptyList();JSONObject().put("path",path).put("name",path.substringAfterLast('/')).put("count",list.size).put("videos",list.count{it.mime.startsWith("video/")})})).put("count",items(c).size)
   }
   "mediaList"->{
    val favorite=favorites(c);val album=q.optString("album");val scope=q.optString("scope","all");val search=q.optString("search").lowercase()
    val rows=items(c).filter{(album.isEmpty()||it.album==album)&&(search.isEmpty()||it.name.lowercase().contains(search))&&when(scope){"videos"->it.mime.startsWith("video/");"favorites"->it.path in favorite;"screenshots"->it.album.contains("screenshot",true);else->true}}
    val ordered=if(scope=="recent")rows.sortedWith(compareByDescending<Item>{it.added}.thenByDescending{it.id})else rows
    val start=q.optInt("offset").coerceIn(0,ordered.size);val page=ordered.drop(start).take(40)
    out.put("items",JSONArray(page.map{it.json(favorite)})).put("next",start+page.size).put("total",ordered.size)
   }
   "mediaInfo"->{
    val path=q.getString("path");val f=file(c,path);val info=JSONObject().put("name",f.name).put("size",f.length()).put("locationAllowed",c.checkSelfPermission(Manifest.permission.ACCESS_MEDIA_LOCATION)==PackageManager.PERMISSION_GRANTED)
    val item=items(c).firstOrNull{it.path==path};if(item!=null)info.put("mime",item.mime).put("date",item.date).put("width",item.width).put("height",item.height).put("duration",item.duration)
    if(item?.mime?.startsWith("video/")==true){
     val retriever=MediaMetadataRetriever();try{retriever.setDataSource(f.path);info.put("duration",retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: 0);info.put("width",retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toIntOrNull() ?: 0);info.put("height",retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toIntOrNull() ?: 0);info.put("rotation",retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION));info.put("codec",retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_MIMETYPE));if(info.optBoolean("locationAllowed")){val loc=retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_LOCATION);val match=Regex("([+-][0-9.]+)([+-][0-9.]+)").find(loc ?: "");match?.let{info.put("latitude",it.groupValues[1].toDouble()).put("longitude",it.groupValues[2].toDouble())}}}finally{retriever.release()}
     val capture=CaptureDates.read(c,f,item.mime,fresh=true);if(capture.time>0)info.put("captureTime",capture.time).put("captureSource",capture.source)
    }else runCatching{
     val exif=if(item!=null && info.optBoolean("locationAllowed")){
      val uri=ContentUris.withAppendedId(MediaStore.Images.Media.EXTERNAL_CONTENT_URI,item.id)
      c.contentResolver.openFileDescriptor(MediaStore.setRequireOriginal(uri),"r")?.use{descriptor->info.put("metadataAccess","mediastore-original");ExifInterface(descriptor.fileDescriptor)} ?: throw StorageFault("original","휴대폰 원본 메타데이터를 열지 못했습니다")
     }else{info.put("metadataAccess","file");ExifInterface(f.path)}
     val capture=CaptureDates.imageExif(exif);if(capture.time>0)info.put("captureTime",capture.time).put("captureSource","exif")
     for((key,tag)in listOf("make" to ExifInterface.TAG_MAKE,"camera" to ExifInterface.TAG_MODEL,"lens" to ExifInterface.TAG_LENS_MODEL,"iso" to ExifInterface.TAG_PHOTOGRAPHIC_SENSITIVITY,"exposure" to ExifInterface.TAG_EXPOSURE_TIME,"aperture" to ExifInterface.TAG_F_NUMBER,"focalLength" to ExifInterface.TAG_FOCAL_LENGTH,"captured" to ExifInterface.TAG_DATETIME_ORIGINAL,"orientation" to ExifInterface.TAG_ORIENTATION))exif.getAttribute(tag)?.let{info.put(key,it)}
     if(info.optBoolean("locationAllowed"))exif.latLong?.let{info.put("latitude",it[0]).put("longitude",it[1])}
    }.onFailure{info.put("metadataError",it.message ?: "원본 EXIF를 읽지 못했습니다")}
    if(item!=null && !info.has("captured")){
     val collection=if(item.mime.startsWith("video/"))MediaStore.Video.Media.EXTERNAL_CONTENT_URI else MediaStore.Images.Media.EXTERNAL_CONTENT_URI
     val uri=ContentUris.withAppendedId(collection,item.id)
     runCatching{c.contentResolver.query(uri,arrayOf(MediaStore.Images.ImageColumns.DATE_TAKEN),null,null,null)?.use{cursor->
      if(cursor.moveToFirst() && !cursor.isNull(0)){val taken=cursor.getLong(0);if(taken>0)info.put("captured",java.text.SimpleDateFormat("yyyy-MM-dd HH:mm:ss",java.util.Locale.getDefault()).format(java.util.Date(taken))).put("captureSource","media-store").put("deviceCaptureTime",taken).put("captureTime",taken)}
     }}.onFailure{info.put("deviceMetadataError",it.message ?: "휴대폰 갤러리 촬영일 조회 실패")}
    }
    if(item!=null && info.optLong("captureTime")>0){CaptureDates.rememberOriginal(c,f,item.mime,info.getLong("captureTime"),if(info.optString("captureSource")=="media-store")"captured"else info.getString("captureSource"));CaptureDates.flush(c)}
    info.put("metadataChecked",true)
    out.put("info",info)
   }
   "mediaFavorite"->{val set=favorites(c).toMutableSet();val paths=paths(q);for(p in paths){file(c,p);if(q.optBoolean("value"))set.add(p)else set.remove(p)};prefs(c).edit().putStringSet("favorites",set).commit()}
   "mediaAlbumCreate"->{val fs=StorageBridge.engine(c);if(!File(Environment.getExternalStorageDirectory(),"Pictures").exists())fs.create("","Pictures",true);val name=q.getString("name");val candidate="Pictures/$name";val path=if(q.optBoolean("reuse")&&runCatching{fs.resolve(candidate).isDirectory}.getOrDefault(false))candidate else fs.create("Pictures",name,true);val albums=(prefs(c).getStringSet("albums",emptySet()) ?: emptySet()).toMutableSet();albums.add(path);prefs(c).edit().putStringSet("albums",albums).commit();out.put("path",path);invalidate()}
   "mediaAlbumRename"->{val fs=StorageBridge.engine(c);val path=q.getString("path");require(path.isNotEmpty());val old=items(c).filter{it.path.startsWith(path+"/")}.map{it.path};val target=fs.rename(path,q.getString("name"));val albums=(prefs(c).getStringSet("albums",emptySet()) ?: emptySet()).toMutableSet();albums.remove(path);albums.add(target);prefs(c).edit().putStringSet("albums",albums).commit();remapFavorites(c,old.associateWith{target+it.removePrefix(path)});rescan(c,old+old.map{target+it.removePrefix(path)});out.put("path",target)}
   "mediaMove","mediaCopy"->{val fs=StorageBridge.engine(c);val paths=paths(q);paths.forEach{file(c,it)};val target=q.getString("destination");fs.relocate(paths,target,q.getString("op")=="mediaCopy");remapFavorites(c,paths.associateWith{target+"/"+it.substringAfterLast('/')},q.getString("op")=="mediaCopy");rescan(c,paths+paths.map{target+"/"+it.substringAfterLast('/')})}
   "mediaTrash"->{val values=paths(q);values.forEach{file(c,it)};StorageBridge.engine(c).discard(values);rescan(c,values)}
   "mediaAlbumTrash"->{val path=q.getString("path");require(path.isNotEmpty());val old=items(c).filter{it.path.startsWith(path+"/")}.map{it.path};StorageBridge.engine(c).discard(listOf(path));val albums=(prefs(c).getStringSet("albums",emptySet()) ?: emptySet()).toMutableSet();albums.remove(path);prefs(c).edit().putStringSet("albums",albums).commit();rescan(c,old)}
   else->throw StorageFault("operation","지원하지 않는 사진 작업입니다")
  }
 }
 fun openOriginal(c:Context,path:String,id:String):android.os.ParcelFileDescriptor{
  file(c,path)
  val item=items(c).firstOrNull{it.path==path && it.id.toString()==id} ?: throw StorageFault("missing","원본 식별자가 변경되었습니다")
  val base=if(item.mime.startsWith("video/"))MediaStore.Video.Media.EXTERNAL_CONTENT_URI else MediaStore.Images.Media.EXTERNAL_CONTENT_URI
  var uri=ContentUris.withAppendedId(base,item.id)
  if(c.checkSelfPermission(Manifest.permission.ACCESS_MEDIA_LOCATION)==PackageManager.PERMISSION_GRANTED)uri=MediaStore.setRequireOriginal(uri)
  return c.contentResolver.openFileDescriptor(uri,"r") ?: throw StorageFault("original","휴대폰 원본을 열지 못했습니다")
 }
 fun originalInfo(c:Context,path:String,id:String):JSONObject{
  val file=file(c,path)
  val known=items(c).firstOrNull{it.path==path&&it.id.toString()==id} ?: throw StorageFault("missing","사진 또는 동영상을 찾지 못했습니다")
  var generation=known.generation
  c.contentResolver.query(MediaStore.Files.getContentUri("external"),arrayOf(MediaStore.Files.FileColumns._ID,MediaStore.MediaColumns.GENERATION_MODIFIED),"_data=? AND is_trashed=0",arrayOf(file.path),null)?.use{cursor->if(!cursor.moveToFirst()||cursor.getLong(0).toString()!=id)throw StorageFault("missing","사진 식별자가 변경되었습니다");generation=cursor.getLong(1)}
  val current=known.copy(size=file.length(),modified=(file.lastModified()/1000)*1000,generation=generation)
  CaptureDates.flush(c);return current.json(favorites(c))
 }
 private fun alignDates(c:Context,q:JSONObject,out:JSONObject){
  val requested=q.getJSONArray("items");if(requested.length() !in 1..20)throw StorageFault("selection","한 번에 20개 이하를 선택하세요")
  invalidate();val current=items(c).associateBy{it.path};val result=JSONArray();val changed=mutableListOf<String>();val history=c.getSharedPreferences("capture-date-history",0)
  for(i in 0 until requested.length()){
   val expected=requested.getJSONObject(i);val path=expected.getString("path");val row=JSONObject().put("path",path)
   try{
    val item=current[path] ?: throw StorageFault("missing","사진 또는 동영상을 찾지 못했습니다")
    if(item.id.toString()!=expected.getString("id")||item.size!=expected.getLong("size")||item.modified!=expected.getLong("modified"))throw StorageFault("conflict","사진 정보가 변경되었습니다. 먼저 동기화하세요")
    val file=file(c,path);val beforeSize=file.length();val beforeModified=file.lastModified()
    val nativeCapture=CaptureDates.read(c,file,item.mime,fresh=true)
    val fallback=expected.optLong("originalCaptureTime",0)
    val capture=if(nativeCapture.time>0)nativeCapture else if(expected.optString("captureSource")=="mac-original" && fallback in 1..253402300799999L)CaptureDates.Result(fallback,if(item.mime.startsWith("video/"))"video"else "exif")else nativeCapture
    if(file.length()!=beforeSize||file.lastModified()!=beforeModified)throw StorageFault("conflict","원본 촬영일을 읽는 중 파일이 변경되었습니다")
    if(capture.source !in setOf("exif","video")||capture.time<=0){row.put("status",if(expected.optBoolean("originalChecked"))"skipped"else "needsOriginal").put("reason",if(item.mime.startsWith("video/"))"동영상 원본에 유효한 내부 촬영일·생성일 메타데이터가 없습니다"else "사진 원본에 유효한 EXIF 촬영일(DateTimeOriginal)이 없습니다")}
    else if(file.lastModified()/1000==capture.time/1000){row.put("status","unchanged").put("reason","이미 원본 촬영일과 같은 수정일입니다")}
    else{
     if(file.length()!=item.size||file.lastModified()/1000!=item.modified/1000)throw StorageFault("conflict","파일이 변경되어 날짜를 수정하지 않았습니다")
     if(!history.contains(path))history.edit().putLong(path,file.lastModified()).commit()
     if(!file.setLastModified(capture.time))throw StorageFault("write","파일 수정일을 바꾸지 못했습니다")
     if(file.lastModified()/1000!=capture.time/1000)throw StorageFault("write","저장소가 수정일 변경을 반영하지 않았습니다")
     changed.add(path);row.put("status","updated").put("captureTime",capture.time).put("previousModified",beforeModified).put("actualModified",file.lastModified()).put("source",if(capture.source=="video")"original-video"else "original-exif")
    }
    if(nativeCapture.time<=0 && capture.time>0)CaptureDates.rememberOriginal(c,file,item.mime,capture.time)
   }catch(e:Exception){row.put("status","failed").put("error",e.message ?: "수정일을 변경하지 못했습니다")}
   result.put(row)
  }
  CaptureDates.flush(c);rescan(c,changed);invalidate();val after=items(c).associateBy{it.path};val favorite=favorites(c)
  for(i in 0 until result.length()){val row=result.getJSONObject(i);if(row.optString("status") in setOf("updated","unchanged"))after[row.getString("path")]?.let{row.put("item",it.json(favorite))}}
  out.put("results",result)
 }
 private fun paths(q:JSONObject):List<String>{val array=q.getJSONArray("paths");if(array.length()>500)throw StorageFault("size","한 번에 500개 이하를 선택하세요");return(0 until array.length()).map{array.getString(it)}}
 fun thumbnail(c:Context,path:String):ByteArray{
  val f=file(c,path)
  // A thumbnail request must not rebuild the full library or scan every original's metadata.
  var uri:Uri?=null;var video=false
  c.contentResolver.query(MediaStore.Files.getContentUri("external"),arrayOf(MediaStore.Files.FileColumns._ID,MediaStore.Files.FileColumns.MEDIA_TYPE),"_data=? AND is_pending=0 AND is_trashed=0",arrayOf(f.path),null)?.use{cursor->
   if(cursor.moveToFirst()){video=cursor.getInt(1)==MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO;uri=ContentUris.withAppendedId(if(video)MediaStore.Video.Media.EXTERNAL_CONTENT_URI else MediaStore.Images.Media.EXTERNAL_CONTENT_URI,cursor.getLong(0))}
  }
  if(uri==null)video=android.webkit.MimeTypeMap.getSingleton().getMimeTypeFromExtension(f.extension.lowercase())?.startsWith("video/")==true
  val bitmap=uri?.let{runCatching{c.contentResolver.loadThumbnail(it,Size(240,240),null)}.getOrNull()}
  val source=bitmap ?: if(video)android.media.ThumbnailUtils.createVideoThumbnail(f,Size(240,240),null)else android.media.ThumbnailUtils.createImageThumbnail(f,Size(240,240),null)
  try{val bytes=java.io.ByteArrayOutputStream();source.compress(Bitmap.CompressFormat.JPEG,75,bytes);require(bytes.size()<=128000);return bytes.toByteArray()}finally{source.recycle()}
 }
}
