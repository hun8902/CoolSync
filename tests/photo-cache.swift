import Foundation
import AppKit
let root=URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent("fixture-"+UUID().uuidString)
try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
defer{try?FileManager.default.removeItem(at:root)}
func model(_ owner:String="A")->GalleryModel {let explorer=ExplorerModel();explorer.connected={true};return GalleryModel(explorer:explorer,store:PhotoLibraryStore(folder:root.appendingPathComponent(owner)),cacheFolder:root.appendingPathComponent("cache"))}
func row(_ id:String="1",modified:Int64?=1000)->GalleryItem{GalleryItem(id:id,name:"one.jpg",path:"DCIM/one.jpg",size:4,mime:"image/jpeg",taken:1000,duration:0,width:10,height:10,album:"Camera",favorite:false,modified:modified)}
let a=model();let item=row();a.items=[item];a.sync.phase = .ready
var calls=0;a.readOverride={_,_,_ in calls+=1}
for _ in 0..<10{a.ensureLoaded()};precondition(calls==0,"reentry must not request catalog")
a.items=[];a.ensureLoaded();precondition(calls==0,"confirmed empty catalog must not reload")
a.sync.phase = .idle;a.ensureLoaded();a.ensureLoaded();precondition(calls==1 && a.loading,"initial entry must issue exactly one request")
a.cancelPhotoLoad();a.items=[item];a.sync.phase = .ready;a.saveCatalogCache()
let restarted=model();restarted.readCatalogCache();precondition(restarted.items.count==1 && restarted.sync.cached)
var freshCalls=0;restarted.readOverride={_,_,_ in freshCalls+=1};restarted.ensureLoaded();restarted.ensureLoaded();precondition(freshCalls==1,"cached catalog revalidates only once")
let url=a.originalCacheURL(item);try Data([1,2,3,4]).write(to:url)
var cacheHit=false;restarted.fetch(item){result in precondition((try?result.get())==url);cacheHit=true};precondition(cacheHit,"persisted original must be reused synchronously")
precondition(model("B").originalCacheURL(item) != url,"different phone must not share originals")
precondition(a.originalCacheURL(row(modified:2000)) != url,"same path/size/capture time with changed file version must miss")
let thumbnail=a.thumbnailURL(item);precondition(a.thumbnailURL(row(modified:2000)) != thumbnail)
try Data([1,2]).write(to:url);precondition(!a.validOriginalCache(url,item),"truncated cache must be rejected")
let changed=model();changed.items=[row("1"),row("2")];let old=row("2");changed.thumbnails[old.id]=NSImage(size:NSSize(width:2,height:2));changed.downloaded[old.path]=url
var pages:[([String:Any])->Void]=[];changed.readOverride={op,_,done in if op=="gallery"{pages.append(done)}else{done(["ok":false])}}
changed.reload()
func reply(_ item:GalleryItem,_ next:Int)->[String:Any]{let data=try!JSONEncoder().encode([item]);return ["ok":true,"items":try!JSONSerialization.jsonObject(with:data),"next":next,"total":2]}
pages.removeFirst()(reply(row("1"),1));pages.removeFirst()(reply(row("2",modified:2000),2))
precondition(changed.thumbnails["2"]==nil && changed.downloaded[old.path]==nil,"later-page changed originals and previews must invalidate")
let legacyData=try JSONEncoder().encode(row(modified:nil));let legacy=try JSONDecoder().decode(GalleryItem.self,from:legacyData);precondition(legacy.modified==nil)
print("PASS: reentry and empty catalog make zero requests; first load and cache revalidation once; persisted original reused after restart; device/file-version isolation; truncated originals rejected; late-page memory invalidation; legacy decoding")
