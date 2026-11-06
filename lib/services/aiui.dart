import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/settings.dart';
import '../ui/providers.dart' show settingsProvider;

/// AIUI 上行事件。
class AiuiEvent {
  final String type;
  final String? text;
  final String? answer;
  final bool finalText;
  final int? code;
  final String? message;
  final String? intent;
  final String? raw;
  final int? level;

  const AiuiEvent({
    required this.type,
    this.text,
    this.answer,
    this.finalText = false,
    this.code,
    this.message,
    this.intent,
    this.raw,
    this.level,
  });

  factory AiuiEvent.fromMap(Map<Object?, Object?> m) {
    final type = (m['type'] as String?) ?? 'log';
    return AiuiEvent(
      type: type,
      text: m['text'] as String?,
      answer: m['answer'] as String?,
      finalText: (m['final'] as bool?) ?? false,
      code: (m['code'] as num?)?.toInt(),
      message: m['message'] as String?,
      intent: m['intent'] as String?,
      raw: m['raw'] as String?,
      level: (m['level'] as num?)?.toInt(),
    );
  }

  bool get isIatFinal => type == 'iat' && finalText;
  bool get isNlpFinal => type == 'nlp' && finalText;
  bool get isError => type == 'error';

  @override
  String toString() => 'AiuiEvent($type, text=$text, code=$code, msg=$message)';
}

/// 讯飞 AIUI 全双工语音交互客户端（Android 原生 MethodChannel / EventChannel 桥接）。
///
/// 与在线版 [XunfeiIatClient] / [XunfeiTtsClient] 并存：AIUI 负责「接电话式」的一问一答
/// 语音回路（本地 VAD + 云端听写 + 云端 TTS 边收边播），在线版负责单句听写和朗读。
class AiuiClient {
  static const _cmd = MethodChannel('com.echoenglish.aiui/cmd');
  static const _events = EventChannel('com.echoenglish.aiui/event');

  final AppSettings settings;

  StreamSubscription<dynamic>? _sub;
  final _ctrl = StreamController<AiuiEvent>.broadcast();

  bool _initialized = false;
  String? _sdkVersion;

  AiuiClient(this.settings);

  /// AIUI 仅 Android 有原生实现
  static bool get isSupported => Platform.isAndroid;

  /// 上行事件流：ready / connected / disconnected / wakeup / sleep / iat / nlp /
  /// tts_start / tts_end / vad_bos / vad_eos / record_start / record_stop / error / log
  Stream<AiuiEvent> get events => _ctrl.stream;

  bool get isInitialized => _initialized;
  String? get sdkVersion => _sdkVersion;

  Future<void> _ensureListening() async {
    if (_sub != null) return;
    _sub = _events.receiveBroadcastStream().listen(
      (dynamic raw) {
        if (raw is Map) {
          final ev = AiuiEvent.fromMap(raw);
          if (!_ctrl.isClosed) _ctrl.add(ev);
          if (ev.type == 'ready' && ev.raw != null) {
            _sdkVersion = ev.raw;
          }
        }
      },
      onError: (Object e) {
        if (!_ctrl.isClosed) {
          _ctrl.add(AiuiEvent(type: 'error', message: e.toString()));
        }
      },
      cancelOnError: false,
    );
  }

  /// 初始化：优先用 [AppSettings] 里的 appId / apiKey / apiSecret，缺省时用 assets 里 cfg 的值。
  Future<String> init({
    String? voice,
    String? scene,
    String? wakeupMode,
  }) async {
    if (!isSupported) {
      throw StateError('AIUI 只在 Android 上可用');
    }
    await _ensureListening();
    final v = await _cmd.invokeMethod<String>('init', <String, Object?>{
      'appId': settings.xfAppId,
      'apiSecret': settings.xfApiSecret,
      'apiKey': settings.xfApiKey,
      'voice': voice ?? settings.xfTtsVoice,
      'scene': scene ?? 'sos_app',
      'wakeupMode': wakeupMode ?? 'off',
    });
    _initialized = true;
    _sdkVersion = v;
    return v ?? '';
  }

  Future<void> startInteraction() async {
    await _ensureListening();
    await _cmd.invokeMethod<bool>('startInteraction');
  }

  Future<void> stopInteraction() async {
    await _cmd.invokeMethod<bool>('stopInteraction');
  }

  /// 预置「用户已说但等待自己大模型回答」的答案，AIUI 的 nlp 结果里会回传。
  Future<void> setPendingAnswer(String text) async {
    await _cmd.invokeMethod<bool>('setPendingAnswer', <String, Object?>{'text': text});
  }

  /// 用我们的文本让 AIUI 云端 TTS 播报（原生边收边播）。
  Future<void> speak(String text) async {
    await _cmd.invokeMethod<bool>('speak', <String, Object?>{'text': text});
  }

  Future<void> abortSpeak() async {
    await _cmd.invokeMethod<bool>('abortSpeak');
  }

  Future<void> wakeup() async {
    await _cmd.invokeMethod<bool>('wakeup');
  }

  Future<bool> hasMicPermission() async {
    try {
      return await _cmd.invokeMethod<bool>('hasMicPermission') ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<void> dispose() async {
    try {
      if (_initialized) await _cmd.invokeMethod<bool>('destroy');
    } catch (_) {
      // 忽略：页面销毁时原生侧可能已经 detach
    }
    _initialized = false;
    await _sub?.cancel();
    _sub = null;
    await _ctrl.close();
  }
}

final aiuiClientProvider = Provider<AiuiClient>((ref) {
  final s = ref.watch(settingsProvider).valueOrNull;
  final c = AiuiClient(s ?? AppSettings.defaults());
  ref.onDispose(c.dispose);
  return c;
});

/// AIUI 是否已被初始化过（用于 UI 决定显示「全双工」开关）
final aiuiReadyProvider = StateProvider<bool>((_) => false);
