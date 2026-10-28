import Foundation
import SQLite3
@main struct PhotoDateRecoveryTests{
 static func main()throws{
  let root=FileManager.default.temporaryDirectory.appendingPathComponent("coolsync-date-tests-"+UUID().uuidString)
  defer{try?FileManager.default.removeItem(at:root)}
  let dbFolder=root.appendingPathComponent("test.photoslibrary/database");try FileManager.default.createDirectory(at:dbFolder,withIntermediateDirectories:true)
  let dbURL=dbFolder.appendingPathComponent("Photos.sqlite");var db:OpaquePointer?
  assert(sqlite3_open(dbURL.path,&db)==SQLITE_OK)
  assert(sqlite3_exec(db,"CREATE TABLE ZASSET(Z_PK INTEGER,ZDATECREATED REAL,ZWIDTH INTEGER,ZHEIGHT INTEGER);CREATE TABLE ZADDITIONALASSETATTRIBUTES(ZASSET INTEGER,ZORIGINALFILENAME TEXT,ZORIGINALFILESIZE INTEGER);INSERT INTO ZASSET VALUES(1,375679540,1280,720);INSERT INTO ZADDITIONALASSETATTRIBUTES VALUES(1,'image_12.jpg',134933);",nil,nil,nil)==SQLITE_OK);sqlite3_close(db)
  let bytes=try Data(contentsOf:dbURL)
  let record=PhotoLibraryDates.Record(identity:"correct",name:"image_12.JPG",size:134933,width:1280,height:720)
  let wrong=PhotoLibraryDates.Record(identity:"wrong",name:"image_12.JPG",size:134934,width:1280,height:720)
  let result=PhotoLibraryDates.read([record,wrong],libraries:[dbFolder.deletingLastPathComponent()]);assert(result["correct"] != nil && result["wrong"]==nil)
  let afterRead=try Data(contentsOf:dbURL);assert(afterRead==bytes)
  assert(sqlite3_open(dbURL.path,&db)==SQLITE_OK);sqlite3_exec(db,"INSERT INTO ZASSET VALUES(2,475679540,1280,720);INSERT INTO ZADDITIONALASSETATTRIBUTES VALUES(2,'image_12.jpg',134933);",nil,nil,nil);sqlite3_close(db)
  assert(PhotoLibraryDates.read([record],libraries:[dbFolder.deletingLastPathComponent()]).isEmpty)
  let copy=root.appendingPathComponent("copy.jpg");let content=Data("test-original-bytes".utf8);try content.write(to:copy)
  let modified=Date(timeIntervalSince1970:1787347042);try FileManager.default.setAttributes([.modificationDate:modified],ofItemAtPath:copy.path)
  try PhotoLibraryDates.applyExportDate(1480964714000,to:copy)
  let attrs=try FileManager.default.attributesOfItem(atPath:copy.path);assert(abs((attrs[.creationDate]as!Date).timeIntervalSince1970-1480964714)<1);assert((attrs[.modificationDate]as!Date)==modified)
  let afterExport=try Data(contentsOf:copy);assert(afterExport==content)
  assert(PhotoOrdering.filenameDate("20260404_215143.JPG") != nil)
  assert(PhotoOrdering.filenameDate("IMG_20260404_215143.JPG") != nil)
  assert(PhotoOrdering.filenameDate("Screen_Recording_2026-04-04-21-51-43.mp4") != nil)
  assert(PhotoOrdering.filenameDate("20260230_215143.JPG")==nil)
  assert(PhotoOrdering.filenameDate("1469673384885.JPG")==nil)
  assert(PhotoOrdering.filenameDate("396213_37880444872441_1916153240_n.JPG")==nil)
  print("PASS: read-only date lookup, ambiguous/wrong-file rejection, creation and modification dates preserved separately, bytes unchanged, explicit filename dates")
 }
}
