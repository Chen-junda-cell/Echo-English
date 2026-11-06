import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../data/settings.dart';
import 'pcm.dart';

/// 讯飞语音合成，同时支持两套接口：
///
/// 1. **在线语音合成（流式版）** —— `tts-api.xfyun.cn/v2/tts`
///    发音人如 `xiaoyan` / `aisjiuxu`，输出 raw PCM 16k。
///
/// 2. **超拟人语音合成** —— `cbm01.cn-huabei-1.xf-yun.com/v1/private/mcd9m97e6`
///    发音人如 `x6_lingxiaoxuan_pro` / `x4_yezi`，默认输出 MP3，音质更好。
///
/// 走哪套由「发音人参数」自动判断：
/// - 参数里带 `_`（如 x6_lingxiaoxuan_pro）或 `x4_`/`x5_`/`x6_` 前缀 → 超拟人
/// - 其余（xiaoyan / aisjiuxu …）→ 在线语音合成
///
/// **重要：每次 synthesize 用的都是函数内的局部变量，没有任何跨调用的
/// 共享 socket / buffer / completer。** 早期版本把它们放在实例字段上，
/// 于是「自动朗读」和「点小喇叭」同时触发时，后一次调用会把前一次的
/// channel 覆盖掉，然后前一次在 finally 里把后一次的 socket 关掉 ——
/// 表现为「这次完全没有声音 + 报语音合成超时，没有收到任何音频」。
class XunfeiTtsClient {
  XunfeiTtsClient(this.settings);

  final AppSettings settings;

  // ---- 在线语音合成（流式版） ----
  static const _host = 'tts-api.xfyun.cn';
  static const _path = '/v2/tts';

  // ---- 超拟人语音合成 ----
  static const _superHost = 'cbm01.cn-huabei-1.xf-yun.com';
  static const _superPath = '/v1/private/mcd9m97e6';

  AppSettings get _s => settings;

  /// 串行锁：同一时刻只跑一次合成，避免两路 TTS 抢同一个播放器、
  /// 也避免服务端并发限制。
  Future<void> _tail = Future<void>.value();

  /// 发音人参数（vcn）
  String get voice {
    final v = _s.xfTtsVoice.trim();
    return v.isEmpty ? 'xiaoyan' : v;
  }

  /// 当前发音人是否属于超拟人合成系列
  bool get isSuperVoice {
    final v = voice;
    return v.contains('_') ||
        v.startsWith('x4') ||
        v.startsWith('x5') ||
        v.startsWith('x6');
  }

  /// 当前使用的接口标识，用于设置页展示
  String get endpointLabel =>
      isSuperVoice ? '超拟人语音合成（MP3 24k）' : '在线语音合成（PCM 16k）';

  /// 超拟人接口支持第二种鉴权：`x-api-key` 请求头（控制台里的 APIKey / APIPassword）。
  /// 填了就优先用它，避免和 URL 签名那套 32 位 APISecret 混淆。
  bool get useHeaderAuth => isSuperVoice && _s.xfApiPassword.trim().isNotEmpty;

  /// 当前使用的鉴权方式，便于设置页展示
  String get authLabel =>
      useHeaderAuth ? 'x-api-key 请求头' : 'URL 签名（APIKey + APISecret）';

  Map<String, dynamic>? get extraHeaders => _headers(useHeaderAuth);

  Map<String, dynamic>? _headers(bool headerAuth) => headerAuth
      ? {'x-api-key': _s.xfApiPassword.trim()}
      : null;

  String buildAuthUrl() => _authUrl(useHeaderAuth);

  String _authUrl(bool headerAuth) {
    final host = isSuperVoice ? _superHost : _host;
    final path = isSuperVoice ? _superPath : _path;
    if (headerAuth) return 'wss://$host$path';
    final date = _rfc1123(DateTime.now().toUtc());
    final origin = 'host: $host\ndate: $date\nGET $path HTTP/1.1';
    final signatureOrigin = _hmacSha256Base64(origin, _s.xfApiSecret.trim());
    final authorizationOrigin =
        'api_key="${_s.xfApiKey.trim()}", algorithm="hmac-sha256", headers="host date request-line", signature="$signatureOrigin"';
    final authorization = base64Encode(utf8.encode(authorizationOrigin));
    final q = 'authorization=$authorization'
        '&date=${Uri.encodeComponent(date)}'
        '&host=$host';
    return 'wss://$host$path?$q';
  }

