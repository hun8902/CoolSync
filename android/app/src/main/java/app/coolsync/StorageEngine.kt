package app.coolsync

import java.io.File
import java.nio.file.*
import java.nio.file.attribute.BasicFileAttributes
import java.util.Properties
import java.util.UUID

class StorageFault(val code: String, message: String): Exception(message)
data class StorageEntry(val name:String,val path:String,val directory:Boolean,val size:Long,val modified:Long)
data class TrashEntry(val id:String,val name:String,val original:String,val deleted:Long)

/** All paths are relative to one explicitly granted shared-storage root. Never follows symlinks. */
class StorageEngine(root:File, private val metadata:File) {
    private val base=root.canonicalFile
    private val trash=File(base,".CoolSyncTrash")
    private fun fail(code:String,message:String):Nothing=throw StorageFault(code,message)
    fun resolve(relative:String,existing:Boolean=true):File {
        if(relative.length>4096 || relative.startsWith('/') || relative.contains('\\') || relative.contains('\u0000')) fail("path","올바르지 않은 경로입니다")
        val parts=relative.split('/').filter{it.isNotEmpty()}
        if(parts.any{it==".." || it=="." || it==".CoolSyncTrash"}) fail("path","이 경로에는 접근할 수 없습니다")
        var file=base
        for(part in parts) { file=File(file,part); if(Files.isSymbolicLink(file.toPath())) fail("link","심볼릭 링크는 지원하지 않습니다") }
        val canonical=file.canonicalFile
        if(canonical!=base && !canonical.path.startsWith(base.path+File.separator)) fail("path","공유한 저장소 밖에는 접근할 수 없습니다")
        if(existing && !canonical.exists()) fail("missing","파일이나 폴더를 찾지 못했습니다")
        return canonical
    }
    private fun relative(file:File)=file.relativeTo(base).invariantSeparatorsPath.let{if(it==".") "" else it}
    private fun mutable(path:String):File=resolve(path).also{if(it==base) fail("root","저장소 자체는 변경할 수 없습니다")}
    private fun name(value:String):String {
        if(value.isBlank() || value=="." || value==".." || value==".CoolSyncTrash" || value.any{it=='/'||it=='\\'||it.code<32} || value.toByteArray().size>255) fail("name","이름에 사용할 수 없는 문자가 있거나 너무 깁니다")
        return value
    }
    fun list(path:String):List<StorageEntry> {
        val directory=resolve(path);if(!directory.isDirectory) fail("directory","폴더가 아닙니다")
        val files=directory.listFiles() ?: fail("permission","이 폴더를 읽을 권한이 없습니다")
        return files.filter{it.name!=".CoolSyncTrash" && !Files.isSymbolicLink(it.toPath())}.map {
            StorageEntry(it.name,relative(it),it.isDirectory,if(it.isDirectory)0 else it.length(),it.lastModified())
        }.sortedWith(compareBy<StorageEntry>{!it.directory}.thenBy{it.name.lowercase()})
    }
    fun create(parent:String,value:String,directory:Boolean):String {
        val folder=resolve(parent);if(!folder.isDirectory) fail("directory","대상 폴더를 찾지 못했습니다")
        val target=resolve(listOf(parent,name(value)).filter{it.isNotEmpty()}.joinToString("/"),false)
        if(target.exists()) fail("exists","같은 이름의 파일이나 폴더가 있습니다")
        val ok=if(directory)target.mkdir() else target.createNewFile()
        if(!ok) fail("write","파일이나 폴더를 만들지 못했습니다")
        return relative(target)
    }
    fun rename(path:String,value:String):String {
        val source=mutable(path); val target=File(source.parentFile,name(value));resolve(relative(target),false)
        if(target.exists()) fail("exists","같은 이름의 파일이나 폴더가 있습니다")
        if(!source.renameTo(target)) fail("write","이름을 변경하지 못했습니다")
        return relative(target)
    }
    fun relocate(paths:List<String>,destination:String,copy:Boolean) {
        val folder=resolve(destination);if(!folder.isDirectory) fail("directory","대상 폴더를 찾지 못했습니다")
        val selected=topLevel(paths)
        val pairs=selected.map { path->
            val source=mutable(path);val target=File(folder,source.name);resolve(relative(target),false)
            if(target.exists()) fail("exists","${source.name}: 같은 이름의 항목이 있습니다")
            if(folder==source || folder.path.startsWith(source.path+File.separator)) fail("recursive","자기 자신의 안으로 복사하거나 이동할 수 없습니다")
            source to target
        }
        for((source,target) in pairs) {
            if(copy) { try { copyTree(source,target) } catch(e:Exception) { if(target.exists()) deleteTree(target);throw e } }
            else if(!source.renameTo(target)) fail("write","${source.name}: 이동하지 못했습니다")
        }
    }
    /** Exact duplicates are checked again on the phone immediately before moving copies to trash. */
    fun mergeIdentical(paths:List<String>):List<String> {
        if(paths.size !in 2..1000 || paths.distinct().size!=paths.size)fail("selection","서로 다른 중복 항목을 선택하세요")
        val files=paths.map{mutable(it).also{file->if(!file.isFile)fail("file","사진이나 영상 파일만 병합할 수 있습니다")}}
        fun digest(file:File):ByteArray {
            val length=file.length();val modified=file.lastModified();val hash=java.security.MessageDigest.getInstance("SHA-256")
            file.inputStream().buffered().use{input->val buffer=ByteArray(262144);while(true){val count=input.read(buffer);if(count<0)break;hash.update(buffer,0,count)}}
            if(file.length()!=length || file.lastModified()!=modified)fail("changed","원본이 변경되어 병합하지 않았습니다")
            return hash.digest()
        }
        val snapshots=files.map{it.length() to it.lastModified()}
        val expected=digest(files.first())
        for(file in files.drop(1))if(file.length()!=files.first().length() || !digest(file).contentEquals(expected))fail("changed","내용이 다른 파일은 병합할 수 없습니다. 다시 분석하세요.")
        for((index,file) in files.withIndex())if(file.length()!=snapshots[index].first || file.lastModified()!=snapshots[index].second)fail("changed","파일이 변경되어 병합하지 않았습니다")
        val removed=paths.drop(1);discard(removed);return removed
    }
    fun duplicateFile(path:String):String {
        val source=mutable(path);if(!source.isFile)fail("file","파일만 복제할 수 있습니다")
        val stem=source.nameWithoutExtension;val extension=source.extension.let{if(it.isEmpty())"" else ".$it"};var number=1
        var target=File(source.parentFile,"$stem 복사본$extension")
        while(target.exists()){number++;target=File(source.parentFile,"$stem 복사본 $number$extension")}
        resolve(relative(target),false)
        source.inputStream().use{input->Files.newOutputStream(target.toPath(),StandardOpenOption.CREATE_NEW,StandardOpenOption.WRITE).use{output->input.copyTo(output)}}
        return relative(target)
    }
    fun discard(paths:List<String>) {
        val selected=topLevel(paths).map{mutable(it)}
        checkTrash()
        if(!trash.exists() && !trash.mkdir()) fail("write","휴지통을 만들지 못했습니다")
        if(!metadata.exists() && !metadata.mkdirs()) fail("write","휴지통 정보를 저장하지 못했습니다")
        for(source in selected) {
            val id=UUID.randomUUID().toString();val folder=File(trash,id);if(!folder.mkdir()) fail("write","휴지통을 만들지 못했습니다")
            val info=Properties().apply{setProperty("path",relative(source));setProperty("name",source.name);setProperty("deleted",System.currentTimeMillis().toString())}
            val record=File(metadata,"$id.properties")
            try { record.writer().use{info.store(it,null)};File(folder,"info.properties").writer().use{info.store(it,null)};if(!source.renameTo(File(folder,"content"))) fail("write","${source.name}: 휴지통으로 옮기지 못했습니다") }
            catch(e:Exception){record.delete();File(folder,"info.properties").delete();folder.delete();throw e}
        }
    }
    fun listTrash():List<TrashEntry> { checkTrash();rebuildIndex();return (metadata.listFiles() ?: emptyArray()).mapNotNull{file->
        try { val id=file.name.removeSuffix(".properties");UUID.fromString(id);val info=Properties().apply{file.reader().use{load(it)}};if(!File(trash,"$id/content").exists())null else TrashEntry(id,info.getProperty("name"),info.getProperty("path"),info.getProperty("deleted").toLong()) }catch(_:Exception){null}
    }.sortedByDescending{it.deleted} }
    fun restore(id:String) {
        val source=trashItem(id);val record=File(metadata,"$id.properties");val info=Properties().apply{record.reader().use{load(it)}}
        val target=resolve(info.getProperty("path"),false)
        val parent=target.parentFile ?: fail("path","원래 경로가 올바르지 않습니다")
        if(target.exists()) fail("exists","원래 위치에 같은 이름의 항목이 있습니다")
        if(!parent.exists() && !parent.mkdirs()) fail("write","원래 폴더를 만들지 못했습니다")
        if(!source.renameTo(target)) fail("write","복원하지 못했습니다")
        source.parentFile?.let{File(it,"info.properties").delete();it.delete()};record.delete()
    }
    fun permanentDelete(id:String) { val source=trashItem(id);deleteTree(source);source.parentFile?.let{File(it,"info.properties").delete();it.delete()};File(metadata,"$id.properties").delete() }
    private fun checkTrash(){if(Files.isSymbolicLink(trash.toPath()) || (trash.exists() && (!trash.isDirectory || trash.canonicalFile.parentFile!=base)))fail("path","휴지통 경로가 올바르지 않습니다")}
    private fun rebuildIndex(){
        if(!trash.isDirectory)return
        metadata.mkdirs()
        for(folder in trash.listFiles() ?: emptyArray()){
            try{
                UUID.fromString(folder.name)
                if(Files.isSymbolicLink(folder.toPath()) || folder.canonicalFile.parentFile!=trash.canonicalFile)continue
                val info=File(folder,"info.properties");val content=File(folder,"content")
                if(!info.isFile || !content.exists() || Files.isSymbolicLink(info.toPath()) || Files.isSymbolicLink(content.toPath()))continue
                val target=File(metadata,"${folder.name}.properties");if(!target.exists())info.copyTo(target)
            }catch(_:Exception){}
        }
    }
    private fun trashItem(id:String):File {
        checkTrash();rebuildIndex()
        try{UUID.fromString(id)}catch(_:Exception){fail("path","올바르지 않은 휴지통 항목입니다")}
        val source=File(trash,"$id/content");if(Files.isSymbolicLink(source.parentFile!!.toPath()) || Files.isSymbolicLink(source.toPath()) || source.canonicalFile.parentFile?.parentFile!=trash.canonicalFile)fail("path","휴지통 항목 경로가 올바르지 않습니다");if(!source.exists())fail("missing","휴지통 항목을 찾지 못했습니다");return source
    }
    private fun topLevel(paths:List<String>):List<String> {
        if(paths.isEmpty() || paths.size>1000) fail("selection","선택한 항목 수를 확인하세요")
        val result=ArrayList<String>()
        for(path in paths.distinct().sortedBy{it.length}) { mutable(path);if(result.none{path==it || path.startsWith("$it/")})result.add(path) }
        return result
    }
    private fun copyTree(source:File,target:File) {
        val start=source.toPath()
        Files.walkFileTree(start,object:SimpleFileVisitor<Path>(){
            override fun preVisitDirectory(dir:Path,attributes:BasicFileAttributes):FileVisitResult {
                resolve(relative(dir.toFile()));Files.createDirectory(target.toPath().resolve(start.relativize(dir)));return FileVisitResult.CONTINUE
            }
            override fun visitFile(file:Path,attributes:BasicFileAttributes):FileVisitResult {
                resolve(relative(file.toFile()));if(attributes.isSymbolicLink)fail("link","심볼릭 링크는 복사하지 않습니다")
                Files.copy(file,target.toPath().resolve(start.relativize(file)));return FileVisitResult.CONTINUE
            }
        })
    }
    private fun deleteTree(file:File) {
        Files.walkFileTree(file.toPath(),object:SimpleFileVisitor<Path>(){
            override fun visitFile(path:Path,attrs:BasicFileAttributes):FileVisitResult{Files.delete(path);return FileVisitResult.CONTINUE}
            override fun postVisitDirectory(path:Path,error:java.io.IOException?):FileVisitResult{if(error!=null)throw error;Files.delete(path);return FileVisitResult.CONTINUE}
        })
    }
}
