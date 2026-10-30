package app.coolsync

import android.content.Context
import android.content.ContentUris
import android.net.Uri
import android.util.Size
import android.graphics.Bitmap
import android.provider.MediaStore
import android.os.Environment
import org.json.JSONObject
import org.json.JSONArray
import java.io.File

/** Read-only catalog: capture date is never replaced by transfer or modification time. */
object GalleryMedia {
    fun list(c:Context,q:JSONObject,out:JSONObject) {
        val root=Environment.getExternalStorageDirectory().canonicalFile
        // Same lightweight MediaStore projection as the pre-removal gallery; no original-file scan.
        val base=arrayOf("_id","_data","_display_name","mime_type","_size","datetaken","width","height","duration","date_added","is_favorite")
        val uri=MediaStore.Files.getContentUri("external")
        val where="media_type IN (1,3) AND is_pending=0 AND is_trashed=0 AND _data LIKE ?"
        val args=arrayOf(root.path+"/%")
        val cursor=try{c.contentResolver.query(uri,base+"xmp",where,args,"datetaken DESC, _id DESC")}catch(_:IllegalArgumentException){c.contentResolver.query(uri,base,where,args,"datetaken DESC, _id DESC")}
            ?: throw StorageFault("media","휴대폰 사진 목록을 열지 못했습니다. 파일 관리 권한을 확인하세요")
        val rows=JSONArray();val offset=q.optInt("offset").coerceAtLeast(0);val fast=q.optBoolean("fast");val limit=q.optInt("limit",if(fast)200 else 12).coerceIn(1,if(fast)200 else 20);val maxBytes=if(fast)60000 else 6000;var next=offset;var total=0
        cursor.use{cur->
            total=cur.count;next=offset.coerceAtMost(total)
            if(cur.moveToPosition(next))do{
                val file=File(cur.getString(1) ?: "");if(!file.path.startsWith(root.path+"/")){next++;continue}
                val path=file.relativeTo(root).invariantSeparatorsPath
                if(path.split('/').any{it.startsWith('.')}){next++;continue}
                val mime=cur.getString(3) ?: android.webkit.MimeTypeMap.getSingleton().getMimeTypeFromExtension(file.extension.lowercase()) ?: ""
                if(!mime.startsWith("image/")&&!mime.startsWith("video/")){next++;continue}
                val index=cur.getColumnIndex("xmp");val xmp=if(index>=0)runCatching{cur.getBlob(index)?.toString(Charsets.UTF_8) ?: ""}.getOrDefault("")else ""
                val live=Regex("""(?:MotionPhoto|MicroVideo)\s*=\s*["']1["']""").containsMatchIn(xmp) || xmp.contains(":MotionPhoto>1<") || (!mime.startsWith("video/") && listOf("mov","MOV").any{File(file.parentFile,file.nameWithoutExtension+"."+it).isFile})
                val album=path.substringBeforeLast('/',"")
                val row=JSONObject().put("id",cur.getLong(0).toString()).put("name",cur.getString(2) ?: file.name).put("path",path).put("size",cur.getLong(4)).put("mime",mime).put("taken",cur.getLong(5)).put("width",cur.getInt(6)).put("height",cur.getInt(7)).put("duration",cur.getLong(8)).put("added",cur.getLong(9)*1000).put("favorite",cur.getInt(10)==1).put("album",album.substringAfterLast('/').ifEmpty{"기타"}).put("bucket",album).put("live",live)
                if(rows.length()>0 && rows.toString().toByteArray().size+row.toString().toByteArray().size>maxBytes)break
                rows.put(row);next++;if(rows.length()>=limit)break
            }while(cur.moveToNext())
        }
        out.put("items",rows).put("next",next).put("total",total)
    }
    fun systemTrash(c:Context,q:JSONObject,out:JSONObject){
        val args=android.os.Bundle().apply{putInt(MediaStore.QUERY_ARG_MATCH_TRASHED,MediaStore.MATCH_INCLUDE);putString(android.content.ContentResolver.QUERY_ARG_SQL_SELECTION,"media_type IN (1,3) AND is_trashed=1");putString(android.content.ContentResolver.QUERY_ARG_SQL_SORT_ORDER,"date_expires DESC, _id DESC")}
        val rows=JSONArray();val offset=q.optInt("offset").coerceAtLeast(0);var next=offset;var total=0
        c.contentResolver.query(MediaStore.Files.getContentUri("external"),arrayOf("_id","_display_name","_data","date_expires"),args,null)?.use{cursor->total=cursor.count;if(cursor.moveToPosition(offset))do{val row=JSONObject().put("id","native:"+cursor.getLong(0)).put("name",cursor.getString(1) ?: "사진").put("original",cursor.getString(2) ?: "시스템 휴지통").put("deleted",0).put("expires",cursor.getLong(3)*1000);if(rows.length()>0 && rows.toString().toByteArray().size+row.toString().toByteArray().size>12000)break;rows.put(row);next++;if(rows.length()>=25)break}while(cursor.moveToNext())}
        out.put("trash",rows).put("next",next).put("total",total)
    }
 fun file(c:Context,path:String):File{val file=StorageBridge.engine(c).resolve(path);val mime=android.webkit.MimeTypeMap.getSingleton().getMimeTypeFromExtension(file.extension.lowercase()) ?: "";if(!file.isFile || (!mime.startsWith("image/")&&!mime.startsWith("video/")))throw StorageFault("media","사진 또는 영상 파일을 찾지 못했습니다");return file}
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
    private fun bitmapCopy(c:Context,uri:android.net.Uri,bytes:java.io.ByteArrayOutputStream){
        val small=c.contentResolver.loadThumbnail(uri,android.util.Size(96,96),null);small.compress(android.graphics.Bitmap.CompressFormat.JPEG,30,bytes);small.recycle()
    }
    fun thumbnail(c:Context,q:JSONObject,out:JSONObject) {
        val id=q.getString("id").toLong();require(id>=0)
        val uri=android.content.ContentUris.withAppendedId(MediaStore.Files.getContentUri("external"),id)
        val bitmap=c.contentResolver.loadThumbnail(uri,android.util.Size(if(q.optBoolean("fast"))320 else 160,if(q.optBoolean("fast"))320 else 160),null)
        val bytes=java.io.ByteArrayOutputStream();bitmap.compress(android.graphics.Bitmap.CompressFormat.JPEG,if(q.optBoolean("fast"))75 else 45,bytes);bitmap.recycle()
        val limit=if(q.optBoolean("fast"))90000 else 10000
        if(bytes.size()>limit){bytes.reset();bitmapCopy(c,uri,bytes)}
        require(bytes.size()<=limit)
        out.put("image",android.util.Base64.encodeToString(bytes.toByteArray(),android.util.Base64.NO_WRAP))
    }
}
