package com.echoenglish.echo_english.audio

import android.content.Context
import android.media.AudioAttributes
import android.media.MediaPlayer
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * 应用内音频播放桥。
 *
 * 之前用 `am start -d file:///data/user/0/<pkg>/...` 把音频甩给系统播放器，
 * 在 Android 7+ 上必然无声：那个路径是应用私有目录，别的进程没有读权限
 * （SELinux + 应用沙箱），MediaPlayer 打开失败，界面却只看到 intent 发成功。
 * 所以这里直接用 MediaPlayer 在本进程内播，不依赖外部 App、不新增 pub 依赖。
 */
class AudioPlayerBridge(
    private val context: Context,
    private val channel: MethodChannel,
) : MethodChannel.MethodCallHandler {

    private var player: MediaPlayer? = null
    private val main = Handler(Looper.getMainLooper())

    init {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "play" -> {
                    val path = call.argument<String>("path")
                    val data = call.argument<ByteArray>("data")
                    val ext = call.argument<String>("ext") ?: "mp3"
                    val volume = (call.argument<Double>("volume") ?: 1.0).toFloat()
                    when {
                        !path.isNullOrEmpty() -> playPath(path, volume, result)
                        data != null && data.isNotEmpty() -> {
                            val f = File(
                                context.cacheDir,
                                "echo_play_${System.currentTimeMillis()}.$ext",
                            )
                            f.writeBytes(data)
                            playPath(f.absolutePath, volume, result)
                        }
                        else -> result.error("bad_args", "play 需要 path 或 data", null)
                    }
                }
                "stop" -> {
                    stopInternal()
                    result.success(true)
                }
                "isPlaying" -> result.success(player?.isPlaying == true)
                else -> result.notImplemented()
            }
        } catch (e: Throwable) {
            result.error("play_failed", e.message ?: e.javaClass.simpleName, null)
        }
    }

    private fun playPath(path: String, volume: Float, result: MethodChannel.Result) {
        stopInternal()
        val mp = MediaPlayer()
        mp.setAudioAttributes(
            AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_MEDIA)
                .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                .build()
        )
        mp.setDataSource(path)
        mp.setVolume(volume, volume)
        mp.setOnCompletionListener {
            notifyCompleted()
            stopInternal()
        }
        mp.setOnErrorListener { _, what, extra ->
            channel.invokeMethod("error", mapOf("what" to what, "extra" to extra))
            stopInternal()
            true
        }
        mp.prepare()
        mp.start()
        player = mp
        result.success(true)
    }

    private fun notifyCompleted() {
        main.post {
            runCatching { channel.invokeMethod("completed", null) }
        }
    }

    private fun stopInternal() {
        val mp = player ?: return
        player = null
        runCatching { if (mp.isPlaying) mp.stop() }
        runCatching { mp.release() }
    }

    fun dispose() {
        stopInternal()
        channel.setMethodCallHandler(null)
    }
}
