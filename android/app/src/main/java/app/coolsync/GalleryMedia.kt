package app.coolsync

import android.content.Context
import android.provider.MediaStore
import android.os.Environment
import org.json.JSONObject
import org.json.JSONArray
import java.io.File

/** Read-only catalog: capture date is never replaced by transfer or modification time. */
object GalleryMedia {
    fun list(c:Context,q:JSONObject,out:JSONObject) {
        val uri=MediaStore.Files.getContentUri("external")
        val cols=arrayOf("_id","_display_name","_data","_size","mime_type","datetaken","duration","width","height","bucket_display_name","is_favorite","date_added","relative_path","xmp")
        val rows=JSONArray();val offset=q.optInt("offset").coerceAtLeast(0);var total=0;var next=offset
        c.contentResolver.query(uri,cols,"media_type IN (1,3) AND is_pending=0 AND is_trashed=0",null,"datetaken DESC, _id DESC")?.use { cur ->
            total=cur.count
            if(cur.moveToPosition(offset)) do {
                val file=File(cur.getString(2) ?: "");val root=Environment.getExternalStorageDirectory().canonicalFile
                if(!file.canonicalPath.startsWith(root.path+"/")) {next++;continue}
                val xmp=cur.getBlob(13)?.toString(Charsets.UTF_8) ?: ""
                val live=Regex("""(?:MotionPhoto|MicroVideo)\s*=\s*["']1["']""").containsMatchIn(xmp) || xmp.contains(":MotionPhoto>1<") || (!cur.getString(4).orEmpty().startsWith("video/") && listOf("mov","MOV").any{File(file.parentFile,file.nameWithoutExtension+"."+it).isFile})
                val row=JSONObject().put("id",cur.getLong(0).toString()).put("name",cur.getString(1)).put("path",file.relativeTo(root).invariantSeparatorsPath).put("size",cur.getLong(3)).put("mime",cur.getString(4)).put("taken",cur.getLong(5)).put("duration",cur.getLong(6)).put("width",cur.getInt(7)).put("height",cur.getInt(8)).put("album",cur.getString(9) ?: "기타").put("favorite",cur.getInt(10)==1).put("added",cur.getLong(11)*1000).put("bucket",cur.getString(12) ?: "").put("live",live)
                if(rows.length()>0 && rows.toString().toByteArray().size+row.toString().toByteArray().size>12000)break
                rows.put(row);next++
                if(rows.length()>=35)break
            } while(cur.moveToNext())
        }
        out.put("items",rows).put("next",next).put("total",total)
    }
    fun systemTrash(c:Context,q:JSONObject,out:JSONObject){
        val args=android.os.Bundle().apply{putInt(MediaStore.QUERY_ARG_MATCH_TRASHED,MediaStore.MATCH_INCLUDE);putString(android.content.ContentResolver.QUERY_ARG_SQL_SELECTION,"media_type IN (1,3) AND is_trashed=1");putString(android.content.ContentResolver.QUERY_ARG_SQL_SORT_ORDER,"date_expires DESC, _id DESC")}
        val rows=JSONArray();val offset=q.optInt("offset").coerceAtLeast(0);var next=offset;var total=0
        c.contentResolver.query(MediaStore.Files.getContentUri("external"),arrayOf("_id","_display_name","_data","date_expires"),args,null)?.use{cursor->total=cursor.count;if(cursor.moveToPosition(offset))do{val row=JSONObject().put("id","native:"+cursor.getLong(0)).put("name",cursor.getString(1) ?: "사진").put("original",cursor.getString(2) ?: "시스템 휴지통").put("deleted",0).put("expires",cursor.getLong(3)*1000);if(rows.length()>0 && rows.toString().toByteArray().size+row.toString().toByteArray().size>12000)break;rows.put(row);next++;if(rows.length()>=25)break}while(cursor.moveToNext())}
        out.put("trash",rows).put("next",next).put("total",total)
    }
    private fun bitmapCopy(c:Context,uri:android.net.Uri,bytes:java.io.ByteArrayOutputStream){
        val small=c.contentResolver.loadThumbnail(uri,android.util.Size(96,96),null);small.compress(android.graphics.Bitmap.CompressFormat.JPEG,30,bytes);small.recycle()
    }
    fun thumbnail(c:Context,q:JSONObject,out:JSONObject) {
        val id=q.getString("id").toLong();require(id>=0)
        val uri=android.content.ContentUris.withAppendedId(MediaStore.Files.getContentUri("external"),id)
        val bitmap=c.contentResolver.loadThumbnail(uri,android.util.Size(160,160),null)
        val bytes=java.io.ByteArrayOutputStream();bitmap.compress(android.graphics.Bitmap.CompressFormat.JPEG,45,bytes);bitmap.recycle()
        if(bytes.size()>10000){bytes.reset();bitmapCopy(c,uri,bytes)}
        require(bytes.size()<=10000)
        out.put("image",android.util.Base64.encodeToString(bytes.toByteArray(),android.util.Base64.NO_WRAP))
    }
}
