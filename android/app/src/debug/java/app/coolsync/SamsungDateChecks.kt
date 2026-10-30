package app.coolsync
import android.database.MatrixCursor
object SamsungDateChecks {
 @JvmStatic fun main(args:Array<String>){
  val paths=listOf("/storage/emulated/0/DCIM/no-exif.jpg","/storage/emulated/0/DCIM/same-time.jpg","/storage/emulated/0/DCIM/zero.jpg","/storage/emulated/0/DCIM/null.jpg")
  val result=SamsungGalleryDates.read(paths){uri,projection,selection,values->
   check(uri.toString()=="content://secmedia/media");check(projection.contentEquals(arrayOf("_id","_data","datetime")));check(selection=="_data IN (?,?,?,?)");check(values.toList()==paths)
   MatrixCursor(projection).apply{addRow(arrayOf<Any?>(900,paths[0],946684800000L));addRow(arrayOf<Any?>(800,paths[1],946684800000L));addRow(arrayOf<Any?>(700,paths[2],0));addRow(arrayOf<Any?>(600,paths[3],null));addRow(arrayOf<Any?>(500,"/unrequested.jpg",1790000000000L))}
  }
  check(result.status=="available"&&result.entries.size==2);check(result.entries[paths[0]]==SamsungGalleryDates.Entry(946684800000L,900));check(result.entries[paths[1]]!!.order==800L)
  check(SamsungGalleryDates.read(paths){_,_,_,_->throw SecurityException()}.status=="permission")
  check(SamsungGalleryDates.read(paths){_,_,_,_->throw IllegalArgumentException()}.status=="unsupported")
  check(SamsungGalleryDates.read(paths){_,_,_,_->null}.status=="unavailable")
  check(SamsungGalleryDates.read(emptyList()){_,_,_,_->error("must not query")}.status=="empty")
  val folder=java.io.File(args[0]);check(folder.path.startsWith("/data/user/0/app.coolsync/cache/date-check-"));folder.mkdirs()
  val file=java.io.File(folder,"20261030.jpg")
  val image=android.graphics.Bitmap.createBitmap(4,4,android.graphics.Bitmap.Config.ARGB_8888)
  file.outputStream().use{image.compress(android.graphics.Bitmap.CompressFormat.JPEG,90,it)};image.recycle()
  val exif=androidx.exifinterface.media.ExifInterface(file)
  exif.setAttribute(androidx.exifinterface.media.ExifInterface.TAG_DATETIME_ORIGINAL,"2006:04:05 14:15:16")
  exif.setAttribute(androidx.exifinterface.media.ExifInterface.TAG_OFFSET_TIME_ORIGINAL,"+09:00")
  exif.setAttribute(androidx.exifinterface.media.ExifInterface.TAG_SUBSEC_TIME_ORIGINAL,"123")
  exif.saveAttributes()
  val before=file.readBytes();val modified=file.lastModified()
  val original=OriginalGalleryDates.read(file,"image/jpeg")
  check(original.time==1144214116123L && original.source=="original_exif"){"Unexpected capture date: $original"}
  check(before.contentEquals(file.readBytes()) && modified==file.lastModified()){"Original changed"}
  val plain=java.io.File(folder,"20261030-no-date.jpg");val bitmap=android.graphics.Bitmap.createBitmap(4,4,android.graphics.Bitmap.Config.ARGB_8888);plain.outputStream().use{bitmap.compress(android.graphics.Bitmap.CompressFormat.JPEG,90,it)};bitmap.recycle()
  check(OriginalGalleryDates.read(plain,"image/jpeg").time==0L){"Must not use filename or mtime"}
  check(OriginalGalleryDates.parse("2026:02:30 10:00:00","yyyy:MM:dd HH:mm:ss",java.util.TimeZone.getTimeZone("UTC"))==0L)
  folder.deleteRecursively()
  println("PASS: Samsung datetime import, preserved gallery ID, bound path arguments, null/zero remain unknown, unrelated paths rejected, access denied explicit; read-only cursor fixture")
 }
}
