import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/settings.dart';
import '../../services/llm.dart';
import '../../services/xunfei_iat.dart';
import '../../services/xunfei_tts.dart';
import '../../ui/providers.dart';
import '../../ui/theme.dart';

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  late AppSettings _s;
  bool _loaded = false;
  bool _showLlmKey = false;
  bool _showXfSecret = false;
  String? _llmMsg;
  String? _asrMsg;
  String? _ttsMsg;
  bool _busy = false;

  final _baseUrl = TextEditingController();
  final _apiKey = TextEditingController();
  final _model = TextEditingController();
  final _xfAppId = TextEditingController();
  final _xfApiKey = TextEditingController();
  final _xfSecret = TextEditingController();
  final _ttsVoice = TextEditingController();
  final _apiPassword = TextEditingController();

  /// 讯飞常用发音人（超拟人系列参数带下划线，自动走超拟人接口）
  static const _voices = <String, String>{
    'x6_lingxiaoxuan_pro': '聆小璇 · 超拟人女声',
    'x6_lingfeiyi_pro': '聆飞逸 · 超拟人男声',
    'x5_lingyuzhao_flow': '聆玉昭 · 超拟人女声',
    'x6_lingxiaoyue_pro': '聆小玥 · 超拟人女声',
    'xiaoyan': '小燕 · 经典女声',
    'aisjiuxu': '许久 · 经典男声',
  };

  static const _presets = <String, (String, String)>{
    'DeepSeek': ('https://api.deepseek.com/v1', 'deepseek-chat'),
    'OpenAI': ('https://api.openai.com/v1', 'gpt-4o-mini'),
    'Moonshot': ('https://api.moonshot.cn/v1', 'moonshot-v1-8k'),
    '通义千问': ('https://dashscope.aliyuncs.com/compatible-mode/v1', 'qwen-plus'),
    '智谱 GLM': ('https://open.bigmodel.cn/api/paas/v4', 'glm-4-flash'),
  };

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    _s = await AppSettings.load();
    _baseUrl.text = _s.llmBaseUrl;
    _apiKey.text = _s.llmApiKey;
    _model.text = _s.llmModel;
    _xfAppId.text = _s.xfAppId;
    _xfApiKey.text = _s.xfApiKey;
    _xfSecret.text = _s.xfApiSecret;
    _ttsVoice.text = _s.xfTtsVoice;
    _apiPassword.text = _s.xfApiPassword;
    if (mounted) setState(() => _loaded = true);
  }

  Future<void> _persist() async {
    _s.llmBaseUrl = _baseUrl.text.trim();
    _s.llmApiKey = _apiKey.text.trim();
    _s.llmModel = _model.text.trim();
    _s.xfAppId = _xfAppId.text.trim();
    _s.xfApiKey = _xfApiKey.text.trim();
    _s.xfApiSecret = _xfSecret.text.trim();
    _s.xfApiPassword = _apiPassword.text.trim();
    _s.xfTtsVoice = _ttsVoice.text.trim().isEmpty ? 'xiaoyan' : _ttsVoice.text.trim();
    await _s.save();
    ref.invalidate(settingsProvider);
  }

  Future<void> _testLlm() async {
    setState(() {
      _busy = true;
      _llmMsg = null;
    });
    await _persist();
    try {
      final out = await LlmClient(_s).ping();
      setState(() => _llmMsg = '✅ 连接成功，模型回复：${out.isEmpty ? '(空)' : out}');
    } catch (e) {
      setState(() => _llmMsg = '❌ $e');
    } finally {
      setState(() => _busy = false);
    }
  }

  Future<void> _testAsr() async {
    setState(() {
      _busy = true;
      _asrMsg = null;
    });
    await _persist();
    try {
      final client = XunfeiIatClient(_s);
      // 发一段 0.5 秒静音，验证鉴权与握手是否通过
      final silence = Uint8List(16000); // 0.5 秒 16k/16bit 静音
      await client
          .transcribePcm(silence)
          .timeout(const Duration(seconds: 20));
      setState(() => _asrMsg = '✅ 鉴权与连接正常（静音测试通过）');
    } catch (e) {
      final msg = '$e';
      setState(() => _asrMsg = msg.contains('授权') || msg.contains('auth')
          ? '❌ 鉴权失败：$msg'
          : '❌ $msg');
    } finally {
      setState(() => _busy = false);
    }
  }

  Future<void> _testTts() async {
    setState(() {
      _busy = true;
      _ttsMsg = null;
    });
    await _persist();
    if (!_s.xfReady) {
      setState(() {
        _ttsMsg = '❌ 请先填完讯飞 APPID / APIKey / APISecret';
        _busy = false;
      });
      return;
    }
    try {
      final client = XunfeiTtsClient(_s);
      final audio = await client
          .synthesize('Hi, this is Echo. Let us practice your English today.')
          .timeout(const Duration(seconds: 25));
      if (audio.isEmpty) {
        setState(() => _ttsMsg = '❌ 合成结果为空，检查发音人是否已开通');
        return;
      }
      await const AudioPlayback().playEncoded(
        audio.toWavBytes(),
        ext: audio.fileExt,
        mime: audio.mime,
      );
      setState(
        () => _ttsMsg =
            '✅ ${client.endpointLabel} · ${client.authLabel} 合成成功（约 ${audio.secondsApprox.toStringAsFixed(1)} 秒），正在播放…',
      );
    } catch (e) {
      setState(() => _ttsMsg = '❌ $e');
    } finally {
      setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _baseUrl.dispose();
    _apiKey.dispose();
    _model.dispose();
    _xfAppId.dispose();
    _xfApiKey.dispose();
    _xfSecret.dispose();
    _ttsVoice.dispose();
    _apiPassword.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('设置'),
        actions: [
          TextButton(
            onPressed: () async {
              final messenger = ScaffoldMessenger.of(context);
              final nav = Navigator.of(context);
              await _persist();
              if (!mounted) return;
              messenger.showSnackBar(const SnackBar(content: Text('已保存')));
              nav.pop();
            },
            child: const Text('保存'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
        children: [
          _Card(
            title: '大模型（翻译 + 词块提取 + 对话）',
            subtitle: '填你自己的 API Key，只会保存在本机，不上传任何服务器',
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final e in _presets.entries)
                    ActionChip(
                      label: Text(e.key),
                      labelStyle: const TextStyle(fontSize: 12.5),
                      onPressed: () {
                        _baseUrl.text = e.value.$1;
                        _model.text = e.value.$2;
                        setState(() {});
                      },
                    ),
                ],
              ),
              Gap.h12,
              _Field(
                label: 'Base URL',
                controller: _baseUrl,
                hint: 'https://api.deepseek.com/v1',
              ),
              Gap.h12,
              _Field(
                label: 'API Key',
                controller: _apiKey,
                hint: 'sk-...',
                obscure: !_showLlmKey,
                suffix: IconButton(
                  onPressed: () => setState(() => _showLlmKey = !_showLlmKey),
                  icon: Icon(
                    _showLlmKey ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                    size: 20,
                  ),
                ),
              ),
              Gap.h12,
              _Field(label: 'Model', controller: _model, hint: 'deepseek-chat'),
              Gap.h12,
              Row(
                children: [
                  FilledButton.tonal(
                    onPressed: _busy ? null : _testLlm,
                    child: const Text('测试连接'),
                  ),
                ],
              ),
              if (_llmMsg != null) ...[
                Gap.h8,
                Text(_llmMsg!, style: TextStyles.small.copyWith(fontSize: 13)),
              ],
            ],
          ),
          Gap.h16,
          _Card(
            title: '讯飞语音听写（流式版 IAT）',
            subtitle: '去 console.xfyun.cn 创建「语音听写」应用，把三件套填进来',
            children: [
              _Field(label: 'APPID', controller: _xfAppId, hint: '如 5f1a2b3c'),
              Gap.h12,
              _Field(label: 'APIKey', controller: _xfApiKey, hint: '32 位字符串'),
              Gap.h12,
              _Field(
                label: 'APISecret',
                controller: _xfSecret,
                hint: '32 位字符串',
                obscure: !_showXfSecret,
                suffix: IconButton(
                  onPressed: () => setState(() => _showXfSecret = !_showXfSecret),
                  icon: Icon(
                    _showXfSecret ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                    size: 20,
                  ),
                ),
              ),
              Gap.h12,
              Row(
                children: [
                  FilledButton.tonal(
                    onPressed: _busy ? null : _testAsr,
                    child: const Text('测试鉴权'),
                  ),
                ],
              ),
              if (_asrMsg != null) ...[
                Gap.h8,
                Text(_asrMsg!, style: TextStyles.small.copyWith(fontSize: 13)),
              ],
            ],
          ),
          Gap.h16,
          _Card(
            title: '讯飞语音合成（TTS）· 让 AI 开口说话',
            subtitle: '带下划线的发音人（如 x6_lingxiaoxuan_pro）自动走「超拟人语音合成」，'
                '其余走「在线语音合成」；两者都和听写共用同一套三件套',
            children: [
              _Field(
                label: '发音人（vcn）',
                controller: _ttsVoice,
                hint: 'x6_lingxiaoxuan_pro',
              ),
              Gap.h8,
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final e in _voices.entries)
                    ActionChip(
                      label: Text(e.value, style: const TextStyle(fontSize: 12.5)),
                      backgroundColor:
                          _ttsVoice.text.trim() == e.key ? const Color(0xFFEAF1FF) : null,
                      onPressed: () {
                        _ttsVoice.text = e.key;
                        setState(() => _s.xfTtsVoice = e.key);
                        _persist();
                      },
                    ),
                ],
              ),
              Gap.h12,
              _Field(
                label: '超拟人 APIKey（选填，控制台「APIKey」那一行，形如 ak-xxx）',
                controller: _apiPassword,
                hint: '填了就改用 x-api-key 请求头鉴权，不再校验 APISecret',
                obscure: true,
              ),
              Gap.h12,
              Row(
                children: [
                  FilledButton.tonal(
                    onPressed: _busy ? null : _testTts,
                    child: const Text('试听一句'),
                  ),
                ],
              ),
              if (_ttsMsg != null) ...[
                Gap.h8,
                Text(_ttsMsg!, style: TextStyles.small.copyWith(fontSize: 13)),
              ],
            ],
          ),
          Gap.h16,
          _Card(
            title: '使用偏好',
            children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _s.voiceChat,
                onChanged: (v) {
                  setState(() => _s.voiceChat = v);
                  _persist();
                },
                title: const Text('复习页默认用语音对话', style: TextStyle(fontSize: 15)),
                subtitle: const Text(
                  '开启后复习页底部是「按住说话」，可以对着 Echo 直接说英文',
                  style: TextStyles.small,
                ),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _s.autoSpeak,
                onChanged: (v) {
                  setState(() => _s.autoSpeak = v);
                  _persist();
                },
                title: const Text('AI 回复自动朗读', style: TextStyle(fontSize: 15)),
                subtitle: const Text('Echo 每说一句都会用讯飞合成播出来', style: TextStyles.small),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppColors.primary.withValues(alpha: 0.05),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.bolt_rounded, size: 18, color: AppColors.primary),
                      Gap.w8,
                      Expanded(
                        child: Text(
                          '复习页语音模式里还能开启「AIUI 全双工」：说完自动断句、'
                          'AI 边答边播，像打电话一样不用按键。录音和播放全部走 AIUI 引擎。',
                          style: TextStyles.small.copyWith(height: 1.5),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _s.autoTranslate,
                onChanged: (v) {
                  setState(() => _s.autoTranslate = v);
                  _persist();
                },
                title: const Text('录音结束自动翻译', style: TextStyle(fontSize: 15)),
                subtitle: const Text('关闭后需要手动点翻译', style: TextStyles.small),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _s.dailyReminder,
                onChanged: (v) {
                  setState(() => _s.dailyReminder = v);
                  _persist();
                },
                title: const Text('每日复习提醒', style: TextStyle(fontSize: 15)),
                subtitle: const Text('每晚 21:00 提醒你复习当天词块', style: TextStyles.small),
              ),
            ],
          ),
          Gap.h16,
          _Card(
            title: '关于',
            children: [
              const Text(
                'Echo English 把你说过的日常中文变成地道英文，'
                '再从里面长出你自己的词块本，最后让 AI 陪你回到当天的场景里把它们说出来。',
                style: TextStyle(fontSize: 13.5, height: 1.6, color: AppColors.sub),
              ),
              Gap.h12,
              Text('版本 1.0.0 · 数据全部保存在本机', style: TextStyles.small),
            ],
          ),
        ],
      ),
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({
    required this.label,
    required this.controller,
    this.hint,
    this.obscure = false,
    this.suffix,
  });

  final String label;
  final TextEditingController controller;
  final String? hint;
  final bool obscure;
  final Widget? suffix;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyles.small.copyWith(fontWeight: FontWeight.w600)),
        Gap.h6,
        TextField(
          controller: controller,
          obscureText: obscure,
          autocorrect: false,
          enableSuggestions: false,
          style: const TextStyle(fontSize: 14),
          decoration: InputDecoration(hintText: hint, suffixIcon: suffix, isDense: true),
        ),
      ],
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.title, this.subtitle, required this.children});

  final String title;
  final String? subtitle;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700)),
            if (subtitle != null) ...[
              Gap.h4,
              Text(subtitle!, style: TextStyles.small),
            ],
            Gap.h16,
            ...children,
          ],
        ),
      ),
    );
  }
}
