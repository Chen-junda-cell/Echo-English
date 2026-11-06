import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../data/settings.dart';

/// 讯飞开放平台 —— 语音听写（流式版）IAT
/// 文档：https://www.xfyun.cn/doc/asr/voicedictation/API.html
///
/// 鉴权：wss 的 URL 需要服务端级签名（HMAC-SHA256），在客户端做完全可行，
/// 公式见 [buildAuthUrl]。APPID/APIKey/APISecret 由用户自己在设置页填写。
class XunfeiIatClient {
  XunfeiIatClient(this.settings);

  final AppSettings settings;

  static const _host = 'iat-api.xfyun.cn';
  static const _path = '/v2/iat';

  /// 每帧发送 40ms 的 16k/16bit 单声道 PCM，即 1280 字节
  static const int frameBytes = 1280;
  static const int sampleRate = 16000;

  WebSocketChannel? _channel;
  final _results = StreamController<String>.broadcast();
  Completer<String>? _done;
  final _buffer = BytesBuilder(copy: false);

  String _acc = '';
  int _frameStatus = 0; // 0=首帧 1=中间帧 2=末帧

  Stream<String> get partial => _results.stream;

  String buildAuthUrl() {
    final date = _rfc1123(DateTime.now().toUtc());
    final origin = 'host: $_host\ndate: $date\nGET $_path HTTP/1.1';
    final signatureOrigin = _hmacSha256Base64(origin, settings.xfApiSecret.trim());
    final authorizationOrigin =
        'api_key="${settings.xfApiKey.trim()}", algorithm="hmac-sha256", headers="host date request-line", signature="$signatureOrigin"';
    final authorization = base64Encode(utf8.encode(authorizationOrigin));
    final q = 'authorization=$authorization&date=${Uri.encodeComponent(date)}&host=$_host';
    return 'wss://$_host$_path?$q';
  }

  Future<String> transcribePcmStream(Stream<Uint8List> pcmStream) async {
    if (!settings.xfReady) {
      throw Exception('尚未填写讯飞 APPID / APIKey / APISecret，请先到「设置」页填写');
    }
    _acc = '';
    _frameStatus = 0;
    _done = Completer<String>();

    final channel = WebSocketChannel.connect(Uri.parse(buildAuthUrl()));
    _channel = channel;

    // 把握手等出来：三件套不对时会立刻报鉴权失败，而不是静默等半天
    try {
      await channel.ready.timeout(const Duration(seconds: 10));
    } on TimeoutException {
      _close();
      throw Exception('连接讯飞听写超时，请检查网络后重试');
    } catch (e) {
      _close();
      throw Exception('讯飞听写鉴权被拒绝：$e${_authHint()}');
    }

    channel.stream.listen(
      _onMessage,
      onError: (e) {
        if (!(_done?.isCompleted ?? true)) {
          _done!.completeError(Exception('讯飞连接错误：$e'));
        }
      },
      onDone: () {
        if (!(_done?.isCompleted ?? true)) _done!.complete(_acc);
      },
      cancelOnError: true,
    );

    unawaited(_pump(pcmStream));
    return _done!.future;
  }

  /// 鉴权自查提示（和 TTS 保持一致的说法）
  String _authHint() {
    final secret = settings.xfApiSecret.trim();
    if (secret.length % 4 != 0) {
      return '（APISecret 现在 ${secret.length} 位，Base64 密码应为 32 位，请回控制台整行重新复制）';
    }
    return '（三件套里 APISecret 与 APIKey 不匹配，请整行重新复制三件套）';
  }

  /// 便捷方法：一次性送整段 PCM
  Future<String> transcribePcm(Uint8List pcm) =>
      transcribePcmStream(Stream.value(pcm));

  Future<void> _pump(Stream<Uint8List> pcmStream) async {
    try {
      await for (final buf in pcmStream) {
        _buffer.add(buf);
        while (_buffer.length >= frameBytes) {
          final all = _buffer.takeBytes();
          await _sendChunk(Uint8List.sublistView(all, 0, frameBytes));
          if (all.length > frameBytes) _buffer.add(Uint8List.sublistView(all, frameBytes));
        }
      }
      // 把剩余不足一帧的数据补静音后发出
      var rest = _buffer.takeBytes();
      if (rest.isNotEmpty) {
        if (rest.length < frameBytes) {
          rest = Uint8List.fromList([...rest, ...List.filled(frameBytes - rest.length, 0)]);
        }
        await _sendChunk(rest);
      }
      await _sendChunk(Uint8List(0)); // 末帧
    } catch (e) {
      if (!(_done?.isCompleted ?? true)) {
        _done!.completeError(Exception('发送音频失败：$e'));
      }
    }
  }