  /// 合成一段文本。返回值里带「编码格式」，调用方据此决定怎么播。
  Future<TtsAudio> synthesize(
    String text, {
    int speed = 50,
    int volume = 60,
    int pitch = 50,
  }) async {
    if (!_s.xfReady) {
      throw Exception('尚未填写讯飞 APPID / APIKey / APISecret，请先到「设置」页填写');
    }

    // 排队：等上一次合成彻底结束再开始，绝不并发
    final prev = _tail;
    final gate = Completer<void>();
    _tail = gate.future;
    try {
      await prev;
    } catch (_) {}

    try {
      return await _synthesizeOnce(
        text,
        speed: speed,
        volume: volume,
        pitch: pitch,
        headerAuth: useHeaderAuth,
      );
    } catch (e) {
      // 超拟人接口允许两种鉴权，用户很容易把「APIKey / APIPassword」和
      // 「APISecret 签名」搞混。主鉴权失败时自动换另一种再试一次，
      // 省掉一轮「改设置 → 重装包」的来回。
      final canAlt = isSuperVoice &&
          _s.xfApiPassword.trim().isNotEmpty &&
          _s.xfApiSecret.trim().isNotEmpty;
      if (!canAlt) rethrow;
      try {
        return await _synthesizeOnce(
          text,
          speed: speed,
          volume: volume,
          pitch: pitch,
          headerAuth: !useHeaderAuth,
        );
      } catch (e2) {
        throw Exception(
          '两种鉴权都失败。\n'
          '① ${useHeaderAuth ? 'x-api-key 请求头' : 'URL 签名'}：$e\n'
          '② ${useHeaderAuth ? 'URL 签名' : 'x-api-key 请求头'}：$e2',
        );
      }
    } finally {
      gate.complete();
    }
  }

  Future<TtsAudio> _synthesizeOnce(
    String text, {
    required int speed,
    required int volume,
    required int pitch,
    required bool headerAuth,
  }) async {
    final clean = _cleanText(text);
    if (clean.isEmpty) return TtsAudio.empty();

    final buf = BytesBuilder(copy: false);
    final done = Completer<TtsAudio>();
    final trace = <String>[];
    WebSocketChannel? channel;
    Timer? idle;

    void closeAll() {
      idle?.cancel();
      idle = null;
      final c = channel;
      channel = null;
      try {
        c?.sink.close();
      } catch (_) {}
    }

    TtsAudio build() {
      final bytes = buf.takeBytes();
      if (bytes.isEmpty) return TtsAudio.empty();
      if (isSuperVoice) {
        return TtsAudio(bytes: bytes, format: TtsFormat.mp3, sampleRate: 24000);
      }
      return TtsAudio(bytes: bytes, format: TtsFormat.pcm16, sampleRate: 16000);
    }

    void finish() {
      if (done.isCompleted) return;
      done.complete(build());
      closeAll();
    }

    void fail(Exception e) {
      if (done.isCompleted) return;
      done.completeError(e);
      closeAll();
    }

    /// 两个协议的「结束」标记并不总是可靠（实测超拟人偶尔只给音频不给结束位），
    /// 所以再加一道保险：收到音频后若 1.2 秒没有新数据，就认为合成完毕。
    void touchIdle() {
      idle?.cancel();
      idle = Timer(const Duration(milliseconds: 1200), finish);
    }

    void onMessage(dynamic raw) {
      final s = _rawToString(raw);
      if (s.isEmpty) return;
      // 留最近几帧，出错时直接写进报错里，省得靠猜
      if (trace.length < 5) {
        trace.add(s.length > 200 ? '${s.substring(0, 200)}…' : s);
      }

      Map<String, dynamic> msg;
      try {
        final decoded = jsonDecode(s);
        if (decoded is! Map) return;
        msg = decoded.cast<String, dynamic>();
      } catch (_) {
        return;
      }

      final header = msg['header'];
      final code = _intOf(header is Map ? header['code'] : msg['code']) ?? 0;
      if (code != 0) {
        final message =
            (header is Map ? header['message'] : msg['message']) ?? '';
        fail(Exception('讯飞 TTS 返回错误 $code：$message${_hintFor(code)}'));
        return;
      }
      final headerStatus = _intOf(header is Map ? header['status'] : null);

      // 超拟人：payload.audio.audio 是 base64 音频分片
      final payload = msg['payload'];
      if (payload is Map) {
        final audioBlock = payload['audio'];
        if (audioBlock is Map) {
          final chunk = audioBlock['audio'];
          if (chunk is String && chunk.isNotEmpty) {
            buf.add(_b64(chunk));
            touchIdle();
          }
          final st = _intOf(audioBlock['status']);
          if (st == 2 || headerStatus == 2) {
            finish();
            return;
          }
        }
      }

      // 在线语音合成：data.audio
      final data = msg['data'];
      if (data is Map) {
        final chunk = data['audio'];
        if (chunk is String && chunk.isNotEmpty) {
          buf.add(_b64(chunk));
          touchIdle();
        }
        final st = _intOf(data['status']);
        if (st == 2 || headerStatus == 2) {
          finish();
        }
      }
    }

    final ws = IOWebSocketChannel.connect(
      Uri.parse(_authUrl(headerAuth)),
      headers: _headers(headerAuth),
      pingInterval: const Duration(seconds: 15),
    );
    channel = ws;

    // 先把握手等出来：被 401 拒绝时会立刻抛错，而不是干等十几秒再报“超时”。
    try {
      await ws.ready.timeout(const Duration(seconds: 10));
    } on TimeoutException {
      closeAll();
      throw Exception('连接讯飞语音合成超时，请检查网络后重试');
    } catch (e) {
      closeAll();
      throw Exception('讯飞语音合成鉴权被拒绝：$e${_authHint()}');
    }

    ws.stream.listen(
      onMessage,
      onError: (e) {
        fail(Exception('讯飞 TTS 连接错误：$e${_authHint()}'));
      },
      onDone: () {
        // 服务端正常结束时也会走这里，兜底
        finish();
      },
      cancelOnError: true,
    );

    final payload = isSuperVoice
        ? _superPayload(clean, speed: speed, volume: volume, pitch: pitch)
        : _classicPayload(clean, speed: speed, volume: volume, pitch: pitch);

    try {
      ws.sink.add(jsonEncode(payload));
    } catch (e) {
      closeAll();
      throw Exception('发送合成请求失败：$e');
    }

    final timeout = Duration(seconds: 10 + clean.length ~/ 5);
    try {
      return await done.future.timeout(timeout);
    } on TimeoutException {
      // 关键：超时但已经收到音频时，把手上这段直接拿来播，
      // 比弹「朗读失败」有用得多（服务端常有收尾包不来的情况）。
      final partial = build();
      closeAll();
      if (partial.isNotEmpty) return partial;
      throw Exception(
        '语音合成超时，没有收到任何音频${_authHint()}'
        '${trace.isEmpty ? '' : '；服务端最后返回：${trace.last}'}',
      );
    } finally {
      closeAll();
    }
  }

