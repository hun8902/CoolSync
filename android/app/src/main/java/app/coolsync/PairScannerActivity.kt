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
import com.google.zxing.BarcodeFormat
import com.journeyapps.barcodescanner.*

class PairScannerActivity : Activity() {
    private lateinit var camera: DecoratedBarcodeView
    private lateinit var message: TextView
    private var finishedScan = false

    override fun onCreate(state: Bundle?) {
        super.onCreate(state)
        val layout = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(Color.BLACK)
            setPadding(24, 24, 24, 24)
        }
        val close = Button(this).apply { text = "닫기"; setOnClickListener { finish() } }
        layout.addView(close)
        message = TextView(this).apply {
            text = "Mac의 CoolSync 연결 QR을 비춰 주세요"
            textSize = 18f; setTextColor(Color.WHITE)
            gravity = Gravity.CENTER; setPadding(12, 24, 12, 24)
        }
        layout.addView(message)
        camera = DecoratedBarcodeView(this)
        camera.barcodeView.decoderFactory = DefaultDecoderFactory(listOf(BarcodeFormat.QR_CODE))
        camera.setStatusText("")
        layout.addView(camera, LinearLayout.LayoutParams(-1, 0, 1f))
        setContentView(layout)
        camera.decodeContinuous(object : BarcodeCallback {
            override fun barcodeResult(result: BarcodeResult) {
                if (finishedScan) return
                val uri = runCatching { Uri.parse(result.text) }.getOrNull()
                val key = uri?.getQueryParameter("key")
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
