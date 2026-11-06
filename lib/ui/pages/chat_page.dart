import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/dao.dart';
import '../../data/models.dart';
import '../providers.dart';
import '../theme.dart';

/// 复习页：
///  - 文字模式：打字聊天（原有逻辑）
///  - 语音模式：
///      · 在线版（默认）：按住说话 → 讯飞 IAT → 大模型 → 讯飞 TTS 朗读
///      · AIUI 全双工：点一下开始交互，本地 VAD 自动断句，边听边答边播报
class ChatPage extends ConsumerStatefulWidget {
  const ChatPage({super.key});

  @override
  ConsumerState<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends ConsumerState<ChatPage> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  bool _sending = false;
  bool _settling = false;

  // 在线语音（按住说话）
  bool _recording = false;
  String _liveText = '';

  // AIUI 全双工
  bool _aiuiOn = false;
  bool _aiuiStarting = false;
  String _aiuiHint = '';
  StreamSubscription<AiuiEvent>? _aiuiSub;
  String _partialIat = '';

  @override
  void dispose() {
    _aiuiSub?.cancel();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  // ---------- 工具 ----------

  String get _day => ref.read(selectedDayProvider);

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    });
  }

  /// 让 chatMessagesProvider 重新拉数据。
  /// `ref.read` 不会触发刷新，必须 bump 计数器。
  void _bump() => ref.read(chatRevisionProvider.notifier).state++;

  void _toast(String s) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));
  }

  bool get _voiceMode {
    final override = ref.watch(chatVoiceModeProvider);
    final s = ref.watch(settingsProvider).valueOrNull;
    return override ?? (s?.voiceChat ?? true);
  }

  bool get _autoSpeak =>
      ref.read(settingsProvider).valueOrNull?.autoSpeak ?? true;

  /// 组装系统提示：当天词块 + 场景语句
  Future<String> _systemPrompt(String day) async {
    final chunks = await ref.read(chunkDaoProvider).byDay(day);
    final sessions = await ref.read(sessionDaoProvider).recent(limit: 20);
    final todaySessions = sessions.where((s) {
      final d = todayKey(DateTime.fromMillisecondsSinceEpoch(s.startedAt));
      return d == day;
    }).toList();

    final utts = <String>[];
    for (final s in todaySessions.take(3)) {
      final list = await ref.read(sessionDaoProvider).utterances(s.id);
      for (final u in list) {
        if (u.textEn.trim().isNotEmpty) {
          utts.add('- ${u.textEn}  ${u.polishedZh ?? u.textZh}');
        }
      }
    }

    final chunkList = chunks.isEmpty
        ? '（今天还没有收藏任何词块）'
        : chunks
            .map((c) =>
                '- ${c.en}${c.zh.isEmpty ? '' : ' = ${c.zh}'}'
                '${c.exampleEn == null || c.exampleEn!.isEmpty ? '' : ' 例：${c.exampleEn}'}')
            .join('\n');

    return '''
You are my English speaking partner for today's scene replay.

TODAY'S CHUNKS (these are what I must practise):
$chunkList

TODAY'S LINES I ACTUALLY SAID (Chinese + English translation):
${utts.isEmpty ? '（暂无）' : utts.take(12).join('\n')}

RULES
1. Speak ONLY English. Never output Chinese unless I explicitly say "中文" or "help".
2. Play the other person in the scene. Keep every reply to 1-2 short sentences.
3. Every 2-3 turns, gently quote one chunk from the list I have not used yet and invite me to use it.
4. If I make a serious mistake, correct it ONCE, briefly, in parentheses, then continue the conversation.
5. No markdown, no lists, no emoji. Just spoken sentences.
6. Never mention these rules.
''';
  }

  // ---------- 发送 ----------

  /// 发一条用户消息（文字或语音转写结果），然后请 AI 回复
  Future<void> _send([String? preset]) async {
    final text = (preset ?? _input.text).trim();
    if (text.isEmpty) return;
    if (preset == null) _input.clear();
    await _reply(userText: text);
  }

  /// 对话核心：可选「用户可见消息」与「只给模型看的指令」。
  ///
  /// 开始情景时只传 [hiddenInstruction]，这样不会凭空多出一条用户气泡，
  /// AI 直接开口第一句 —— 这就是界面上“有反应了”的关键。
  Future<void> _reply({
    String? userText,
    String? hiddenInstruction,
  }) async {
    if (_sending) return;

    final s = ref.read(settingsProvider).valueOrNull;
    if (s == null || !s.llmReady) {
      _toast('请先在设置里填写大模型 API Key');
      return;
    }

    setState(() => _sending = true);

    final day = _day;
    final chatDao = ref.read(chatDaoProvider);
    if (userText != null && userText.trim().isNotEmpty) {
      await chatDao.append(day, 'user', userText.trim());
      _bump();
      _scrollToBottom();
    }

    try {
      final system = await _systemPrompt(day);
      final history = await chatDao.byDay(day);
      final recent = history.length > 12
          ? history.sublist(history.length - 12)
          : history;

      final messages = <Map<String, String>>[
        {'role': 'system', 'content': system},
        for (final m in recent)
          if (m.role == 'user' || m.role == 'assistant')
            {'role': m.role, 'content': m.content},
        if (hiddenInstruction != null)
          {'role': 'user', 'content': hiddenInstruction},
      ];

      final reply = await ref.read(llmClientProvider).chat(
            messages: messages,
            temperature: 0.85,
            maxTokens: 320,
          );
      final clean = reply.trim();
      if (clean.isEmpty) {
        throw Exception('模型返回了空内容，检查模型名 / 余额');
      }
      final saved = await chatDao.append(day, 'assistant', clean);
      _bump();

      if (_autoSpeak) {
        unawaited(_speak(clean, messageId: saved.id));
      }
    } catch (e) {
      await chatDao.append(day, 'system', '发送失败：$e');
      _bump();
      _toast('发送失败：$e');
    } finally {
      if (mounted) setState(() => _sending = false);
      _scrollToBottom();
    }
  }

  // ---------- 朗读（在线 TTS） ----------

  Future<void> _speak(String text, {String? messageId}) async {
    final clean = text.trim();
    if (clean.isEmpty) return;
    final play = ref.read(audioPlaybackProvider);
    try {
      // 上一句还没播完就先掐掉，避免两句话叠在一起
      await play.stop();
      if (messageId != null) {
        ref.read(speakingMessageIdProvider.notifier).state = messageId;
      }
      final tts = ref.read(xunfeiTtsProvider);
      final audio = await tts.synthesize(clean);
      if (audio.isEmpty) return;
      await play.playEncoded(
        audio.toWavBytes(),
        ext: audio.fileExt,
        mime: audio.mime,
      );
    } catch (e) {
      _toast('朗读失败：$e');
    } finally {
      if (messageId != null) {
        ref.read(speakingMessageIdProvider.notifier).state = null;
      }
    }
  }

  // ---------- 在线按住说话 ----------

  Future<void> _startHold() async {
    final s = ref.read(settingsProvider).valueOrNull;
    if (s == null || !s.xfReady) {
      _toast('请先填写讯飞三件套');
      return;
    }
    setState(() {
      _recording = true;
      _liveText = '';
    });
    final rec = ref.read(voiceRecorderProvider);
    try {
      await rec.start();
      rec.liveChunks.listen((_) {
        // 实时波形由 RecorderState 驱动，这里只占位
      });
    } catch (e) {
      setState(() => _recording = false);
      _toast('录音失败：$e');
    }
  }

  Future<void> _stopHold() async {
    if (!_recording) return;
    setState(() => _recording = false);
    final rec = ref.read(voiceRecorderProvider);
    try {
      final res = await rec.stop();
      if (res.silent) {
        _toast('没听清，再来一次');
        return;
      }
      setState(() => _liveText = '识别中…');
      final iat = ref.read(xunfeiProvider);
      final zh = await iat.transcribePcm(res.pcm);
      setState(() => _liveText = '');
      if (zh.trim().isEmpty) {
        _toast('没听清，再来一次');
        return;
      }
      await _send(zh);
    } catch (e) {
      setState(() => _liveText = '');
      _toast('识别失败：$e');
    }
  }

  // ---------- AIUI 全双工 ----------

  Future<void> _toggleAiui() async {
    if (_aiuiOn) {
      await _stopAiui();
      return;
    }
    if (!AiuiClient.isSupported) {
      _toast('AIUI 全双工只在 Android 上可用');
      return;
    }
    setState(() {
      _aiuiStarting = true;
      _aiuiHint = '正在连接…';
    });

    try {
      final client = ref.read(aiuiClientProvider);
      final s = ref.read(settingsProvider).valueOrNull;
      if (s == null) throw StateError('设置未加载');

      _aiuiSub?.cancel();
      _aiuiSub = client.events.listen(_onAiuiEvent);

      await client.init(voice: s.xfTtsVoice);
      await client.startInteraction();

      ref.read(aiuiReadyProvider.notifier).state = true;
      if (mounted) {
        setState(() {
          _aiuiOn = true;
          _aiuiStarting = false;
          _aiuiHint = '正在听…';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _aiuiStarting = false;
          _aiuiOn = false;
          _aiuiHint = '';
        });
      }
      _toast('AIUI 启动失败：$e');
    }
  }

  Future<void> _stopAiui() async {
    final client = ref.read(aiuiClientProvider);
    try {
      await client.stopInteraction();
    } catch (_) {}
    await _aiuiSub?.cancel();
    _aiuiSub = null;
    if (mounted) {
      setState(() {
        _aiuiOn = false;
        _aiuiHint = '';
      });
    }
  }

  void _onAiuiEvent(AiuiEvent ev) {
    if (!mounted) return;
    switch (ev.type) {
      case 'connected':
        setState(() => _aiuiHint = '已连接，请说话');
        break;
      case 'vad_bos':
        setState(() {
          _aiuiHint = '在听…';
          _partialIat = '';
        });
        break;
      case 'vad_eos':
        setState(() => _aiuiHint = '思考中…');
        break;
      case 'iat':
        if (!ev.finalText && ev.text != null) {
          setState(() => _partialIat = ev.text!);
        }
        break;
      case 'nlp':
        if (ev.finalText && (ev.text ?? '').trim().isNotEmpty) {
          setState(() => _partialIat = '');
          // 把 AIUI 听写的中文当作「我说的话」，交给自己的大模型作答
          unawaited(_send(ev.text));
        }
        break;
      case 'error':
        setState(() => _aiuiHint = '出错：${ev.message ?? ev.code}');
        break;
      case 'sleep':
        setState(() => _aiuiHint = '已休眠，点「继续」唤醒');
        break;
      case 'wakeup':
        setState(() => _aiuiHint = '正在听…');
        break;
      default:
        break;
    }
  }

  // ---------- 结算 ----------

  Future<void> _settle() async {
    final s = ref.read(settingsProvider).valueOrNull;
    if (s == null || !s.llmReady) {
      _toast('请先填写大模型 API Key');
      return;
    }
    final day = _day;
    final chunks = await ref.read(chunkDaoProvider).byDay(day);
    if (chunks.isEmpty) {
      _toast('今天还没有词块，先去记录里收藏几个');
      return;
    }
    final msgs = await ref.read(chatDaoProvider).byDay(day);
    if (msgs.isEmpty) {
      _toast('先聊几轮再结算吧');
      return;
    }

    setState(() => _settling = true);
    try {
      final chunkLines = chunks.map((c) => '- ${c.en}').join('\n');
      final dialog = msgs
          .where((m) => m.role == 'user' || m.role == 'assistant')
          .map((m) => '${m.role}: ${m.content}')
          .join('\n');

      final prompt = '''
Here are today's target chunks:
$chunkLines

Here is our conversation:
$dialog

Judge which chunks I actually used correctly (used), which I never used (missed),
and which I used wrongly (wrong). Reply with STRICT JSON only:
{"used": ["..."], "missed": ["..."], "wrong": ["..."], "advice": "..."}
Use the exact English strings from the chunk list. advice must be one short Chinese sentence.
''';

      final raw = await ref.read(llmClientProvider).chat(
        messages: [
          {'role': 'system', 'content': 'You are a strict but kind English coach. Output JSON only.'},
          {'role': 'user', 'content': prompt},
        ],
        temperature: 0.2,
        maxTokens: 600,
      );

      final parsed = _extractJson(raw);
      final used = (parsed['used'] as List?)?.map((e) => '$e').toList() ?? [];
      final missed = (parsed['missed'] as List?)?.map((e) => '$e').toList() ?? [];
      final wrong = (parsed['wrong'] as List?)?.map((e) => '$e').toList() ?? [];
      final advice = (parsed['advice'] as String?) ?? '';

      final dao = ref.read(chunkDaoProvider);
      for (final c in chunks) {
        if (used.contains(c.en)) {
          await dao.grade(c, hit: true);
        } else if (wrong.contains(c.en)) {
          await dao.grade(c, hit: false);
        }
      }
      await ref.read(chatDaoProvider).saveReport(ReviewReport(
            id: '${DateTime.now().millisecondsSinceEpoch}-$day',
            day: day,
            used: used,
            missed: missed,
            wrong: wrong,
            advice: advice,
            createdAt: DateTime.now().millisecondsSinceEpoch,
          ));
      ref.read(chunksRevisionProvider);
      _bump();

      if (mounted) {
        await showDialog<void>(
          context: context,
          builder: (_) => _ReportDialog(
            used: used,
            missed: missed,
            wrong: wrong,
            advice: advice,
          ),
        );
      }
    } catch (e) {
      _toast('结算失败：$e');
    } finally {
      if (mounted) setState(() => _settling = false);
    }
  }

  Map<String, dynamic> _extractJson(String raw) {
    final start = raw.indexOf('{');
    final end = raw.lastIndexOf('}');
    if (start < 0 || end <= start) return <String, dynamic>{};
    try {
      final decoded = jsonDecode(raw.substring(start, end + 1));
      if (decoded is Map<String, dynamic>) return decoded;
    } catch (_) {}
    return <String, dynamic>{};
  }

  Future<void> _startScenario() async {
    if (_sending) return;
    await ref.read(chatDaoProvider).clearDay(_day);
    _bump();
    await ref.read(audioPlaybackProvider).stop();

    final chunks = await ref.read(chunkDaoProvider).byDay(_day);
    final scene = chunks.isEmpty
        ? 'a normal day'
        : (chunks.first.sceneTag ?? 'a normal day');

    // 只作为隐藏指令给模型，不写进数据库 —— 否则聊天里会冒出一条
    // 用户气泡“Let's start the scene…”，看着很怪。
    await _reply(
      hiddenInstruction: '(Start the scene now: $scene. '
          'You are the other person in this scene. '
          'Open with ONE short natural English line to me, then wait for my reply. '
          'Do not describe the scene, do not explain, just speak.)',
    );
    _scrollToBottom();
  }

  // ---------- build ----------

  @override
  Widget build(BuildContext context) {
    final day = ref.watch(selectedDayProvider);
    final msgs = ref.watch(chatMessagesProvider);
    final chunks = ref.watch(dayChunksProvider);
    final settings = ref.watch(settingsProvider).valueOrNull;

    final voice = _voiceMode;
    final chunkCount = chunks.valueOrNull?.length ?? 0;

    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: Column(
          children: [
            _TopBar(
              day: day,
              chunkCount: chunkCount,
              onStart: _startScenario,
              onSettle: _settle,
              busy: _settling,
            ),
            _ModeBar(
              voice: voice,
              aiuiOn: _aiuiOn,
              aiuiStarting: _aiuiStarting,
              aiuiHint: _aiuiHint,
              aiuiAvailable: AiuiClient.isSupported && settings != null,
              onToggleMode: () {
                final cur = ref.read(chatVoiceModeProvider);
                final next = !(cur ?? (settings?.voiceChat ?? true));
                ref.read(chatVoiceModeProvider.notifier).state = next;
                if (!next && _aiuiOn) unawaited(_stopAiui());
              },
              onToggleAiui: _toggleAiui,
            ),
            Expanded(
              child: msgs.when(
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (e, _) => Center(child: Text('加载失败：$e')),
                data: (list) {
                  final visible =
                      list.where((m) => m.role != 'system').toList(growable: false);
                  if (visible.isEmpty) {
                    return _EmptyChat(
                      chunkCount: chunkCount,
                      onStart: _startScenario,
                      voice: voice,
                      sending: _sending,
                    );
                  }
                  return ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                    itemCount: visible.length + (_sending ? 1 : 0),
                    itemBuilder: (_, i) {
                      if (i >= visible.length) return const _TypingBubble();
                      final m = visible[i];
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: _Bubble(
                          message: m,
                          onSpeak: () => _speak(m.content, messageId: m.id),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
            if (_partialIat.isNotEmpty)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(20, 6, 20, 0),
                child: Text(
                  _partialIat,
                  style: TextStyles.small.copyWith(color: AppColors.sub),
                ),
              ),
            _ChatInputBar(
              voice: voice,
              controller: _input,
              enabled: !_sending,
              recording: _recording,
              onlineReady: settings?.xfReady ?? false,
              liveText: _liveText,
              sending: _sending,
              onToggleMode: () {
                final cur = ref.read(chatVoiceModeProvider);
                final next = !(cur ?? (settings?.voiceChat ?? true));
                ref.read(chatVoiceModeProvider.notifier).state = next;
                if (!next && _aiuiOn) unawaited(_stopAiui());
              },
              onSend: () => _send(),
              onStartHold: _startHold,
              onStopHold: _stopHold,
              ),
          ],
        ),
      ),
    );
  }
}

// ---------- 子组件 ----------

class _TopBar extends StatelessWidget {
  final String day;
  final int chunkCount;
  final Future<void> Function() onStart;
  final Future<void> Function() onSettle;
  final bool busy;

  const _TopBar({
    required this.day,
    required this.chunkCount,
    required this.onStart,
    required this.onSettle,
    required this.busy,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('情景复现', style: TextStyles.h2),
                Gap.h4,
                Text(
                  '$day · $chunkCount 个词块',
                  style: TextStyles.small.copyWith(color: AppColors.sub),
                ),
              ],
            ),
          ),
          OutlinedButton(
            onPressed: onStart,
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(0, 36),
              padding: const EdgeInsets.symmetric(horizontal: 12),
            ),
            child: const Text('开始情景'),
          ),
          Gap.w8,
          FilledButton(
            onPressed: busy ? null : onSettle,
            style: FilledButton.styleFrom(
              minimumSize: const Size(0, 36),
              padding: const EdgeInsets.symmetric(horizontal: 12),
            ),
            child: busy
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  )
                : const Text('结算'),
          ),
        ],
      ),
    );
  }
}

