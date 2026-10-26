import AppKit
let folder=URL(fileURLWithPath:CommandLine.arguments[1]);let h=ClipHistory(folder:folder,recording:true)
precondition(h.entries.isEmpty)
h.add(text:"one",source:"test");let id=h.entries[0].id;h.favorite(id);h.add(text:"one",source:"test");precondition(h.entries.count==1 && h.entries[0].favorite)
for i in 0..<210{h.add(text:"item-\(i)",source:"test")};precondition(h.entries.count==200 && h.entries.contains{$0.text=="one" && $0.favorite})
let restored=ClipHistory(folder:folder,recording:true);precondition(restored.entries.count==200)
let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:8,pixelsHigh:8,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
let url=folder.appendingPathComponent("fixture.png");try bitmap.representation(using:.png,properties:[:])!.write(to:url);h.add(image:url,source:"test");let image=h.entries[0];precondition(image.image != nil);h.remove(image.id);precondition(!FileManager.default.fileExists(atPath:folder.appendingPathComponent(image.image!).path))
h.enabled=false;let count=h.entries.count;h.add(text:"not-recorded",source:"test");precondition(h.entries.count==count);h.clear();precondition(h.entries.isEmpty)
print("History PASS: dedup, favorite retention, 200-item bound, persistence, image deletion, recording disabled, clear")
