// SPDX-License-Identifier: AGPL-3.0-or-later
package pl.personal.chatloom.media

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import androidx.core.content.FileProvider
import java.io.File
import java.io.IOException

/**
 * Serves ChatLoom's short-lived "open in another app" copies
 * (`cache/chatloom_open/`, see `res/xml/chatloom_open_paths.xml`) as
 * read-only content URIs. Its own subclass, so its manifest entry never
 * merges with a plugin's FileProvider.
 */
class OpenFileProvider : FileProvider()

/** `openFile`: ACTION_VIEW on one copy; false when no app takes the type. */
object ExternalFileOpener {
    private const val FOLDER = "chatloom_open"

    fun open(context: Context, path: String, mimeType: String): Boolean {
        val root = File(context.cacheDir, FOLDER).canonicalPath + File.separator
        val file = File(path).canonicalFile
        // Only a Dart copy inside the private folder, never another file.
        if (!file.path.startsWith(root) || !file.isFile) throw IOException("copy")
        val uri = FileProvider.getUriForFile(context, "${context.packageName}.open_files", file)
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, mimeType)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        return try {
            context.startActivity(intent)
            true
        } catch (e: ActivityNotFoundException) {
            false
        }
    }
}
