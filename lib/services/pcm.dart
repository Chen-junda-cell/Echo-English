import 'dart:math' as math;
import 'dart:typed_data';

/// WAV 封装：把 16bit/mono PCM 加 44 字节头存成可播放文件
class WavWriter {
  static Uint8List wrapPcm16Mono(Uint8List pcm, {int sampleRate = 16000}) {
    final byteRate = sampleRate * 2;
    final header = Uint8List(44);
    final bd = ByteData.view(header.buffer);

    void ascii(int offset, String s) {
      for (var i = 0; i < s.length; i++) {
        header[offset + i] = s.codeUnitAt(i);
      }
    }

    ascii(0, 'RIFF');
    bd.setUint32(4, 36 + pcm.length, Endian.little);
    ascii(8, 'WAVE');
    ascii(12, 'fmt ');
    bd.setUint32(16, 16, Endian.little); // subchunk1 size
    bd.setUint16(20, 1, Endian.little); // PCM
    bd.setUint16(22, 1, Endian.little); // mono
    bd.setUint32(24, sampleRate, Endian.little);
    bd.setUint32(28, byteRate, Endian.little);
    bd.setUint16(32, 2, Endian.little); // block align
    bd.setUint16(34, 16, Endian.little); // bits per sample
    ascii(36, 'data');
    bd.setUint32(40, pcm.length, Endian.little);

    final out = Uint8List(44 + pcm.length);
    out.setRange(0, 44, header);
    out.setRange(44, 44 + pcm.length, pcm);
    return out;
  }

  /// 从 WAV 里读 duratio
  static int durationMsOfPcm16Mono(int byteLength, {int sampleRate = 16000}) =>
      (byteLength / (sampleRate * 2) * 1000).round();
}

/// 简单的能量 VAD：把 PCM 切成静音分隔的语音段
class Vad {
  Vad({this.frameMs = 30, this.threshold = 0.012, this.minSilenceMs = 350});

  final int frameMs;
  final double threshold;
  final int minSilenceMs;

  /// 返回每段的 [startByte, endByte)
  List<(int, int)> segment(Uint8List pcm16, {int sampleRate = 16000}) {
    final bytesPerFrame = (sampleRate * 2 * frameMs ~/ 1000);
    if (pcm16.isEmpty || bytesPerFrame <= 0) return const [];

    final frames = <(double, int, int)>[];
    for (var off = 0; off + bytesPerFrame <= pcm16.length; off += bytesPerFrame) {
      var sum = 0.0;
      var count = 0;
      for (var i = off; i < off + bytesPerFrame - 1; i += 2) {
        final s = (pcm16[i] | (pcm16[i + 1] << 8)).toSigned(16) / 32768.0;
        sum += s * s;
        count++;
      }
      frames.add((math.sqrt(sum / math.max(count, 1)), off, off + bytesPerFrame));
    }
    if (frames.isEmpty) return [];

    final silenceFrames = (minSilenceMs / frameMs).round();
    final segments = <(int, int)>[];
    int? start;
    var silentRun = 0;

    for (final f in frames) {
      if (f.$1 >= threshold) {
        start ??= f.$2;
        silentRun = 0;
      } else if (start != null) {
        silentRun++;
        if (silentRun >= silenceFrames) {
          segments.add((start, f.$3 - silentRun * bytesPerFrame));
          start = null;
          silentRun = 0;
        }
      }
    }
    if (start != null) segments.add((start, pcm16.length));
    return segments.where((s) => s.$2 - s.$1 > bytesPerFrame * 3).toList();
  }
}
