package com.iptvplayer.iptv_player

import android.app.PendingIntent
import android.app.PictureInPictureParams
import android.app.RemoteAction
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.graphics.drawable.Icon
import android.os.Build
import android.util.Rational
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Picture-in-picture for the phone build: the player keeps playing in a
 * small floating window on top of other apps.
 *
 * Dart drives it over the `cat/pip` channel: `arm` while the player page is
 * open (pressing Home then floats the video), `enter` for the PiP button, and
 * `update` when play state or video size changes. This side reports
 * `changed` with `{active, dismissed}` and `togglePlay` from the window's
 * play/pause button.
 */
class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null
    private var armed = false
    private var playing = true
    private var aspect = Rational(16, 9)
    private var receiverRegistered = false
    private var started = false

    private val actionReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action == ACTION_TOGGLE) channel?.invokeMethod("togglePlay", null)
        }
    }

    private val supported: Boolean
        get() = Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "cat/pip").apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "isSupported" -> result.success(supported)
                    "arm" -> {
                        armed = call.argument<Boolean>("armed") ?: false
                        readState(call.argument("playing"), call.argument("width"), call.argument("height"))
                        applyParams()
                        result.success(null)
                    }
                    "update" -> {
                        readState(call.argument("playing"), call.argument("width"), call.argument("height"))
                        applyParams()
                        result.success(null)
                    }
                    "enter" -> result.success(enter())
                    else -> result.notImplemented()
                }
            }
        }
    }

    private fun readState(playing: Boolean?, width: Int?, height: Int?) {
        if (playing != null) this.playing = playing
        if (width != null && height != null && width > 0 && height > 0) {
            // Android rejects ratios outside 1:2.39 .. 2.39:1.
            val r = width.toDouble() / height
            aspect = when {
                r > 2.39 -> Rational(239, 100)
                r < 1 / 2.39 -> Rational(100, 239)
                else -> Rational(width, height)
            }
        }
    }

    private fun buildParams(): PictureInPictureParams? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return null
        val toggle = PendingIntent.getBroadcast(
            this, 0,
            Intent(ACTION_TOGGLE).setPackage(packageName),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val action = RemoteAction(
            Icon.createWithResource(
                this,
                if (playing) android.R.drawable.ic_media_pause else android.R.drawable.ic_media_play,
            ),
            if (playing) "Pause" else "Play",
            if (playing) "Pause" else "Play",
            toggle,
        )
        val b = PictureInPictureParams.Builder()
            .setAspectRatio(aspect)
            .setActions(listOf(action))
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            b.setAutoEnterEnabled(armed)
            b.setSeamlessResizeEnabled(false)
        }
        return b.build()
    }

    private fun applyParams() {
        if (!supported) return
        buildParams()?.let { runCatching { setPictureInPictureParams(it) } }
    }

    private fun enter(): Boolean {
        if (!supported) return false
        registerActions()
        val p = buildParams() ?: return false
        return runCatching { enterPictureInPictureMode(p) }.getOrDefault(false)
    }

    private fun registerActions() {
        if (receiverRegistered) return
        val filter = IntentFilter(ACTION_TOGGLE)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(actionReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            registerReceiver(actionReceiver, filter)
        }
        receiverRegistered = true
    }

    private fun unregisterActions() {
        if (!receiverRegistered) return
        runCatching { unregisterReceiver(actionReceiver) }
        receiverRegistered = false
    }

    // Android 8-11 have no auto-enter: float the player when the user
    // leaves with Home / Recents while it is open.
    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        if (armed && Build.VERSION.SDK_INT < Build.VERSION_CODES.S) enter()
    }

    override fun onPictureInPictureModeChanged(isInPictureInPictureMode: Boolean, newConfig: Configuration) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        if (isInPictureInPictureMode) {
            registerActions()
        } else {
            unregisterActions()
        }
        // Closing the floating window stops the activity; expanding it
        // brings it back to the front.
        val dismissed = !isInPictureInPictureMode && !started
        channel?.invokeMethod(
            "changed",
            mapOf("active" to isInPictureInPictureMode, "dismissed" to dismissed),
        )
    }

    override fun onStart() {
        super.onStart()
        started = true
    }

    override fun onStop() {
        started = false
        super.onStop()
    }

    override fun onDestroy() {
        unregisterActions()
        super.onDestroy()
    }

    private companion object {
        const val ACTION_TOGGLE = "com.iptvplayer.iptv_player.PIP_TOGGLE"
    }
}
