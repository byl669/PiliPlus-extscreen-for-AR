package com.example.piliplus

import android.app.Activity
import android.app.Presentation
import android.content.Context
import android.hardware.display.DisplayManager
import android.os.Build
import android.os.Bundle
import android.view.Display
import android.view.ViewGroup
import android.view.WindowManager
import android.widget.FrameLayout
import io.flutter.FlutterInjector
import io.flutter.embedding.android.FlutterView
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import com.alexmercerind.media_kit_libs_android_video.MediaKitLibsAndroidVideoPlugin
import com.alexmercerind.media_kit_video.MediaKitVideoPlugin

/**
 * 外接显示器（HDMI / 无线投屏）支持：
 * 在外接屏上以独立 FlutterEngine 运行 /external-player 路由（纯视频画面），
 * 主屏与副屏之间的指令/状态通过本类的桥接 MethodChannel 转发。
 *
 * 重要（2026-10-16 v6 修复）：
 * 副屏 FlutterEngine 一经创建便**常驻进程**，投屏开关只创建/销毁 Presentation。
 * 原因：media-kit（libmpv FFI）的原生事件循环在进程内存在跨引擎的全局互斥；
 * 若在副屏播放器尚未释放时直接 engine.destroy()，其事件循环线程会挂在全局锁上，
 * 之后本进程所有 mpv 调用（含新建播放器）全部永久死锁 —— 表现为
 * 「退出投屏后播放任何视频都黑屏、界面卡死（ANR，主线程 futex_wait）」。
 * 引擎只在应用退出（Activity detach）时销毁。
 */
object ExternalDisplayManager : MethodChannel.MethodCallHandler {
    private const val MAIN_CHANNEL = "piliplus/external_display"
    private const val BRIDGE_CHANNEL = "piliplus/external_display/bridge"
    const val ROUTE = "/external-player"

    private var mainChannel: MethodChannel? = null
    private var bridgeChannel: MethodChannel? = null
    private var presentation: Presentation? = null
    private var engine: FlutterEngine? = null
    private var rootView: FrameLayout? = null
    private var activity: Activity? = null
    private var displayListener: DisplayManager.DisplayListener? = null
    private var displayManager: DisplayManager? = null
    private var connectedDisplayId: Int = -1

    fun init(messenger: BinaryMessenger) {
        mainChannel = MethodChannel(messenger, MAIN_CHANNEL).also {
            it.setMethodCallHandler(this)
        }
    }

    private fun externalDisplays(context: Context): List<Display> {
        val dm = context.getSystemService(Context.DISPLAY_SERVICE) as DisplayManager
        return dm.getDisplays(DisplayManager.DISPLAY_CATEGORY_PRESENTATION).toList()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val ctx = activity ?: run {
            result.error("NO_ACTIVITY", "activity not attached", null)
            return
        }
        when (call.method) {
            "isAvailable" -> result.success(externalDisplays(ctx).isNotEmpty())
            "connect" -> connect(ctx, result)
            "disconnect" -> {
                disconnect()
                result.success(true)
            }
            // 主屏 Dart -> 副屏 Dart
            "forwardToExternal" -> {
                val bridge = bridgeChannel
                if (bridge == null) {
                    result.error("NOT_CONNECTED", "external display not connected", null)
                } else {
                    bridge.invokeMethod(
                        call.argument<String>("method") ?: "",
                        call.argument<Any?>("args")
                    )
                    result.success(null)
                }
            }
            else -> result.notImplemented()
        }
    }

