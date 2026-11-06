import 'dart:convert';

import 'dao.dart';

/// 应用设置（服务密钥与用户可填的 API Key 都放这里）
/// 说明：
/// - LLM 的 key 由用户在设置页填写，存在本地 kv 表（不上传）
/// - 讯飞开放平台的 APPID / APIKey / APISecret 需要用户在设置页填写自己的
/// - 听写（IAT）与语音合成（TTS）共用同一套讯飞三件套
class AppSettings {
  AppSettings({
    required this.llmBaseUrl,
    required this.llmApiKey,
    required this.llmModel,
    required this.xfAppId,
    required this.xfApiKey,
    required this.xfApiSecret,
    required this.xfApiPassword,
    required this.xfTtsVoice,
    required this.autoTranslate,
    required this.dailyReminder,
    required this.themeSeed,
    required this.voiceChat,
    required this.autoSpeak,
  });

  String llmBaseUrl;
  String llmApiKey;
  String llmModel;
  String xfAppId;
  String xfApiKey;
  String xfApiSecret;

  /// 超拟人语音合成的第二种鉴权：控制台「APIKey（ak-xxx）」那一行。
  /// 填了它就走 `x-api-key` 请求头，不再走 URL 签名（签名模式要求 APISecret 完整 32 位）。
  String xfApiPassword;

  /// 讯飞 TTS 发音人，例如 xiaoyan / xiaofeng / aisjiuxu
  String xfTtsVoice;
  bool autoTranslate;
  bool dailyReminder;
  int themeSeed;

  /// 复习页默认用语音模式（AI 朗读 + 按住说话）
  bool voiceChat;

  /// AI 回复后自动朗读
  bool autoSpeak;

  static const kLlmBaseUrl = 'llm_base_url';
  static const kLlmApiKey = 'llm_api_key';
  static const kLlmModel = 'llm_model';
  static const kXfAppId = 'xf_app_id';
  static const kXfApiKey = 'xf_api_key';
  static const kXfApiSecret = 'xf_api_secret';
  static const kXfApiPassword = 'xf_api_password';
  static const kXfTtsVoice = 'xf_tts_voice';
  static const kAutoTranslate = 'auto_translate';
  static const kDailyReminder = 'daily_reminder';
  static const kThemeSeed = 'theme_seed';
  static const kVoiceChat = 'voice_chat';
  static const kAutoSpeak = 'auto_speak';

  static AppSettings defaults() => AppSettings(
        llmBaseUrl: 'https://api.deepseek.com/v1',
        llmApiKey: '',
        llmModel: 'deepseek-chat',
        xfAppId: '',
        xfApiKey: '',
        xfApiSecret: '',
        xfApiPassword: '',
        xfTtsVoice: 'x6_lingxiaoxuan_pro',
        autoTranslate: true,
        dailyReminder: false,
        themeSeed: 0xFF2F6FED,
        voiceChat: true,
        autoSpeak: true,
      );

  bool get llmReady => llmApiKey.trim().isNotEmpty && llmBaseUrl.trim().isNotEmpty;
  bool get xfReady =>
      xfAppId.trim().isNotEmpty && xfApiKey.trim().isNotEmpty && xfApiSecret.trim().isNotEmpty;

  Map<String, String> toKv() => {
        kLlmBaseUrl: llmBaseUrl,
        kLlmApiKey: llmApiKey,
        kLlmModel: llmModel,
        kXfAppId: xfAppId,
        kXfApiKey: xfApiKey,
        kXfApiSecret: xfApiSecret,
        kXfApiPassword: xfApiPassword,
        kXfTtsVoice: xfTtsVoice,
        kAutoTranslate: jsonEncode(autoTranslate),
        kDailyReminder: jsonEncode(dailyReminder),
        kThemeSeed: jsonEncode(themeSeed),
        kVoiceChat: jsonEncode(voiceChat),
        kAutoSpeak: jsonEncode(autoSpeak),
      };

  static Future<AppSettings> load() async {
    final kv = KvDao();
    final s = defaults();
    s.llmBaseUrl = (await kv.get(kLlmBaseUrl)) ?? s.llmBaseUrl;
    s.llmApiKey = (await kv.get(kLlmApiKey)) ?? '';
    s.llmModel = (await kv.get(kLlmModel)) ?? s.llmModel;
    s.xfAppId = (await kv.get(kXfAppId)) ?? '';
    s.xfApiKey = (await kv.get(kXfApiKey)) ?? '';
    s.xfApiSecret = (await kv.get(kXfApiSecret)) ?? '';
    s.xfApiPassword = (await kv.get(kXfApiPassword)) ?? '';
    s.xfTtsVoice = (await kv.get(kXfTtsVoice)) ?? s.xfTtsVoice;
    final at = await kv.get(kAutoTranslate);
    if (at != null) s.autoTranslate = at == 'true';
    final dr = await kv.get(kDailyReminder);
    if (dr != null) s.dailyReminder = dr == 'true';
    final ts = await kv.get(kThemeSeed);
    if (ts != null) s.themeSeed = int.tryParse(ts) ?? s.themeSeed;
    final vc = await kv.get(kVoiceChat);
    if (vc != null) s.voiceChat = vc == 'true';
    final as = await kv.get(kAutoSpeak);
    if (as != null) s.autoSpeak = as == 'true';
    return s;
  }

  Future<void> save() async {
    final kv = KvDao();
    for (final e in toKv().entries) {
      await kv.set(e.key, e.value);
    }
  }
}
