package com.echoenglish.echo_english.aiui

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.content.res.AssetManager
import android.os.Handler
import android.os.Looper
import android.util.Base64
import android.util.Log
import com.iflytek.aiui.AIUIAgent
import com.iflytek.aiui.AIUIConstant
import com.iflytek.aiui.AIUIEvent
import com.iflytek.aiui.AIUIListener
import com.iflytek.aiui.AIUIMessage
import com.iflytek.aiui.AIUISetting
import com.iflytek.aiui.Version
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONException
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.io.InputStream

/**
 * 讯飞 AIUI 全双工语音交互桥接。
 *
 * Dart 侧：
 *   - MethodChannel  com.echoenglish.aiui/cmd
 *   - EventChannel   com.echoenglish.aiui/event
 *
 * 上行事件（原生 -> Dart）：
 *   {type: "ready" | "connected" | "disconnected" | "wakeup" | "sleep"
 *          | "iat" | "nlp" | "tts_start" | "tts_end" | "vad_bos" | "vad_eos"
 *          | "error" | "record_start" | "record_stop" | "log",
 *    text?, final?, code?, message?, scene?, raw?}
 */
class AiuiBridge(
    private val context: Context,
    private val cmdChannel: MethodChannel,
    private val eventChannel: EventChannel,
) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    companion object {
        private const val TAG = "AiuiBridge"
        private const val CFG_ASSET = "cfg/aiui_phone.cfg"

        fun readAssetText(assets: AssetManager, path: String): String? = try {
            assets.open(path).use { input: InputStream ->
                input.readBytes().toString(Charsets.UTF_8)
            }
        } catch (e: Throwable) {
            Log.e(TAG, "readAssetText($path) failed: ${e.message}")
            null
        }

        /** 需要语音唤醒时把 assets/ivw 拷到 /sdcard/AIUI/ivw */
        fun copyAssetFolder(assets: AssetManager, src: String, dstDir: File): Boolean {
            return try {
                val children = assets.list(src) ?: return false
                if (children.isEmpty()) {
                    copyAssetFile(assets, src, File(dstDir.parentFile, dstDir.name))
                } else {
                    if (!dstDir.exists()) dstDir.mkdirs()
                    var ok = true
                    for (name in children) {
                        ok = copyAssetFolder(assets, "$src/$name", File(dstDir, name)) && ok
                    }
                    ok
                }
            } catch (e: Throwable) {
                Log.e(TAG, "copyAssetFolder($src) failed: ${e.message}")
                false
            }
        }

        private fun copyAssetFile(assets: AssetManager, src: String, out: File): Boolean = try {
            out.parentFile?.mkdirs()
            assets.open(src).use { input ->
                FileOutputStream(out).use { os -> input.copyTo(os) }
            }
            true
        } catch (e: Throwable) {
            Log.e(TAG, "copyAssetFile($src) failed: ${e.message}")
            false
        }
    }

    private var agent: AIUIAgent? = null
    private var eventSink: EventChannel.EventSink? = null
    private val main = Handler(Looper.getMainLooper())

    private val player = PcmStreamPlayer().apply {
        setListener(object : PcmStreamPlayer.Listener {
            override fun onPlayStarted() = emit("tts_start")
            override fun onPlayCompleted() = emit("tts_end")
        })
    }

    // 本次会话累积的识别/理解文本
    private val iatBuilder = StringBuilder(256)
    private val nlpBuilder = StringBuilder(256)
    private var curIatSid = ""
    private var curTtsSid = ""

    private var interacting = false
    private var pendingAnswer: String? = null
    private var startedOnce = false

    // ---------- 通道 ----------

    fun attach() {
        cmdChannel.setMethodCallHandler(this)
        eventChannel.setStreamHandler(this)
    }

    fun detach() {
        cmdChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        destroyAgent()
        player.release()
        eventSink = null
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
        emit("ready", mapOf<String, Any?>("sdkVersion" to Version.getVersion()))
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    private fun emit(type: String, extra: Map<String, Any?> = emptyMap()) {
        val payload = HashMap<String, Any?>()
        payload["type"] = type
        payload.putAll(extra)
        main.post { eventSink?.success(payload) }
    }

    private fun emitError(code: Int, message: String?) {
        emit("error", mapOf<String, Any?>("code" to code, "message" to (message ?: "")))
    }

    // ---------- MethodChannel ----------

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "init" -> {
                val appId = call.argument<String>("appId")
                val apiSecret = call.argument<String>("apiSecret")
                val apiKey = call.argument<String>("apiKey")
                val voice = call.argument<String>("voice")
                val scene = call.argument<String>("scene")
                val wakeupMode = call.argument<String>("wakeupMode")
                try {
                    createAgent(appId, apiSecret, apiKey, voice, scene, wakeupMode)
                    result.success(Version.getVersion())
                } catch (e: Throwable) {
                    Log.e(TAG, "init failed: ${e.message}")
                    result.error("AIUI_INIT_FAILED", e.message, null)
                }
            }

            "startInteraction", "start" -> {
                try {
                    startInteraction()
                    result.success(true)
                } catch (e: Throwable) {
                    result.error("AIUI_START_FAILED", e.message, null)
                }
            }

            "stopInteraction", "stop" -> {
                try {
                    stopInteraction()
                    result.success(true)
                } catch (e: Throwable) {
                    result.error("AIUI_STOP_FAILED", e.message, null)
                }
            }

            "answer" -> {
                // 用用户自己的大模型回答替代 AIUI 的 cbm 结果
                val text = call.argument<String>("text") ?: ""
                try {
                    speak(text)
                    result.success(true)
                } catch (e: Throwable) {
                    result.error("AIUI_TTS_FAILED", e.message, null)
                }
            }

            "setPendingAnswer" -> {
                pendingAnswer = call.argument<String>("text")
                result.success(true)
            }

            "speak" -> {
                val text = call.argument<String>("text") ?: ""
                try {
                    speak(text)
                    result.success(true)
                } catch (e: Throwable) {
                    result.error("AIUI_TTS_FAILED", e.message, null)
                }
            }

            "abortSpeak" -> {
                send(AIUIConstant.CMD_TTS, AIUIConstant.PAUSE, 0, null, null)
                player.stop()
                result.success(true)
            }

            "wakeup" -> {
                send(AIUIConstant.CMD_WAKEUP, 0, 0, "", null)
                result.success(true)
            }

            "destroy" -> {
                destroyAgent()
                result.success(true)
            }

            "isReady" -> result.success(agent != null)

            "sdkVersion" -> result.success(Version.getVersion())

            "hasMicPermission" -> {
                val ok = context.checkSelfPermission(Manifest.permission.RECORD_AUDIO) ==
                        PackageManager.PERMISSION_GRANTED
                result.success(ok)
            }

            else -> result.notImplemented()
        }
    }

    private fun send(cmd: Int, arg1: Int, arg2: Int, params: String?, data: ByteArray?) {
        agent?.sendMessage(AIUIMessage(cmd, arg1, arg2, params, data))
    }

    // ---------- Agent 生命周期 ----------

    private fun createAgent(
        appIdOverride: String?,
        apiSecretOverride: String?,
        apiKeyOverride: String?,
        voice: String?,
        scene: String?,
        wakeupMode: String?,
    ) {
        destroyAgent()

        val assets = context.assets
        val raw = readAssetText(assets, CFG_ASSET)
            ?: throw IllegalStateException("缺少 assets/$CFG_ASSET")

        val paramsJson = JSONObject(raw)

        // 1. 登录参数：Dart 侧传入优先，否则用 cfg 里的
        val login = paramsJson.optJSONObject("login") ?: JSONObject().also { paramsJson.put("login", it) }
        if (!appIdOverride.isNullOrBlank()) login.put("appid", appIdOverride)
        if (!apiSecretOverride.isNullOrBlank()) login.put("api_secret", apiSecretOverride)
        if (!apiKeyOverride.isNullOrBlank()) login.put("key", apiKeyOverride)

        val effectiveWakeup = (wakeupMode ?: paramsJson.optJSONObject("speech")
            ?.optString("wakeup_mode") ?: "off")
        paramsJson.optJSONObject("speech")?.put("wakeup_mode", effectiveWakeup)?.toString()
            ?: JSONObject().let { sp ->
                sp.put("data_source", "sdk")
                sp.put("wakeup_mode", effectiveWakeup)
                sp.put("interact_mode", "continuous")
                sp.put("audio_source", 7)
                paramsJson.put("speech", sp)
            }

        if (!scene.isNullOrBlank()) {
            paramsJson.optJSONObject("global")?.put("scene", scene)?.toString()
                ?: JSONObject().let { g ->
                    g.put("scene", scene)
                    g.put("aiui_ver", "3")
                    paramsJson.put("global", g)
                }
        } else {
            paramsJson.optJSONObject("global")?.put("aiui_ver", "3")
        }

        // 2. TTS：外部播放，16k raw
        val tts = paramsJson.optJSONObject("tts") ?: JSONObject().also { paramsJson.put("tts", it) }
        tts.put("play_mode", "user")
        tts.put("audio_encoding", "raw")
        tts.put("data_encoding", "raw")
        tts.put("sample_rate", "16000")
        tts.put("buffer_time", 0)
        if (!voice.isNullOrBlank()) tts.put("voice_name", voice)

        paramsJson.optJSONObject("iat")?.put("data_encoding", "raw")

        // 3. 唤醒词需要把 ivw 资源外置到 /sdcard/AIUI/ivw
        if (effectiveWakeup != "off") {
            val ivwDir = File("/sdcard/AIUI/ivw")
            if (!ivwDir.exists()) copyAssetFolder(assets, "ivw", ivwDir)
        }

        // 4. 序列号（AIUI 用于区分设备/uid）
        AIUISetting.setSystemInfo(
            AIUIConstant.KEY_SERIAL_NUM,
            android.provider.Settings.Secure.getString(
                context.contentResolver,
                android.provider.Settings.Secure.ANDROID_ID
            ) ?: "echo-english"
        )
        try {
            AIUISetting.setNetLogLevel(AIUISetting.LogLevel.debug)
        } catch (_: Throwable) {
        }

        player.start(16000)
        startedOnce = false
        interacting = false
        iatBuilder.setLength(0)
        nlpBuilder.setLength(0)

        agent = AIUIAgent.createAgent(context.applicationContext, paramsJson.toString(), listener)
        if (agent == null) throw IllegalStateException("AIUIAgent.createAgent 返回 null（检查 appid/key/api_secret）")
        Log.i(TAG, "AIUIAgent created, params=$paramsJson")
    }

    private fun destroyAgent() {
        stopInteraction()
        try {
            agent?.destroy()
        } catch (e: Throwable) {
            Log.e(TAG, "destroy failed: ${e.message}")
        }
        agent = null
        try {
            player.stop()
        } catch (_: Throwable) {
        }
    }

    private fun startInteraction() {
        val a = agent ?: throw IllegalStateException("请先 init")
        if (interacting) {
            send(AIUIConstant.CMD_WAKEUP, 0, 0, "", null)
            return
        }
        interacting = true
        iatBuilder.setLength(0)
        nlpBuilder.setLength(0)
        curIatSid = ""
        curTtsSid = ""

        if (!startedOnce) {
            send(AIUIConstant.CMD_WAKEUP, 0, 0, "", null)
            startedOnce = true
        } else {
            send(AIUIConstant.CMD_WAKEUP, 0, 0, "", null)
        }
        send(AIUIConstant.CMD_START_RECORD, 0, 0, "data_type=audio", null)
        emit("record_start")
    }

    private fun stopInteraction() {
        if (!interacting && agent == null) return
        interacting = false
        send(AIUIConstant.CMD_STOP_RECORD, 0, 0, "data_type=audio", null)
        send(AIUIConstant.CMD_TTS, AIUIConstant.PAUSE, 0, null, null)
        send(AIUIConstant.CMD_RESET_WAKEUP, 0, 0, "", null)
        send(AIUIConstant.CMD_DISCONNECT_SERVER, 0, 0, null, null)
        try {
            player.stop()
        } catch (_: Throwable) {
        }
    }

    /** 让 AIUI 用我们的文本走云端 TTS（同时本地播放） */
    private fun speak(text: String) {
        val clean = sanitize(text)
        if (clean.isBlank()) return
        try {
            player.start(16000)
        } catch (e: Throwable) {
            Log.e(TAG, "player restart failed: ${e.message}")
        }
        val params = JSONObject()
            .put("vcn", currentVoice)
            .put("speed", 50)
            .put("pitch", 50)
            .put("volume", 60)
            .put("sample_rate", "16000")
            .put("audio_encoding", "raw")
            .toString()
        send(AIUIConstant.CMD_TTS, AIUIConstant.START, 0, params, clean.toByteArray(Charsets.UTF_8))
        emit("tts_request", mapOf<String, Any?>("text" to clean))
    }

    private var currentVoice: String = "x5_lingxiaoyue_flow"

    fun setVoice(v: String) {
        currentVoice = v
    }

    private fun sanitize(s: String): String =
        s.replace(Regex("[*#`_>\\[\\]()~|]"), " ").replace(Regex("\\s+"), " ").trim()

    // ---------- 事件回调 ----------

    private val listener = AIUIListener { event: AIUIEvent ->
        when (event.eventType) {
            AIUIConstant.EVENT_VAD -> {
                when (event.arg1) {
                    AIUIConstant.VAD_BOS -> emit("vad_bos")
                    AIUIConstant.VAD_EOS -> emit("vad_eos")
                    else -> emit("volume", mapOf<String, Any?>("level" to event.arg2))
                }
            }

            AIUIConstant.EVENT_CONNECTED_TO_SERVER -> emit("connected")

            AIUIConstant.EVENT_SERVER_DISCONNECTED -> emit("disconnected")

            AIUIConstant.EVENT_WAKEUP -> emit("wakeup")

            AIUIConstant.EVENT_SLEEP -> emit("sleep")

            AIUIConstant.EVENT_START_RECORD -> emit("record_start")

            AIUIConstant.EVENT_STOP_RECORD -> emit("record_stop")

            AIUIConstant.EVENT_ERROR -> {
                Log.e(TAG, "EVENT_ERROR code=${event.arg1} info=${event.info}")
                emitError(event.arg1, event.info)
            }

            AIUIConstant.EVENT_RESULT -> handleResult(event)

            else -> Log.d(TAG, "unhandled eventType=${event.eventType}")
        }
    }

    private fun handleResult(event: AIUIEvent) {
        try {
            val bizParam = JSONObject(event.info ?: return)
            val data = bizParam.optJSONArray("data")?.optJSONObject(0) ?: return
            val params = data.optJSONObject("params") ?: JSONObject()
            val sub = params.optString("sub", "")
            val content = data.optJSONArray("content")?.optJSONObject(0) ?: JSONObject()
            val sid = event.data?.getString("sid") ?: ""

            when (sub) {
                "iat" -> {
                    val cntId = content.optString("cnt_id", "")
                    if (cntId.isEmpty()) return
                    val bytes = event.data?.getByteArray(cntId) ?: return
                    if (bytes.isEmpty()) return
                    if (sid != curIatSid) {
                        curIatSid = sid
                        iatBuilder.setLength(0)
                    }
                    handleIat(String(bytes, Charsets.UTF_8))
                }

                "nlp" -> {
                    val cntId = content.optString("cnt_id", "")
                    if (cntId.isEmpty()) return
                    val bytes = event.data?.getByteArray(cntId) ?: return
                    if (bytes.isEmpty()) return
                    handleNlp(String(bytes, Charsets.UTF_8))
                }

                "tts" -> {
                    val cntId = content.optString("cnt_id", "")
                    if (cntId.isEmpty()) return
                    val audio = event.data?.getByteArray(cntId) ?: return
                    if (audio.isEmpty()) return
                    if (sid != curTtsSid) {
                        curTtsSid = sid
                        player.start(16000)
                    }
                    val dts = content.optInt("dts", 0)
                    player.write(audio)
                    if (dts == 2) {
                        // 末帧，交给播放器自然播完
                    }
                }

                "event" -> {
                    val cntId = content.optString("cnt_id", "")
                    if (cntId.isEmpty()) return
                    val bytes = event.data?.getByteArray(cntId) ?: return
                    if (bytes.isEmpty()) return
                    handleCloudEvent(String(bytes, Charsets.UTF_8))
                }

                else -> {
                    // sos_vms / cbm_vms 属于虚拟人，本应用不使用
                }
            }
        } catch (e: Throwable) {
            Log.e(TAG, "handleResult failed: ${e.message}")
        }
    }

    private fun handleIat(json: String) {
        try {
            val root = JSONObject(json)
            val textObj = root.optJSONObject("text") ?: return
            val isLast = textObj.optBoolean("ls", false)
            val ws = textObj.optJSONArray("ws") ?: return
            for (i in 0 until ws.length()) {
                val cw = ws.optJSONObject(i)?.optJSONArray("cw") ?: continue
                if (cw.length() == 0) continue
                val w = cw.optJSONObject(0)?.optString("w", "") ?: ""
                if (w.isNotEmpty()) iatBuilder.append(w)
            }
            if (isLast) {
                val finalText = iatBuilder.toString()
                iatBuilder.setLength(0)
                emit("iat", mapOf<String, Any?>("text" to finalText, "final" to true))
            } else {
                emit("iat", mapOf<String, Any?>("text" to iatBuilder.toString(), "final" to false))
            }
        } catch (e: JSONException) {
            Log.e(TAG, "handleIat failed: ${e.message}")
        }
    }

    private fun handleNlp(json: String) {
        try {
            val root = JSONObject(json)
            val intent = root.optString("intent", "")
            val nlp = root.optJSONObject("nlp") ?: return
            val text = nlp.optString("text", "")
            val status = nlp.optInt("status", 0)
            nlpBuilder.append(text)
            if (status == 2) {
                val answer = pendingAnswer
                val full = nlpBuilder.toString()
                nlpBuilder.setLength(0)
                emit(
                    "nlp",
                    mapOf<String, Any?>(
                        "text" to full,
                        "answer" to answer,
                        "intent" to intent,
                        "final" to true,
                    )
                )
                pendingAnswer = null
            }
        } catch (e: JSONException) {
            Log.e(TAG, "handleNlp failed: ${e.message}")
        }
    }

    private fun handleCloudEvent(json: String) {
        try {
            val root = JSONObject(json)
            val textStr = root.optJSONObject("event")?.optString("text", "") ?: return
            if (textStr.isEmpty()) return
            val evt = JSONObject(textStr)
            val type = evt.optString("type", "")
            if (type.equals("Vad", true)) {
                val key = evt.optString("key", "")
                when {
                    key.equals("Bos", true) -> emit("vad_bos")
                    key.equals("Eos", true) -> emit("vad_eos")
                    else -> emit("log", mapOf<String, Any?>("raw" to "cloud.vad.$key"))
                }
            } else {
                emit("log", mapOf<String, Any?>("raw" to "cloud.event.$type"))
            }
        } catch (e: JSONException) {
            Log.e(TAG, "handleCloudEvent failed: ${e.message}")
        }
    }

    // 供调试：把任意字节转 base64（预留）
    @Suppress("unused")
    private fun b64(b: ByteArray): String = Base64.encodeToString(b, Base64.NO_WRAP)
}
