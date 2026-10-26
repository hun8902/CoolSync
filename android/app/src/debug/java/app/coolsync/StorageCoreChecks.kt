package app.coolsync
import java.io.File
import java.nio.file.Files

object StorageCoreChecks {
 @JvmStatic fun main(args:Array<String>){
  val folder=File(args[0]);require(!folder.exists() || folder.listFiles()?.isEmpty()==true){"Use a fresh, empty test directory"};folder.mkdirs();val root=File(folder,"root").apply{mkdirs()};val db=File(folder,"index");val fs=StorageEngine(root,db)
  val outside=File(folder,"outside.txt").apply{writeText("outside sentinel")}
  fs.create("","A",true);fs.create("A","note.txt",false);File(root,"A/note.txt").writeText("한글\nData 😀")
  fs.rename("A/note.txt","renamed.txt");check(fs.list("A").single().name=="renamed.txt")
  fs.create("","B",true);fs.relocate(listOf("A"),"B",true);check(File(root,"B/A/renamed.txt").readText()=="한글\nData 😀")
  File(root,"A/renamed.txt").writeText("changed");check(File(root,"B/A/renamed.txt").readText()!="changed")
  fs.create("","C",true);fs.relocate(listOf("B/A"),"C",false);check(!File(root,"B/A").exists());check(File(root,"C/A/renamed.txt").exists())
  fs.discard(listOf("A","A/renamed.txt"));check(!File(root,"A").exists());check(fs.listTrash().size==1)
  val id=fs.listTrash().single().id;db.deleteRecursively();check(StorageEngine(root,db).listTrash().size==1);StorageEngine(root,db).restore(id);check(File(root,"A/renamed.txt").readText()=="changed")
  fs.discard(listOf("C/A"));val permanent=fs.listTrash().single().id;fs.permanentDelete(permanent);check(fs.listTrash().isEmpty())
  for(path in listOf("../outside.txt","/tmp","A/../../outside.txt",".CoolSyncTrash")){check(runCatching{fs.resolve(path)}.isFailure)}
  check(runCatching{fs.relocate(listOf("A"),"A",true)}.isFailure)
  check(runCatching{fs.create("","../escape",false)}.isFailure)
  check(runCatching{fs.rename("A","B")}.isFailure)
  if(args.getOrNull(1)!="android"){
   Files.createSymbolicLink(File(root,"B/link").toPath(),outside.toPath());check(runCatching{fs.resolve("B/link")}.isFailure);check(fs.list("B").none{it.name=="link"})
  }
  check(outside.readText()=="outside sentinel")
  println("Storage core: PASS (create/list/rename, recursive copy/move, trash/restore/permanent delete, traversal and collision rejection; external sentinel preserved)")
 }
}
