import Foundation
import AppKit
@main struct MessageTests {
 static func main()throws{
  assert(MessageCodes.extract("인증번호 [482913] 입니다")=="482913")
  assert(MessageCodes.extract("Your verification code is 830124.")=="830124")
  assert(MessageCodes.extract("결제금액 45000원")==nil)
  assert(MessageCodes.extract("verification 1234567890")==nil)
  let inbox=MessageInbox()
  let row=["eventID":"one","kind":"sms","package":"sms","app":"문자 메시지","title":"01000000000","body":"인증번호 482913","thread":"sms:01000000000","postedAt":"10000","sensitive":"true"]
  let entry=inbox.receive(row)!
  assert(entry.hidden(true) && !entry.hidden(false));assert(entry.code=="482913")
  inbox.receive(row);assert(inbox.items.count==1)
  var imported=row;imported["eventID"]="sms-db:1";inbox.receive(imported);assert(inbox.items.count==1)
  var redacted=row;redacted["eventID"]="redacted";redacted["body"]="민감한 내용 숨김";redacted["redacted"]="true";redacted["postedAt"]="20000"
  let hidden=inbox.receive(redacted)!;assert(hidden.hidden(false) && hidden.code==nil)
  var appRow=row;appRow["eventID"]="app";appRow["kind"]="app";appRow["title"]="인증번호 482913";appRow["app"]="테스트 앱";appRow["thread"]="app"
  assert(inbox.receive(appRow)!.displayTitle(true)=="테스트 앱")
  inbox.search="482913";assert(inbox.threads.isEmpty);inbox.search=""
  for i in 0..<505{inbox.receive(["eventID":"cap-\(i)","body":"sample","postedAt":String(30000+i)])}
  assert(inbox.items.count==500 && inbox.items.first!.id=="cap-504")
  let directory=FileManager.default.temporaryDirectory.appendingPathComponent("coolsync-message-test-"+UUID().uuidString)
  defer{try?FileManager.default.removeItem(at:directory)}
  let store=MessageInbox();let identity=Data(repeating:1,count:32);store.configure(identity:identity,baseDirectory:directory);store.receive(row)
  let reopened=MessageInbox();reopened.configure(identity:identity,baseDirectory:directory);assert(reopened.items.count==1)
  let another=MessageInbox();another.configure(identity:Data(repeating:2,count:32),baseDirectory:directory);assert(another.items.isEmpty)
  var offsets:[Int]=[];let history=MessageInbox();history.request={offsets.append($0)};history.refresh();assert(offsets==[0]);history.page(["items":[row],"next":1,"total":2]);assert(offsets==[0,1]);history.page(["items":[redacted],"next":2,"total":2]);assert(!history.syncing && history.items.count==2)
  print("PASS: OTP detection, redaction, title/search privacy, SMS deduplication, 500-entry cap, persistence, pairing isolation, history pagination")
 }
}
