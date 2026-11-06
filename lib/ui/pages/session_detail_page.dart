import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/dao.dart';
import '../../data/models.dart';
import '../../services/audio_io.dart';
import '../../services/llm.dart';
import '../../ui/providers.dart';
import '../../ui/theme.dart';
import 'library_page.dart';

class SessionDetailPage extends ConsumerStatefulWidget {
  const SessionDetailPage({
    super.key,
    required this.sessionId,
    this.autoCandidates,
  });

  final String sessionId;
  final List<ChunkCandidate>? autoCandidates;

  @override
  ConsumerState<SessionDetailPage> createState() => _SessionDetailPageState();
}

class _SessionDetailPageState extends ConsumerState<SessionDetailPage> {
  /// 已收进词块本的英文，用来把按钮置灰
  final _added = <String>{};
  Session? _session;
  bool _playing = false;

  @override
  void initState() {
    super.initState();
    _loadSession();
  }

  Future<void> _loadSession() async {
    final s = await ref.read(sessionDaoProvider).byId(widget.sessionId);
    if (!mounted) return;
    setState(() => _session = s);
  }

  @override
  Widget build(BuildContext context) {
    final detail = ref.watch(sessionDetailProvider(widget.sessionId));
    final s = _session;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          s?.displayName ?? '录音详情',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          if (s != null) ...[
            IconButton(
              tooltip: '重命名',
              onPressed: () => _rename(s),
              icon: const Icon(Icons.drive_file_rename_outline_rounded),
            ),
            IconButton(
              tooltip: '删除这条语音',
              onPressed: () => _delete(s),
              icon: const Icon(Icons.delete_outline_rounded),
            ),
          ],
        ],
      ),
      body: detail.when(
        data: (utterances) {
          final day = _dayOf(_session);
          final candidates = widget.autoCandidates ?? const <ChunkCandidate>[];
          return RefreshIndicator(
            onRefresh: () async {
              await _loadSession();
              ref.invalidate(sessionDetailProvider(widget.sessionId));
            },
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
              children: [
                _SessionMeta(
                  session: _session,
                  count: utterances.length,
                  day: day,
                  playing: _playing,
                  onPlay: _playWhole,
                ),
                if (candidates.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  const SectionHeader(title: 'AI 建议收藏的词块'),
                  _CandidatePanel(
                    candidates: candidates,
                    day: day,
                    added: _added,
                    onAdd: _addChunk,
                  ),
                ],
                const SizedBox(height: 24),
                const SectionHeader(title: '逐句对照'),
                if (utterances.isEmpty)
                  const EmptyState(
                    icon: Icons.subtitles_off_rounded,
                    title: '还没有转写结果',
                    subtitle: '录音完成后会自动转写并翻译，稍等片刻再看看。',
                  )
                else
                  ...utterances.map(
                    (u) => _UtteranceCard(
                      utterance: u,
                      onPlay: () => _playUtterance(u),
                      onSpeak: () => _speak(u.textEn),
                    ),
                  ),
              ],
            ),
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => EmptyState(
          icon: Icons.error_outline_rounded,
          title: '加载失败',
          subtitle: '$e',
        ),
      ),
    );
  }

  String _dayOf(Session? s) {
    if (s == null) return todayKey();
    return todayKey(DateTime.fromMillisecondsSinceEpoch(s.startedAt));
  }

  Future<void> _rename(Session s) async {
    final name = await showRenameDialog(context, s);
    if (name == null) return;
    await ref.read(sessionDaoProvider).rename(s.id, name);
    ref.read(sessionsRevisionProvider.notifier).state++;
    await _loadSession();
  }

  Future<void> _delete(Session s) async {
    final ok = await showDeleteConfirm(context, s);
    if (ok != true) return;
    await ref.read(sessionDaoProvider).deleteWithAudio(s.id);
    ref.read(sessionsRevisionProvider.notifier).state++;
    ref.read(chunksRevisionProvider.notifier).state++;
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  void _toast(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(m), duration: const Duration(milliseconds: 1600)),
    );
  }

  /// 播整段录音
  Future<void> _playWhole() async {
    final audio = _session?.audioPath;
    if (audio == null || audio.isEmpty) {
      _toast('这条记录没有保存音频文件');
      return;
    }
    if (!await File(audio).exists()) {
      _toast('音频文件已不存在');
      return;
    }
    setState(() => _playing = true);
    try {
      await ref.read(audioPlaybackProvider).playFile(audio);
    } catch (e) {
      _toast('播放失败：$e');
    } finally {
      if (mounted) setState(() => _playing = false);
    }
  }

  /// 播某一句话对应的原始录音片段；拿不到时间轴时退化为整段播放
  Future<void> _playUtterance(Utterance u) async {
    final audio = _session?.audioPath;
    final clip = await sliceUtterance(
      startMs: u.startMs,
      endMs: u.endMs,
      audioPath: audio,
    );
    if (clip != null) {
      await ref.read(audioPlaybackProvider).playPcm(clip.pcm, sampleRate: clip.sampleRate);
      return;
    }
    if (audio != null && audio.isNotEmpty && await File(audio).exists()) {
      await ref.read(audioPlaybackProvider).playFile(audio);
      return;
    }
    _toast('这句没有可定位的录音片段');
  }

  /// 用讯飞 TTS 把这句英文读出来
  Future<void> _speak(String text) async {
    final clean = text.trim();
    if (clean.isEmpty) {
      _toast('这句还没有英文');
      return;
    }
    final settings = ref.read(settingsProvider).valueOrNull;
    if (settings == null || !settings.xfReady) {
      _toast('请先在「设置」里填写讯飞三件套');
      return;
    }
    try {
      final audio = await ref.read(xunfeiTtsProvider).synthesize(clean);
      if (audio.isEmpty) {
        _toast('合成结果为空，请检查发音人是否已开通');
        return;
      }
      await ref.read(audioPlaybackProvider).playEncoded(
            audio.toWavBytes(),
            ext: audio.fileExt,
            mime: audio.mime,
          );
    } catch (e) {
      _toast('朗读失败：$e');
    }
  }

  Future<void> _addChunk(String en, String zh, String? example, String day) async {
    if (_added.contains(en)) return;
    await ref.read(chunkDaoProvider).add(
          en: en,
          zh: zh,
          exampleEn: example,
          sourceSessionId: widget.sessionId,
          day: day,
        );
    ref.read(chunksRevisionProvider.notifier).state++;
    if (!mounted) return;
    setState(() => _added.add(en));
    _toast('已加入 $day 的词块本：$en');
  }
}

