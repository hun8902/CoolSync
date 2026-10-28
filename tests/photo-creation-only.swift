import Foundation
@main struct Check {
 static func main(){
  for source in ["modified","created","added","filename","unknown"]{precondition(PhotoCreationOrdering.time(1782160858534,source:source)==0)}
  for source in ["captured","exif","video"]{precondition(PhotoCreationOrdering.time(1163494500000,source:source)==1163494500000)}
  precondition(PhotoCreationOrdering.time(0,source:"captured")==0)
  precondition(PhotoCreationOrdering.time(1782160858534,source:nil)==0)
  print("PASS: modification, filesystem, added, filename and unknown dates excluded; only original media date accepted")
 }
}
