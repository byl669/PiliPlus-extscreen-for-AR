import 'dart:async';

import 'package:PiliPlus/http/browser_ua.dart';
import 'package:PiliPlus/http/constants.dart';
import 'package:PiliPlus/pages/video/external_display/service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';


/// 外接显示器副屏应用（入口函数在 main.dart 的 externalDisplayMain）。
/// 仅显示视频画面，所有控制由主屏通过 bridge 下发。
class ExternalPlayerApp extends StatelessWidget {
  const ExternalPlayerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      routes: {
        ExternalDisplayService.route: (_) => const _ExternalPlayerPage(),
      },
    );
  }
}

class _ExternalPlayerPage extends StatefulWidget {
  const _ExternalPlayerPage();

  @override
  State<_ExternalPlayerPage> createState() => _ExternalPlayerPageState();
}

/// 副屏播放器生命周期（2026-10-16 v7 关键修复）
///
/// 【为什么副屏 Player 创建一次后永不 dispose】
/// media-kit 的 `NativePlayer.dispose()` 会把真正的 `mpv_terminate_destroy()`
/// 放进一个 5 秒后的 `Timer` 里执行（见 media_kit real.dart）。若此时副屏的
/// 视频输出（Surface）已随 Presentation 关闭而销毁，mpv 的核心线程会卡在视频
/// 输出拆除上，`mpv_terminate_destroy` 将**永久阻塞**（libmpv 内部
/// `pthread_cond_wait`），把整个 App 拖成 ANR（主线程 futex_wait）。
///
/// 因此这里改为：副屏 `Player` + `VideoController` 只创建一次，跨投屏会话
/// 长期复用；会话结束只 `pause()` + `stop()`（在 Surface 仍然存在时执行），
/// 从不销毁 `Player`，从根本上消除那段延迟 `mpv_terminate_destroy`。
///
/// 同时新增 `disposeDone` 回执：主屏必须等副屏停播完成后，才去关闭
/// Presentation，避免出现「Surface 先没了、mpv 还在用」的竞态。
class _ExternalPlayerPageState extends State<_ExternalPlayerPage> {
  static const MethodChannel _bridge = MethodChannel(
    'piliplus/external_display/bridge',
  );

  Player? _player;
  VideoController? _videoController;
  StreamSubscription? _errSub;
  StreamSubscription? _completedSub;
  Timer? _reportTimer;
  String? _errorText;
  bool _sessionActive = false;

  /// 上一次会话收尾（pause/stop）超时 → 这个 Player 的 mpv 句柄已经不可靠
  /// （命令永不回执，后续 await 会永久挂起）。下次 load 时直接丢弃重建。
  bool _playerPoisoned = false;

  @override
  void initState() {
    super.initState();
    _bridge.setMethodCallHandler(_onCommand);
    // 通知主屏：副屏已就绪，可下发 load
    _bridge.invokeMethod('forwardToMain', {
      'method': 'externalReady',
      'args': null,
    });
  }

  Future<dynamic> _onCommand(MethodCall call) async {
    final args = Map<String, dynamic>.from(call.arguments as Map? ?? {});
    switch (call.method) {
      case 'load':
        await _load(args);
        break;
      case 'play':
        unawaited(_player?.play());
        break;
      case 'pause':
        unawaited(_player?.pause());
        break;
      case 'seek':
        final ms = (args['position'] as num?)?.toInt() ?? 0;
        unawaited(_player?.seek(Duration(milliseconds: ms)));
        break;
      case 'setRate':
        final rate = (args['rate'] as num?)?.toDouble() ?? 1.0;
        unawaited(_player?.setRate(rate));
        break;
      case 'ping':
        await _sendToMain('pong', null);
        break;
      case 'dispose':
        // 先停播（此时 Surface 仍在），再回执；主屏收到回执后才关闭 Presentation
        await _stopSession();
        await _sendToMain('disposeDone', null);
        break;
      case 'getPos':
        _reportState(force: true);
        break;
    }
    return null;
  }

  Future<void> _sendToMain(String method, Object? args) async {
    try {
      await _bridge.invokeMethod('forwardToMain', {
        'method': method,
        'args': args,
      });
    } catch (_) {
      // 主屏可能已销毁，忽略
    }
  }

  /// 懒创建（并复用）副屏播放器与视频输出
  Future<Player> _ensurePlayer() async {
    var exist = _player;
    if (exist != null && _playerPoisoned) {
      // 上一轮 stop/pause 超时：该 mpv 句柄已不再回执事件，任何 await 都会
      // 永久挂起。这里丢弃重建，避免「投屏一次之后再也投不上去」。
      final old = _player!;
      _player = null;
      _playerPoisoned = false;
      final oldSub1 = _errSub;
      final oldSub2 = _completedSub;
      _errSub = null;
      _completedSub = null;
      _videoController = null;
      unawaited(oldSub1?.cancel());
      unawaited(oldSub2?.cancel());
      // 刻意不 await dispose：media-kit 的 dispose 会把 mpv_terminate_destroy
      // 丢进 5 秒后的 Timer，若句柄已卡死，await 会把副屏一起拖住。
      unawaited(
        Future<void>(() async {
          try {
            await old.dispose();
          } catch (_) {
            // ignore
          }
        }),
      );
      exist = null;
    }
    if (exist != null) return exist;
    final player = await Player.create(
      configuration: const PlayerConfiguration(
        logLevel: MPVLogLevel.error,
      ),
    );
    player.setMediaHeader(userAgent: BrowserUa.pc, referer: HttpString.baseUrl);
    _videoController = await VideoController.create(
      player,
      configuration: const VideoControllerConfiguration(
        enableHardwareAcceleration: true,
        // 默认 true：等视频参数就绪后再挂 Surface，提前挂会白屏
        androidAttachSurfaceAfterVideoParameters: true,
      ),
    );
    _errSub = player.stream.error.listen((e) {
      if (mounted) {
        setState(() => _errorText = e.toString());
      }
      _sendToMain('playbackError', {'error': e.toString()});
    });
    _completedSub = player.stream.completed.listen((completed) {
      if (completed) _reportState(force: true);
    });
    _player = player;
    return player;
  }

