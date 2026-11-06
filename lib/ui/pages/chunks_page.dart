import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/dao.dart';
import '../../data/models.dart';
import '../../ui/providers.dart';
import '../../ui/theme.dart';
import 'chunk_edit_page.dart';

class ChunksPage extends ConsumerWidget {
  const ChunksPage({super.key, this.day});

  /// 指定日期时只看那天；为空则跟随全局 selectedDay
  final String? day;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final explicitDay = day;
    final String targetDay = explicitDay ?? ref.watch(selectedDayProvider);

    return Scaffold(
      appBar: explicitDay == null ? null : AppBar(title: Text('$explicitDay 的词块')),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.read(chunksRevisionProvider.notifier).state++;
        },
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 96),
          children: [
            const _DaySelector(),
            Gap.h16,
            const _DueBanner(),
            _ChunkList(day: targetDay),
          ],
        ),
      ),
      floatingActionButton: explicitDay == null
          ? null
          : FloatingActionButton.extended(
              onPressed: () async {
                await Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => ChunkEditPage(day: targetDay)),
                );
                ref.read(chunksRevisionProvider.notifier).state++;
              },
              icon: const Icon(Icons.add_rounded),
              label: const Text('新增词块'),
            ),
    );
  }
}

class _DaySelector extends ConsumerWidget {
  const _DaySelector();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final days = ref.watch(allDaysProvider);
    final cur = ref.watch(selectedDayProvider);

    return days.when(
      data: (list) {
        final all = [todayKey(), ...list.where((d) => d != todayKey())];
        return SizedBox(
          height: 38,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: all.length,
            separatorBuilder: (_, __) => Gap.w8,
            itemBuilder: (_, i) {
              final d = all[i];
              final sel = d == cur;
              final label =
                  d == todayKey() ? '今天' : d.substring(5).replaceAll('-', '/');
              return ChoiceChip(
                label: Text(label),
                selected: sel,
                showCheckmark: false,
                labelStyle: TextStyle(
                  fontSize: 13,
                  color: sel ? Colors.white : AppColors.ink,
                  fontWeight: FontWeight.w600,
                ),
                selectedColor: AppColors.primary,
                backgroundColor: Colors.white,
                side: BorderSide(color: sel ? AppColors.primary : AppColors.line),
                onSelected: (_) => ref.read(selectedDayProvider.notifier).state = d,
              );
            },
          ),
        );
      },
      loading: () => const SizedBox(height: 38),
      error: (_, __) => const SizedBox(height: 38),
    );
  }
}

class _DueBanner extends ConsumerWidget {
  const _DueBanner();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final due = ref.watch(dueChunksProvider);
    return due.maybeWhen(
      data: (list) {
        if (list.isEmpty) return const SizedBox.shrink();
        return Container(
          margin: const EdgeInsets.only(bottom: 14),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: const Color(0xFFEFFAF3),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: const Color(0xFFCBEFD8)),
          ),
          child: Row(
            children: [
              const Icon(Icons.schedule_rounded, size: 18, color: AppColors.ok),
              Gap.w8,
              Expanded(
                child: Text(
                  '今天有 ${list.length} 个词块到期复习',
                  style: const TextStyle(
                    fontSize: 13,
                    color: AppColors.ok,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const Text('去「复习」页', style: TextStyles.small),
            ],
          ),
        );
      },
      orElse: () => const SizedBox.shrink(),
    );
  }
}

class _ChunkList extends ConsumerWidget {
  const _ChunkList({required this.day});

  final String day;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chunks = ref.watch(chunksRevisionProvider);
    final selected = ref.watch(selectedDayProvider);

    if (day != selected) {
      return FutureBuilder<List<Chunk>>(
        key: ValueKey('$day-$chunks'),
        future: ref.read(chunkDaoProvider).byDay(day),
        builder: (_, snap) => _build(context, ref, snap.data ?? const <Chunk>[], snap.connectionState),
      );
    }

    return ref.watch(dayChunksProvider).when(
          data: (list) => _build(context, ref, list, ConnectionState.done),
          loading: () => const Padding(
            padding: EdgeInsets.all(40),
            child: Center(child: CircularProgressIndicator()),
          ),
          error: (e, _) => Text('$e'),
        );
  }

  Widget _build(BuildContext context, WidgetRef ref, List<Chunk> list, ConnectionState st) {
    if (st == ConnectionState.waiting) {
      return const Padding(
        padding: EdgeInsets.all(40),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (list.isEmpty) {
      return const EmptyState(
        icon: Icons.style_outlined,
        title: '这一天还没有词块',
        subtitle: '去「记录」页录一段，AI 会帮你挑词块；\n也可以在下方手动添加。',
      );
    }

    final mastered = list.where((c) => c.status == 'mastered').length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(day, style: TextStyles.h1),
            Gap.w8,
            Text('${list.length} 个 · 已掌握 $mastered', style: TextStyles.small),
          ],
        ),
        Gap.h12,
        for (final c in list) ...[
          _ChunkTile(chunk: c),
          Gap.h8,
        ],
      ],
    );
  }
}

class _ChunkTile extends ConsumerWidget {
  const _ChunkTile({required this.chunk});

  final Chunk chunk;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mastered = chunk.status == 'mastered';

    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () async {
          await Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => ChunkEditPage(day: chunk.day, chunk: chunk)),
          );
          ref.read(chunksRevisionProvider.notifier).state++;
        },
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      chunk.en,
                      style: TextStyle(
                        fontSize: 16.5,
                        fontWeight: FontWeight.w700,
                        color: mastered ? AppColors.sub : AppColors.ink,
                        decoration: mastered ? TextDecoration.lineThrough : null,
                      ),
                    ),
                    Gap.h2,
                    Text(chunk.zh, style: TextStyles.small.copyWith(fontSize: 13.5)),
                    if (chunk.exampleEn != null && chunk.exampleEn!.trim().isNotEmpty) ...[
                      Gap.h6,
                      Text(
                        '“${chunk.exampleEn}”',
                        style: TextStyles.small.copyWith(fontStyle: FontStyle.italic),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
              IconButton(
                tooltip: mastered ? '标记为未掌握' : '标记为已掌握',
                onPressed: () async {
                  await ref.read(chunkDaoProvider).toggleMastered(chunk);
                  ref.read(chunksRevisionProvider.notifier).state++;
                },
                icon: Icon(
                  mastered ? Icons.check_circle_rounded : Icons.radio_button_unchecked,
                  color: mastered ? AppColors.ok : AppColors.line,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
