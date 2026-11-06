import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models.dart';
import '../../services/recorder.dart';
import '../../ui/providers.dart';
import '../../ui/theme.dart';
import 'library_page.dart';
import 'session_detail_page.dart';
import 'settings_page.dart';

class RecordPage extends ConsumerStatefulWidget {
  const RecordPage({super.key});

  @override
  ConsumerState<RecordPage> createState() => _RecordPageState();
}

class _RecordPageState extends ConsumerState<RecordPage> {
  late final VoiceRecorder _rec;
  StreamSubscription<RecorderState>? _sub;
  RecorderState _st = RecorderState();

  /// 边录边传：实时转写
  String _liveText = '';
  bool _liveMode = false;
  bool _busy = false;
  String? _busyLabel;

  @override
  void initState() {
    super.initState();
    _rec = ref.read(voiceRecorderProvider);
    _sub = _rec.stateStream.listen((s) {
      if (mounted) setState(() => _st = s);
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _start() async {
    final s = ref.read(settingsProvider).valueOrNull;
    if (s == null || !s.xfReady) {
      _toast('请先在「设置」里填写讯飞 APPID / APIKey / APISecret');
      return;
    }
    try {
      await _rec.start();
      setState(() {
        _liveText = '';
        _liveMode = false;
      });
    } catch (e) {
      _toast('$e');
    }
  }

  Future<void> _stopAndProcess() async {
    setState(() => _busy = true);
    try {
      final res = await _rec.stop();
      if (res.silent) {
        _toast('录得太短了，再来一次');
        setState(() => _busy = false);
        return;
      }
      await _process(res, liveText: _liveMode ? _liveText : null);
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _busyLabel = null;
        });
      }
    }
  }

  /// 完整流水线：ASR → 清洗翻译 + 抽词块 → 落库
  Future<void> _process(RecordingResult res, {String? liveText}) async {
    final sessionDao = ref.read(sessionDaoProvider);
    final session = await sessionDao.create();
    await sessionDao.finish(session, audioPath: res.wavPath, durationMs: res.durationMs);

    setState(() => _busyLabel = '正在转写…');
    await sessionDao.setStatus(session.id, 'transcribing');

    String zh;
    try {
      final xf = ref.read(xunfeiProvider);
      if (liveText != null && liveText.trim().isNotEmpty) {
        zh = liveText.trim();
      } else {
        zh = await xf.transcribePcm(res.pcm);
      }
    } catch (e) {
      await sessionDao.setStatus(session.id, 'failed', error: '$e');
      _toast('转写失败：$e');
      ref.read(sessionsRevisionProvider.notifier).state++;
      return;
    }

    if (zh.trim().isEmpty) {
      await sessionDao.setStatus(session.id, 'failed', error: '转写结果为空');
      _toast('没有识别到语音，可能是环境太吵');
      ref.read(sessionsRevisionProvider.notifier).state++;
      return;
    }

    setState(() => _busyLabel = '正在翻译并提取词块…');

    final pipe = ref.read(translatePipelineProvider);
    try {
      final result = await pipe.run(
        sessionId: session.id,
        rawText: zh,
        preSliced: [
          Utterance(id: '${session.id}-u0', sessionId: session.id, seq: 0, textZh: zh),
        ],
      );
      await sessionDao.replaceUtterances(session.id, result.utterances);
      await sessionDao.setStatus(session.id, 'done');
      ref.read(sessionsRevisionProvider.notifier).state++;
      ref.read(chunksRevisionProvider.notifier).state++;

      if (mounted) {
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => SessionDetailPage(
              sessionId: session.id,
              autoCandidates: result.candidates,
            ),
          ),
        );
      }
      ref.read(sessionsRevisionProvider.notifier).state++;
    } catch (e) {
      await sessionDao.setStatus(session.id, 'failed', error: '$e');
      _toast('翻译失败：$e');
      ref.read(sessionsRevisionProvider.notifier).state++;
    }
  }

  void _toast(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  @override
  Widget build(BuildContext context) {
    final setting = ref.watch(settingsProvider).valueOrNull;
    final notReady = setting != null && !setting.xfReady;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
      children: [
        if (notReady) _SetupHint(),
        _RecordCard(
          state: _st,
          busy: _busy,
          busyLabel: _busyLabel,
          onStart: _start,
          onStop: _stopAndProcess,
          onCancel: () async {
            await _rec.cancel();
            setState(() => _liveText = '');
          },
        ),
        Gap.h16,
        _liveCard(),
        Gap.h24,
        SectionHeader(
          title: '最近的记录',
          trailing: TextButton(
            onPressed: () => ref.read(sessionsRevisionProvider.notifier).state++,
            child: const Text('刷新'),
          ),
        ),
        Consumer(builder: (_, ref, __) {
          final sessions = ref.watch(sessionsProvider);
          return sessions.when(
            data: (list) {
              if (list.isEmpty) {
                return const EmptyState(
                  icon: Icons.graphic_eq_rounded,
                  title: '还没有记录',
                  subtitle: '点击上方按钮开始第一次录音，\n它会自动转成英文。',
                );
              }
              return Column(
                children: [
                  for (final s in list) ...[
                    _SessionTile(session: s),
                    Gap.h8,
                  ]
                ],
              );
            },
            loading: () => const Padding(
              padding: EdgeInsets.all(32),
              child: Center(child: CircularProgressIndicator()),
            ),
            error: (e, _) => Text('$e'),
          );
        }),
      ],
    );
  }

  Widget _liveCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.bolt_rounded, size: 18, color: AppColors.warn),
                Gap.w6,
                Expanded(
                  child: Text(
                    _st.recording
                        ? (_liveMode ? '实时转写中…' : '正在录音（结束后一次性转写）')
                        : '录音结束后自动转写 → 翻译 → 提取词块',
                    style: TextStyles.small,
                  ),
                ),
              ],
            ),
            if (_liveText.isNotEmpty) ...[
              Gap.h8,
              Text(_liveText, style: TextStyles.body),
            ],
          ],
        ),
      ),
    );
  }
}

