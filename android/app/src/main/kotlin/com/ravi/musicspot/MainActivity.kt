package com.ravi.musicspot

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * UpZe host activity. Besides the stock FlutterActivity behaviour it serves
 * two small platform channels the Dart side needs:
 *
 *  - `upze/romanizer` — ICU transliteration for non-Latin lyrics
 *    (see RomanizerBridge.kt; a faithful port of the Kotlin app's
 *    lyrics/Romanizer.kt).
 *  - `upze/installer` — the last, Android-only step of the in-app updater:
 *    hand a downloaded APK to the system installer via a FileProvider
 *    content:// URI (authority "<applicationId>.updates", paths in
 *    res/xml/upze_paths.xml).
 */
class MainActivity : FlutterActivity() {

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        MethodChannel(messenger, "upze/romanizer").setMethodCallHandler { call, result ->
            when (call.method) {
                "isAvailable" -> result.success(RomanizerBridge.available)
                "romanize" -> {
                    // Argument: the List<String> of lyric lines, passed directly.
                    val texts = (call.arguments as? List<*>)
                        ?.map { it as? String ?: "" }
                        ?: emptyList()
                    result.success(RomanizerBridge.lines(texts))
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(messenger, "upze/media").setMethodCallHandler { call, result ->
            when (call.method) {
                "songs" -> {
                    // MediaStore query can block on large libraries; keep it
                    // off the platform thread.
                    Thread {
                        val rows = runCatching { MediaBridge.songs(this) }
                            .getOrDefault(emptyList())
                        runOnUiThread { result.success(rows) }
                    }.start()
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(messenger, "upze/installer").setMethodCallHandler { call, result ->
            when (call.method) {
                "canInstall" -> result.success(canInstallPackages())
                "openInstallSettings" -> {
                    openInstallSettings()
                    result.success(true)
                }
                "installApk" -> {
                    // Argument: the APK's absolute file path, passed directly.
                    val path = call.arguments as? String
                    result.success(path != null && installApk(path))
                }
                else -> result.notImplemented()
            }
        }
    }

    /** API 26+: the user must have allowed installs from this app. Below that, always true. */
    private fun canInstallPackages(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.O ||
            packageManager.canRequestPackageInstalls()

    /** Sends the user to the "install unknown apps" toggle for UpZe (API 26+). */
    private fun openInstallSettings() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val intent = Intent(
            Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
            Uri.parse("package:$packageName"),
        ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        runCatching { startActivity(intent) }
    }

    /**
     * Opens the system installer for the APK at [path]. Returns false when
     * the file is missing or no installer activity accepts it.
     */
    private fun installApk(path: String): Boolean {
        val file = File(path)
        if (!file.isFile) return false
        return runCatching {
            val uri = FileProvider.getUriForFile(this, "$packageName.updates", file)
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(intent)
            true
        }.getOrDefault(false)
    }
}
