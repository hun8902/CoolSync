package app.coolsync

import android.app.Activity
import android.content.*
import android.content.pm.PackageManager
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.*
import android.provider.OpenableColumns
import android.provider.Settings
import android.util.Base64
import org.json.JSONObject
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.security.*
import java.security.spec.X509EncodedKeySpec
import java.util.concurrent.Executors

/** Only checks while the app is open; no background polling or wakeups. */
object AppUpdates {
    private const val FEED="https://github.com/hun8902/CoolSync/releases/latest/download/android-update.json"
    private const val MAX_APK=128L*1024*1024
    private val main=Handler(Looper.getMainLooper())
    private val worker=Executors.newSingleThreadExecutor()
    var changed:(()->Unit)?=null
    var busy=false;private set
    var status="업데이트 확인";private set
    var available:JSONObject?=null;private set
    private var verified:File?=null
    private var updateActivity:java.lang.ref.WeakReference<Activity>?=null
    private var continueInstall=false
    private var waitingPermission=false
    fun update(a:Activity){
        updateActivity=java.lang.ref.WeakReference(a)
        continueInstall=true
        if(busy)return
        when { ready()->install(a); available!=null->download(a); else->check(a) }
    }
    fun resume(a:Activity){
        if(waitingPermission){waitingPermission=false;if(a.packageManager.canRequestPackageInstalls()&&ready())install(a)else{continueInstall=false;publish("설치 권한이 필요합니다 · 눌러서 다시 시도")}}
    }
    private fun advance(){
        val a=updateActivity?.get()
        if(!continueInstall||a==null||a.isFinishing||a.isDestroyed){continueInstall=false;return}
        if(ready())install(a) else if(available!=null)download(a) else continueInstall=false
    }
    private fun publish(text:String){main.post{status=text;changed?.invoke()}}
    private fun localCode(c:Context)=c.packageManager.getPackageInfo(c.packageName,0).longVersionCode
    fun automatic(c:Context){val p=c.getSharedPreferences("updates",0);if(p.getBoolean("automatic",true)&&System.currentTimeMillis()-p.getLong("lastCheck",0)>86400000)check(c)}
    private fun connect(url:String):HttpURLConnection {
        val u=Uri.parse(url)
        require(u.scheme=="https"&&u.host in setOf("github.com","release-assets.githubusercontent.com","objects.githubusercontent.com")){"허용되지 않은 다운로드 주소"}
        return (URL(url).openConnection() as HttpURLConnection).apply{connectTimeout=20000;readTimeout=30000;setRequestProperty("User-Agent","CoolSync-Android");setRequestProperty("Cache-Control","no-cache")}
    }
    private fun get(url:String,max:Int):ByteArray{val c=connect(url);try{if(c.responseCode==404)throw IllegalStateException("아직 배포된 업데이트가 없습니다");require(c.responseCode==200){"GitHub 응답 오류 (${c.responseCode})"};return c.inputStream.use{val out=java.io.ByteArrayOutputStream();val buf=ByteArray(8192);while(true){val n=it.read(buf);if(n<0)break;require(out.size()+n<=max){"업데이트 정보 크기 초과"};out.write(buf,0,n)};out.toByteArray()}}finally{c.disconnect()}}
    fun check(context:Context){
        if(busy)return;busy=true;verified=null;status="업데이트 확인 중…";changed?.invoke()
        val c=context.applicationContext;c.getSharedPreferences("updates",0).edit().putLong("lastCheck",System.currentTimeMillis()).apply()
        worker.execute{try{
            val bytes=get(FEED,65536);val sig=get(FEED+".sig",4096)
            val pem=c.assets.open("android-public.pem").bufferedReader().use{it.readText()}.replace("-----BEGIN PUBLIC KEY-----","").replace("-----END PUBLIC KEY-----","").replace(Regex("\\s"),"")
            val key=KeyFactory.getInstance("RSA").generatePublic(X509EncodedKeySpec(Base64.decode(pem,Base64.DEFAULT)))
            require(Signature.getInstance("SHA256withRSA").run{initVerify(key);update(bytes);verify(Base64.decode(sig,Base64.DEFAULT))}){"업데이트 서명 검증 실패"}
            val m=JSONObject(String(bytes,Charsets.UTF_8));require(m.getString("package")==c.packageName&&m.getInt("minSdk")<=Build.VERSION.SDK_INT){"이 기기와 호환되지 않는 업데이트"}
            require(m.getLong("size") in 1..MAX_APK&&m.getString("sha256").matches(Regex("[a-f0-9]{64}"))){"업데이트 정보 오류"}
            val u=Uri.parse(m.getString("url"));require(u.scheme=="https"&&u.host=="github.com"&&u.path?.startsWith("/hun8902/CoolSync/releases/download/")==true){"업데이트 주소 오류"}
            main.post{available=m.takeIf{it.getLong("build")>localCode(c)};busy=false;status=if(available==null)"최신 상태"else "업데이트 설치";changed?.invoke();advance()}
        }catch(e:Exception){main.post{continueInstall=false;busy=false;status=e.message ?: "업데이트 확인 실패";changed?.invoke()}}}
    }
    fun download(context:Context){
        val m=available ?: return;if(busy)return;busy=true;status="다운로드 중…";changed?.invoke();val c=context.applicationContext
        worker.execute{
            val folder=File(c.cacheDir,"updates").apply{mkdirs()};val tmp=File(folder,"download.tmp");val target=File(folder,"CoolSync.apk")
            try{val conn=connect(m.getString("url"));try{
                require(conn.responseCode==200){"다운로드 응답 오류 (${conn.responseCode})"}
                val expected=m.getLong("size");require(conn.contentLengthLong<=MAX_APK){"파일 크기 초과"};val digest=MessageDigest.getInstance("SHA-256");var count=0L
                conn.inputStream.use{input->tmp.outputStream().use{output->val buffer=ByteArray(65536);while(true){val n=input.read(buffer);if(n<0)break;count+=n;require(count<=expected&&count<=MAX_APK){"다운로드 크기 오류"};digest.update(buffer,0,n);output.write(buffer,0,n)}}}
                require(count==expected&&digest.digest().joinToString(""){"%02x".format(it)}==m.getString("sha256")){"다운로드 검증 실패"}
            }finally{conn.disconnect()}
            @Suppress("DEPRECATION") val archive=c.packageManager.getPackageArchiveInfo(tmp.path,PackageManager.GET_SIGNING_CERTIFICATES) ?: error("APK를 읽을 수 없습니다")
            @Suppress("DEPRECATION") val installed=c.packageManager.getPackageInfo(c.packageName,PackageManager.GET_SIGNING_CERTIFICATES)
            require(archive.packageName==c.packageName&&archive.longVersionCode==m.getLong("build")&&archive.longVersionCode>installed.longVersionCode){"앱 이름 또는 빌드 번호 불일치"}
            val actual=archive.signingInfo?.apkContentsSigners?.map{it.toCharsString()}?.toSet();val current=installed.signingInfo?.apkContentsSigners?.map{it.toCharsString()}?.toSet()
            require(!actual.isNullOrEmpty()&&actual==current){"APK 서명이 기존 앱과 다릅니다"}
            require(!target.exists()||target.delete());require(tmp.renameTo(target)){"업데이트 파일 저장 실패"}
            main.post{verified=target;busy=false;status="설치 준비됨";changed?.invoke();advance()}
            }catch(e:Exception){tmp.delete();main.post{verified=null;continueInstall=false;busy=false;status=e.message ?: "다운로드 실패";changed?.invoke()}}
        }
    }
    fun ready()=verified?.isFile==true
    fun install(a:Activity){
        if(!ready())return
        if(!a.packageManager.canRequestPackageInstalls()){waitingPermission=true;a.startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,Uri.parse("package:${a.packageName}")));return}
        continueInstall=false
        a.startActivity(Intent(Intent.ACTION_VIEW).setDataAndType(Uri.parse("content://${a.packageName}.updates/CoolSync.apk"),"application/vnd.android.package-archive").addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION))
    }
}

