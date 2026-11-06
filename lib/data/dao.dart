import 'dart:io';

import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import 'db.dart';
import 'models.dart';

const _uuid = Uuid();

String todayKey([DateTime? d]) {
  final t = d ?? DateTime.now();
  final m = t.month.toString().padLeft(2, '0');
  final day = t.day.toString().padLeft(2, '0');
  return '${t.year}-$m-$day';
}

class SessionDao {
  Future<Database> get _d => AppDb.instance.db;

  Future<Session> create() async {
    final s = Session(id: _uuid.v4(), startedAt: DateTime.now().millisecondsSinceEpoch);
    await (await _d).insert('sessions', s.toMap());
    return s;
  }

  Future<void> finish(Session s, {required String audioPath, required int durationMs}) async {
    await (await _d).update(
      'sessions',
      {
        'audio_path': audioPath,
        'duration_ms': durationMs,
        'ended_at': DateTime.now().millisecondsSinceEpoch,
        'status': 'transcribed',
      },
      where: 'id = ?',
      whereArgs: [s.id],
    );
  }

  Future<void> setStatus(String id, String status, {String? error}) async {
    await (await _d).update(
      'sessions',
      {'status': status, 'error': error},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<List<Session>> recent({int limit = 50}) async {
    final rows = await (await _d).query('sessions', orderBy: 'started_at DESC', limit: limit);
    return rows.map(Session.fromMap).toList();
  }

  Future<Session?> byId(String id) async {
    final rows = await (await _d).query('sessions', where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : Session.fromMap(rows.first);
  }

  /// 重命名一条语音记录。[name] 传空字符串表示清除自定义名称（回退到场景标签）。
  Future<void> rename(String id, String name) async {
    final clean = name.trim();
    await (await _d).update(
      'sessions',
      {'title': clean.isEmpty ? null : clean},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// 删除会话记录。语句由外键级联删除；音频文件由调用方负责清理
  /// （见 [deleteWithAudio]，需要 file 层配合）。
  Future<void> delete(String id) async {
    await (await _d).delete('sessions', where: 'id = ?', whereArgs: [id]);
  }

  /// 删除会话，同时把对应的录音文件也清掉（不清就永远占着存储）。
  /// 返回被删掉的音频路径，方便上层提示。
  Future<List<String>> deleteWithAudio(String id) async {
    final s = await byId(id);
    final removed = <String>[];
    final audio = s?.audioPath;
    await delete(id);
    if (audio != null && audio.trim().isNotEmpty) {
      for (final path in <String>{
        audio,
        audio.endsWith('.wav') ? '${audio.substring(0, audio.length - 4)}.pcm' : audio,
      }) {
        try {
          final f = File(path);
          if (await f.exists()) {
            await f.delete();
            removed.add(path);
          }
        } catch (_) {
          // 文件被系统占用时忽略，记录本身已经删掉
        }
      }
    }
    return removed;
  }

  Future<List<Utterance>> utterances(String sessionId) async {
    final rows = await (await _d)
        .query('utterances', where: 'session_id = ?', whereArgs: [sessionId], orderBy: 'seq ASC');
    return rows.map(Utterance.fromMap).toList();
  }

  /// 覆盖式写入某会话的语句（翻译流水线完成后一次性落库）
  Future<void> replaceUtterances(String sessionId, List<Utterance> list) async {
    final d = await _d;
    await d.transaction((txn) async {
      await txn.delete('utterances', where: 'session_id = ?', whereArgs: [sessionId]);
      final b = txn.batch();
      for (final u in list) {
        b.insert('utterances', u.toMap());
      }
      await b.commit(noResult: true);
    });
  }
}

class ChunkDao {
  Future<Database> get _d => AppDb.instance.db;

  Future<Chunk> add({
    required String en,
    required String zh,
    String? exampleEn,
    String? sourceUtteranceId,
    String? sourceSessionId,
    String? sceneTag,
    String? day,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final c = Chunk(
      id: _uuid.v4(),
      en: en.trim(),
      zh: zh.trim(),
      exampleEn: exampleEn,
      sourceUtteranceId: sourceUtteranceId,
      sourceSessionId: sourceSessionId,
      day: day ?? todayKey(),
      sceneTag: sceneTag,
      createdAt: now,
      updatedAt: now,
      dueAt: now,
    );
    await (await _d).insert('chunks', c.toMap(), conflictAlgorithm: ConflictAlgorithm.ignore);
    return c;
  }

  Future<List<Chunk>> byDay(String day) async {
    final rows = await (await _d)
        .query('chunks', where: 'day = ?', whereArgs: [day], orderBy: 'created_at ASC');
    return rows.map(Chunk.fromMap).toList();
  }

  Future<List<Chunk>> all() async {
    final rows = await (await _d).query('chunks', orderBy: 'created_at DESC');
    return rows.map(Chunk.fromMap).toList();
  }

  Future<List<String>> days() async {
    final rows = await (await _d).rawQuery('SELECT DISTINCT day FROM chunks ORDER BY day DESC');
    return rows.map((e) => e['day'] as String).toList();
  }

  Future<List<Chunk>> dueNow() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final rows = await (await _d).query(
      'chunks',
      where: 'due_at IS NULL OR due_at <= ?',
      whereArgs: [now],
      orderBy: 'due_at ASC',
      limit: 100,
    );
    return rows.map(Chunk.fromMap).toList();
  }

  Future<void> toggleMastered(Chunk c) async {
    final next = c.status == 'mastered' ? 'learning' : 'mastered';
    await (await _d).update(
      'chunks',
      {'status': next, 'updated_at': DateTime.now().millisecondsSinceEpoch},
      where: 'id = ?',
      whereArgs: [c.id],
    );
  }

  Future<void> update(Chunk c) async {
    await (await _d).update('chunks', {...c.toMap(), 'updated_at': DateTime.now().millisecondsSinceEpoch},
        where: 'id = ?', whereArgs: [c.id]);
  }

  Future<void> delete(String id) async {
    await (await _d).delete('chunks', where: 'id = ?', whereArgs: [id]);
  }

  /// 复习结算：命中则拉长间隔，未命中则重置
  Future<void> grade(Chunk c, {required bool hit}) async {
    final d = await _d;
    const day = Duration.millisecondsPerDay;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (hit) {
      final ease = (c.ease + 0.1).clamp(1.3, 3.0);
      final nextInterval = c.intervalDays == 0
          ? 1
          : c.intervalDays == 1
              ? 3
              : (c.intervalDays * ease).round();
      await d.update(
        'chunks',
        {
          'hits': c.hits + 1,
          'ease': ease,
          'interval_days': nextInterval,
          'due_at': now + nextInterval * day,
          'status': nextInterval >= 7 ? 'mastered' : 'learning',
          'updated_at': now,
        },
        where: 'id = ?',
        whereArgs: [c.id],
      );
    } else {
      await d.update(
        'chunks',
        {
          'misses': c.misses + 1,
          'ease': (c.ease - 0.2).clamp(1.3, 3.0),
          'interval_days': 0,
          'due_at': now,
          'status': 'learning',
          'updated_at': now,
        },
        where: 'id = ?',
        whereArgs: [c.id],
      );
    }
  }

  Future<int> countByDay(String day) async {
    final r = await (await _d)
        .rawQuery('SELECT COUNT(*) c FROM chunks WHERE day = ?', [day]);
    return (r.first['c'] as int?) ?? 0;
  }
}

class ChatDao {
  Future<Database> get _d => AppDb.instance.db;

  Future<List<ChatMessage>> byDay(String day) async {
    final rows = await (await _d)
        .query('chat_messages', where: 'day = ?', whereArgs: [day], orderBy: 'created_at ASC');
    return rows.map(ChatMessage.fromMap).toList();
  }

  Future<ChatMessage> append(String day, String role, String content) async {
    final m = ChatMessage(
      id: _uuid.v4(),
      day: day,
      role: role,
      content: content,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    await (await _d).insert('chat_messages', m.toMap());
    return m;
  }

  Future<void> clearDay(String day) async {
    await (await _d).delete('chat_messages', where: 'day = ?', whereArgs: [day]);
  }

  Future<void> saveReport(ReviewReport r) async {
    await (await _d).insert('review_reports', {
      'id': r.id,
      'day': r.day,
      'used_json': _jsonList(r.used),
      'missed_json': _jsonList(r.missed),
      'wrong_json': _jsonList(r.wrong),
      'advice': r.advice,
      'created_at': r.createdAt,
    });
  }
}

String _jsonList(List<String> l) =>
    '[${l.map((e) => '"${e.replaceAll('"', r'\"')}"').join(',')}]';

class KvDao {
  Future<Database> get _d => AppDb.instance.db;

  Future<String?> get(String k) async {
    final rows = await (await _d).query('kv', where: 'k = ?', whereArgs: [k], limit: 1);
    return rows.isEmpty ? null : rows.first['v'] as String;
  }

  Future<void> set(String k, String v) async {
    await (await _d).insert('kv', {'k': k, 'v': v}, conflictAlgorithm: ConflictAlgorithm.replace);
  }
}
