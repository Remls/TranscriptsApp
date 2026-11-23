package io.remls.transcripts

import android.Manifest
import android.app.Activity
import android.app.NotificationManager
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
import android.net.Uri
import android.os.Build
import android.provider.OpenableColumns
import android.util.Rational
import com.ryanheise.audioservice.AudioServiceActivity
import com.ryanheise.audioservice.R as AudioServiceR
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.UUID
import kotlin.concurrent.thread

class MainActivity : AudioServiceActivity() {
    private var channel: MethodChannel? = null

    // Paths of shared files copied into the cache, waiting for Dart to take them.
    // An empty string stands for a file that could not be read.
    private val pending = mutableListOf<String>()

    // The file being saved through the system dialog, and the Dart call waiting on it.
    private var saveSource: File? = null
    private var saveResult: MethodChannel.Result? = null

    private var askedToNotify = false

    // Whether leaving the app shrinks the video into a floating window, and the video's size.
    private var pipChannel: MethodChannel? = null
    private var pipActive = false
    private var pipWidth = 0
    private var pipHeight = 0
    private var pipPlaying = false

    // Receives taps on the floating window's buttons.
    private val pipReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            pipChannel?.invokeMethod("action", intent.getStringExtra(EXTRA_PIP_ACTION))
        }
    }
    private var nextResultId = 100

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "transcripts/share").also {
            it.setMethodCallHandler { call, result ->
                if (call.method == "takePending") {
                    result.success(pending.toList())
                    pending.clear()
                } else {
                    result.notImplemented()
                }
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "transcripts/files")
            .setMethodCallHandler { call, result ->
                if (call.method == "saveAs") {
                    saveSource = File(call.argument<String>("path")!!)
                    saveResult = result
                    val intent = Intent(Intent.ACTION_CREATE_DOCUMENT)
                        .addCategory(Intent.CATEGORY_OPENABLE)
                        .setType(call.argument<String>("mimeType"))
                        .putExtra(Intent.EXTRA_TITLE, call.argument<String>("name"))
                    startActivityForResult(intent, REQUEST_SAVE)
                } else {
                    result.notImplemented()
                }
            }
        JobService.createChannels(this)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "transcripts/jobs")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "keepAlive" -> {
                        askToNotify()
                        startForegroundService(
                            Intent(this, JobService::class.java)
                                .putExtra(JobService.EXTRA_TEXT, call.argument<String>("text")),
                        )
                        result.success(null)
                    }
                    "release" -> {
                        stopService(Intent(this, JobService::class.java))
                        result.success(null)
                    }
                    "announce" -> {
                        getSystemService(NotificationManager::class.java).notify(
                            nextResultId++,
                            JobService.resultNotification(
                                this,
                                call.argument<String>("title")!!,
                                call.argument<String>("text")!!,
                            ),
                        )
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        pipChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "transcripts/pip").also {
            it.setMethodCallHandler { call, result ->
                if (call.method == "setVideo") {
                    pipActive = call.argument<Boolean>("active")!!
                    pipPlaying = call.argument<Boolean>("playing")!!
                    val width = call.argument<Int>("width")!!
                    val height = call.argument<Int>("height")!!
                    if (width > 0 && height > 0) {
                        pipWidth = width
                        pipHeight = height
                    }
                    setPictureInPictureParams(pipParams())
                    result.success(null)
                } else {
                    result.notImplemented()
                }
            }
        }
        val filter = IntentFilter(ACTION_PIP)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(pipReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            registerReceiver(pipReceiver, filter)
        }
        receive(intent)
    }

    override fun onDestroy() {
        unregisterReceiver(pipReceiver)
        super.onDestroy()
    }

    // A floating window button that sends [action] to Dart.
    private fun pipAction(action: String, requestCode: Int, icon: Int, title: String): RemoteAction {
        val intent = PendingIntent.getBroadcast(
            this,
            requestCode,
            Intent(ACTION_PIP).setPackage(packageName).putExtra(EXTRA_PIP_ACTION, action),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        return RemoteAction(Icon.createWithResource(this, icon), title, title, intent)
    }

    // The video's aspect ratio, clamped to the range Android accepts.
    private fun pipAspectRatio(): Rational? {
        if (pipWidth <= 0 || pipHeight <= 0) return null
        return when {
            pipWidth * 100L > pipHeight * 239L -> Rational(239, 100)
            pipHeight * 100L > pipWidth * 239L -> Rational(100, 239)
            else -> Rational(pipWidth, pipHeight)
        }
    }

    private fun pipParams(): PictureInPictureParams {
        val builder = PictureInPictureParams.Builder()
        pipAspectRatio()?.let { builder.setAspectRatio(it) }
        builder.setActions(
            listOf(
                pipAction("back", 10, AudioServiceR.drawable.audio_service_fast_rewind, "Back 10 seconds"),
                if (pipPlaying) {
                    pipAction("pause", 11, AudioServiceR.drawable.audio_service_pause, "Pause")
                } else {
                    pipAction("play", 12, AudioServiceR.drawable.audio_service_play_arrow, "Play")
                },
                pipAction("forward", 13, AudioServiceR.drawable.audio_service_fast_forward, "Forward 10 seconds"),
            ),
        )
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            builder.setAutoEnterEnabled(pipActive)
            builder.setSeamlessResizeEnabled(true)
        }
        return builder.build()
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S && pipActive) {
            enterPictureInPictureMode(pipParams())
        }
    }

    override fun onPictureInPictureModeChanged(isInPictureInPictureMode: Boolean, newConfig: Configuration) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        pipChannel?.invokeMethod("modeChanged", isInPictureInPictureMode)
    }

    // Asks once per launch for permission to show notifications.
    private fun askToNotify() {
        if (askedToNotify) return
        askedToNotify = true
        if (checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), REQUEST_NOTIFY)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQUEST_SAVE) return
        val source = saveSource
        val result = saveResult
        saveSource = null
        saveResult = null
        val uri = data?.data
        if (source == null || result == null) return
        if (resultCode != Activity.RESULT_OK || uri == null) {
            result.success(false)
            return
        }
        thread {
            try {
                contentResolver.openOutputStream(uri)!!.use { output ->
                    source.inputStream().use { input -> input.copyTo(output) }
                }
                runOnUiThread { result.success(true) }
            } catch (e: Exception) {
                runOnUiThread { result.error("save_failed", e.message, null) }
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        receive(intent)
    }

    @Suppress("DEPRECATION")
    private fun sharedUris(intent: Intent): List<Uri> = when (intent.action) {
        Intent.ACTION_SEND -> listOfNotNull(intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM))
        Intent.ACTION_SEND_MULTIPLE ->
            intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM).orEmpty()
        else -> emptyList()
    }

    private fun receive(intent: Intent?) {
        if (intent == null || intent.getBooleanExtra(EXTRA_HANDLED, false)) return
        val uris = sharedUris(intent)
        if (uris.isEmpty()) return
        intent.putExtra(EXTRA_HANDLED, true)
        thread {
            val paths = uris.map { copyToCache(it) ?: "" }
            runOnUiThread {
                pending.addAll(paths)
                channel?.invokeMethod("shared", null)
            }
        }
    }

    private fun displayName(uri: Uri): String? {
        contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use {
            if (it.moveToFirst() && !it.isNull(0)) return it.getString(0)
        }
        return uri.lastPathSegment
    }

    private fun copyToCache(uri: Uri): String? {
        val dir = File(cacheDir, "shared/${UUID.randomUUID()}")
        return try {
            val target = File(dir.apply { mkdirs() }, File(displayName(uri) ?: "shared").name)
            contentResolver.openInputStream(uri)!!.use { input ->
                target.outputStream().use { output -> input.copyTo(output) }
            }
            target.path
        } catch (e: Exception) {
            dir.deleteRecursively()
            null
        }
    }

    private companion object {
        const val EXTRA_HANDLED = "io.remls.transcripts.HANDLED"
        const val REQUEST_SAVE = 1
        const val REQUEST_NOTIFY = 2
        const val ACTION_PIP = "io.remls.transcripts.PIP_ACTION"
        const val EXTRA_PIP_ACTION = "action"
    }
}