class _SessionMeta extends StatelessWidget {
  const _SessionMeta({
    required this.session,
    required this.count,
    required this.day,
    required this.playing,
    required this.onPlay,
  });

  final Session? session;
  final int count;
  final String day;
  final bool playing;
  final VoidCallback onPlay;

  @override
  Widget build(BuildContext context) {
    final s = session;
    var when = day;
    if (s != null) {
      final d = DateTime.fromMillisecondsSinceEpoch(s.startedAt);
      when =
          '$day ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
    }
    final secs = s == null ? 0 : (s.durationMs / 1000).round();
    final audio = s?.audioPath;
    final hasAudio = audio != null && audio.isNotEmpty && File(audio).existsSync();

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.line),
      ),
      child: Row(
        children: [
          const Icon(Icons.graphic_eq_rounded, color: AppColors.primary, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '$when · 时长 $secs 秒 · $count 句',
              style: TextStyles.small.copyWith(fontSize: 13, color: AppColors.ink),
            ),
          ),
          if (hasAudio)
            IconButton(
              tooltip: '播放整段录音',
              visualDensity: VisualDensity.compact,
              onPressed: playing ? null : onPlay,
              icon: Icon(
                playing ? Icons.hourglass_top_rounded : Icons.play_circle_fill_rounded,
                color: AppColors.primary,
              ),
            )
          else
            const Padding(
              padding: EdgeInsets.only(right: 8),
              child: Text('无音频', style: TextStyle(fontSize: 12, color: AppColors.sub)),
            ),
        ],
      ),
    );
  }
}

class _CandidatePanel extends StatelessWidget {
  const _CandidatePanel({
    required this.candidates,
    required this.day,
    required this.added,
    required this.onAdd,
  });

  final List<ChunkCandidate> candidates;
  final String day;
  final Set<String> added;
  final Future<void> Function(String en, String zh, String? example, String day) onAdd;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      decoration: BoxDecoration(
        color: AppColors.aiBubble,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFD5E3FF)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('点一下就收进词块本', style: TextStyle(fontSize: 12.5, color: AppColors.sub)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: candidates.map((c) {
              final done = added.contains(c.en);
              return ActionChip(
                avatar: Icon(
                  done ? Icons.check_rounded : Icons.add_rounded,
                  size: 16,
                  color: done ? AppColors.ok : AppColors.primary,
                ),
                label: Text(c.en, style: const TextStyle(fontSize: 13)),
                backgroundColor: done ? const Color(0xFFEFFAF3) : Colors.white,
                side: BorderSide(color: done ? const Color(0xFFCBEFD8) : AppColors.line),
                onPressed: done ? null : () => onAdd(c.en, c.zh, c.example, day),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }
}

class _UtteranceCard extends StatelessWidget {
  const _UtteranceCard({
    required this.utterance,
    required this.onPlay,
    required this.onSpeak,
  });

  final Utterance utterance;
  final VoidCallback onPlay;
  final VoidCallback onSpeak;

  @override
  Widget build(BuildContext context) {
    final zh = (utterance.polishedZh ?? '').trim().isNotEmpty
        ? utterance.polishedZh!.trim()
        : utterance.textZh.trim();
    final en = utterance.textEn.trim();

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.line),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (zh.isNotEmpty) ...[
                  Text(zh, style: TextStyles.small.copyWith(fontSize: 13)),
                  const SizedBox(height: 4)
                ],
                Text(
                  en.isEmpty ? '（未翻译）' : en,
                  style: TextStyles.body.copyWith(fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: '播放原声',
            icon: const Icon(Icons.play_circle_outline_rounded, color: AppColors.primary),
            onPressed: onPlay,
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: '朗读英文',
            icon: const Icon(Icons.volume_up_outlined, color: AppColors.sub),
            onPressed: en.isEmpty ? null : onSpeak,
          ),
        ],
      ),
    );
  }
}
