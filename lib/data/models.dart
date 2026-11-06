class Session {
  Session({
    required this.id,
    required this.startedAt,
    this.endedAt,
    this.audioPath,
    this.durationMs = 0,
    this.status = 'recorded',
    this.sceneTag,
    this.title,
    this.error,
  });

  final String id;
  final int startedAt;
  int? endedAt;
  String? audioPath;
  int durationMs;
  String status; // recorded | transcribing | transcribed | translating | done | failed
  String? sceneTag;

  /// 用户自定义名称（长按可重命名）。为空时回退到 sceneTag / 时间
  String? title;
  String? error;

  /// 列表里展示的主标题
  String get displayName {
    final t = (title ?? '').trim();
    if (t.isNotEmpty) return t;
    final s = (sceneTag ?? '').trim();
    if (s.isNotEmpty) return s;
    return '未命名语音';
  }

  Session copyWith({
    int? endedAt,
    String? audioPath,
    int? durationMs,
    String? status,
    String? sceneTag,
    String? title,
    String? error,
  }) =>
      Session(
        id: id,
        startedAt: startedAt,
        endedAt: endedAt ?? this.endedAt,
        audioPath: audioPath ?? this.audioPath,
        durationMs: durationMs ?? this.durationMs,
        status: status ?? this.status,
        sceneTag: sceneTag ?? this.sceneTag,
        title: title ?? this.title,
        error: error ?? this.error,
      );

  Map<String, Object?> toMap() => {
        'id': id,
        'started_at': startedAt,
        'ended_at': endedAt,
        'audio_path': audioPath,
        'duration_ms': durationMs,
        'status': status,
        'scene_tag': sceneTag,
        'title': title,
        'error': error,
      };

  factory Session.fromMap(Map<String, Object?> m) => Session(
        id: m['id'] as String,
        startedAt: m['started_at'] as int,
        endedAt: m['ended_at'] as int?,
        audioPath: m['audio_path'] as String?,
        durationMs: (m['duration_ms'] as int?) ?? 0,
        status: (m['status'] as String?) ?? 'recorded',
        sceneTag: m['scene_tag'] as String?,
        title: m['title'] as String?,
        error: m['error'] as String?,
      );
}

class Utterance {
  Utterance({
    required this.id,
    required this.sessionId,
    this.seq = 0,
    this.startMs = 0,
    this.endMs = 0,
    this.textZh = '',
    this.textEn = '',
    this.polishedZh,
    this.sceneTag,
  });

  final String id;
  final String sessionId;
  int seq;
  int startMs;
  int endMs;
  String textZh;
  String textEn;
  String? polishedZh;
  String? sceneTag;

  Map<String, Object?> toMap() => {
        'id': id,
        'session_id': sessionId,
        'seq': seq,
        'start_ms': startMs,
        'end_ms': endMs,
        'text_zh': textZh,
        'text_en': textEn,
        'polished_zh': polishedZh,
        'scene_tag': sceneTag,
      };

  factory Utterance.fromMap(Map<String, Object?> m) => Utterance(
        id: m['id'] as String,
        sessionId: m['session_id'] as String,
        seq: (m['seq'] as int?) ?? 0,
        startMs: (m['start_ms'] as int?) ?? 0,
        endMs: (m['end_ms'] as int?) ?? 0,
        textZh: (m['text_zh'] as String?) ?? '',
        textEn: (m['text_en'] as String?) ?? '',
        polishedZh: m['polished_zh'] as String?,
        sceneTag: m['scene_tag'] as String?,
      );
}

class Chunk {
  Chunk({
    required this.id,
    required this.en,
    this.zh = '',
    this.exampleEn,
    this.sourceUtteranceId,
    this.sourceSessionId,
    required this.day,
    this.sceneTag,
    this.status = 'new',
    this.ease = 2.5,
    this.intervalDays = 0,
    this.dueAt,
    this.hits = 0,
    this.misses = 0,
    this.note,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  String en;
  String zh;
  String? exampleEn;
  String? sourceUtteranceId;
  String? sourceSessionId;
  String day;
  String? sceneTag;
  String status; // new | learning | mastered
  double ease;
  int intervalDays;
  int? dueAt;
  int hits;
  int misses;
  String? note;
  final int createdAt;
  int updatedAt;

  Map<String, Object?> toMap() => {
        'id': id,
        'en': en,
        'zh': zh,
        'example_en': exampleEn,
        'source_utterance_id': sourceUtteranceId,
        'source_session_id': sourceSessionId,
        'day': day,
        'scene_tag': sceneTag,
        'status': status,
        'ease': ease,
        'interval_days': intervalDays,
        'due_at': dueAt,
        'hits': hits,
        'misses': misses,
        'note': note,
        'created_at': createdAt,
        'updated_at': updatedAt,
      };

  factory Chunk.fromMap(Map<String, Object?> m) => Chunk(
        id: m['id'] as String,
        en: m['en'] as String,
        zh: (m['zh'] as String?) ?? '',
        exampleEn: m['example_en'] as String?,
        sourceUtteranceId: m['source_utterance_id'] as String?,
        sourceSessionId: m['source_session_id'] as String?,
        day: m['day'] as String,
        sceneTag: m['scene_tag'] as String?,
        status: (m['status'] as String?) ?? 'new',
        ease: ((m['ease'] as num?) ?? 2.5).toDouble(),
        intervalDays: (m['interval_days'] as int?) ?? 0,
        dueAt: m['due_at'] as int?,
        hits: (m['hits'] as int?) ?? 0,
        misses: (m['misses'] as int?) ?? 0,
        note: m['note'] as String?,
        createdAt: m['created_at'] as int,
        updatedAt: m['updated_at'] as int,
      );
}

class ChatMessage {
  ChatMessage({
    required this.id,
    required this.day,
    required this.role,
    required this.content,
    required this.createdAt,
  });

  final String id;
  final String day;
  final String role; // user | assistant | system
  final String content;
  final int createdAt;

  Map<String, Object?> toMap() => {
        'id': id,
        'day': day,
        'role': role,
        'content': content,
        'created_at': createdAt,
      };

  factory ChatMessage.fromMap(Map<String, Object?> m) => ChatMessage(
        id: m['id'] as String,
        day: m['day'] as String,
        role: m['role'] as String,
        content: m['content'] as String,
        createdAt: m['created_at'] as int,
      );
}

class ReviewReport {
  ReviewReport({
    required this.id,
    required this.day,
    required this.used,
    required this.missed,
    required this.wrong,
    required this.advice,
    required this.createdAt,
  });

  final String id;
  final String day;
  final List<String> used;
  final List<String> missed;
  final List<String> wrong;
  final String advice;
  final int createdAt;
}
