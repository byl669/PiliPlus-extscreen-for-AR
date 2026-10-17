import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';


/// 主引擎侧的外接显示器服务。
/// 负责与原生 ExternalDisplayManager 通信，并桥接主副屏之间的消息。
class ExternalDisplayService {
  ExternalDisplayService._();

  static const MethodChannel _channel = MethodChannel('piliplus/external_display');
  static const String route = '/external-player';

  /// 副屏是否已就绪（副屏页面 initState 后上报）
  static bool _externalReady = false;
  static Map<String, dynamic>? _pendingLoad;

  /// 来自副屏的事件流：{'event': method, 'data': args}
  static final StreamController<Map<String, dynamic>> _events =
      StreamController<Map<String, dynamic>>.broadcast();

  /// 看门狗：副屏每 500ms 上报一次状态，若连接状态下超过 6s 无上报，
  /// 判定副屏引擎已死，自动断开并通知主屏回本机，避免卡死只能强杀
  static Timer? _watchdog;
  static int _lastStateAt = 0;

  /// 「副屏已停播并摘掉视频输出」的一次性回执。
  /// 关闭 Presentation 前必须等到它，否则 Surface 先销毁、mpv 还在用，
  /// 会导致 mpv 核心线程卡死（详见 external_player_page.dart 头部说明）。
  static Completer<void>? _externalDispose;

  static Stream<Map<String, dynamic>> get events => _events.stream;
  static bool get isConnected => _connected;
  static bool _connected = false;

  /// 当前投屏会话的属主控制器（页面）。
  /// 多个视频页可同时存活，只有属主响应 disconnected 等会话级事件，
  /// 避免栈底的旧页面误触发回本机续播。
  static Object? _owner;
  static bool isOwner(Object c) => identical(_owner, c);
  static Object? get owner => _owner;

  /// 登记一次「等待副屏释放完成」，返回值在副屏回执 disposeDone 时完成。
  static Future<void> armExternalDispose() {
    _completeExternalDispose();
    final c = Completer<void>();
    _externalDispose = c;
    return c.future;
  }

  static void _completeExternalDispose() {
    final c = _externalDispose;
    _externalDispose = null;
    if (c != null && !c.isCompleted) {
      c.complete();
    }
  }

  /// 当前属主被新页面接管时的回调，用于让旧页面静默退出投屏态（不主动断开连接）
  static void Function()? _ownerRelease;

  /// 接管投屏会话：若已有其他属主，先通知其静默退出，再让本次调用者成为唯一属主。
  /// 这样任何时刻只有一个视频页持有会话，避免多页面共用同一播放器互相干扰。
  static void takeOwner(Object c, {void Function()? onRelease}) {
    if (_owner != null && !identical(_owner, c)) {
      final release = _ownerRelease;
      _ownerRelease = null;
      try {
        release?.call();
      } catch (_) {
        // ignore
      }
    }
    _owner = c;
    _ownerRelease = onRelease;
  }

  static void clearOwner(Object c) {
    if (identical(_owner, c)) {
      _owner = null;
      _ownerRelease = null;
    }
  }

  static bool _listening = false;

  static void _ensureListener() {
    if (_listening) return;
    _listening = true;
    _channel.setMethodCallHandler(_onNativeCall);
  }

  static Future<dynamic> _onNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'forwarded':
        final args = Map<String, dynamic>.from(call.arguments as Map? ?? {});
        final method = args['method'] as String? ?? '';
        final data = args['args'];
        if (method == 'externalReady') {
          _externalReady = true;
          if (_pendingLoad != null) {
            sendToExternal('load', _pendingLoad);
            _pendingLoad = null;
          }
        }
        if (method == 'state') {
          _lastStateAt = DateTime.now().millisecondsSinceEpoch;
        }
        if (method == 'disposeDone') {
          _completeExternalDispose();
        }
        _events.add({'event': method, 'data': data});
        break;
      case 'presentationDismissed':
        _externalReady = false;
        _connected = false;
        _owner = null;
        _ownerRelease = null;
        _completeExternalDispose();
        _events.add({'event': 'dismissed', 'data': null});
        break;
    }
    return null;
  }

  /// 是否检测到外接显示器
  static Future<bool> isAvailable() async {
    try {
      _ensureListener();
      return await _channel.invokeMethod('isAvailable') == true;
    } on PlatformException {
      return false;
    }
  }

  /// 连接外接屏（成功返回分辨率，失败抛 PlatformException）
  static Future<Map<String, dynamic>?> connect() async {
    _ensureListener();
    _externalReady = false;
    final res = await _channel.invokeMapMethod<String, dynamic>('connect');
    _connected = true;
    // 副屏引擎常驻复用：此时副屏页面早已就绪，不会再发 externalReady，
    // 需在此直接标记就绪并补发挂起的 load，否则副屏永远收不到播放任务。
    final reused = (res?['reused'] as num?)?.toInt() == 1;
    if (reused) {
      _externalReady = true;
      final pending = _pendingLoad;
      if (pending != null) {
        _pendingLoad = null;
        sendToExternal('load', pending);
      }
    }
    return res;
  }

  /// 启动看门狗（下发播放任务后调用）
  static void startWatchdog() {
    _lastStateAt = DateTime.now().millisecondsSinceEpoch;
    _watchdog?.cancel();
    _watchdog = Timer.periodic(const Duration(seconds: 2), (_) async {
      if (!_connected) {
        _watchdog?.cancel();
        _watchdog = null;
        return;
      }
      final idle = DateTime.now().millisecondsSinceEpoch - _lastStateAt;
      if (idle > 6000) {
        // 副屏无响应：断开并通知回本机
        await disconnect();
        _events.add({'event': 'dismissed', 'data': null});
      }
    });
  }

  /// 断开外接屏
  static Future<void> disconnect() async {
    _watchdog?.cancel();
    _watchdog = null;
    try {
      await _channel.invokeMethod('disconnect');
    } on PlatformException {
      // ignore
    }
    _connected = false;
    _externalReady = false;
    _pendingLoad = null;
    _owner = null;
    _ownerRelease = null;
  }

  /// 向副屏发送加载载荷（若副屏未就绪则缓存，就绪后自动补发）
  static void load(Map<String, dynamic> payload) {
    if (_externalReady) {
      sendToExternal('load', payload);
      _pendingLoad = null;
    } else {
      _pendingLoad = payload;
    }
  }

  /// 向副屏发送指令
  static Future<void> sendToExternal(String method, Map<String, dynamic>? args) async {
    try {
      await _channel.invokeMethod('forwardToExternal', {'method': method, 'args': args});
    } on PlatformException {
      // ignore
    }
  }

  static void dispose() {
    _events.close();
  }
}