  /// 鉴权自查提示：把「为什么失败」直接写进报错里，省得用户对着“超时”猜。
  String _authHint() {
    if (useHeaderAuth) return '（当前用 x-api-key 请求头鉴权，请核对这一行的 APIKey）';
    final secret = _s.xfApiSecret.trim();
    if (secret.length % 4 != 0) {
      return '（APISecret 现在 ${secret.length} 位，Base64 密码应为 32 位，'
          '少复制了 ${32 - secret.length} 个字符，请回控制台整行重新复制）';
    }
    if (secret.length != 32) {
      return '（APISecret 是 ${secret.length} 位，讯飞的通常为 32 位，请核对）';
    }
    return '（三件套里 APISecret 与 APIKey 不匹配，请整行重新复制三件套）';
  }

  /// 在线语音合成（流式版）v2 协议
  Map<String, Object?> _classicPayload(
    String text, {
    required int speed,
    required int volume,
    required int pitch,
  }) =>
      {
        'common': {'app_id': _s.xfAppId.trim()},
        'business': {
          'aue': 'raw',
          'auf': 'audio/L16;rate=16000',
          'vcn': voice,
          'speed': speed,
          'volume': volume,
          'pitch': pitch,
          'tte': 'UTF8',
          'sfl': 1,
        },
        'data': {
          'status': 2,
          'text': base64Encode(utf8.encode(text)),
        },
      };

  /// 超拟人语音合成 v1 协议
  Map<String, Object?> _superPayload(
    String text, {
    required int speed,
    required int volume,
    required int pitch,
  }) =>
      {
        'header': {
          'app_id': _s.xfAppId.trim(),
          'status': 2,
        },
        'parameter': {
          'oral': {'oral_level': 'mid'},
          'tts': {
            'vcn': voice,
            'speed': speed,
            'volume': volume,
            'pitch': pitch,
            'bgs': 0,
            'reg': 0,
            'rdn': 0,
            'rhy': 0,
            'audio': {
              'encoding': 'lame', // MP3，体积小、系统播放器直接认
              'sample_rate': 24000,
              'channels': 1,
              'bit_depth': 16,
              'frame_size': 0,
            },
          },
        },
        'payload': {
          'text': {
            'encoding': 'utf8',
            'compress': 'raw',
            'format': 'plain',
            'status': 2,
            'seq': 0,
            // 10163 的教训：这个字段必须 base64(utf8 字节)，
            // 直接塞明文会报 "field 'text' must be encode to base64 string"
            'text': base64Encode(utf8.encode(text)),
          },
        },
      };

