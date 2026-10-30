package app.coolsync

import android.content.ContentResolver
import android.database.Cursor
import android.net.Uri

/** Reads Samsung's resolved gallery date; never reconstructs it from file timestamps. */
object SamsungGalleryDates {
 data class Entry(val time:Long,val order:Long)
 data class Result(val entries:Map<String,Entry>,val status:String)
 fun read(resolver:ContentResolver,paths:List<String>):Result = read(paths){uri,projection,selection,args->resolver.query(uri,projection,selection,args,"datetime DESC, _id DESC")}
 internal fun read(paths:List<String>,query:(Uri,Array<String>,String,Array<String>)->Cursor?):Result {
  if(paths.isEmpty())return Result(emptyMap(),"empty")
  return try {
   val values=linkedMapOf<String,Entry>()
   val cursor=query(Uri.parse("content://secmedia/media"),arrayOf("_id","_data","datetime"),"_data IN (${paths.joinToString(","){"?"}})",paths.toTypedArray()) ?: return Result(emptyMap(),"unavailable")
   cursor.use { c->
    val id=c.getColumnIndexOrThrow("_id");val path=c.getColumnIndexOrThrow("_data");val date=c.getColumnIndexOrThrow("datetime")
    while(c.moveToNext()) {val name=c.getString(path) ?: continue;val time=if(c.isNull(date))0 else c.getLong(date)
     if(name in paths && time>0 && name !in values)values[name]=Entry(time,c.getLong(id))
    }
   }
   Result(values,"available")
  }catch(_:SecurityException){Result(emptyMap(),"permission")}catch(_:IllegalArgumentException){Result(emptyMap(),"unsupported")}catch(_:Exception){Result(emptyMap(),"unavailable")}
 }
}
