import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../data/models.dart';
import '../../ui/providers.dart';
import '../../ui/theme.dart';
import 'session_detail_page.dart';
import 'chunks_page.dart';

class LibraryPage extends ConsumerWidget {
  const LibraryPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sessions = ref.watch(sessionsProvider);
    final days = ref.watch(allDaysProvider);

    return RefreshIndicator(
      onRefresh: () async {
        ref.read(sessionsRevisionProvider.notifier).state++;
        ref.read(chunksRevisionProvider.notifier).state++;
      },
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
        children: [
          days.when(
            data: (ds) => ds.isEmpty
                ? const SizedBox.shrink()
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SectionHeader(title: '按天回顾'),
                      SizedBox(
                        height: 76,
                        child: ListView.separated(
                          scrollDirection: Axis.horizontal,
                          itemCount: ds.length,
                          separatorBuilder: (_, __) => Gap.w8,
                          itemBuilder: (_, i) {
                            final d = ds[i];
                            final sel = ref.watch(selectedDayProvider) == d;
                            return _DayChip(
                              day: d,
                              selected: sel,
                              onTap: () {
                                ref.read(selectedDayProvider.notifier).state = d;
                                Navigator.of(context).push(
                                  MaterialPageRoute(builder: (_) => ChunksPage(day: d)),
                                );
                              },
                            );
                          },
                        ),
                      ),
                      Gap.h24,
                    ],
                  ),
            loading: () => const SizedBox.shrink(),
            error: (_, __) => const SizedBox.shrink(),
          ),
          SectionHeader(
            title: '全部语音记录',
            trailing: Text(
              '长按可重命名 / 删除',
              style: TextStyles.small.copyWith(fontSize: 12),
            ),
          ),
          sessions.when(
            data: (list) {
              if (list.isEmpty) {
                return const EmptyState(
                  icon: Icons.mic_none_rounded,
                  title: '还没有语音日志',
                  subtitle: '去「记录」页录一段日常对话试试。',
                );
              }
              final groups = <String, List<Session>>{};
              for (final s in list) {
                final d = DateTime.fromMillisecondsSinceEpoch(s.startedAt);
                final key = DateFormat('yyyy年M月d日').format(d);
                groups.putIfAbsent(key, () => []).add(s);
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final e in groups.entries) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(2, 10, 0, 8),
                      child: Text(e.key, style: TextStyles.small.copyWith(fontWeight: FontWeight.w600)),
                    ),
                    for (final s in e.value) ...[
                      _SessionRow(session: s),
                      Gap.h8,
                    ],
                  ],
                ],
              );
            },
            loading: () => const Padding(
              padding: EdgeInsets.all(40),
              child: Center(child: CircularProgressIndicator()),
            ),
            error: (e, _) => Text('$e'),
          ),
        ],
      ),
    );
  }
}

class _DayChip extends StatelessWidget {
  const _DayChip({required this.day, required this.selected, required this.onTap});

