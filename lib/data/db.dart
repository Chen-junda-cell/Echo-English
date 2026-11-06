import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 全局数据库单例。所有表结构变更都走 [_onUpgrade] 的版本号迁移。
class AppDb {
  AppDb._();
  static final AppDb instance = AppDb._();

  static const _dbName = 'echo_english.db';
  static const _dbVersion = 2;

  Database? _db;

  Future<Database> get db async {
    if (_db != null) return _db!;
    final dir = await getApplicationDocumentsDirectory();
    final path = p.join(dir.path, _dbName);
    _db = await openDatabase(
      path,
      version: _dbVersion,
      onConfigure: (d) async {
        await d.execute('PRAGMA foreign_keys = ON');
      },
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
    return _db!;
  }

  Future<void> _onCreate(Database d, int version) async {
    final b = d.batch();

    // 会话：一次录音
    b.execute('''
      CREATE TABLE sessions (
        id TEXT PRIMARY KEY,
        started_at INTEGER NOT NULL,
        ended_at INTEGER,
        audio_path TEXT,
        duration_ms INTEGER NOT NULL DEFAULT 0,
        status TEXT NOT NULL DEFAULT 'recorded',
        scene_tag TEXT,
        title TEXT,
        error TEXT
      )
    ''');

    // 语句：转写+翻译后的一句
    b.execute('''
      CREATE TABLE utterances (
        id TEXT PRIMARY KEY,
        session_id TEXT NOT NULL,
        seq INTEGER NOT NULL DEFAULT 0,
        start_ms INTEGER NOT NULL DEFAULT 0,
        end_ms INTEGER NOT NULL DEFAULT 0,
        text_zh TEXT NOT NULL DEFAULT '',
        text_en TEXT NOT NULL DEFAULT '',
        polished_zh TEXT,
        scene_tag TEXT,
        FOREIGN KEY (session_id) REFERENCES sessions(id) ON DELETE CASCADE
      )
    ''');
    b.execute('CREATE INDEX idx_utt_session ON utterances(session_id, seq)');

    // 词块：核心资产
    b.execute('''
      CREATE TABLE chunks (
        id TEXT PRIMARY KEY,
        en TEXT NOT NULL,
        zh TEXT NOT NULL DEFAULT '',
        example_en TEXT,
        source_utterance_id TEXT,
        source_session_id TEXT,
        day TEXT NOT NULL,
        scene_tag TEXT,
        status TEXT NOT NULL DEFAULT 'new',
        ease REAL NOT NULL DEFAULT 2.5,
        interval_days INTEGER NOT NULL DEFAULT 0,
        due_at INTEGER,
        hits INTEGER NOT NULL DEFAULT 0,
        misses INTEGER NOT NULL DEFAULT 0,
        note TEXT,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');
    b.execute('CREATE INDEX idx_chunk_day ON chunks(day)');
    b.execute('CREATE UNIQUE INDEX idx_chunk_unique ON chunks(en, day)');

    // AI 对话
    b.execute('''
      CREATE TABLE chat_messages (
        id TEXT PRIMARY KEY,
        day TEXT NOT NULL,
        role TEXT NOT NULL,
        content TEXT NOT NULL,
        created_at INTEGER NOT NULL
      )
    ''');
    b.execute('CREATE INDEX idx_chat_day ON chat_messages(day, created_at)');

    // 当日结算报告
    b.execute('''
      CREATE TABLE review_reports (
        id TEXT PRIMARY KEY,
        day TEXT NOT NULL,
        used_json TEXT NOT NULL DEFAULT '[]',
        missed_json TEXT NOT NULL DEFAULT '[]',
        wrong_json TEXT NOT NULL DEFAULT '[]',
        advice TEXT NOT NULL DEFAULT '',
        created_at INTEGER NOT NULL
      )
    ''');

    // 键值设置
    b.execute('''
      CREATE TABLE kv (
        k TEXT PRIMARY KEY,
        v TEXT NOT NULL
      )
    ''');

    await b.commit(noResult: true);
  }

  Future<void> _onUpgrade(Database d, int oldV, int newV) async {
    // v1 -> v2：会话支持用户自定义名称
    if (oldV < 2) {
      await d.execute('ALTER TABLE sessions ADD COLUMN title TEXT');
    }
  }

  Future<void> close() async {
    await _db?.close();
    _db = null;
  }
}