class _SetupHint extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF7E6),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFFFE2A8)),
      ),
      child: Row(
        children: [
          const Icon(Icons.info_outline_rounded, color: AppColors.warn, size: 20),
          Gap.w12,
          const Expanded(
            child: Text(
              '先用「设置」填好讯飞听写的三件套和大模型 API Key，录音才能工作。',
              style: TextStyle(fontSize: 13, height: 1.45),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const SettingsPage()),
            ),
            child: const Text('去设置'),
          ),
        ],
      ),
    );
  }
}

class _RecordCard extends StatelessWidget {
  const _RecordCard({
    required this.state,
    required this.busy,
    required this.busyLabel,
    required this.onStart,
    required this.onStop,
    required this.onCancel,
  });

  final RecorderState state;
  final bool busy;
  final String? busyLabel;
  final VoidCallback onStart;
  final VoidCallback onStop;
  final VoidCallback onCancel;

  String _fmt(Duration d) {
    final m = d.inMinutes.toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    final ms = ((d.inMilliseconds % 1000) ~/ 100).toString();
    return '$m:$s.$ms';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 28, 20, 24),
        child: Column(
          children: [
            if (busy) ...[
              const SizedBox(
                width: 26,
                height: 26,
                child: CircularProgressIndicator(strokeWidth: 2.6),
              ),
              Gap.h12,
              Text(busyLabel ?? '处理中…', style: TextStyles.small),
              Gap.h16,
            ] else ...[
              AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                width: 108 + state.amplitude * 34,
                height: 108 + state.amplitude * 34,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: state.recording
                      ? scheme.primary.withValues(alpha: 0.10 + state.amplitude * 0.16)
                      : scheme.primary.withValues(alpha: 0.08),
                ),
                child: Center(
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: () {
                      if (state.recording) {
                        onStop();
                      } else {
                        onStart();
                      }
                    },
                    child: Container(
                      width: 84,
                      height: 84,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: state.recording ? AppColors.danger : scheme.primary,
                        boxShadow: [
                          BoxShadow(
                            color: (state.recording ? AppColors.danger : scheme.primary)
                                .withValues(alpha: 0.32),
                            blurRadius: 22,
                            offset: const Offset(0, 8),
                          )
                        ],
                      ),
                      child: Icon(
                        state.recording ? Icons.stop_rounded : Icons.mic_rounded,
                        color: Colors.white,
                        size: 38,
                      ),
                    ),
                  ),
                ),
              ),
              Gap.h16,
              Text(
                state.recording ? _fmt(state.elapsed) : '点击开始录音',
                style: TextStyle(
                  fontSize: state.recording ? 28 : 15,
                  fontWeight: state.recording ? FontWeight.w700 : FontWeight.w500,
                  color: state.recording ? AppColors.ink : AppColors.sub,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              if (state.recording) ...[
                Gap.h4,
                Text('点击方块结束并开始翻译', style: TextStyles.small),
                Gap.h8,
                TextButton.icon(
                  onPressed: onCancel,
                  icon: const Icon(Icons.close_rounded, size: 16),
                  label: const Text('丢弃这次录音'),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

class _SessionTile extends ConsumerWidget {
  const _SessionTile({required this.session});

  final Session session;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = DateTime.fromMillisecondsSinceEpoch(session.startedAt);
    final time =
        '${t.month}/${t.day} ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    final dur = '${(session.durationMs / 1000).toStringAsFixed(0)}s';

    final (label, color) = switch (session.status) {
      'done' => ('已翻译', AppColors.ok),
      'failed' => ('失败', AppColors.danger),
      'transcribing' => ('转写中', AppColors.warn),
      'translated' => ('待翻译', AppColors.warn),
      _ => ('待处理', AppColors.sub),
    };

    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => SessionDetailPage(sessionId: session.id)),
        ),
        onLongPress: () => showSessionActions(context, ref, session),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: AppColors.bg,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  session.status == 'failed' ? Icons.error_outline : Icons.graphic_eq,
                  color: session.status == 'failed' ? AppColors.danger : AppColors.primary,
                ),
              ),
              Gap.w12,
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      session.displayName,
                      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Gap.h2,
                    Text('$time · $dur', style: TextStyles.small),
                    if (session.error != null) ...[
                      Gap.h2,
                      Text(
                        session.error!,
                        style: TextStyles.small.copyWith(color: AppColors.danger),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  label,
                  style: TextStyle(fontSize: 11.5, color: color, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
