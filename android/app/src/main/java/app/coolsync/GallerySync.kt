package app.coolsync

import android.content.Context
import android.provider.MediaStore
import android.util.AtomicFile
import org.json.*
import java.io.File
import java.security.MessageDigest
import java.util.UUID

/** Request-driven immutable metadata snapshots; no polling or original-file downloads. */
object GallerySync {
 private data class Batch(val revision:String,val reset:Boolean,val events:List<JSONObject>)
 private val batches=LinkedHashMap<String,Batch>()
 private fun hash(s:String)=MessageDigest.getInstance("SHA-256").digest(s.toByteArray()).joinToString(""){"%02x".format(it)}
 private fun folder(c:Context)=File(c.filesDir,"gallery-sync/"+hash(Protocol.key(c)?.joinToString(""){"%02x".format(it)} ?: "none")).apply{mkdirs()}
 private fun read(f:File)=runCatching{JSONObject(AtomicFile(f).readFully().toString(Charsets.UTF_8))}.getOrNull()
 private fun write(f:File,value:JSONObject){val atomic=AtomicFile(f);val stream=atomic.startWrite();try{stream.write(value.toString().toByteArray());atomic.finishWrite(stream)}catch(e:Exception){atomic.failWrite(stream);throw e}}
 private fun snapshot(c:Context):Pair<String,JSONObject>{
  val dir=folder(c)
  val volumes=MediaStore.getExternalVolumeNames(c).sorted()
  val version=volumes.joinToString("|"){it+":"+MediaStore.getVersion(c,it)}
  val generation=volumes.joinToString("|"){it+":"+MediaStore.getGeneration(c,it)}
  val prefs=c.getSharedPreferences("gallery",0)
  val stamp=hash(JSONObject().put("schema",8).put("version",version).put("generation",generation).put("local",prefs.getString("syncChange","")).put("favorites",JSONArray((prefs.getStringSet("favorites",emptySet()) ?: emptySet()).sorted())).put("albums",JSONArray((prefs.getStringSet("albums",emptySet()) ?: emptySet()).sorted())).toString())
  // A deleted row need not change the remaining rows' maximum generation.
  // Rebuild once per requested snapshot, including reconnect after the service was stopped.
  val rows=JSONArray(GalleryMedia.syncRows(c).sortedBy{it.getString("id")})
  val albumResult=JSONObject();GalleryMedia.handle(c,JSONObject().put("op","mediaAlbums"),albumResult)
  val value=JSONObject().put("version",version).put("items",rows).put("albums",albumResult.getJSONArray("albums"))
  val token=hash(value.toString());write(File(dir,"$token.json"),value);write(File(dir,"latest.json"),JSONObject().put("stamp",stamp).put("revision",token))
  dir.listFiles()?.filter{it.name.matches(Regex("[a-f0-9]{64}\\.json"))}?.sortedByDescending{it.lastModified()}?.drop(4)?.forEach{it.delete()}
  return token to value
 }
 @Synchronized fun sync(c:Context,q:JSONObject,out:JSONObject){
  var batchID=q.optString("batch")
  val batch=if(batchID.isNotEmpty())batches[batchID] ?: throw StorageFault("snapshotExpired","사진 목록이 갱신되었습니다. 다시 동기화하세요") else {
   val (revision,current)=snapshot(c);val since=q.optString("since")
   val old=if(since.matches(Regex("[a-f0-9]{64}")))read(File(folder(c),"$since.json"))else null
   val reset=old==null || old.optString("version")!=current.optString("version")
   fun map(value:JSONObject?,key:String,id:String):Map<String,JSONObject>{val a=value?.optJSONArray(key) ?: JSONArray();return(0 until a.length()).associate{val row=a.getJSONObject(it);row.getString(id) to row}}
   val before=if(reset)emptyMap()else map(old,"items","id");val after=map(current,"items","id")
   val beforeAlbums=if(reset)emptyMap()else map(old,"albums","path");val afterAlbums=map(current,"albums","path")
   val events=mutableListOf<JSONObject>()
   for(id in before.keys-after.keys)events.add(JSONObject().put("removed",id))
   for((id,item) in after)if(before[id]?.toString()!=item.toString())events.add(JSONObject().put("item",item))
   for(path in beforeAlbums.keys-afterAlbums.keys)events.add(JSONObject().put("removedAlbum",path))
   for((path,album) in afterAlbums)if(beforeAlbums[path]?.toString()!=album.toString())events.add(JSONObject().put("album",album))
   batchID=UUID.randomUUID().toString();val value=Batch(revision,reset,events);batches[batchID]=value
   while(batches.size>3)batches.remove(batches.keys.first());value
  }
  val start=q.optInt("offset").coerceIn(0,batch.events.size);val rows=JSONArray();var next=start;var size=0
  for(event in batch.events.drop(start).take(40)){val bytes=event.toString().toByteArray().size;if(rows.length()>0&&size+bytes>20000)break;rows.put(event);size+=bytes;next++}
  out.put("dateSchema",8).put("batch",batchID).put("revision",batch.revision).put("reset",batch.reset).put("events",rows).put("next",next).put("total",batch.events.size)
 }
 @Synchronized fun trash(c:Context,q:JSONObject,out:JSONObject,rescan:Boolean=true,known:Map<String,JSONObject>?=null){
  if(q.has("items")){
   val values=q.getJSONArray("items");if(values.length() !in 1..20)throw StorageFault("selection","한 번에 20개 이하의 삭제를 요청하세요")
   val rows=GalleryMedia.syncRows(c).associateBy{it.getString("id")}
   val results=JSONArray();val changed=mutableListOf<String>()
   for(i in 0 until values.length()){
    val request=values.getJSONObject(i);val result=JSONObject().put("operation",request.getString("operation"))
    try{trash(c,request,result,false,rows);result.put("ok",true);if(result.has("path"))changed.add(result.getString("path"))}
    catch(e:StorageFault){result.put("ok",false).put("code",e.code).put("error",e.message)}
    catch(_:Exception){result.put("ok",false).put("error","사진 삭제를 완료하지 못했습니다. 다시 시도하세요")}
    results.put(result)
   }
   GalleryMedia.rescan(c,changed);out.put("results",results);return
  }
  val operation=q.getString("operation");UUID.fromString(operation)
  val receipts=c.getSharedPreferences("gallery-trash-receipts",0)
  val expected=q.getJSONObject("item");val path=expected.getString("path");val fs=StorageBridge.engine(c)
  if(receipts.contains(operation)){if(fs.resolve(path,false).exists())throw StorageFault("conflict","삭제했던 경로에 파일이 다시 있습니다. 삭제 대기를 취소하고 최신 사진을 선택하세요");out.put("alreadyApplied",true).put("path",path);if(rescan)GalleryMedia.rescan(c,listOf(path));return}
  val current=known?.get(expected.getString("id")) ?: if(known==null)GalleryMedia.syncRows(c).firstOrNull{it.getString("id")==expected.getString("id")}else null
  if(current==null&&!fs.resolve(path,false).exists()){out.put("alreadyApplied",true).put("path",path);if(rescan)GalleryMedia.rescan(c,listOf(path));return}
  if(current==null||listOf("path","size","modified").any{current.optString(it)!=expected.optString(it)})throw StorageFault("conflict","휴대폰에서 변경된 사진입니다. 삭제 대기를 취소하고 최신 사진을 다시 선택하세요")
  val file=fs.resolve(path)
  if(file.length()!=expected.getLong("size")||file.lastModified()/1000!=expected.getLong("modified")/1000)throw StorageFault("conflict","사진 파일이 변경되어 삭제하지 않았습니다")
  fs.discard(listOf(path));if(fs.resolve(path,false).exists())throw StorageFault("write","휴대폰 원본이 남아 있어 삭제 완료로 처리하지 않았습니다");val editor=receipts.edit();if(receipts.all.size>2000)editor.clear();editor.putBoolean(operation,true).commit()
  out.put("path",path);if(rescan)GalleryMedia.rescan(c,listOf(path))
 }
}
