import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'pcm.dart';

/// 极简 WAV（PCM 16bit 单声道）读取器。
///
/// 播放走应用内 MediaPlayer（见 AudioPlayback），录音/切片的 PCM 则用
/// [WavWriter] 包成标准 wav 后交给同一个播放器。
class WavData {
  WavData({required this.pcm, required this.sampleRate});

  final List<int> pcm;
  final int sampleRate;

  int get durationMs =>
      pcm.length * 1000 ~/ (2 * (sampleRate <= 0 ? 16000 : sampleRate));

  static WavData? tryParse(List<int> bytes) {
    if (bytes.length < 44) return null;
    final riff = String.fromCharCodes(bytes.sublist(0, 4));
    final wave = String.fromCharCodes(bytes.sublist(8, 12));
    if (riff != 'RIFF' || wave != 'WAVE') return null;

    var i = 12;
    var rate = 16000;
    while (i + 8 <= bytes.length) {
      final id = String.fromCharCodes(bytes.sublist(i, i + 4));
      final size = bytes[i + 4] |
          (bytes[i + 5] << 8) |
          (bytes[i + 6] << 16) |
          (bytes[i + 7] << 24);
      final body = i + 8;
      if (id == 'fmt ') {
        if (body + 6 <= bytes.length) {
          final r = bytes[body + 4] | (bytes[body + 5] << 8);
          if (r > 0) rate = r;
        }
      }
      if (id == 'data') {
        final end = (body + size).clamp(body, bytes.length);
        return WavData(pcm: bytes.sublist(body, end), sampleRate: rate);
      }
      i = body + size + (size.isOdd ? 1 : 0);
    }
    return null;
  }
}

/// 一段可直接播放的 PCM
class VoiceClip {
  VoiceClip({required this.pcm, this.sampleRate = 16000});

  final List<int> pcm;
  final int sampleRate;

  int get durationMs => pcm.length * 1000 ~/ (2 * sampleRate);

  List<int> toWavBytes() =>
      WavWriter.wrapPcm16Mono(Uint8List.fromList(pcm), sampleRate: sampleRate);
}

/// 播放音频：Android 走应用内 MediaPlayer（MethodChannel），
/// 其它平台回退到系统默认播放器。
///
/// 历史坑：原来在 Android 上用 `am start -d file:///data/user/0/<pkg>/...`
/// 把音频甩给系统播放器，界面显示“成功”但完全没声音 —— 那是应用私有目录，
/// 别的进程没有读权限，MediaPlayer 打开就失败。现在改成本进程内播放。
class AudioPlayback {
  const AudioPlayback();

  static const MethodChannel _ch = MethodChannel('com.echoenglish.audio/play');

  /// 播 PCM（16bit 单声道），内部包成 wav
  Future<void> playPcm(List<int> pcm, {int sampleRate = 16000}) async {
    final bytes =
        WavWriter.wrapPcm16Mono(Uint8List.fromList(pcm), sampleRate: sampleRate);
    await playWavBytes(bytes);
  }

  Future<void> playWavBytes(List<int> bytes) async {
    await playEncoded(bytes, ext: 'wav', mime: 'audio/wav');
  }

  /// 播 MP3 / 或任何已知扩展名的音频字节（超拟人合成默认返回 mp3）
  Future<void> playEncoded(
    List<int> bytes, {
    String ext = 'mp3',
    String mime = 'audio/mpeg',
  }) async {
    if (bytes.isEmpty) return;
    if (Platform.isAndroid) {
      final ok = await _nativePlay(
        data: Uint8List.fromList(bytes),
        ext: ext,
      );
      if (ok) return;
    }
    await _writeAndPlay(bytes, ext, mime: mime);
  }

  Future<void> _writeAndPlay(List<int> bytes, String ext, {String? mime}) async {
    final dir = await getTemporaryDirectory();
    final f = File(
      p.join(dir.path, 'echo_play_${DateTime.now().microsecondsSinceEpoch}.$ext'),
    );
    await f.writeAsBytes(bytes, flush: true);
    await playFile(f.path, mime: mime);
  }

  /// 播放本地音频文件（不等待播放结束）
  Future<void> playFile(String path, {String? mime}) async {
    if (Platform.isAndroid) {
      if (await _nativePlay(path: path)) return;
      // 原生通道不可用时，最后再试一次 intent（部分设备/播放器能读 content）
      final type = mime ?? _guessMime(path);
      await Process.run('am', [
        'start',
        '-a',
        'android.intent.action.VIEW',
        '-d',
        'file://$path',
        '-t',
        type,
        '-f',
        '0x10000000',
      ]);
      return;
    }
    if (Platform.isWindows) {
      await Process.run('powershell', ['-c', 'Start-Process "$path"']);
      return;
    }
    await Process.run('open', [path]);
  }

  /// 停止当前播放
  Future<void> stop() async {
    if (!Platform.isAndroid) return;
    try {
      await _ch.invokeMethod('stop');
    } catch (_) {
      // 通道不可用时忽略
    }
  }

  Future<bool> _nativePlay({String? path, Uint8List? data, String ext = 'mp3'}) async {
    try {
      final ok = await _ch.invokeMethod<bool>('play', {
        if (path != null) 'path': path,
        if (data != null) 'data': data,
        'ext': ext,
      });
      return ok ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    } catch (_) {
      return false;
    }
  }

  static String _guessMime(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.mp3')) return 'audio/mpeg';
    if (lower.endsWith('.m4a')) return 'audio/mp4';
    if (lower.endsWith('.aac')) return 'audio/aac';
    if (lower.endsWith('.ogg')) return 'audio/ogg';
    if (lower.endsWith('.pcm')) return 'audio/L16';
    return 'audio/wav';
  }
}

/// 把某条语句在原始录音里的时间段切出来，得到一个可播放片段。
/// 转写流水线目前把时间轴压成 0，因此多数情况返回 null，
/// 调用方需要回退到「播整段录音」。
Future<VoiceClip?> sliceUtterance({
  required int startMs,
  required int endMs,
  required String? audioPath,
}) async {
  if (audioPath == null || audioPath.isEmpty) return null;
  if (endMs <= startMs) return null;
  final f = File(audioPath);
  if (!await f.exists()) return null;
  final wav = WavData.tryParse(await f.readAsBytes());
  if (wav == null) return null;

  final bytesPerMs = 2 * wav.sampleRate ~/ 1000;
  final start = (startMs * bytesPerMs).clamp(0, wav.pcm.length);
  final end = (endMs * bytesPerMs).clamp(start, wav.pcm.length);
  if (end - start < bytesPerMs * 60) return null;
  return VoiceClip(pcm: wav.pcm.sublist(start, end), sampleRate: wav.sampleRate);
}

final audioPlaybackProvider =
    Provider<AudioPlayback>((_) => const AudioPlayback());