  final String day;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final d = DateTime.parse(day);
    final wd = const ['一', '二', '三', '四', '五', '六', '日'][d.weekday - 1];
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      child: Container(
        width: 84,
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: selected ? AppColors.primary : Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: selected ? AppColors.primary : AppColors.line),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              '${d.month}/${d.day}',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: selected ? Colors.white : AppColors.ink,
              ),
            ),
            Gap.h2,
            Text(
              '周$wd',
              style: TextStyle(
                fontSize: 11.5,
                color: selected ? Colors.white70 : AppColors.sub,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SessionRow extends ConsumerWidget {
  const _SessionRow({required this.session});

  final Session session;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = DateTime.fromMillisecondsSinceEpoch(session.startedAt);
    final hm = DateFormat('HH:mm').format(t);

    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => SessionDetailPage(sessionId: session.id)),
        ),
        onLongPress: () => showSessionActions(context, ref, session),
        onSecondaryTap: () => showSessionActions(context, ref, session),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: session.status == 'failed'
                      ? AppColors.danger.withValues(alpha: 0.08)
                      : AppColors.primary.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  session.status == 'failed' ? Icons.close_rounded : Icons.audiotrack_rounded,
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
                      style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Gap.h2,
                    Text(
                      '$hm · ${(session.durationMs / 1000).toStringAsFixed(0)} 秒',
                      style: TextStyles.small,
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: '更多',
                visualDensity: VisualDensity.compact,
                onPressed: () => showSessionActions(context, ref, session),
                icon: const Icon(Icons.more_horiz_rounded, color: AppColors.sub),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 长按 / 点「更多」弹出的操作面板：重命名、删除
Future<void> showSessionActions(BuildContext context, WidgetRef ref, Session session) async {
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheetCtx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text(
              session.displayName,
              style: const TextStyle(fontSize: 13, color: AppColors.sub),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          ListTile(
            leading: const Icon(Icons.drive_file_rename_outline_rounded),
            title: const Text('重命名'),
            onTap: () async {
              Navigator.of(sheetCtx).pop();
              final name = await showRenameDialog(context, session);
              if (name == null) return;
              await ref.read(sessionDaoProvider).rename(session.id, name);
              ref.read(sessionsRevisionProvider.notifier).state++;
            },
          ),
          ListTile(
            leading: const Icon(Icons.delete_outline_rounded, color: AppColors.danger),
            title: const Text('删除这条语音', style: TextStyle(color: AppColors.danger)),
            subtitle: const Text('录音文件和转写内容都会一并删除', style: TextStyles.small),
            onTap: () async {
              Navigator.of(sheetCtx).pop();
              final ok = await showDeleteConfirm(context, session);
              if (ok != true) return;
              await ref.read(sessionDaoProvider).deleteWithAudio(session.id);
              ref.read(sessionsRevisionProvider.notifier).state++;
              ref.read(chunksRevisionProvider.notifier).state++;
              ref.read(sessionDetailRevisionProvider.notifier).state++;
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('已删除「${session.displayName}」')),
                );
              }
            },
          ),
          Gap.h8,
        ],
      ),
    ),
  );
}

/// 重命名对话框。返回 null 表示取消；返回空字符串表示清除自定义名称。
Future<String?> showRenameDialog(BuildContext context, Session session) async {
  final controller = TextEditingController(text: session.title ?? '');
  controller.selection = TextSelection.collapsed(offset: controller.text.length);

  final result = await showDialog<String>(
    context: context,
    builder: (dialogCtx) => AlertDialog(
      title: const Text('重命名语音'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: controller,
            autofocus: true,
            maxLength: 40,
            textInputAction: TextInputAction.done,
            decoration: InputDecoration(
              hintText: session.sceneTag ?? '例如：和同事吃午饭',
              isDense: true,
            ),
            onSubmitted: (v) => Navigator.of(dialogCtx).pop(v.trim()),
          ),
          Text(
            '留空则恢复成默认名称（${session.sceneTag ?? '未命名语音'}）',
            style: TextStyles.small.copyWith(fontSize: 12),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogCtx).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogCtx).pop(controller.text.trim()),
          child: const Text('保存'),
        ),
      ],
    ),
  );

  controller.dispose();
  return result;
}

/// 删除确认。返回 true 表示确认删除。
Future<bool?> showDeleteConfirm(BuildContext context, Session session) {
  return showDialog<bool>(
    context: context,
    builder: (dialogCtx) => AlertDialog(
      title: const Text('删除这条语音？'),
      content: Text(
        '「${session.displayName}」的录音文件、逐句翻译都会被删除，'
        '已经收进词块本的内容会保留。此操作无法撤销。',
        style: const TextStyle(height: 1.5, fontSize: 14),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogCtx).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
          onPressed: () => Navigator.of(dialogCtx).pop(true),
          child: const Text('删除'),
        ),
      ],
    ),
  );
}
