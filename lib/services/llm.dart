import 'dart:convert';

import 'package:http/http.dart' as http;

import '../data/models.dart';
import '../data/settings.dart';

class LlmException implements Exception {
  LlmException(this.message, {this.statusCode});
  final String message;
  final int? statusCode;
  @override
  String toString() => statusCode == null ? message : '[$statusCode] $message';
}

/// OpenAI 兼容 Chat Completions 客户端。
/// 支持 DeepSeek / OpenAI / Moonshot / 通义兼容模式 / 任意自建网关。
class LlmClient {
  LlmClient(this.settings);

  final AppSettings settings;

  Uri get _endpoint {
    var base = settings.llmBaseUrl.trim();
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    // 允许用户只填到域名，自动补 /chat/completions
    if (!base.endsWith('/chat/completions')) {
      base = '$base/chat/completions';
    }
    return Uri.parse(base);
  }

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ${settings.llmApiKey.trim()}',
      };

  /// 普通对话：返回文本
  Future<String> chat({
    required List<Map<String, String>> messages,
    double temperature = 0.8,
    int maxTokens = 1200,
  }) async {
    final res = await _post({
      'model': settings.llmModel.trim(),
      'messages': messages,
      'temperature': temperature,
      'max_tokens': maxTokens,
      'stream': false,
    });
    return _extractContent(res);
  }

  Future<Map<String, dynamic>> _post(Map<String, dynamic> body) async {
    if (!settings.llmReady) {
      throw LlmException('尚未填写 LLM API Key，请先到「设置」页填写');
    }
    late http.Response r;
    try {
      r = await http
          .post(_endpoint, headers: _headers, body: jsonEncode(body))
          .timeout(const Duration(seconds: 120));
    } catch (e) {
      throw LlmException('网络请求失败：$e');
    }
    if (r.statusCode < 200 || r.statusCode >= 300) {
      throw LlmException(_brief(r.body), statusCode: r.statusCode);
    }
    try {
      return jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
    } catch (e) {
      throw LlmException('响应不是合法 JSON：$e');
    }
  }

  String _extractContent(Map<String, dynamic> json) {
    final choices = json['choices'];
    if (choices is List && choices.isNotEmpty) {
      final msg = choices.first['message'];
      if (msg is Map && msg['content'] is String) return msg['content'] as String;
      if (choices.first['text'] is String) return choices.first['text'] as String;
    }
    throw LlmException('响应中没有内容：${_brief(jsonEncode(json))}');
  }

  String _brief(String s) => s.length > 300 ? '${s.substring(0, 300)}…' : s;

  /// 连通性测试
  Future<String> ping() async {
    final out = await chat(messages: [
      {'role': 'user', 'content': 'Reply with exactly: PONG'}
    ], maxTokens: 16, temperature: 0);
    return out.trim();
  }
}

class TranslateResult {
  TranslateResult({
    required this.utterances,
    required this.sceneTag,
    required this.candidates,
  });

  final List<Utterance> utterances;
  final String sceneTag;
  final List<ChunkCandidate> candidates;
}

class ChunkCandidate {
  ChunkCandidate({required this.en, required this.zh, this.example});

  final String en;
  final String zh;
  final String? example;

  Map<String, dynamic> toJson() => {'en': en, 'zh': zh, 'example': example};
}

/// 翻译 + 词块抽取流水线（一次 LLM 调用同时完成）
class TranslatePipeline {
  TranslatePipeline(this.llm);

  final LlmClient llm;

  static const _system = '''
你是一位中英双语的英语口语教练，擅长把中文日常口语转成自然的、母语者真的会说的英文。

任务：把我提供的一段中文口语转写稿，处理成结构化 JSON。

硬性要求：
1. 先对我给出的每一句中文做「口语清洗」：去掉「嗯、啊、那个、就是说」等语气词/口吃/重复，补全语义，但不要改变我的原意，不要扩写。
2. 把每一句意译成自然的口语英文（conversational English），要求：
   - 不要逐字直译，要用地道的搭配和连读表达（如 "grab a bite"、"swing by"、"no big deal"）。
   - 保持口语感，允许简略句、口语缩略（gonna / kinda / I'd rather）。
   - 句子长度控制在口说一句能说完的范围内。
3. 从全部英文里挑出 5-12 个「值得背的语块（chunk）」：2-5 个词的固定搭配、短语动词、地道表达。不要挑单个普通单词，不要挑专有名词，不要重复。
4. 判断这段对话发生的场景，给一个中文场景标签（如「午餐闲聊」「地铁通勤」「工作会议」）。

只输出 JSON，不要任何解释、不要 markdown 代码块。JSON 结构：
{
  "scene_tag": "午餐闲聊",
  "utterances": [
    {"i": 0, "zh": "清洗后的中文", "en": "自然英文"}
  ],
  "chunks": [
    {"en": "grab a bite", "zh": "随便吃点东西", "example": "Wanna grab a bite after work?"}
  ]
}
''';

