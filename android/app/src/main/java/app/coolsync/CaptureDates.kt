package app.coolsync

import android.content.Context
import android.media.MediaMetadataRetriever
import android.util.AtomicFile
import androidx.exifinterface.media.ExifInterface
import org.json.JSONObject
import java.io.File
import java.security.MessageDigest
import java.text.ParsePosition
import java.text.SimpleDateFormat
import java.util.Locale
import java.util.TimeZone

/** Original capture metadata is cached per file version; no background scanning. */
object CaptureDates {
 data class Result(val time:Long,val source:String)
 private var values:JSONObject?=null
 private var dirty=false
 private val missing=mutableSetOf<String>()
 @Synchronized fun read(c:Context,file:File,mime:String,fresh:Boolean=false):Result {
  if(values==null)values=runCatching{JSONObject(AtomicFile(File(c.filesDir,"capture-dates-v2.json")).readFully().toString(Charsets.UTF_8))}.getOrDefault(JSONObject())
  val key=MessageDigest.getInstance("SHA-256").digest("${file.path}|${file.length()}|${file.lastModified()}".toByteArray()).joinToString(""){"%02x".format(it)}
  if(!fresh){values!!.optJSONObject(key)?.let{if(it.optLong("time")>0)return Result(it.optLong("time"),it.optString("source"))};if(key in missing)return Result(0,"")}
  fun extract()=if(mime.startsWith("video/"))video(file)else image(file)
  val result=if(fresh)extract()else try{extract()}catch(_:Exception){return Result(0,"")}
  if(result.time>0){values!!.put(key,JSONObject().put("time",result.time).put("source",result.source));missing.remove(key)}else{if(values!!.optJSONObject(key)?.optString("source")!="captured")values!!.remove(key);missing.add(key)};dirty=true
  return result
 }
 @Synchronized fun rememberOriginal(c:Context,file:File,mime:String,time:Long,source:String?=null){
  read(c,file,mime)
  val key=MessageDigest.getInstance("SHA-256").digest("${file.path}|${file.length()}|${file.lastModified()}".toByteArray()).joinToString(""){"%02x".format(it)}
  values!!.put(key,JSONObject().put("time",time).put("source",source ?: if(mime.startsWith("video/"))"video"else "exif"));dirty=true
 }
 private fun parse(text:String,pattern:String,zone:TimeZone):Long {
  val format=SimpleDateFormat(pattern,Locale.US);format.isLenient=false;format.timeZone=zone
  val position=ParsePosition(0);val date=format.parse(text,position)
  return if(date!=null&&position.index==text.length)date.time.coerceAtLeast(0)else 0
 }
 private fun image(file:File):Result = imageExif(ExifInterface(file))
 fun imageExif(exif:ExifInterface):Result {
  val tags=listOf(ExifInterface.TAG_DATETIME_ORIGINAL to ExifInterface.TAG_OFFSET_TIME_ORIGINAL,ExifInterface.TAG_DATETIME_DIGITIZED to ExifInterface.TAG_OFFSET_TIME_DIGITIZED,ExifInterface.TAG_DATETIME to ExifInterface.TAG_OFFSET_TIME)
  val selected=tags.firstOrNull{!exif.getAttribute(it.first).isNullOrBlank()} ?: return Result(0,"")
  val original=exif.getAttribute(selected.first)!!.trim()
  val offset=exif.getAttribute(selected.second)?.trim()
  val zone=if(offset!=null&&offset.matches(Regex("[+-][0-9]{2}:[0-9]{2}")))TimeZone.getTimeZone("GMT$offset")else TimeZone.getDefault()
  val base=parse(original,"yyyy:MM:dd HH:mm:ss",zone)
  val fraction=exif.getAttribute(if(selected.first==ExifInterface.TAG_DATETIME_ORIGINAL)ExifInterface.TAG_SUBSEC_TIME_ORIGINAL else if(selected.first==ExifInterface.TAG_DATETIME_DIGITIZED)ExifInterface.TAG_SUBSEC_TIME_DIGITIZED else ExifInterface.TAG_SUBSEC_TIME)?.takeWhile{it.isDigit()}?.take(3)?.padEnd(3,'0')?.toLongOrNull() ?: 0
  return if(base>0)Result(base+fraction,"exif")else Result(0,"")
 }
 private fun video(file:File):Result {
  val retriever=MediaMetadataRetriever()
  try {
   retriever.setDataSource(file.path)
   val value=retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DATE)?.trim() ?: return Result(0,"")
   val zone=TimeZone.getTimeZone("UTC")
   for(pattern in listOf("yyyyMMdd'T'HHmmss.SSSX","yyyyMMdd'T'HHmmssX","yyyy-MM-dd'T'HH:mm:ss.SSSX","yyyy-MM-dd'T'HH:mm:ssX","yyyyMMdd'T'HHmmss")){
    val time=parse(value,pattern,zone);if(time>0)return Result(time,"video")
   }
   return Result(0,"")
  }finally{retriever.release()}
 }
 @Synchronized fun flush(c:Context){
  if(!dirty)return
  val entries=values ?: return
  if(entries.length()>25000){val keys=entries.keys().asSequence().take(entries.length()-20000).toList();keys.forEach{entries.remove(it)}}
  val atomic=AtomicFile(File(c.filesDir,"capture-dates-v2.json"))
  runCatching{val output=atomic.startWrite();try{output.write(entries.toString().toByteArray());atomic.finishWrite(output);dirty=false}catch(e:Exception){atomic.failWrite(output);throw e}}
 }
}
