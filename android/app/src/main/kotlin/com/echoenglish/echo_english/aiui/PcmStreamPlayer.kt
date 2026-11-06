package com.echoenglish.echo_english.aiui

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.os.Message
import android.os.SystemClock
import android.util.Log

/**
 * 极简 PCM 流式播放器（16k / 16bit / 单声道）。
 * 供 AIUI 的 TTS 音频（play_mode=user）边收边播，避免自己写一套完整的 AudioTrack 状态机。
 */
class PcmStreamPlayer {

    companion object {
        private const val TAG = "PcmStreamPlayer"
        private const val FRAME_MS = 40
    }

    interface Listener {
        fun onPlayStarted()
        fun onPlayCompleted()
    }

    private var listener: Listener? = null

    private var sampleRate = 16000
    private var frameBytes = sampleRate * 2 / 1000 * FRAME_MS

    private var track: AudioTrack? = null

    private val pending = ArrayDeque<ByteArray>()
    private var pendingSize = 0

    private var thread: HandlerThread? = null
    private var handler: Handler? = null

    private val MSG_PLAY = 1
    private val MSG_STOP = 2
    private val MSG_RELEASE = 3

    private var playing = false
    private var completedNotified = true

    fun setListener(l: Listener?) {
        listener = l
    }

    fun start(rate: Int = 16000) {
        sampleRate = rate
        frameBytes = sampleRate * 2 / 1000 * FRAME_MS
        if (thread == null) {
            thread = HandlerThread("aiui-pcm-player").also { it.start() }
            handler = object : Handler(thread!!.looper) {
                override fun handleMessage(msg: Message) {
                    when (msg.what) {
                        MSG_PLAY -> drain()
                        MSG_STOP -> doStop()
                        MSG_RELEASE -> doRelease()
                    }
                }
            }
        }
        synchronized(pending) {
            pending.clear()
            pendingSize = 0
        }
        completedNotified = true
        ensureTrack()
    }

    private fun ensureTrack() {
        val t = track
        if (t != null && t.state == AudioTrack.STATE_INITIALIZED) return
        val minBuf = AudioTrack.getMinBufferSize(
            sampleRate,
            AudioFormat.CHANNEL_OUT_MONO,
            AudioFormat.ENCODING_PCM_16BIT
        ).coerceAtLeast(frameBytes * 2)

        val attrs = AudioAttributes.Builder()
            .setLegacyStreamType(AudioManager.STREAM_MUSIC)
            .setUsage(AudioAttributes.USAGE_MEDIA)
            .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
            .build()
        val format = AudioFormat.Builder()
            .setSampleRate(sampleRate)
            .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
            .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
            .build()

        track = AudioTrack.Builder()
            .setAudioAttributes(attrs)
            .setAudioFormat(format)
            .setBufferSizeInBytes(minBuf * 4)
            .setTransferMode(AudioTrack.MODE_STREAM)
            .build()
        playing = false
    }

    /** 写入一段 PCM，dts 语义由调用方忽略，这里只关心字节流 */
    fun write(audio: ByteArray) {
        if (audio.isEmpty()) return
        ensureTrack()
        synchronized(pending) {
            pending.addLast(audio)
            pendingSize += audio.size
        }
        handler?.sendEmptyMessage(MSG_PLAY)

        val t = track ?: return
        if (!playing) {
            try {
                t.play()
                playing = true
                completedNotified = false
                listener?.onPlayStarted()
            } catch (e: Throwable) {
                Log.e(TAG, "play() failed: ${e.message}")
            }
        }
    }

    private fun drain() {
        val t = track ?: return
        while (true) {
            val chunk = synchronized(pending) {
                if (pending.isEmpty()) null else {
                    val c = pending.removeFirst()
                    pendingSize -= c.size
                    c
                }
            } ?: break
            try {
                t.write(chunk, 0, chunk.size)
            } catch (e: Throwable) {
                Log.e(TAG, "write failed: ${e.message}")
                break
            }
        }
        // 队列见空且已经播完缓冲，认为本轮结束
        if (synchronized(pending) { pending.isEmpty() } && !completedNotified) {
            completedNotified = true
            listener?.onPlayCompleted()
        }
    }

    fun stop() {
        handler?.sendEmptyMessage(MSG_STOP)
    }

    private fun doStop() {
        synchronized(pending) {
            pending.clear()
            pendingSize = 0
        }
        val t = track
        try {
            if (t != null) {
                if (t.playState == AudioTrack.PLAYSTATE_PLAYING) t.pause()
                t.flush()
            }
        } catch (e: Throwable) {
            Log.e(TAG, "stop failed: ${e.message}")
        }
        playing = false
        completedNotified = true
    }

    /** 直接阻塞式播放一整段 PCM（用于非流式场景） */
    fun playAll(pcm: ByteArray, rate: Int = 16000) {
        stop()
        start(rate)
        write(pcm)
    }

    fun release() {
        handler?.sendEmptyMessage(MSG_RELEASE)
        thread?.quitSafely()
        thread = null
        handler = null
    }

    private fun doRelease() {
        doStop()
        try {
            track?.release()
        } catch (e: Throwable) {
            Log.e(TAG, "release failed: ${e.message}")
        }
        track = null
    }

    fun waitIdle(timeoutMs: Long = 3000) {
        val deadline = SystemClock.elapsedRealtime() + timeoutMs
        while (SystemClock.elapsedRealtime() < deadline) {
            if (synchronized(pending) { pending.isEmpty() } && completedNotified) break
            SystemClock.sleep(20)
        }
    }

    fun isPlaying(): Boolean = playing
}