    /**
     * 确保副屏引擎已创建。返回 true 表示本次是新建（首次连接），
     * false 表示复用了已常驻的引擎（副屏页面早已就绪，不会再上报 externalReady）。
     */
    private fun ensureEngine(ctx: Activity): Boolean {
        if (engine != null && rootView != null) {
            return false
        }

        val loader = FlutterInjector.instance().flutterLoader()
        loader.startInitialization(ctx)
        val appBundlePath = loader.findAppBundlePath()

        val eng = FlutterEngine(ctx)
        // 只注册 media-kit 两个插件：副屏引擎绝不能注册 audio_service 等
        // 全局单例插件，否则会劫持主引擎的音频会话导致本机黑屏无声
        eng.plugins.add(MediaKitLibsAndroidVideoPlugin())
        eng.plugins.add(MediaKitVideoPlugin())
        eng.navigationChannel.setInitialRoute(ROUTE)
        eng.dartExecutor.executeDartEntrypoint(
            DartExecutor.DartEntrypoint(appBundlePath, "externalDisplayMain")
        )
        eng.lifecycleChannel.appIsResumed()
        engine = eng

        bridgeChannel = MethodChannel(eng.dartExecutor.binaryMessenger, BRIDGE_CHANNEL)
        bridgeChannel?.setMethodCallHandler { call, r ->
            if (call.method == "forwardToMain") {
                // 副屏 Dart -> 主屏 Dart
                mainChannel?.invokeMethod(
                    "forwarded",
                    mapOf(
                        "method" to (call.argument<Any?>("method") ?: ""),
                        "args" to call.argument<Any?>("args")
                    )
                )
                r.success(null)
            } else {
                r.notImplemented()
            }
        }

        val flutterView = FlutterView(ctx)
        flutterView.attachToFlutterEngine(eng)
        val root = FrameLayout(ctx).apply {
            setBackgroundColor(0xFF000000.toInt())
            addView(
                flutterView,
                FrameLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT,
                    ViewGroup.LayoutParams.MATCH_PARENT
                )
            )
        }
        rootView = root
        return true
    }

    private fun connect(ctx: Activity, result: MethodChannel.Result) {
        val display = externalDisplays(ctx).firstOrNull() ?: run {
            result.error("NO_DISPLAY", "no presentation display", null)
            return
        }

        try {
            val created = ensureEngine(ctx)
            val root = rootView ?: run {
                result.error("NO_VIEW", "external view unavailable", null)
                return
            }
            // 上一次投屏的 Presentation 若还没关，先关掉
            try {
                presentation?.dismiss()
            } catch (_: Exception) {
            }
            presentation = null
            (root.parent as? ViewGroup)?.removeView(root)

            connectedDisplayId = display.displayId
            registerDisplayListener(ctx)

            val p = object : Presentation(ctx, display) {
                override fun onCreate(savedInstanceState: Bundle?) {
                    super.onCreate(savedInstanceState)
                    window?.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                }

                override fun onStop() {
                    super.onStop()
                    mainChannel?.invokeMethod("presentationDismissed", null)
                }
            }
            p.setContentView(root)
            p.show()
            presentation = p

            // 保持本机屏幕常亮，避免息屏后副屏画面中断
            ctx.window?.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)

            val resolution: Map<String, Any> =
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                    mapOf(
                        "width" to display.mode.physicalWidth.toDouble(),
                        "height" to display.mode.physicalHeight.toDouble(),
                        "reused" to if (created) 0.0 else 1.0
                    )
                } else {
                    mapOf("reused" to if (created) 0.0 else 1.0)
                }
            result.success(resolution)
        } catch (e: Exception) {
            try {
                presentation?.dismiss()
            } catch (_: Exception) {
            }
            presentation = null
            result.error("CONNECT_FAILED", e.message, null)
        }
    }

    private fun registerDisplayListener(ctx: Context) {
        unregisterDisplayListener()
        val dm = ctx.getSystemService(Context.DISPLAY_SERVICE) as DisplayManager
        displayManager = dm
        val l = object : DisplayManager.DisplayListener {
            override fun onDisplayAdded(displayId: Int) {}
            override fun onDisplayChanged(displayId: Int) {}
            override fun onDisplayRemoved(displayId: Int) {
                if (displayId == connectedDisplayId) {
                    // 拔线/投屏断开：清理并通知主屏回本机
                    disconnect()
                }
            }
        }
        dm.registerDisplayListener(l, null)
        displayListener = l
    }

    private fun unregisterDisplayListener() {
        val l = displayListener ?: return
        displayListener = null
        try {
            displayManager?.unregisterDisplayListener(l)
        } catch (_: Exception) {
        }
        displayManager = null
    }

    /**
     * 结束投屏：**只关闭 Presentation**，副屏引擎保持常驻以便下次复用。
     * 副屏播放器由 Dart 侧下发 dispose 释放（引擎活着才能正常收尾 mpv）。
     */
    private fun disconnect() {
        connectedDisplayId = -1
        unregisterDisplayListener()
        try {
            presentation?.dismiss()
        } catch (_: Exception) {
        }
        presentation = null
        activity?.window?.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    }

    /** 仅在应用退出时调用：彻底销毁副屏引擎与视图 */
    private fun shutdownEngine() {
        try {
            bridgeChannel?.setMethodCallHandler(null)
        } catch (_: Exception) {
        }
        bridgeChannel = null
        try {
            (rootView?.parent as? ViewGroup)?.removeView(rootView)
        } catch (_: Exception) {
        }
        rootView = null
        try {
            engine?.destroy()
        } catch (_: Exception) {
        }
        engine = null
    }

    fun attach(activity: Activity, messenger: BinaryMessenger) {
        this.activity = activity
        init(messenger)
    }

    fun detach() {
        disconnect()
        // 刻意不在这里 destroy 副屏引擎：若副屏播放器的 mpv 尚未收尾完成，
        // 强杀引擎会让进程内的 mpv 原生事件循环锁永久悬挂（退出时表现为卡死）。
        // 引擎随进程结束一并回收，代价可忽略。
        mainChannel?.setMethodCallHandler(null)
        mainChannel = null
        activity = null
    }
}
