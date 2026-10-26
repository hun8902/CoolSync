package app.coolsync

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Color
import android.net.Uri
import android.os.Bundle
import android.view.Gravity
import android.widget.*
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.drawable.GradientDrawable
import android.view.View
import com.google.zxing.BarcodeFormat
import com.journeyapps.barcodescanner.*

class PairScannerActivity : Activity() {
    private lateinit var camera: BarcodeView
    private lateinit var message: TextView
    private var finishedScan = false

    override fun onCreate(state: Bundle?) {
        super.onCreate(state)
        val layout = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(Color.BLACK)
            setPadding(24, 24, 24, 24)
        }
        window.setDecorFitsSystemWindows(false)
        layout.setOnApplyWindowInsetsListener{view,insets->val bars=insets.getInsets(android.view.WindowInsets.Type.systemBars());val pad=(20*resources.displayMetrics.density).toInt();view.setPadding(bars.left+pad,bars.top+pad,bars.right+pad,bars.bottom+pad);insets}
        val heading=LinearLayout(this).apply{gravity=Gravity.CENTER_VERTICAL}
        heading.addView(TextView(this).apply{text="QR 스캔";textSize=24f;setTextColor(Color.WHITE);typeface=android.graphics.Typeface.DEFAULT_BOLD},LinearLayout.LayoutParams(0,-2,1f))
        val close = TextView(this).apply {
            text = "닫기";textSize=16f;setTextColor(Color.WHITE);gravity=Gravity.CENTER;setPadding(28,18,28,18)
            background=GradientDrawable().apply{setColor(0x403e3e44);cornerRadius=40*resources.displayMetrics.density}
            minHeight=(44*resources.displayMetrics.density).toInt();isFocusable=true;setOnClickListener { finish() }
        }
        heading.addView(close);layout.addView(heading)
        message = TextView(this).apply {
            text = "Mac의 CoolSync 연결 QR을 비춰 주세요"
            textSize = 18f; setTextColor(Color.WHITE)
            gravity = Gravity.CENTER; setPadding(12, 24, 12, 24)
        }
        layout.addView(message)
        camera = BarcodeView(this)
        camera.decoderFactory = DefaultDecoderFactory(listOf(BarcodeFormat.QR_CODE))
        val preview=FrameLayout(this).apply{background=GradientDrawable().apply{setColor(Color.BLACK);cornerRadius=28*resources.displayMetrics.density};clipToOutline=true}
        preview.addView(camera,FrameLayout.LayoutParams(-1,-1))
        preview.addView(object:View(this){
            private val line=Paint(3).apply{color=Color.WHITE;style=Paint.Style.STROKE;strokeWidth=3*resources.displayMetrics.density}
            override fun onDraw(c:Canvas){val size=minOf(width,height)*.72f;val x=(width-size)/2;val y=(height-size)/2;c.drawRoundRect(x,y,x+size,y+size,24*resources.displayMetrics.density,24*resources.displayMetrics.density,line)}
        },FrameLayout.LayoutParams(-1,-1))
        layout.addView(preview, LinearLayout.LayoutParams(-1, 0, 1f))
        layout.addView(TextView(this).apply{text="QR을 읽으면 연결이 자동으로 시작됩니다";textSize=14f;setTextColor(0xffb7b7bf.toInt());gravity=Gravity.CENTER;setPadding(0,28,0,16)})
        setContentView(layout)
        camera.decodeContinuous(object : BarcodeCallback {
            override fun barcodeResult(result: BarcodeResult) {
                if (finishedScan) return
                val uri = runCatching { Uri.parse(result.text) }.getOrNull()
                val key = if(uri?.scheme=="coolsync" && uri.host=="pair")runCatching{uri.getQueryParameter("key")}.getOrNull()else null
                if (uri?.scheme != "coolsync" || uri.host != "pair" || key?.matches(Regex("[a-fA-F0-9]{64}")) != true) {
                    message.text = "CoolSync 연결 QR이 아닙니다. Mac의 연결 화면을 확인하세요."
                    return
                }
                finishedScan = true; camera.pause()
                setResult(RESULT_OK, Intent().setData(uri)); finish()
            }
        })
    }
    override fun onResume() {
        super.onResume()
        if (checkSelfPermission(Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) camera.resume()
        else requestPermissions(arrayOf(Manifest.permission.CAMERA), 1)
    }
    override fun onPause() { camera.pause(); super.onPause() }
    override fun onRequestPermissionsResult(code: Int, permissions: Array<out String>, results: IntArray) {
        super.onRequestPermissionsResult(code, permissions, results)
        if (code == 1 && results.firstOrNull() == PackageManager.PERMISSION_GRANTED) camera.resume()
        else { Toast.makeText(this, "QR 스캔에는 카메라 권한이 필요합니다. 연결 정보를 붙여넣어 연결할 수도 있습니다.", Toast.LENGTH_LONG).show(); finish() }
    }
}