  /// 结束一次投屏会话：停播 + 停上报，但**保留 Player / VideoController**。
  /// 只在 Surface 仍然存在时执行，确保 mpv 能干净地停下来。
  ///
  /// 注意：media-kit 的 pause()/stop() 都是「发异步命令 + await 回执」，
  /// 一旦 mpv 不再产出事件（副屏视频输出卡住等），await 会**永久挂起**。
  /// 早先这里没有超时，导致 disposeDone 回执永远不来、主屏只能超时兜底，
  /// 而副屏播放器被留在半死状态，下一次投屏（复用引擎）必然失败。
  /// 现在全部加超时，并把超时的播放器标记为不可信（下次重建）。
  Future<void> _stopSession() async {
    _reportTimer?.cancel();
    _reportTimer = null;
    _sessionActive = false;
    final player = _player;
    if (player != null) {
      var ok = true;
      // 预算必须小于主屏 armExternalDispose 的 2500ms 等待窗口，
      // 否则主屏会先超时、disposeDone 回执白等。
      try {
        await player.pause().timeout(const Duration(milliseconds: 800));
      } catch (_) {
        ok = false;
      }
      try {
        await player.stop().timeout(const Duration(milliseconds: 1200));
      } catch (_) {
        ok = false;
      }
      if (!ok) {
        _playerPoisoned = true;
      }
    }
    if (mounted) setState(() {});
  }

  Future<void> _load(Map<String, dynamic> args) async {
    if (mounted && _errorText != null) {
      setState(() => _errorText = null);
    }
    final video = args['video'] as String?;
    if (video == null || video.isEmpty) return;

    try {
      final player = await _ensurePlayer();
      // 同一 Player 换片：先停掉上一段（保留视频输出，不销毁播放器）
      try {
        await player.stop().timeout(const Duration(seconds: 2));
      } catch (_) {
        _playerPoisoned = true;
      }

      final extras = Map<String, String>.from(args['extras'] as Map? ?? {});
      final posMs = (args['position'] as num?)?.toInt() ?? 0;
      final rate = (args['rate'] as num?)?.toDouble() ?? 1.0;

      _sessionActive = true;
      if (mounted) setState(() {});

      _reportTimer?.cancel();
      _reportTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
        _reportState();
      });

      try {
        await player.setRate(rate).timeout(const Duration(seconds: 2));
      } catch (_) {
        _playerPoisoned = true;
      }
      await player
          .open(
            Media(
              video,
              start: posMs > 0 ? Duration(milliseconds: posMs) : null,
              extras: extras.isEmpty ? null : extras,
            ),
            play: true,
          )
          .timeout(const Duration(seconds: 10));
    } catch (e) {
      _playerPoisoned = true;
      if (mounted) setState(() => _errorText = e.toString());
      await _sendToMain('playbackError', {'error': e.toString()});
    }
  }

  void _reportState({bool force = false}) {
    final player = _player;
    if (player == null) return;
    final st = player.state;
    _sendToMain('state', {
      'position': st.position.inMilliseconds,
      'duration': st.duration.inMilliseconds,
      'buffered': st.buffer.inMilliseconds,
      'playing': st.playing,
      'completed': st.completed,
    });
  }

  @override
  void dispose() {
    _bridge.setMethodCallHandler(null);
    // 注意：刻意不销毁 _player（见类头注释，销毁会触发 5 秒后的
    // mpv_terminate_destroy 永久阻塞）。副屏引擎与播放器随进程常驻复用。
    _reportTimer?.cancel();
    _reportTimer = null;
    _sessionActive = false;
    unawaited(_errSub?.cancel());
    unawaited(_completedSub?.cancel());
    _errSub = _completedSub = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _videoController;
    final error = _errorText;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: error != null
            ? Text(
                '播放出错：$error',
                style: const TextStyle(color: Colors.redAccent, fontSize: 18),
                textAlign: TextAlign.center,
              )
            : (!_sessionActive || controller == null)
                ? const Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.connected_tv, color: Colors.white24, size: 64),
                      SizedBox(height: 12),
                      Text(
                        '等待主屏下发播放任务…',
                        style: TextStyle(color: Colors.white24, fontSize: 16),
                      ),
                    ],
                  )
                : Video(controller: controller),
      ),
    );
  }
}