/** Read-only URI restricted to the single verified update cache file. */
class UpdateFileProvider:ContentProvider(){
    override fun onCreate()=true
    private fun file(uri:Uri):File{require(uri.path=="/CoolSync.apk");return File(context!!.cacheDir,"updates/CoolSync.apk")}
    override fun openFile(uri:Uri,mode:String):ParcelFileDescriptor{require(mode=="r");return ParcelFileDescriptor.open(file(uri),ParcelFileDescriptor.MODE_READ_ONLY)}
    override fun getType(uri:Uri)="application/vnd.android.package-archive"
    override fun query(uri:Uri,projection:Array<out String>?,selection:String?,args:Array<out String>?,sort:String?):Cursor{val f=file(uri);val columns=projection ?: arrayOf(OpenableColumns.DISPLAY_NAME,OpenableColumns.SIZE);return MatrixCursor(columns).apply{addRow(columns.map{when(it){OpenableColumns.DISPLAY_NAME->f.name;OpenableColumns.SIZE->f.length();else->null}})}}
    override fun insert(uri:Uri,values:ContentValues?):Uri?=throw UnsupportedOperationException()
    override fun update(uri:Uri,values:ContentValues?,selection:String?,args:Array<out String>?)=0
    override fun delete(uri:Uri,selection:String?,args:Array<out String>?)=0
}
