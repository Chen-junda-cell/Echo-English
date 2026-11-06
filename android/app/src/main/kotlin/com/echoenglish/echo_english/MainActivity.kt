package com.echoenglish.echo_english

import com.echoenglish.echo_english.aiui.AiuiBridge
import com.echoenglish.echo_english.audio.AudioPlayerBridge
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private var bridge: AiuiBridge? = null
    private var audio: AudioPlayerBridge? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        val messenger = flutterEngine.dartExecutor.binaryMessenger
        val cmd = MethodChannel(messenger, "com.echoenglish.aiui/cmd")
        val events = EventChannel(messenger, "com.echoenglish.aiui/event")

        val b = AiuiBridge(applicationContext, cmd, events)
        bridge = b
        b.attach()

        val playChannel = MethodChannel(messenger, "com.echoenglish.audio/play")
        audio = AudioPlayerBridge(applicationContext, playChannel)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        bridge?.detach()
        bridge = null
        audio?.dispose()
        audio = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