  /// [rawText] 可以是整段文本，也可以是多行；[sentenceSplit] 由调用方决定是否预切
  Future<TranslateResult> run({
    required String sessionId,
    required String rawText,
    List<Utterance>? preSliced,
  }) async {
    final lines = preSliced ?? _naiveSplit(sessionId, rawText);
    final numbered = StringBuffer();
    for (var i = 0; i < lines.length; i++) {
      numbered.writeln('[$i] ${lines[i].textZh}');
    }

    final content = await llm.chat(
      messages: [
        {'role': 'system', 'content': _system},
        {'role': 'user', 'content': '转写稿：\n$numbered'},
      ],
      temperature: 0.3,
      maxTokens: 3000,
    );

    final json = _parseJson(content);
    final outList = <Utterance>[];
    final uttNodes = (json['utterances'] as List?) ?? const [];
    for (final n in uttNodes) {
      final m = n as Map;
      final i = (m['i'] as num?)?.toInt() ?? outList.length;
      final src = i >= 0 && i < lines.length ? lines[i] : null;
      outList.add(Utterance(
        id: src?.id ?? '$sessionId-u${outList.length}',
        sessionId: sessionId,
        seq: outList.length,
        startMs: src?.startMs ?? 0,
        endMs: src?.endMs ?? 0,
        textZh: src?.textZh ?? '',
        polishedZh: (m['zh'] as String?)?.trim(),
        textEn: ((m['en'] as String?) ?? '').trim(),
        sceneTag: (json['scene_tag'] as String?)?.trim(),
      ));
    }

    final cands = <ChunkCandidate>[];
    final chunkNodes = (json['chunks'] as List?) ?? const [];
    for (final n in chunkNodes) {
      final m = n as Map;
      final en = ((m['en'] as String?) ?? '').trim();
      if (en.isEmpty) continue;
      cands.add(ChunkCandidate(
        en: en,
        zh: ((m['zh'] as String?) ?? '').trim(),
        example: (m['example'] as String?)?.trim(),
      ));
    }

    if (outList.isEmpty) {
      throw LlmException('模型没有返回有效句子，请检查模型是否支持中文口语翻译');
    }

    return TranslateResult(
      utterances: outList,
      sceneTag: (json['scene_tag'] as String?)?.trim() ?? '日常',
      candidates: cands,
    );
  }

  /// 去掉 ```json 包裹后解析，并容忍模型前后寒暄
  Map<String, dynamic> _parseJson(String raw) {
    var s = raw.trim();
    if (s.startsWith('```')) {
      final firstNl = s.indexOf('\n');
      if (firstNl > 0) s = s.substring(firstNl + 1);
      final fence = s.lastIndexOf('```');
      if (fence >= 0) s = s.substring(0, fence);
    }
    final start = s.indexOf('{');
    final end = s.lastIndexOf('}');
    if (start < 0 || end <= start) {
      throw LlmException('模型没有输出 JSON：${raw.length > 200 ? raw.substring(0, 200) : raw}');
    }
    try {
      return jsonDecode(s.substring(start, end + 1)) as Map<String, dynamic>;
    } catch (e) {
      throw LlmException('JSON 解析失败：$e');
    }
  }

  List<Utterance> _naiveSplit(String sessionId, String raw) {
    final cleaned = raw.replaceAll('\r', '').trim();
    if (cleaned.isEmpty) return [];
    final parts = cleaned
        .split(RegExp(r'(?<=[。！？；!?;\n])'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    final list = <Utterance>[];
    for (var i = 0; i < parts.length; i++) {
      list.add(Utterance(
        id: '$sessionId-u$i',
        sessionId: sessionId,
        seq: i,
        textZh: parts[i],
      ));
    }
    return list;
  }
}
