import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/dao.dart';
import '../data/models.dart';
import '../data/settings.dart';
import '../services/llm.dart';
import '../services/recorder.dart';
import '../services/xunfei_iat.dart';
import '../services/xunfei_tts.dart';

export '../services/aiui.dart' show aiuiClientProvider, aiuiReadyProvider, AiuiClient, AiuiEvent;
export '../services/audio_io.dart' show audioPlaybackProvider, AudioPlayback, VoiceClip;

// ---------- 基础依赖 ----------

final sessionDaoProvider = Provider((_) => SessionDao());
final chunkDaoProvider = Provider((_) => ChunkDao());
final chatDaoProvider = Provider((_) => ChatDao());

final settingsProvider = FutureProvider<AppSettings>((ref) async {
  return AppSettings.load();
});

/// 设置变更后 bump 一下即可刷新下载依赖
final settingsRevisionProvider = StateProvider<int>((_) => 0);

final llmClientProvider = Provider<LlmClient>((ref) {
  final s = ref.watch(settingsProvider).valueOrNull ?? AppSettings.defaults();
  return LlmClient(s);
});

final translatePipelineProvider = Provider<TranslatePipeline>((ref) {
  return TranslatePipeline(ref.watch(llmClientProvider));
});

final xunfeiProvider = Provider<XunfeiIatClient>((ref) {
  final s = ref.watch(settingsProvider).valueOrNull ?? AppSettings.defaults();
  return XunfeiIatClient(s);
});

/// 讯飞语音合成（让 AI 把英文说给我听）
final xunfeiTtsProvider = Provider<XunfeiTtsClient>((ref) {
  final s = ref.watch(settingsProvider).valueOrNull ?? AppSettings.defaults();
  return XunfeiTtsClient(s);
});

final voiceRecorderProvider = Provider<VoiceRecorder>((ref) {
  final r = VoiceRecorder();
  ref.onDispose(r.dispose);
  return r;
});

// ---------- 数据流 ----------

final sessionsProvider = FutureProvider<List<Session>>((ref) async {
  ref.watch(sessionsRevisionProvider);
  return ref.watch(sessionDaoProvider).recent();
});

final sessionsRevisionProvider = StateProvider<int>((_) => 0);

final sessionDetailProvider =
    FutureProvider.family<List<Utterance>, String>((ref, sessionId) async {
  ref.watch(sessionDetailRevisionProvider);
  return ref.watch(sessionDaoProvider).utterances(sessionId);
});

final sessionDetailRevisionProvider = StateProvider<int>((_) => 0);

/// 选中日期（yyyy-MM-dd）
final selectedDayProvider = StateProvider<String>((_) => todayKey());

final dayChunksProvider = FutureProvider<List<Chunk>>((ref) async {
  ref.watch(chunksRevisionProvider);
  final day = ref.watch(selectedDayProvider);
  return ref.watch(chunkDaoProvider).byDay(day);
});

final chunksRevisionProvider = StateProvider<int>((_) => 0);

final allDaysProvider = FutureProvider<List<String>>((ref) async {
  ref.watch(chunksRevisionProvider);
  return ref.watch(chunkDaoProvider).days();
});

final dueChunksProvider = FutureProvider<List<Chunk>>((ref) async {
  ref.watch(chunksRevisionProvider);
  return ref.watch(chunkDaoProvider).dueNow();
});

final chatMessagesProvider = FutureProvider<List<ChatMessage>>((ref) async {
  ref.watch(chatRevisionProvider);
  final day = ref.watch(selectedDayProvider);
  return ref.watch(chatDaoProvider).byDay(day);
});

final chatRevisionProvider = StateProvider<int>((_) => 0);

/// 复习页的语音/文字模式开关（默认跟着设置走）
final chatVoiceModeProvider = StateProvider<bool?>((_) => null);

/// 当前正在朗读的消息 id，用于气泡上的动画
final speakingMessageIdProvider = StateProvider<String?>((_) => null);