class _ModeBar extends StatelessWidget {
  final bool voice;
  final bool aiuiOn;
  final bool aiuiStarting;
  final String aiuiHint;
  final bool aiuiAvailable;
  final VoidCallback onToggleMode;
  final Future<void> Function() onToggleAiui;

  const _ModeBar({
    required this.voice,
    required this.aiuiOn,
    required this.aiuiStarting,
    required this.aiuiHint,
    required this.aiuiAvailable,
    required this.onToggleMode,
    required this.onToggleAiui,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                voice ? Icons.graphic_eq_rounded : Icons.keyboard_alt_outlined,
                size: 18,
                color: AppColors.primary,
              ),
              Gap.w8,
              Text(voice ? '语音模式' : '文字模式', style: TextStyles.body),
              const Spacer(),
              Switch.adaptive(
                value: voice,
                onChanged: (_) => onToggleMode(),
              ),
            ],
          ),
          if (voice && aiuiAvailable) ...[
            const Divider(height: 12, color: AppColors.line),
            Row(
              children: [
                Icon(
                  Icons.bolt_rounded,
                  size: 18,
                  color: aiuiOn ? AppColors.ok : AppColors.sub,
                ),
                Gap.w8,
                Expanded(
                  child: Text(
                    aiuiOn
                        ? (aiuiHint.isEmpty ? '全双工已开启' : '全双工 · $aiuiHint')
                        : '开启 AIUI 全双工（说完自动断句，边答边播）',
                    style: TextStyles.small.copyWith(
                      color: aiuiOn ? AppColors.ok : AppColors.sub,
                    ),
                  ),
                ),
                Gap.w8,
                FlatButton(
                  label: aiuiStarting
                      ? '连接中'
                      : (aiuiOn ? '停止' : '开启'),
                  onTap: aiuiStarting ? null : () => onToggleAiui(),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class FlatButton extends StatelessWidget {
  final String label;
  final VoidCallback? onTap;
  const FlatButton({super.key, required this.label, this.onTap});

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: enabled ? AppColors.primary.withValues(alpha: 0.08) : AppColors.line,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          label,
          style: TextStyles.small.copyWith(
            color: enabled ? AppColors.primary : AppColors.sub,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

class _Bubble extends ConsumerWidget {
  final ChatMessage message;
  final VoidCallback onSpeak;

  const _Bubble({required this.message, required this.onSpeak});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isUser = message.role == 'user';
    final speaking = ref.watch(speakingMessageIdProvider) == message.id;

    return Row(
      mainAxisAlignment: isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        if (!isUser)
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: CircleAvatar(
              radius: 14,
              backgroundColor: AppColors.primary.withValues(alpha: 0.12),
              child: const Icon(Icons.smart_toy_outlined,
                  size: 16, color: AppColors.primary),
            ),
          ),
        Flexible(
          child: Container(
            constraints: const BoxConstraints(maxWidth: 300),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: isUser ? AppColors.primary : AppColors.aiBubble,
              borderRadius: BorderRadius.only(
                topLeft: const Radius.circular(14),
                topRight: const Radius.circular(14),
                bottomLeft: Radius.circular(isUser ? 14 : 4),
                bottomRight: Radius.circular(isUser ? 4 : 14),
              ),
            ),
            child: Column(
              crossAxisAlignment:
                  isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
              children: [
                Text(
                  message.content,
                  style: TextStyles.body.copyWith(
                    color: isUser ? Colors.white : AppColors.ink,
                    height: 1.45,
                  ),
                ),
                if (!isUser) ...[
                  Gap.h6,
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      InkWell(
                        onTap: onSpeak,
                        child: Icon(
                          speaking
                              ? Icons.volume_up_rounded
                              : Icons.volume_up_outlined,
                          size: 16,
                          color: AppColors.primary,
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _TypingBubble extends StatelessWidget {
  const _TypingBubble();

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: AppColors.aiBubble,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: List.generate(3, (i) {
              return Container(
                margin: const EdgeInsets.symmetric(horizontal: 2),
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.35 + i * 0.2),
                  shape: BoxShape.circle,
                ),
              );
            }),
          ),
        ),
      ],
    );
  }
}

class _EmptyChat extends StatelessWidget {
  final int chunkCount;
  final Future<void> Function() onStart;
  final bool voice;
  final bool sending;

  const _EmptyChat({
    required this.chunkCount,
    required this.onStart,
    required this.voice,
    this.sending = false,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.forum_outlined, size: 48, color: AppColors.sub),
            Gap.h16,
            Text(
              chunkCount == 0 ? '今天还没有词块' : '准备好了吗？',
              style: TextStyles.h2,
              textAlign: TextAlign.center,
            ),
            Gap.h8,
            Text(
              chunkCount == 0
                  ? '先去「记录」里录一段对话，把想练的词块收藏起来'
                  : (voice
                      ? '点「开始情景」，AI 会先开口说一句英文，\n然后你按住下面的麦克风回答'
                      : '点「开始情景」开始对话'),
              style: TextStyles.small.copyWith(color: AppColors.sub),
              textAlign: TextAlign.center,
            ),
            if (chunkCount > 0) ...[
              Gap.h24,
              FilledButton(
                onPressed: sending ? null : onStart,
                child: Text(sending ? '正在开始…' : '开始情景'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ChatInputBar extends StatelessWidget {
  final bool voice;
  final TextEditingController controller;
  final bool enabled;
  final bool recording;
  final bool onlineReady;
  final String liveText;
  final bool sending;
  final VoidCallback onToggleMode;
  final VoidCallback onSend;
  final Future<void> Function() onStartHold;
  final Future<void> Function() onStopHold;

  const _ChatInputBar({
    required this.voice,
    required this.controller,
    required this.enabled,
    required this.recording,
    required this.onlineReady,
    required this.liveText,
    required this.sending,
    required this.onToggleMode,
    required this.onSend,
    required this.onStartHold,
    required this.onStopHold,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(6, 8, 8, 10),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: AppColors.line)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (liveText.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 6, left: 12, right: 12),
              child: Text(
                liveText,
                style: TextStyles.small.copyWith(color: AppColors.sub),
              ),
            ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              IconButton(
                tooltip: voice ? '切换到键盘' : '切换到语音',
                onPressed: onToggleMode,
                icon: Icon(
                  voice ? Icons.keyboard_alt_outlined : Icons.mic_none_rounded,
                  color: AppColors.ink,
                ),
              ),
              Expanded(
                child: voice
                    ? GestureDetector(
                        onLongPressStart: (_) => onStartHold(),
                        onLongPressEnd: (_) => onStopHold(),
                        child: Container(
                          height: 48,
                          decoration: BoxDecoration(
                            color: recording
                                ? AppColors.danger
                                : (onlineReady ? AppColors.bg : AppColors.line),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(color: AppColors.line),
                          ),
                          alignment: Alignment.center,
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                recording
                                    ? Icons.mic_rounded
                                    : Icons.mic_none_rounded,
                                size: 20,
                                color: recording
                                    ? Colors.white
                                    : (onlineReady ? AppColors.ink : AppColors.sub),
                              ),
                              Gap.w8,
                              Text(
                                recording
                                    ? '松手发送'
                                    : (onlineReady
                                        ? '按住 说话'
                                        : '请先在设置里配置讯飞三件套'),
                                style: TextStyles.body.copyWith(
                                  color: recording
                                      ? Colors.white
                                      : (onlineReady
                                          ? AppColors.ink
                                          : AppColors.sub),
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                      )
                    : Container(
                        constraints: const BoxConstraints(maxHeight: 120),
                        decoration: BoxDecoration(
                          color: AppColors.bg,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: AppColors.line),
                        ),
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: TextField(
                          controller: controller,
                          enabled: enabled,
                          minLines: 1,
                          maxLines: 5,
                          textInputAction: TextInputAction.send,
                          onSubmitted: (_) => onSend(),
                          decoration: const InputDecoration(
                            hintText: '说点什么…',
                            border: InputBorder.none,
                            isDense: true,
                            contentPadding: EdgeInsets.symmetric(vertical: 12),
                          ),
                        ),
                      ),
              ),
              Gap.w8,
              if (!voice)
                Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: SizedBox(
                    width: 44,
                    height: 44,
                    child: FilledButton(
                      onPressed: enabled ? onSend : null,
                      style: FilledButton.styleFrom(
                        padding: EdgeInsets.zero,
                        shape: const CircleBorder(),
                      ),
                      child: sending
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.arrow_upward_rounded, size: 20),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
class _ReportDialog extends StatelessWidget {
  final List<String> used;
  final List<String> missed;
  final List<String> wrong;
  final String advice;

  const _ReportDialog({
    required this.used,
    required this.missed,
    required this.wrong,
    required this.advice,
  });

  @override
  Widget build(BuildContext context) {
    Widget section(String title, List<String> items, Color color) {
      if (items.isEmpty) return const SizedBox.shrink();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: TextStyles.small.copyWith(color: color, fontWeight: FontWeight.w700)),
          Gap.h6,
          ...items.map((e) => Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text('· $e', style: TextStyles.body),
              )),
          Gap.h12,
        ],
      );
    }

    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: const Text('今日结算'),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            section('用上了', used, AppColors.ok),
            section('没用上', missed, AppColors.warn),
            section('用错了', wrong, AppColors.danger),
            if (advice.isNotEmpty) ...[
              const Divider(color: AppColors.line),
              Gap.h8,
              Text(advice, style: TextStyles.body),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('好'),
        ),
      ],
    );
  }
}