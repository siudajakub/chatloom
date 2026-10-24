// SPDX-License-Identifier: AGPL-3.0-or-later
package pl.personal.chatloom.media

import android.annotation.TargetApi
import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream
import java.io.IOException
import java.util.concurrent.Executors

/**
 * One-tap "Save" into shared storage (Telegram style): Pictures/ChatLoom,
 * Movies/ChatLoom or Download/ChatLoom through MediaStore. Android 10+ needs
 * no storage permission for this; older versions answer `false` and Dart
 * falls back to the system "Save as" dialog.
 *
 * `saveToCollection` takes `displayName`, `mimeType`, `collection`
 * (images | video | downloads) and either `bytes` or `path` (a private
 * lease under the app cache, read once; Dart deletes it afterwards).
 * `openFile` takes `path` (a copy under `cache/chatloom_open/`) and
 * `mimeType` and answers whether an app took it.
 */
class MediaStorePlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private var context: Context? = null
    private var channel: MethodChannel? = null
    private val main = Handler(Looper.getMainLooper())
    private val io = Executors.newSingleThreadExecutor()

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL).also {
            it.setMethodCallHandler(this)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        context = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method == "openFile") return openFile(call, result)
        if (call.method != "saveToCollection") return result.notImplemented()
        val appContext = context ?: return result.error("unavailable", null, null)
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return result.success(false)
        val displayName = call.argument<String>("displayName")
        val mimeType = call.argument<String>("mimeType")
        val collection = call.argument<String>("collection")
        val bytes = call.argument<ByteArray>("bytes")
        val path = call.argument<String>("path")
        if (displayName.isNullOrBlank() || mimeType.isNullOrBlank() || collection == null ||
            (bytes == null) == (path == null)) {
            return result.error("invalid_arguments", null, null)
        }
        io.execute {
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    save(appContext, displayName, mimeType, collection, bytes, path)
                    main.post { result.success(true) }
                } else {
                    main.post { result.success(false) }
                }
            } catch (e: Exception) {
                // No paths or names in the error: Dart shows a plain message.
                main.post { result.error("save_failed", e.javaClass.simpleName, null) }
            }
        }
    }

    /** Opens a private copy in the default app (ExternalFileOpener). */
    private fun openFile(call: MethodCall, result: MethodChannel.Result) {
        val appContext = context ?: return result.error("unavailable", null, null)
        val path = call.argument<String>("path")
        val mimeType = call.argument<String>("mimeType")
        if (path.isNullOrBlank() || mimeType.isNullOrBlank()) {
            return result.error("invalid_arguments", null, null)
        }
        try {
            result.success(ExternalFileOpener.open(appContext, path, mimeType))
        } catch (e: Exception) {
            result.error("open_failed", e.javaClass.simpleName, null)
        }
    }

    @TargetApi(Build.VERSION_CODES.Q)
    private fun save(
        context: Context,
        displayName: String,
        mimeType: String,
        collection: String,
        bytes: ByteArray?,
        path: String?,
    ) {
        val volume = MediaStore.VOLUME_EXTERNAL_PRIMARY
        val (target, directory) = when (collection) {
            "images" -> MediaStore.Images.Media.getContentUri(volume) to Environment.DIRECTORY_PICTURES
            "video" -> MediaStore.Video.Media.getContentUri(volume) to Environment.DIRECTORY_MOVIES
            "downloads" -> MediaStore.Downloads.getContentUri(volume) to Environment.DIRECTORY_DOWNLOADS
            else -> throw IllegalArgumentException("collection")
        }
        val source = path?.let { leaseFile(context, it) }
        val resolver = context.contentResolver
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, displayName)
            put(MediaStore.MediaColumns.MIME_TYPE, mimeType)
            put(MediaStore.MediaColumns.RELATIVE_PATH, "$directory/ChatLoom")
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }
        val uri: Uri = resolver.insert(target, values) ?: throw IOException("insert")
        try {
            val out = resolver.openOutputStream(uri) ?: throw IOException("open")
            out.use { stream ->
                if (bytes != null) {
                    stream.write(bytes)
                } else {
                    FileInputStream(source!!).use { it.copyTo(stream) }
                }
            }
            val done = ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }
            resolver.update(uri, done, null, null)
        } catch (e: Exception) {
            // Never leave a pending, half-written entry behind.
            try {
                resolver.delete(uri, null, null)
            } catch (ignored: Exception) {
            }
            throw e
        }
    }

    /** Only a file inside the app's own cache (the Dart lease) is read. */
    private fun leaseFile(context: Context, path: String): File {
        val file = File(path).canonicalFile
        val cache = context.cacheDir.canonicalPath + File.separator
        if (!file.path.startsWith(cache) || !file.isFile) throw IOException("lease")
        return file
    }

    companion object {
        const val CHANNEL = "pl.personal.chat/media_store"
    }
}
