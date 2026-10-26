package app.coolsync

import android.Manifest
import android.app.*
import android.bluetooth.BluetoothAdapter
import android.content.*
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.net.Uri
import android.os.*
import android.provider.Settings
import android.view.*
import android.widget.*

class MainActivity:Activity() {
    private val prefs by lazy{getSharedPreferences("sync",0)}
    private var animateTab=false
    private var historyFilter=false
    private var selectedTab=0
    private var renderedTab=0
    private var activeScroll:ScrollView?=null
    private val scrollOffsets=IntArray(4)
    private var pairingDialog:Dialog?=null
    private var connectionDetail:TextView?=null
    private var connectionBadge:TextView?=null
    private var autoConnect=false
    private var pending=false
    private var observed=false
    private var wizard:Dialog?=null
    private var wizardContinue:TextView?=null
    private var wizardBody:LinearLayout?=null
    private var ink=Color.BLACK
    private var secondary=Color.GRAY
    private var paper=Color.WHITE
    private var liveFingerprint=""
    private val values=HashMap<String,TextView>()
    private val details=HashMap<String,TextView>()
    private val blue=0xff007aff.toInt()
    private val receiver=object:BroadcastReceiver(){override fun onReceive(c:Context?,i:Intent?){refreshLive();refreshWizard()}}
    private fun dp(n:Int)=(n*resources.displayMetrics.density).toInt()
    override fun onCreate(state:Bundle?){super.onCreate(state);selectedTab=state?.getInt("tab",0) ?: 0;window.setDecorFitsSystemWindows(false);render();consume(intent)}
    override fun onSaveInstanceState(out:Bundle){out.putInt("tab",selectedTab);super.onSaveInstanceState(out)}
    override fun onNewIntent(value:Intent){super.onNewIntent(value);intent=value;consume(value);render()}
    // Android 12 uses a signature permission in place of Android 13's non-exported receiver flag.
    @android.annotation.SuppressLint("UnspecifiedRegisterReceiverFlag")
    override fun onResume(){
        super.onResume()
        AppUpdates.resume(this)
        if(!observed){if(Build.VERSION.SDK_INT>=33)registerReceiver(receiver,IntentFilter(SyncService.STATE),RECEIVER_NOT_EXPORTED)else registerReceiver(receiver,IntentFilter(SyncService.STATE),"$packageName.INTERNAL",null);observed=true}
        AppUpdates.changed={if(!isFinishing)render()};AppUpdates.automatic(this)
        render();refreshWizard()
        if(autoConnect || prefs.getBoolean("enabled",false))begin(false)
        if(!prefs.getBoolean("onboardingSeen",false)){prefs.edit().putBoolean("onboardingSeen",true).apply();window.decorView.post{showPermissions()}}
    }
    override fun onPause(){AppUpdates.changed=null;if(observed){unregisterReceiver(receiver);observed=false};super.onPause()}
    private fun nearby()=checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT)==PackageManager.PERMISSION_GRANTED && checkSelfPermission(Manifest.permission.BLUETOOTH_ADVERTISE)==PackageManager.PERMISSION_GRANTED
    private fun accessibility()=Settings.Secure.getString(contentResolver,Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES)?.contains("$packageName/",true)==true
    private fun notifications()=Build.VERSION.SDK_INT<33 || checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS)==PackageManager.PERMISSION_GRANTED
    private fun notificationAccess()=Settings.Secure.getString(contentResolver,"enabled_notification_listeners")?.split(':')?.any{ComponentName.unflattenFromString(it)?.packageName==packageName}==true
    private fun notificationSettings(){startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS))}
    private fun storage()=Environment.isExternalStorageManager()
    private fun consume(value:Intent){
        val uri=value.data
        if(uri?.scheme=="coolsync" && uri.host=="pair"){
            val key=uri.getQueryParameter("key")?.lowercase()
            if(key?.matches(Regex("[a-f0-9]{64}"))!=true){showIssue("연결 정보를 확인하세요","Mac에서 복사한 연결 키 또는 CoolSync 연결 링크를 붙여넣어 주세요.");return}
            val previous=prefs.getString("key","")
            fun save(){stopService(Intent(this,SyncService::class.java));prefs.edit().putString("key",key).putString("macName",uri.getQueryParameter("name")?.take(80) ?: "Mac").remove("connectionIssue").putBoolean("enabled",true).apply();autoConnect=true;begin(true);render()}
            if(!previous.isNullOrEmpty() && previous!=key){val(d,b)=sheet("연결할 Mac 변경");b.addView(label("기존 Mac 대신 새 Mac에 연결합니다.",15f,secondary));space(b,16);button(b,"변경하고 연결"){d.dismiss();save()};button(b,"취소",false){d.dismiss()}}else save()
            value.data=null
        }
        if(value.action==Intent.ACTION_SEND){@Suppress("DEPRECATION")val uri=value.getParcelableExtra<Uri>(Intent.EXTRA_STREAM);if(uri!=null)FilesBridge.select(this,uri);value.action=Intent.ACTION_MAIN}
    }
    private fun begin(request:Boolean){
        if(Protocol.key(this)==null){if(request)manualKey();return}
        if(!nearby()){if(request || autoConnect)showPermissions();return}
        if(checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT)!=PackageManager.PERMISSION_GRANTED)return
        val adapter=getSystemService(android.bluetooth.BluetoothManager::class.java).adapter
        if(adapter?.isEnabled!=true){if((request||autoConnect)&&!pending){pending=true;@Suppress("DEPRECATION")startActivityForResult(Intent(BluetoothAdapter.ACTION_REQUEST_ENABLE),30)};return}
        try{prefs.edit().putBoolean("enabled",true).apply();startForegroundService(Intent(this,SyncService::class.java));autoConnect=false}catch(e:Exception){showIssue("연결을 시작하지 못했습니다", "시스템이 백그라운드 연결 시작을 거부했습니다. 앱을 연 상태에서 다시 연결해 주세요.\n"+e.javaClass.simpleName)}
    }
    private fun requestRuntime(){
        if(pending)return
        val missing=mutableListOf<String>()
        if(!nearby()){missing+=Manifest.permission.BLUETOOTH_CONNECT;missing+=Manifest.permission.BLUETOOTH_ADVERTISE}
        if(Build.VERSION.SDK_INT>=33 && !notifications())missing+=Manifest.permission.POST_NOTIFICATIONS
        if(missing.isNotEmpty()){pending=true;requestPermissions(missing.toTypedArray(),10)}
    }
    private fun requestMediaLocation(){if(pending)return;val permissions=mutableListOf(Manifest.permission.ACCESS_MEDIA_LOCATION);if(Build.VERSION.SDK_INT>=33){permissions+=Manifest.permission.READ_MEDIA_IMAGES;permissions+=Manifest.permission.READ_MEDIA_VIDEO}else permissions+=Manifest.permission.READ_EXTERNAL_STORAGE;val missing=permissions.filter{checkSelfPermission(it)!=PackageManager.PERMISSION_GRANTED};if(missing.isNotEmpty()){pending=true;requestPermissions(missing.toTypedArray(),11)}}
    private fun special(kind:Int){
        try{if(kind==1)startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))else startActivity(Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,Uri.parse("package:$packageName")))}
        catch(_:Exception){toast("시스템 설정에서 CoolSync 권한을 확인하세요")}
    }
    private fun nextPermission(){when{!nearby()->requestRuntime();!accessibility()->special(1);!storage()->special(2);else->{wizard?.dismiss();prefs.edit().putBoolean("onboardingComplete",true).apply();if(autoConnect)begin(false)}}}
    private fun showPermissions(){
        if(isFinishing)return
        if(wizard?.isShowing==true){refreshWizard();return}
        val dialog=Dialog(this);val content=column();content.setPadding(dp(24),dp(24),dp(24),dp(16));content.background=shape(paper,24)
        content.addView(label("권한 설정",23f,ink,true));space(content,16)
        val body=column();wizardBody=body;val scroll=ScrollView(this);scroll.addView(body);content.addView(scroll,LinearLayout.LayoutParams(-1,0,1f))
        space(content,16);button(content,"설정 계속"){nextPermission()};wizardContinue=content.getChildAt(content.childCount-2) as TextView;button(content,"나중에",false){dialog.dismiss()}
        dialog.setContentView(content);dialog.window?.setBackgroundDrawableResource(android.R.color.transparent);wizard=dialog
        dialog.setOnDismissListener{wizardBody=null;wizardContinue=null;wizard=null;render()};dialog.show()
        dialog.window?.setLayout(dp((resources.configuration.screenWidthDp-40).coerceAtMost(380)),dp((resources.configuration.screenHeightDp-64).coerceAtMost(620)))
        refreshWizard()
    }

    private fun refreshWizard(){
        val body=wizardBody ?: return;body.removeAllViews()
        body.addView(label("필요한 권한을 여기서 한 번에 확인합니다. 실제 허용은 안드로이드 시스템 화면에서 진행됩니다.",14f,secondary));space(body,18)
        permissionRow(body,"주변 기기","Mac과 Bluetooth로 연결",nearby()){requestRuntime()}
        permissionRow(body,"자동 복사","복사 동작 감지 · 접근성 설정",accessibility()){special(1)}
        permissionRow(body,"파일 관리","Mac에서 내부 저장소 탐색·편집",storage()){special(2)}
        permissionRow(body,"사진 촬영 위치","사진첩에서 촬영 장소 표시 · 선택 사항",checkSelfPermission(Manifest.permission.ACCESS_MEDIA_LOCATION)==PackageManager.PERMISSION_GRANTED){requestMediaLocation()}
        permissionRow(body,"알림","연결 상태 표시 · 선택 사항",notifications()){requestRuntime()}
        permissionRow(body,"Mac으로 알림 공유","다른 앱의 알림 전달 · 선택 사항",notificationAccess()){notificationSettings()}
        space(body,14);body.addView(label("파일 관리 권한도 앱 전용 데이터나 시스템 보호 폴더를 열 수 있게 하지는 않습니다.",12f,secondary))
        wizardContinue?.text=if(nearby()&&accessibility()&&storage())"완료"else "설정 계속"
    }
    private fun permissionRow(parent:LinearLayout,title:String,detail:String,granted:Boolean,action:()->Unit){
        val row=column();row.setPadding(0,dp(12),0,dp(12));val heading=LinearLayout(this);heading.addView(label(title,16f,ink,true),LinearLayout.LayoutParams(0,-2,1f));heading.addView(label(if(granted)"허용됨"else"허용",14f,if(granted)secondary else blue));row.addView(heading);row.addView(label(detail,13f,secondary));row.setOnClickListener{if(!granted)action()};parent.addView(row);divider(parent)
    }
    override fun onRequestPermissionsResult(code:Int,permissions:Array<out String>,results:IntArray){super.onRequestPermissionsResult(code,permissions,results);pending=false;render();refreshWizard();if(nearby()&&autoConnect)begin(false)}
    @Deprecated("Activity result")override fun onActivityResult(code:Int,result:Int,data:Intent?){super.onActivityResult(code,result,data);pending=false;if(code==52&&result==RESULT_OK)data?.data?.let{consume(Intent(Intent.ACTION_VIEW,it))};if(code==30&&result==RESULT_OK)begin(false);if(code==41&&result==RESULT_OK)data?.data?.let{FilesBridge.accept(this,it)};render();refreshWizard()}
    private fun label(value:String,size:Float=16f,color:Int=ink,bold:Boolean=false)=TextView(this).apply{text=value;textSize=size;setTextColor(color);if(bold)typeface=Typeface.DEFAULT_BOLD;setLineSpacing(dp(2).toFloat(),1f)}
    private fun column()=LinearLayout(this).apply{orientation=LinearLayout.VERTICAL}
    private fun space(parent:LinearLayout,n:Int=16){parent.addView(Space(this),LinearLayout.LayoutParams(1,dp(n)))}
    private fun divider(parent:LinearLayout){parent.addView(View(this).apply{setBackgroundColor(if(paper==Color.WHITE)0xffe4e4e8.toInt()else 0xff3b3b3f.toInt())},LinearLayout.LayoutParams(-1,dp(1)))}
    private fun surface():android.graphics.drawable.Drawable=GradientDrawable(GradientDrawable.Orientation.TL_BR,if(paper==Color.WHITE)intArrayOf(0xfaffffff.toInt(),0xdfffffff.toInt())else intArrayOf(0xf232343a.toInt(),0xe51c1d24.toInt())).apply{cornerRadius=dp(22).toFloat();setStroke(dp(1),if(paper==Color.WHITE)0xffffffff.toInt()else 0xff4c4e58.toInt())}
    private fun group(parent:LinearLayout,title:String):LinearLayout{parent.addView(label(title,12f,secondary,true).apply{setPadding(dp(18),0,0,0)});space(parent,8);val g=column();g.setPadding(dp(18),dp(2),dp(18),dp(2));g.background=surface();g.elevation=dp(1).toFloat();parent.addView(g,LinearLayout.LayoutParams(-1,-2));space(parent,16);return g}
    private fun interactive(view:View,action:()->Unit){view.isFocusable=true;view.setOnClickListener{it.performHapticFeedback(HapticFeedbackConstants.CLOCK_TICK);action()};view.setOnTouchListener{v,e->when(e.actionMasked){MotionEvent.ACTION_DOWN->v.animate().scaleX(.975f).scaleY(.975f).setDuration(100).start();MotionEvent.ACTION_UP,MotionEvent.ACTION_CANCEL->v.animate().scaleX(1f).scaleY(1f).setDuration(180).setInterpolator(android.view.animation.OvershootInterpolator(.6f)).start()};false}}
    private fun row(parent:LinearLayout,title:String,value:String,detail:String?=null,action:(()->Unit)?=null){
        if(parent.childCount>0)divider(parent)
        val row=column();row.minimumHeight=dp(48);row.gravity=Gravity.CENTER_VERTICAL;row.setPadding(0,dp(12),0,dp(12));val line=LinearLayout(this);line.gravity=Gravity.CENTER_VERTICAL;line.addView(label(title),LinearLayout.LayoutParams(0,-2,1f))
        val valueView=label(if(value=="›")""else value.replace(" ›",""),14f,secondary).apply{maxWidth=dp(160);maxLines=2;gravity=Gravity.END;ellipsize=android.text.TextUtils.TruncateAt.END};values[title]=valueView;line.addView(valueView)
        if(action!=null)line.addView(Chevron(this,secondary),LinearLayout.LayoutParams(dp(16),dp(18)).apply{leftMargin=dp(10)})
        row.addView(line);if(detail!=null){space(row,5);val detailView=label(detail,13f,secondary);details[title]=detailView;row.addView(detailView)};if(action!=null)interactive(row,action);parent.addView(row)
    }
    private fun toggleRow(parent:LinearLayout,title:String,checked:Boolean,changed:(Boolean)->Unit){
        if(parent.childCount>0)divider(parent)
        val line=LinearLayout(this);line.gravity=Gravity.CENTER_VERTICAL;line.minimumHeight=dp(48);line.setPadding(0,dp(12),0,dp(12));line.addView(label(title),LinearLayout.LayoutParams(0,-2,1f));val control=GlassToggle(this,checked,blue,changed).apply{contentDescription=title};line.addView(control,LinearLayout.LayoutParams(dp(50),dp(30)).apply{leftMargin=dp(18)});line.setOnClickListener{control.performClick()};parent.addView(line)
    }
    private fun fingerprint()="${SyncService.active?.authenticated}:${prefs.getString("connectionIssue",null)}:${FilesBridge.offer?.optString("id")}:${FilesBridge.busy}:${if(selectedTab==1)ClipHistory.revision else 0}"
    private fun refreshLive(){
        if(fingerprint()!=liveFingerprint){render();return}
        connectionDetail?.text=connectionText()
        connectionBadge?.text=if(SyncService.active?.authenticated==true)"연결됨" else "미연결"
        values["진행 상태"]?.text=if(FilesBridge.busy) "${FilesBridge.progress}%" else "대기"
        values["마지막 동기화"]?.text=lastSyncText()
    }
    private fun lastSyncText()=SyncService.active?.lastSync?.takeIf{it>0}?.let{android.text.format.DateFormat.format("a h:mm",it).toString()} ?: "아직 없음"
    private fun connectionText():String {
        if(Protocol.key(this)==null)return "Mac에서 CoolSync를 열고 연결 QR을 스캔하세요."
        if(!nearby())return "주변 기기 권한이 필요합니다. 권한 설정에서 허용하세요."
        if(!prefs.getBoolean("enabled",false))return "연결이 중지되어 있습니다. 아래에서 연결을 시작하세요."
        return SyncService.active?.status ?: "연결 서비스가 실행되지 않았습니다. 다시 연결해 주세요."
    }
    private fun shape(color:Int,radius:Int=16)=GradientDrawable().apply{setColor(color);cornerRadius=dp(radius).toFloat()}
    private fun button(parent:LinearLayout,title:String,primary:Boolean=true,action:()->Unit){
        val v=label(title,16f,if(primary)Color.WHITE else blue,true).apply{gravity=Gravity.CENTER;minHeight=dp(50);background=shape(if(primary)blue else if(paper==Color.WHITE)0xffeaf2ff.toInt() else 0xff172c49.toInt(),25);isFocusable=true;interactive(this,action)}
        parent.addView(v,LinearLayout.LayoutParams(-1,dp(50)));space(parent,10)
    }
    private fun pauseConnection(){autoConnect=false;prefs.edit().putBoolean("enabled",false).apply();stopService(Intent(this,SyncService::class.java));render()}
    private fun reconnect(){
        autoConnect=true;stopService(Intent(this,SyncService::class.java));prefs.edit().remove("connectionIssue").apply();begin(true);render()
    }
    private fun panels(parent:LinearLayout,wide:Boolean):Pair<LinearLayout,LinearLayout>{
        val row=LinearLayout(this).apply{orientation=if(wide)LinearLayout.HORIZONTAL else LinearLayout.VERTICAL};parent.addView(row)
        val left=column();val right=column()
        row.addView(left,LinearLayout.LayoutParams(if(wide)0 else -1,-2,if(wide)1f else 0f).apply{if(wide)rightMargin=dp(20)})
        row.addView(right,LinearLayout.LayoutParams(if(wide)0 else -1,-2,if(wide)1f else 0f))
        return left to right
    }
    private fun render(){
        activeScroll?.let{scrollOffsets[renderedTab]=it.scrollY}
        renderedTab=selectedTab
        values.clear();details.clear();connectionDetail=null;connectionBadge=null
        val dark=resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK==Configuration.UI_MODE_NIGHT_YES
        ink=if(dark)0xfff4f4f6.toInt()else 0xff1c1c1e.toInt();secondary=if(dark)0xffa0a0a6.toInt()else 0xff707078.toInt();paper=if(dark)0xff1c1c1e.toInt()else Color.WHITE
        val root=FrameLayout(this);root.setBackgroundColor(if(dark)0xff101114.toInt()else 0xfff2f2f7.toInt())
        root.setOnApplyWindowInsetsListener{view,insets->val bars=insets.getInsets(WindowInsets.Type.systemBars());view.setPadding(bars.left,bars.top,bars.right,bars.bottom);insets}
        val wide=resources.configuration.screenWidthDp>=720
        val scroll=ScrollView(this);scroll.clipToPadding=true;scroll.setPadding(0,0,0,dp(if(wide)16 else 94));root.addView(scroll,FrameLayout.LayoutParams(-1,-1).apply{if(wide)leftMargin=dp(96)})
        val frame=FrameLayout(this);scroll.addView(frame)
        val body=column();body.setPadding(dp(20),dp(16),dp(20),dp(12));frame.addView(body,FrameLayout.LayoutParams(-1,-2))
        val titles=listOf("연결","클립보드","파일","설정")
        body.addView(label(titles[selectedTab],30f,ink,true));space(body,16)
        when(selectedTab){
            0->{
                val connected=SyncService.active?.authenticated==true
                val panels=LinearLayout(this).apply{orientation=if(wide)LinearLayout.HORIZONTAL else LinearLayout.VERTICAL};body.addView(panels)
                val left=column();val right=column()
                panels.addView(left,LinearLayout.LayoutParams(if(wide)0 else -1,-2,if(wide)1f else 0f).apply{if(wide)rightMargin=dp(20)})
                panels.addView(right,LinearLayout.LayoutParams(if(wide)0 else -1,-2,if(wide)1f else 0f))
                val device=group(left,"연결 기기")
                val top=LinearLayout(this).apply{gravity=Gravity.CENTER_VERTICAL;setPadding(0,dp(16),0,dp(16))}
                top.addView(LinkIcon(this,0,blue),LinearLayout.LayoutParams(dp(38),dp(38)))
                val title=column();title.setPadding(dp(14),0,0,0);title.addView(label(prefs.getString("macName","연결할 Mac") ?: "Mac",20f,ink,true));connectionBadge=label(if(connected)"연결됨"else"미연결",13f,if(connected)0xff248a3d.toInt()else secondary);title.addView(connectionBadge);top.addView(title,LinearLayout.LayoutParams(0,-2,1f));device.addView(top)
                connectionDetail=label(connectionText(),15f,secondary);device.addView(connectionDetail);space(device,12)
                if(Protocol.key(this)==null){button(device,"QR로 Mac 연결"){scanQR()}}else{val actions=LinearLayout(this);device.addView(actions);val start=column();actions.addView(start,LinearLayout.LayoutParams(0,-2,1f));button(start,if(connected)"다시 연결"else"연결하기"){reconnect()};if(prefs.getBoolean("enabled",false)){val stop=column();actions.addView(stop,LinearLayout.LayoutParams(0,-2,1f).apply{leftMargin=dp(10)});button(stop,"중지",false){pauseConnection()}}}
                val setup=group(right,"연결 관리")
                row(setup,"QR 스캔","›","Mac의 연결 QR을 앱에서 바로 스캔합니다.",action={scanQR()})
                row(setup,"연결 정보 입력","›","Mac의 QR을 스캔하거나 연결 정보를 붙여넣으세요.",action={manualKey()})
                row(setup,"권한 설정",if(nearby())"확인 ›"else"허용 필요 ›",action={showPermissions()})
                row(setup,"연결 문제 확인","›",action={diagnostics()})
                if(Protocol.key(this)!=null)row(setup,"등록 해제 후 새로 연결","›",action={confirmUnlink()})
                val issue=prefs.getString("connectionIssue",null)
                if(issue!=null){val g=group(left,"최근 연결 문제");g.addView(label(issue,14f,secondary));space(g,12);button(g,"원인과 해결 방법",false){diagnostics()}}
            }
            1->{
                val (options,records)=panels(body,wide)
                val tools=group(options,"클립보드")
                toggleRow(tools,"복사 기록 저장",ClipHistory.enabled(this)){getSharedPreferences("clipboard",0).edit().putBoolean("history",it).apply()}
                row(tools,"현재 클립보드 가져오기","›","자동 감지가 안 되는 앱의 텍스트·이미지 한 장을 가져옵니다.",action={captureNow()})
                toggleRow(tools,"즐겨찾기만 보기",historyFilter){historyFilter=it;render()}
                val items=ClipHistory.entries(this).filter{!historyFilter||it.optBoolean("favorite")}
                val list=group(records,if(historyFilter)"즐겨찾기"else"최근 기록 · 최대 200개")
                if(items.isEmpty()){val empty=label("아직 기록이 없습니다. CoolSync에서 감지한 새 복사부터 여기에 표시됩니다.",14f,secondary);empty.setPadding(0,dp(18),0,dp(18));list.addView(empty)}
                items.forEach{item->
                    if(list.childCount>0)divider(list)
                    val entry=column();entry.setPadding(0,dp(14),0,dp(14))
                    if(item.has("image")){val image=ImageView(this);val f=ClipHistory.file(this,item);val bounds=android.graphics.BitmapFactory.Options().apply{inJustDecodeBounds=true};android.graphics.BitmapFactory.decodeFile(f.path,bounds);val options=android.graphics.BitmapFactory.Options().apply{inSampleSize=maxOf(1,maxOf(bounds.outWidth,bounds.outHeight)/128)};image.setImageBitmap(android.graphics.BitmapFactory.decodeFile(f.path,options));image.scaleType=ImageView.ScaleType.CENTER_CROP;image.background=shape(0x10007aff,12);image.clipToOutline=true;entry.addView(image,LinearLayout.LayoutParams(-1,dp(120)))}else entry.addView(label(item.optString("text"),15f).apply{maxLines=3;ellipsize=android.text.TextUtils.TruncateAt.END})
                    space(entry,6);entry.addView(label(item.optString("source")+" · "+android.text.format.DateFormat.format("M/d a h:mm",item.optLong("time")),11f,secondary));space(entry,10)
                    val actions=LinearLayout(this)
                    fun action(title:String,run:()->Unit){actions.addView(label(title,13f,blue,true).apply{gravity=Gravity.CENTER;minHeight=dp(42);background=shape(0x0c007aff,12);interactive(this,run)},LinearLayout.LayoutParams(0,dp(42),1f).apply{rightMargin=dp(6)})}
                    action("다시 복사"){ClipHistory.copy(this,item);toast("클립보드에 복사했습니다")};action(if(item.optBoolean("favorite"))"★ 해제"else"☆ 즐겨찾기"){ClipHistory.favorite(this,item.getString("id"));render()};action("삭제"){ClipHistory.remove(this,item.getString("id"));render()};entry.addView(actions);list.addView(entry)
                }
                if(items.isNotEmpty())button(records,"모든 기록 삭제",false){val(d,b)=sheet("기록을 모두 삭제할까요?");b.addView(label("이 기기의 기록과 즐겨찾기를 삭제합니다. 현재 시스템 클립보드와 상대 기기의 기록은 유지됩니다.",14f,secondary));space(b,18);button(b,"모두 삭제"){ClipHistory.clear(this);d.dismiss();render()};button(b,"취소",false){d.dismiss()}}
                options.addView(label("기록은 이 기기에만 저장합니다. 민감한 클립보드 표시는 존중하며, 휴대폰 잠금 중에는 공유하지 않습니다.",12f,secondary))
            }

            2->{
                val (storagePanel,transferPanel)=panels(body,wide)
                val g=group(storagePanel,"휴대폰 저장소")
                row(g,"파일 관리",if(storage())"허용됨"else"권한 필요",action={showPermissions()})
                row(g,"Mac에서 탐색",if(SyncService.active?.authenticated==true)"연결됨"else"연결 필요","Mac 앱의 내부 저장소에서 파일·폴더를 만들고 복사·이동·삭제합니다.",action={if(!storage())showPermissions()else{selectedTab=0;render()}})
                val transfer=group(transferPanel,"전송")
                row(transfer,"진행 상태",if(FilesBridge.busy)"${FilesBridge.progress}%"else"대기",FilesBridge.summary.takeIf{FilesBridge.busy||FilesBridge.offer!=null})
                FilesBridge.offer?.takeIf{it.optString("flow")=="download"&&FilesBridge.destination==null}?.let{offer->button(transfer,"파일 받기"){ @Suppress("DEPRECATION")startActivityForResult(Intent(Intent.ACTION_CREATE_DOCUMENT).setType("application/octet-stream").addCategory(Intent.CATEGORY_OPENABLE).putExtra(Intent.EXTRA_TITLE,offer.optString("name")),41)}}
                if(FilesBridge.busy||FilesBridge.offer!=null)button(transfer,"전송 취소",false){FilesBridge.reject(this)}
            }
            3->{
                val (deviceSettings,appSettings)=panels(body,wide)
                val g=group(deviceSettings,"연결 및 권한")
                row(g,"권한 관리","›",action={showPermissions()});row(g,"연결 진단","›",action={diagnostics()})
                toggleRow(g,"재부팅 후 연결 시작",prefs.getBoolean("boot",true)){prefs.edit().putBoolean("boot",it).apply()}

                val alerts=group(appSettings,"알림 공유")
                toggleRow(alerts,"Mac에 휴대폰 알림 표시",prefs.getBoolean("forwardNotifications",false)){enabled->prefs.edit().putBoolean("forwardNotifications",enabled).apply();if(enabled&&!notificationAccess())notificationSettings()}
                row(alerts,"알림 접근 권한",if(notificationAccess())"허용됨"else"설정 필요",action={notificationSettings()})
                alerts.addView(label("휴대폰이 잠겨 있으면 내용을 보내지 않습니다. Mac에서도 알림 권한을 허용하세요.",12f,secondary).apply{setPadding(0,dp(8),0,dp(12))})
                val unlink=group(deviceSettings,"등록된 Mac")
                row(unlink,"다른 Mac 연결","›",action={manualKey()})
                row(unlink,"등록 해제","›","저장된 연결 정보를 삭제합니다.",action={confirmUnlink()})
                val updates=group(appSettings,"앱 업데이트")
                row(updates,"업데이트",AppUpdates.status,action={AppUpdates.update(this)})
                row(updates,"설치된 빌드",packageManager.getPackageInfo(packageName,0).longVersionCode.toString())
                toggleRow(updates,"새 업데이트 자동 확인",getSharedPreferences("updates",0).getBoolean("automatic",true)){getSharedPreferences("updates",0).edit().putBoolean("automatic",it).apply()}

                body.addView(label("CoolSync",13f,secondary))
            }
        }
        val nav=LinearLayout(this).apply{orientation=if(wide)LinearLayout.VERTICAL else LinearLayout.HORIZONTAL;setPadding(dp(6),dp(6),dp(6),dp(6));background=surface();elevation=dp(10).toFloat()}
        titles.forEachIndexed{i,title->
            val item=column();item.gravity=Gravity.CENTER;item.background=if(i==selectedTab)GradientDrawable(GradientDrawable.Orientation.TL_BR,intArrayOf(0x38007aff,0x18007aff)).apply{cornerRadius=dp(22).toFloat();setStroke(dp(1),0x22007aff)}else null
            item.addView(LinkIcon(this,i,if(i==selectedTab)blue else secondary),LinearLayout.LayoutParams(dp(23),dp(23)));space(item,4);item.addView(label(title,10f,if(i==selectedTab)blue else secondary,i==selectedTab).apply{gravity=Gravity.CENTER});item.contentDescription=title+" 탭";interactive(item){if(selectedTab!=i){selectedTab=i;animateTab=true;render()}};nav.addView(item,(if(wide)LinearLayout.LayoutParams(-1,dp(68))else LinearLayout.LayoutParams(0,dp(54),1f)).apply{setMargins(dp(2),dp(2),dp(2),dp(2))})
        }
        root.addView(nav,FrameLayout.LayoutParams(dp(if(wide)76 else (resources.configuration.screenWidthDp-32).coerceAtMost(520)),-2,if(wide)Gravity.START or Gravity.CENTER_VERTICAL else Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL).apply{if(wide)leftMargin=dp(12)else bottomMargin=dp(12)})
        if(animateTab&&android.animation.ValueAnimator.areAnimatorsEnabled()){scroll.alpha=0f;scroll.translationY=dp(12).toFloat();scroll.animate().alpha(1f).translationY(0f).setDuration(240).setInterpolator(android.view.animation.DecelerateInterpolator()).start()};animateTab=false
        activeScroll=scroll;scroll.post{scroll.scrollTo(0,scrollOffsets[selectedTab])}
        setContentView(root);root.requestApplyInsets()
        window.insetsController?.setSystemBarsAppearance(if(dark)0 else WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS or WindowInsetsController.APPEARANCE_LIGHT_NAVIGATION_BARS,WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS or WindowInsetsController.APPEARANCE_LIGHT_NAVIGATION_BARS)
        liveFingerprint=fingerprint()
    }
    private fun sheet(title:String):Pair<Dialog,LinearLayout>{
        pairingDialog?.dismiss()
        val dialog=Dialog(this);val body=column();body.setPadding(dp(24),dp(24),dp(24),dp(16));body.background=shape(paper,24)
        body.addView(label(title,21f,ink,true));space(body,12)
        val scroll=ScrollView(this);scroll.addView(body);dialog.setContentView(scroll);dialog.window?.setBackgroundDrawableResource(android.R.color.transparent)
        dialog.setOnDismissListener{if(pairingDialog==dialog)pairingDialog=null};pairingDialog=dialog
        dialog.show();if(Build.VERSION.SDK_INT>=31){dialog.window?.addFlags(WindowManager.LayoutParams.FLAG_BLUR_BEHIND);dialog.window?.attributes=dialog.window?.attributes?.apply{setBlurBehindRadius(18)}};dialog.window?.setLayout(dp((resources.configuration.screenWidthDp-40).coerceAtMost(380)),-2);dialog.window?.setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE)
        return dialog to body
    }
    @Suppress("DEPRECATION") private fun scanQR(){startActivityForResult(Intent(this,PairScannerActivity::class.java),52)}
    private fun manualKey(){
        val(dialog,body)=sheet("Mac 연결")
        button(body,"카메라로 QR 스캔"){dialog.dismiss();scanQR()}
        body.addView(label("Mac의 CoolSync에서 연결 QR을 스캔하세요. 직접 연결할 때는 복사한 연결 정보를 아래에 붙여넣으세요.",14f,secondary));space(body,20)
        body.addView(label("연결 키 또는 링크",12f,secondary,true));space(body,8)
        val input=EditText(this).apply{hint="여기에 붙여넣기";textSize=16f;setTextColor(ink);setHintTextColor(secondary);setPadding(dp(16),dp(14),dp(16),dp(14));background=shape(if(paper==Color.WHITE)0xfff2f2f7.toInt()else 0xff303034.toInt(),12);maxLines=3;minHeight=dp(54);inputType=android.text.InputType.TYPE_CLASS_TEXT or android.text.InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS;importantForAutofill=View.IMPORTANT_FOR_AUTOFILL_NO_EXCLUDE_DESCENDANTS}
        body.addView(input,LinearLayout.LayoutParams(-1,-2));space(body,8)
        val error=label("",13f,0xffff453a.toInt());error.visibility=View.GONE;body.addView(error)
        input.addTextChangedListener(object:android.text.TextWatcher{override fun beforeTextChanged(s:CharSequence?,start:Int,count:Int,after:Int){};override fun onTextChanged(s:CharSequence?,start:Int,before:Int,count:Int){error.visibility=View.GONE};override fun afterTextChanged(s:android.text.Editable?) {}})
        space(body,16)
        button(body,"연결"){
            val value=input.text.toString().trim();val key=if(value.startsWith("coolsync://"))runCatching{Uri.parse(value).getQueryParameter("key")}.getOrNull()else value
            if(key?.matches(Regex("[a-fA-F0-9]{64}"))!=true){error.text="연결 정보가 올바르지 않습니다. Mac에서 복사한 키 또는 링크를 붙여넣으세요.";error.visibility=View.VISIBLE;input.requestFocus()}
            else{dialog.dismiss();selectedTab=0;consume(Intent(Intent.ACTION_VIEW,if(value.startsWith("coolsync://"))Uri.parse(value)else Uri.parse("coolsync://pair?key=$key")));render()}
        }
        button(body,"취소",false){dialog.dismiss()}
    }
    private fun captureNow(){
        try{val cb=getSystemService(android.content.ClipboardManager::class.java);val clip=cb.primaryClip ?: return;val desc=cb.primaryClipDescription;if(desc?.extras?.getBoolean("android.content.extra.IS_SENSITIVE",false)==true){toast("민감한 내용은 기록하지 않습니다");return};val item=clip.getItemAt(0);val uri=item.uri
            if(uri!=null&&contentResolver.getType(uri)?.startsWith("image/")==true){val file=ClipHistory.normalized(this,uri);ClipHistory.image(this,file,"휴대폰");val sync=SyncService.active;if(sync?.authenticated==true&&!FilesBridge.busy&&FilesBridge.offer==null)sync.localImage(Uri.fromFile(file),false)else file.delete()}else item.text?.toString()?.let{ClipHistory.text(this,it,"휴대폰");SyncService.active?.localCopy(it)};render()
        }catch(_:Exception){toast("이 이미지에 접근할 수 없습니다. 원본 앱에서 공유 기능을 사용해 주세요")}
    }
    private fun confirmUnlink(){val(d,b)=sheet("Mac 등록을 해제할까요?");b.addView(label("다시 연결하려면 Mac의 QR을 스캔해야 합니다.",14f,secondary));space(b,20);button(b,"등록 해제"){pauseConnection();prefs.edit().remove("key").remove("macName").remove("connectionIssue").apply();d.dismiss();render();scanQR()};button(b,"취소",false){d.dismiss()}}
    private fun showIssue(title:String,message:String){val(d,b)=sheet(title);b.addView(label(message,15f,secondary));space(b,20);button(b,"다시 연결"){d.dismiss();reconnect()};button(b,"닫기",false){d.dismiss()}}
    private fun diagnostics(){
        val(d,b)=sheet("연결 확인")
        val adapter=if(nearby())runCatching{getSystemService(android.bluetooth.BluetoothManager::class.java).adapter?.isEnabled==true}.getOrDefault(false)else false
        listOf("연결 정보" to (Protocol.key(this)!=null),"주변 기기 권한" to nearby(),"Bluetooth" to adapter,"연결 서비스" to (SyncService.active!=null),"Mac 인증" to (SyncService.active?.authenticated==true)).forEach{(name,ok)->row(b,name,if(ok)"확인됨"else"확인 필요")}
        space(b,12);b.addView(label(prefs.getString("connectionIssue",null) ?: connectionText(),14f,secondary));space(b,8)
        b.addView(label("Mac에서도 CoolSync를 열고 Bluetooth를 켜세요. 인증이 실패하면 Mac의 현재 QR을 다시 스캔하고 두 기기의 날짜·시간을 자동으로 설정하세요.",14f,secondary));space(b,20)
        button(b,"다시 연결"){d.dismiss();reconnect()};button(b,"권한 설정",false){d.dismiss();showPermissions()};button(b,"닫기",false){d.dismiss()}
    }
    private class Chevron(c:Context,private val tint:Int):View(c){private val paint=android.graphics.Paint(3).apply{color=tint;style=android.graphics.Paint.Style.STROKE;strokeWidth=2f;strokeCap=android.graphics.Paint.Cap.ROUND;strokeJoin=android.graphics.Paint.Join.ROUND};override fun onDraw(canvas:android.graphics.Canvas){val x=width*.4f;val y=height*.5f;canvas.drawLine(x,y-5*resources.displayMetrics.density,x+5*resources.displayMetrics.density,y,paint);canvas.drawLine(x+5*resources.displayMetrics.density,y,x,y+5*resources.displayMetrics.density,paint)}}
    private class GlassToggle(c:Context,initial:Boolean,private val tint:Int,private val changed:(Boolean)->Unit):View(c){
        private var checked=initial;private var position=if(initial)1f else 0f;private var animator:android.animation.ValueAnimator?=null
        private val paint=android.graphics.Paint(3)
        init{isClickable=true;isFocusable=true;importantForAccessibility=IMPORTANT_FOR_ACCESSIBILITY_YES;setLayerType(LAYER_TYPE_SOFTWARE,null)}
        override fun performClick():Boolean{super.performClick();checked=!checked;performHapticFeedback(HapticFeedbackConstants.CLOCK_TICK);animator?.cancel();if(android.animation.ValueAnimator.areAnimatorsEnabled()){animator=android.animation.ValueAnimator.ofFloat(position,if(checked)1f else 0f).apply{duration=220;interpolator=android.view.animation.DecelerateInterpolator();addUpdateListener{position=it.animatedValue as Float;invalidate()};start()}}else{position=if(checked)1f else 0f;invalidate()};changed(checked);return true}
        override fun onDraw(canvas:android.graphics.Canvas){val h=height.toFloat();val w=width.toFloat();paint.clearShadowLayer();paint.color=android.animation.ArgbEvaluator().evaluate(position,0xffc8cad2.toInt(),tint)as Int;canvas.drawRoundRect(0f,0f,w,h,h/2,h/2,paint);paint.color=Color.WHITE;paint.setShadowLayer(h*.08f,0f,h*.04f,0x40000000);canvas.drawCircle(h/2+(w-h)*position,h/2,h*.405f,paint);paint.clearShadowLayer()}
        override fun onInitializeAccessibilityNodeInfo(info:android.view.accessibility.AccessibilityNodeInfo){super.onInitializeAccessibilityNodeInfo(info);info.className="android.widget.Switch";info.isCheckable=true;info.isChecked=checked}
    }
    private class LinkIcon(context:Context,private val kind:Int,private val tint:Int):View(context){
        override fun onDraw(c:android.graphics.Canvas){super.onDraw(c);c.save();c.scale(width/24f,height/24f);val p=android.graphics.Paint(3).apply{color=tint;style=android.graphics.Paint.Style.STROKE;strokeWidth=1.7f;strokeCap=android.graphics.Paint.Cap.ROUND;strokeJoin=android.graphics.Paint.Join.ROUND}
            when(kind){
                0->{c.drawRoundRect(2f,3f,22f,17f,2f,2f,p);c.drawLine(8f,21f,16f,21f,p);c.drawLine(12f,17f,12f,21f,p)}
                1->{c.drawRoundRect(5f,4f,19f,22f,2f,2f,p);c.drawRoundRect(9f,2f,15f,6f,1f,1f,p);c.drawLine(9f,11f,15f,11f,p);c.drawLine(9f,15f,15f,15f,p)}
                2->{val path=android.graphics.Path();path.moveTo(2f,7f);path.lineTo(2f,4f);path.lineTo(9f,4f);path.lineTo(12f,7f);path.lineTo(22f,7f);path.lineTo(22f,21f);path.lineTo(2f,21f);path.close();c.drawPath(path,p)}
                else->{c.drawCircle(12f,12f,7f,p);c.drawCircle(12f,12f,2.5f,p);for(i in 0..7){val a=i*Math.PI/4;c.drawLine((12+8*kotlin.math.cos(a)).toFloat(),(12+8*kotlin.math.sin(a)).toFloat(),(12+10*kotlin.math.cos(a)).toFloat(),(12+10*kotlin.math.sin(a)).toFloat(),p)}}
            };c.restore()
        }
    }
    private fun toast(text:String){Toast.makeText(this,text,Toast.LENGTH_LONG).show()}
}
