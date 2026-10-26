package app.coolsync

import android.content.Context
import android.net.Uri
import android.os.Environment
import android.os.Handler
import android.os.Looper
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.concurrent.Executors

object StorageBridge {
    private val worker=Executors.newSingleThreadExecutor()
    private val main=Handler(Looper.getMainLooper())
    fun engine(c:Context):StorageEngine {
        if(!Environment.isExternalStorageManager()) throw StorageFault("setup","휴대폰 CoolSync의 권한 설정에서 파일 관리를 허용하세요")
        return StorageEngine(Environment.getExternalStorageDirectory(),File(c.filesDir,"trash-index"))
    }
    fun handle(service:SyncService,message:JSONObject) {
        val sessionKey=Protocol.key(service) ?: return
        val reference=message.optString("ref")
        worker.execute {
            val response=JSONObject()
            try {
                if(SyncService.active!==service || !service.authenticated || !sessionKey.contentEquals(Protocol.key(service) ?: byteArrayOf())) return@execute
                val q=JSONObject(message.getString("text"));val fs=engine(service);val path=q.optString("path")
                java.util.UUID.fromString(reference)
                if(q.optString("op") in setOf("mkdir","touch","rename","copy","move","trash","restore","deletePermanent")){
                    val prefs=service.getSharedPreferences("fs-replay",0)
                    val seen=(prefs.getStringSet("ids",emptySet()) ?: emptySet()).toMutableSet()
                    if(reference in seen)throw StorageFault("duplicate","이미 처리한 요청입니다. 목록을 새로 고침하세요.")
                    if(seen.size>=4096)seen.clear()
                    seen.add(reference);prefs.edit().putStringSet("ids",seen).commit()
                }
                response.put("ok",true)
                when(q.getString("op")) {
                    "list" -> {
                        val items=fs.list(path);val start=q.optInt("offset",0).coerceIn(0,items.size);val rows=JSONArray();var next=start
                        for(item in items.drop(start).take(50)) {
                            val row=JSONObject().put("name",item.name).put("path",item.path).put("directory",item.directory).put("size",item.size).put("modified",item.modified)
                            if(rows.length()>0 && rows.toString().toByteArray().size+row.toString().toByteArray().size>24000)break
                            rows.put(row);next++
                        }
                        response.put("entries",rows).put("path",path).put("offset",start).put("next",next).put("total",items.size)
                        val root=Environment.getExternalStorageDirectory();response.put("free",root.usableSpace).put("capacity",root.totalSpace)
                    }
                    "mkdir" -> response.put("path",fs.create(path,q.getString("name"),true))
                    "touch" -> response.put("path",fs.create(path,q.getString("name"),false))
                    "rename" -> response.put("path",fs.rename(path,q.getString("name")))
                    "copy","move" -> fs.relocate(paths(q),q.getString("destination"),q.getString("op")=="copy")
                    "trash" -> fs.discard(paths(q))
                    "listTrash" -> {
                        val items=fs.listTrash();val start=q.optInt("offset",0).coerceIn(0,items.size);val rows=JSONArray();var next=start
                        for(item in items.drop(start).take(50)){
                            val row=JSONObject().put("id",item.id).put("name",item.name).put("original",item.original).put("deleted",item.deleted)
                            if(rows.length()>0 && rows.toString().toByteArray().size+row.toString().toByteArray().size>24000)break
                            rows.put(row);next++
                        }
                        response.put("trash",rows).put("next",next).put("total",items.size)
                    }
                    "restore" -> fs.restore(q.getString("id"))
                    "deletePermanent" -> fs.permanentDelete(q.getString("id"))
                    "download" -> {
                        if(FilesBridge.busy || FilesBridge.offer!=null)throw StorageFault("busy","진행 중인 파일 작업을 먼저 마치세요")
                        val file=fs.resolve(path);if(!file.isFile)throw StorageFault("file","다운로드할 파일을 선택하세요")
                        if(file.length()>FilesBridge.LIMIT)throw StorageFault("size","기기 간 전송은 파일당 256 MB 이하를 지원합니다")
                        main.post { if(service.authenticated) FilesBridge.select(service,Uri.fromFile(file),path) }
                    }
                    else -> throw StorageFault("operation","지원하지 않는 작업입니다")
                }
            } catch(e:StorageFault) { response.put("ok",false).put("code",e.code).put("error",e.message) }
            catch(_:SecurityException) { response.put("ok",false).put("code","permission").put("error","이 항목을 관리할 권한이 없습니다") }
            catch(_:Exception) { response.put("ok",false).put("code","io").put("error","파일 작업을 완료하지 못했습니다. 경로와 권한을 확인하세요.") }
            main.post { if(SyncService.active===service && service.authenticated && sessionKey.contentEquals(Protocol.key(service) ?: byteArrayOf())) service.sendControl("fsResponse",response.toString(),reference) }
        }
    }
    private fun paths(q:JSONObject):List<String> {val array=q.getJSONArray("paths");return (0 until array.length()).map{array.getString(it)}}
    data class Upload(val temporary:File,val final:File)
    fun prepareUpload(c:Context,parent:String,name:String):Upload {
        val fs=engine(c);val folder=fs.resolve(parent);if(!folder.isDirectory)throw StorageFault("directory","저장할 폴더가 아닙니다")
        if(name.isBlank()||name.any{it=='/'||it=='\\'||it.code<32}||name=="."||name==".."||name==".CoolSyncTrash")throw StorageFault("name","올바르지 않은 파일 이름입니다")
        val final=fs.resolve(listOf(parent,name).filter{it.isNotEmpty()}.joinToString("/"),false)
        if(final.exists())throw StorageFault("exists","같은 이름의 파일이 있습니다. 이름을 바꾸거나 기존 파일을 옮긴 뒤 다시 시도하세요.")
        val temporary=File(folder,".coolsync-${java.util.UUID.randomUUID()}.partial");if(!temporary.createNewFile())throw StorageFault("write","파일을 만들지 못했습니다")
        return Upload(temporary,final)
    }
}