  static int? _intOf(dynamic v) {
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v);
    return null;
  }

  /// 服务端有时候回二进制帧，统一转成字符串再解析
  static String _rawToString(dynamic raw) {
    if (raw is String) return raw;
    if (raw is List<int>) {
      try {
        return utf8.decode(raw);
      } catch (_) {
        return '';
      }
    }
    if (raw is List) {
      try {
        return utf8.decode(raw.cast<int>());
      } catch (_) {
        return '';
      }
    }
    return raw?.toString() ?? '';
  }

  static List<int> _b64(String s) {
    try {
      return base64Decode(s);
    } catch (_) {
      return const <int>[];
    }
  }

  static String _hintFor(int code) {
    switch (code) {
      case 10105:
        return '（该发音人未授权，请在控制台开通对应发音人，或换成已开通的）';
      case 10106:
      case 11200:
        return '（该服务未开通，请到控制台「服务管理」添加对应语音合成服务）';
      case 10165:
        return '（鉴权失败，检查 APIKey / APISecret 是否复制完整）';
      case 10161:
        return '（合成超时）';
      default:
        return '';
    }
  }

  static String _cleanText(String text) {
    var t = text;
    // 去掉 markdown 与多余符号，避免念出 "star star"
    t = t.replaceAll(RegExp(r'[*#`_>\[\]()~|]'), ' ');
    t = t.replaceAll(RegExp(r'\s+'), ' ');
    return t.trim();
  }

  static String _rfc1123(DateTime utc) {
    const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    String two(int n) => n.toString().padLeft(2, '0');
    final wd = weekdays[utc.weekday - 1];
    final mo = months[utc.month - 1];
    return '$wd, ${two(utc.day)} $mo ${utc.year} '
        '${two(utc.hour)}:${two(utc.minute)}:${two(utc.second)} GMT';
  }

  static String _hmacSha256Base64(String data, String key) {
    final hmac = Hmac(sha256, utf8.encode(key));
    return base64Encode(hmac.convert(utf8.encode(data)).bytes);
  }

  /// 兼容旧调用点：现在没有需要释放的共享资源了
  Future<void> dispose() async {}
}

/// TTS 输出的音频格式
enum TtsFormat { pcm16, mp3, wav }

/// 合成结果：字节 + 格式 + 采样率
class TtsAudio {
  TtsAudio({required this.bytes, required this.format, required this.sampleRate});

  final List<int> bytes;
  final TtsFormat format;
  final int sampleRate;

  factory TtsAudio.empty() =>
      TtsAudio(bytes: const <int>[], format: TtsFormat.pcm16, sampleRate: 16000);

  bool get isEmpty => bytes.isEmpty;
  bool get isNotEmpty => bytes.isNotEmpty;

  /// 供 AudioPlayback 用的扩展名和 MIME
  String get fileExt => switch (format) {
        TtsFormat.mp3 => 'mp3',
        TtsFormat.wav => 'wav',
        TtsFormat.pcm16 => 'wav',
      };

  String get mime => switch (format) {
        TtsFormat.mp3 => 'audio/mpeg',
        TtsFormat.wav => 'audio/wav',
        TtsFormat.pcm16 => 'audio/wav',
      };

  /// 转成可直接落盘的 wav 字节（仅 PCM 需要包壳）
  List<int> toWavBytes() {
    if (format == TtsFormat.pcm16) {
      return WavWriter.wrapPcm16Mono(Uint8List.fromList(bytes),
          sampleRate: sampleRate);
    }
    return bytes;
  }

  double get secondsApprox {
    if (format == TtsFormat.pcm16) {
      return bytes.length / (2 * sampleRate);
    }
    // mp3 24kbps 左右的粗略估算
    return bytes.length / 3000;
  }
}

/// 让 TTS 结果能顺手落盘复用
Future<File> writeTtsToCache(TtsAudio audio, {String name = 'tts'}) async {
  final dir = Directory.systemTemp;
  final f = File('${dir.path}/echo_$name.${audio.fileExt}');
  await f.writeAsBytes(audio.toWavBytes(), flush: true);
  return f;
}
