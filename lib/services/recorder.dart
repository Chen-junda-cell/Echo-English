import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:uuid/uuid.dart';

import 'pcm.dart';

const _uuid = Uuid();

class RecorderState {
  RecorderState({
    this.recording = false,
    this.elapsed = Duration.zero,
    this.amplitude = 0,
    this.wavPath,
    this.paused = false,
  });

  final bool recording;
  final Duration elapsed;
  final double amplitude; // 0..1
  final String? wavPath;
  final bool paused;

  RecorderState copyWith({
    bool? recording,
    Duration? elapsed,
    double? amplitude,
    String? wavPath,
    bool? paused,
  }) =>
      RecorderState(
        recording: recording ?? this.recording,
        elapsed: elapsed ?? this.elapsed,
        amplitude: amplitude ?? this.amplitude,
        wavPath: wavPath ?? this.wavPath,
        paused: paused ?? this.paused,
      );
}

class RecordingResult {
  RecordingResult({
    required this.pcm,
    required this.wavPath,
    required this.durationMs,
    required this.silent,
  });

  final Uint8List pcm;
  final String wavPath;
  final int durationMs;
  final bool silent;
}

/// 录音器：录 16k/16bit/单声道 PCM（讯飞直吃），同时落盘 .pcm 与 .wav
class VoiceRecorder {
  final AudioRecorder _rec = AudioRecorder();
  final _pcm = BytesBuilder(copy: false);
  final _liveCtrl = StreamController<Uint8List>.broadcast();

  RecorderState _state = RecorderState();
  final _stateCtrl = StreamController<RecorderState>.broadcast();

  Timer? _ticker;
  DateTime? _startedAt;
  String? _pcmPath;
  String? _wavPath;
  IOSink? _pcmSink;
  StreamSubscription<Uint8List>? _sub;
  Future<Stream<Uint8List>>? _live;

  Stream<RecorderState> get stateStream => _stateCtrl.stream;
  RecorderState get state => _state;
  Stream<Uint8List> get liveChunks => _liveCtrl.stream;

  static Future<Directory> _dir() async {
    final d = Directory(p.join((await getApplicationDocumentsDirectory()).path, 'recordings'));
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  Future<void> start() async {
    if (_state.recording) return;
    if (!await _rec.hasPermission()) {
      throw Exception('没有麦克风权限，请到「系统设置 → 应用 → Echo English → 权限」里开启');
    }

    final dir = await _dir();
    final id = _uuid.v4();
    _pcmPath = p.join(dir.path, '$id.pcm');
    _wavPath = p.join(dir.path, '$id.wav');
    _pcm.clear();

    _pcmSink = File(_pcmPath!).openWrite();
    _sub?.cancel();
    _live = _rec.startStream(const RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      sampleRate: 16000,
      numChannels: 1,
      autoGain: true,
      echoCancel: true,
      noiseSuppress: true,
    ));
    _sub = (await _live!).listen(_onPcm);

    _startedAt = DateTime.now();
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(milliseconds: 200), (_) {
      final d = DateTime.now().difference(_startedAt!);
      _emit(_state.copyWith(recording: true, elapsed: d));
    });

    _emit(RecorderState(recording: true, wavPath: _wavPath));
  }

  void _onPcm(Uint8List chunk) {
    _pcm.add(chunk);
    _pcmSink?.add(chunk);
    if (!_liveCtrl.isClosed) _liveCtrl.add(chunk);
    var peak = 0;
    for (var i = 0; i + 1 < chunk.length; i += 2) {
      final v = (chunk[i] | (chunk[i + 1] << 8)).toSigned(16).abs();
      if (v > peak) peak = v;
    }
    _emit(_state.copyWith(recording: true, amplitude: (peak / 32768.0).clamp(0.0, 1.0)));
  }

  Future<RecordingResult> stop() async {
    _ticker?.cancel();
    _ticker = null;
    await _rec.stop();
    await _sub?.cancel();
    _sub = null;
    await _pcmSink?.flush();
    await _pcmSink?.close();
    _pcmSink = null;

    final pcm = _pcm.takeBytes();
    final wav = WavWriter.wrapPcm16Mono(pcm);
    var wavPath = _wavPath ?? '';
    if (wavPath.isNotEmpty) {
      await File(wavPath).writeAsBytes(wav, flush: true);
    }
    final durationMs =
        _startedAt == null ? 0 : DateTime.now().difference(_startedAt!).inMilliseconds;
    _startedAt = null;

    _emit(RecorderState(wavPath: wavPath));
    return RecordingResult(
      pcm: pcm,
      wavPath: wavPath,
      durationMs: durationMs,
      silent: pcm.length < 16000 * 2 * 0.4, // 少于 0.4 秒视为空录
    );
  }

  Future<void> cancel() async {
    _ticker?.cancel();
    _ticker = null;
    if (await _rec.isRecording()) await _rec.stop();
    await _sub?.cancel();
    _sub = null;
    await _pcmSink?.close();
    _pcmSink = null;
    _pcm.clear();
    _emit(RecorderState());
  }

  void _emit(RecorderState s) {
    _state = s;
    if (!_stateCtrl.isClosed) _stateCtrl.add(s);
  }

  Future<void> dispose() async {
    _ticker?.cancel();
    await _sub?.cancel();
    await _rec.dispose();
    await _stateCtrl.close();
    await _liveCtrl.close();
  }
}