  Future<void> _sendChunk(Uint8List data) async {
    final ch = _channel;
    if (ch == null) throw Exception('连接已关闭');

    final first = _frameStatus == 0;
    final last = data.isEmpty;
    final status = last ? 2 : (first ? 0 : 1);

    final business = first
        ? {
            'language': 'zh_cn',
            'domain': 'iat',
            'accent': 'mandarin',
            'vad_eos': 3000,
            'dwa': 'wpgs', // 开启动态修正，长语音必须开
            'ptt': 1,
          }
        : null;

    final payload = <String, dynamic>{
      'data': {
        'status': status,
        'format': 'audio/L16;rate=16000',
        'encoding': 'raw',
        'audio': last ? '' : base64Encode(data),
      },
    };
    if (business != null) {
      payload['common'] = {'app_id': settings.xfAppId.trim()};
      payload['business'] = business;
    }

    ch.sink.add(jsonEncode(payload));
    _frameStatus = last ? 2 : 1;

    // 40ms 一帧，稍微留余量避免被服务端判为超时
    if (!last) await Future.delayed(const Duration(milliseconds: 40));
  }

  void _onMessage(dynamic raw) {
    final msg = jsonDecode(raw as String) as Map<String, dynamic>;
    final code = msg['code'] as int? ?? -1;
    if (code != 0) {
      if (!(_done?.isCompleted ?? true)) {
        _done!.completeError(
            Exception('讯飞返回错误 $code：${msg['message']}'));
      }
      _close();
      return;
    }

    final data = msg['data'];
    if (data is Map) {
      final result = data['result'];
      if (result is Map) {
        final sn = result['sn'] as int? ?? 1;
        final pgs = result['pgs'] as String?;
        final rg = result['rg'];
        final text = _concatWs((result['ws'] as List?) ?? const []);

        if (pgs == 'rpl' && rg is List && rg.length == 2) {
          // 动态修正：替换 [rg0, rg1] 区间
          final start = (rg[0] as num).toInt() - 1;
          final parts = _acc.split('');
          final head = start >= 0 && start <= parts.length ? parts.sublist(0, start).join() : _acc;
          _acc = head + text;
        } else if (sn == 1) {
          _acc = text;
        } else {
          _acc += text;
        }
        _results.add(_acc);
      }
      if ((data['status'] as int?) == 2) {
        if (!(_done?.isCompleted ?? true)) _done!.complete(_acc);
        _close();
      }
    }
  }

  String _concatWs(List wsList) {
    final sb = StringBuffer();
    for (final w in wsList) {
      final cw = (w as Map)['cw'];
      if (cw is List) {
        for (final c in cw) {
          sb.write((c as Map)['w'] ?? '');
        }
      }
    }
    return sb.toString();
  }

  void _close() {
    try {
      _channel?.sink.close();
    } catch (_) {}
    _channel = null;
  }

  Future<void> dispose() async {
    _close();
    await _results.close();
  }

  /// RFC1123 格式：Fri, 06 Nov 2026 05:09:43 GMT
  static String _rfc1123(DateTime utc) {
    const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    String two(int n) => n.toString().padLeft(2, '0');
    // DateTime.weekday: 1=Mon..7=Sun
    final wd = weekdays[utc.weekday - 1];
    final mo = months[utc.month - 1];
    return '$wd, ${two(utc.day)} $mo ${utc.year} '
        '${two(utc.hour)}:${two(utc.minute)}:${two(utc.second)} GMT';
  }

  static String _hmacSha256Base64(String data, String key) {
    final hmac = Hmac(sha256, utf8.encode(key));
    return base64Encode(hmac.convert(utf8.encode(data)).bytes);
  }
}

/// 把录音文件转成 16k/16bit/单声道 PCM
/// record 插件可以直接录 pcm16bits，因此主流程不依赖转码；
/// 此处保留一个安全兜底：若拿到的是 wav，剥掉 44 字节头（或搜索 data 块）。
class WavHelper {
  static Uint8List stripWavHeaderIfPresent(Uint8List bytes) {
    if (bytes.length < 12) return bytes;
    final riff = String.fromCharCodes(bytes.sublist(0, 4));
    final wave = String.fromCharCodes(bytes.sublist(8, 12));
    if (riff != 'RIFF' || wave != 'WAVE') return bytes;

    // 找到 data chunk
    var i = 12;
    while (i + 8 <= bytes.length) {
      final id = String.fromCharCodes(bytes.sublist(i, i + 4));
      final size = bytes[i + 4] | (bytes[i + 5] << 8) | (bytes[i + 6] << 16) | (bytes[i + 7] << 24);
      final body = i + 8;
      if (id == 'data') {
        final end = (body + size).clamp(0, bytes.length);
        return Uint8List.sublistView(bytes, body, end);
      }
      i = body + size + (size.isOdd ? 1 : 0);
    }
    return bytes;
  }
}
