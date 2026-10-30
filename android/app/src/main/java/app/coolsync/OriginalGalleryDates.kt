package app.coolsync

import androidx.exifinterface.media.ExifInterface
import android.media.MediaMetadataRetriever
import java.io.File
import java.text.ParsePosition
import java.text.SimpleDateFormat
import java.util.Locale
import java.util.TimeZone

/** Only reads embedded capture metadata. mtime is a cache invalidator, never a date source. */
object OriginalGalleryDates {
 data class Result(val time:Long=0,val source:String="missing")
 private val cache=linkedMapOf<String,Result>()
 @Synchronized fun read(file:File,mime:String):Result {
  val key="${file.path}|${file.length()}|${file.lastModified()}"
  cache[key]?.let{return it}
  val result=try{if(mime.startsWith("video/"))video(file)else file.inputStream().use{image(ExifInterface(it))}}catch(_:Exception){Result()}
  if(cache.size>=20000)cache.clear();cache[key]=result;return result
 }
 internal fun parse(value:String,pattern:String,zone:TimeZone):Long {
  val parser=SimpleDateFormat(pattern,Locale.US).apply{isLenient=false;timeZone=zone};val position=ParsePosition(0)
  val date=parser.parse(value,position)
  return if(date!=null && position.index==value.length)date.time.coerceAtLeast(0)else 0
 }
 internal fun image(exif:ExifInterface):Result {
  for(tags in listOf(arrayOf(ExifInterface.TAG_DATETIME_ORIGINAL,ExifInterface.TAG_OFFSET_TIME_ORIGINAL,ExifInterface.TAG_SUBSEC_TIME_ORIGINAL),arrayOf(ExifInterface.TAG_DATETIME_DIGITIZED,ExifInterface.TAG_OFFSET_TIME_DIGITIZED,ExifInterface.TAG_SUBSEC_TIME_DIGITIZED))) {
   val text=exif.getAttribute(tags[0])?.trim() ?: continue
   val offset=exif.getAttribute(tags[1])?.trim()
   val zone=if(offset!=null && offset.matches(Regex("[+-](?:0[0-9]|1[0-4]):[0-5][0-9]")))TimeZone.getTimeZone("GMT$offset")else TimeZone.getDefault()
   val base=parse(text,"yyyy:MM:dd HH:mm:ss",zone)
   val fraction=exif.getAttribute(tags[2])?.takeWhile{it.isDigit()}?.take(3)?.padEnd(3,'0')?.toLongOrNull() ?: 0
   if(base>0)return Result(base+fraction,"original_exif")
  }
  return Result()
 }
 private fun video(file:File):Result {
  val retriever=MediaMetadataRetriever()
  try{retriever.setDataSource(file.path);val text=retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DATE)?.trim() ?: return Result()
   for(pattern in listOf("yyyyMMdd'T'HHmmss.SSSX","yyyyMMdd'T'HHmmssX","yyyy-MM-dd'T'HH:mm:ss.SSSX","yyyy-MM-dd'T'HH:mm:ssX","yyyyMMdd'T'HHmmss")){val time=parse(text,pattern,TimeZone.getTimeZone("UTC"));if(time>0)return Result(time,"original_video")}
   return Result()
  }finally{retriever.release()}
 }
}
