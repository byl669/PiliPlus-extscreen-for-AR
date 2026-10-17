package com.example.piliplus

import android.app.Activity
import android.content.Intent
import android.net.Uri
import androidx.core.content.FileProvider
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * 外接屏定制版应用内更新：接收 Dart 侧下载好的 APK 路径，
 * 通过 FileProvider 授予系统安装器读权限并拉起安装确认界面。
 * 需要 Manifest 声明 REQUEST_INSTALL_PACKAGES 权限。
 */
object UpdateInstaller : MethodChannel.MethodCallHandler {
    private const val CHANNEL = "piliplus/update_installer"
    private var activity: Activity? = null

    fun attach(messenger: BinaryMessenger, activity: Activity) {
        this.activity = activity
        MethodChannel(messenger, CHANNEL).setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "install" -> {
                try {
                    val path = call.argument<String>("path")
                    val ctx = activity
                    if (path == null || ctx == null) {
                        result.error("args", "path/activity missing", null)
                        return
                    }
                    val file = File(path)
                    if (!file.exists()) {
                        result.error("file", "apk not found: $path", null)
                        return
                    }
                    val uri: Uri = FileProvider.getUriForFile(
                        ctx, ctx.packageName + ".updateProvider", file
                    )
                    val intent = Intent(Intent.ACTION_VIEW).apply {
                        setDataAndType(uri, "application/vnd.android.package-archive")
                        addFlags(
                            Intent.FLAG_GRANT_READ_URI_PERMISSION
                                or Intent.FLAG_ACTIVITY_NEW_TASK
                        )
                    }
                    ctx.startActivity(intent)
                    result.success(true)
                } catch (e: Exception) {
                    result.error("install", e.message, null)
                }
            }
            else -> result.notImplemented()
        }
    }
}
