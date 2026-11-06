import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models.dart';
import '../../ui/providers.dart';
import '../../ui/theme.dart';

class ChunkEditPage extends ConsumerStatefulWidget {
  const ChunkEditPage({super.key, required this.day, this.chunk});

  final String day;
  final Chunk? chunk;

  @override
  ConsumerState<ChunkEditPage> createState() => _ChunkEditPageState();
}

class _ChunkEditPageState extends ConsumerState<ChunkEditPage> {
  final _en = TextEditingController();
  final _zh = TextEditingController();
  final _ex = TextEditingController();
  final _note = TextEditingController();
  bool _initialized = false;

  @override
  void initState() {
    super.initState();
    final c = widget.chunk;
    if (c != null) {
      _en.text = c.en;
      _zh.text = c.zh;
      _ex.text = c.exampleEn ?? '';
      _note.text = c.note ?? '';
    }
    _initialized = true;
  }

  @override
  void dispose() {
    _en.dispose();
    _zh.dispose();
    _ex.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final en = _en.text.trim();
    if (en.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('词块内容不能为空')));
      return;
    }
    final dao = ref.read(chunkDaoProvider);
    if (widget.chunk == null) {
      await dao.add(
        en: en,
        zh: _zh.text.trim(),
        exampleEn: _ex.text.trim().isEmpty ? null : _ex.text.trim(),
        day: widget.day,
      );
    } else {
      final c = widget.chunk!;
      c.en = en;
      c.zh = _zh.text.trim();
      c.exampleEn = _ex.text.trim().isEmpty ? null : _ex.text.trim();
      c.note = _note.text.trim().isEmpty ? null : _note.text.trim();
      await dao.update(c);
    }
    ref.read(chunksRevisionProvider.notifier).state++;
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _delete() async {
    await ref.read(chunkDaoProvider).delete(widget.chunk!.id);
    ref.read(chunksRevisionProvider.notifier).state++;
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final isNew = widget.chunk == null;
    return Scaffold(
      appBar: AppBar(
        title: Text(isNew ? '新增词块' : '编辑词块'),
        actions: [
          if (!isNew)
            IconButton(
              tooltip: '删除',
              onPressed: _delete,
              icon: const Icon(Icons.delete_outline_rounded, color: AppColors.danger),
            ),
        ],
      ),
      body: !_initialized
          ? const SizedBox.shrink()
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
              children: [
                const _Label('英文词块（2-5 词的地道搭配）'),
                TextField(
                  controller: _en,
                  autofocus: isNew,
                  textCapitalization: TextCapitalization.sentences,
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                  decoration: const InputDecoration(hintText: 'e.g. grab a bite'),
                ),
                Gap.h16,
                const _Label('中文意思'),
                TextField(
                  controller: _zh,
                  decoration: const InputDecoration(hintText: 'e.g. 随便吃点东西'),
                ),
                Gap.h16,
                const _Label('例句'),
                TextField(
                  controller: _ex,
                  minLines: 1,
                  maxLines: 3,
                  decoration: const InputDecoration(hintText: 'Wanna grab a bite after work?'),
                ),
                Gap.h16,
                const _Label('我的备注'),
                TextField(
                  controller: _note,
                  minLines: 1,
                  maxLines: 3,
                  decoration: const InputDecoration(hintText: '什么时候用过 / 易错点'),
                ),
                Gap.h24,
                FilledButton(onPressed: _save, child: Text(isNew ? '加入词块本' : '保存修改')),
                Gap.h8,
                Center(
                  child: Text('归档日期：${widget.day}', style: TextStyles.small),
                ),
              ],
            ),
    );
  }
}

class _Label extends StatelessWidget {
  const _Label(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 6, left: 2),
        child: Text(text, style: TextStyles.small.copyWith(fontWeight: FontWeight.w600)),
      );
}
