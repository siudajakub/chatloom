// SPDX-License-Identifier: AGPL-3.0-or-later
package pl.personal.chatloom.round

import java.io.File

/** A failed trim never consumes the last validated recording or its thumbnail. */
internal class RoundTrimTransaction(private val output: File, private val thumbnail: File) {
    val source = File(output.parentFile, "trim.source.mp4")
    val candidate = File(output.parentFile, "trim.candidate.mp4")
    private val oldThumbnail = File(output.parentFile, "trim.source.jpg")
    private var ended = false

    init {
        require(output.isFile && !source.exists() && !candidate.exists() && !oldThumbnail.exists())
        require(output.renameTo(source))
        try {
            if (thumbnail.exists()) require(thumbnail.renameTo(oldThumbnail))
        } catch (error: Exception) {
            check(source.renameTo(output))
            throw error
        }
    }

    fun commit() {
        check(!ended && candidate.isFile && thumbnail.isFile)
        require(candidate.renameTo(output))
        ended = true
        source.delete(); oldThumbnail.delete()
    }

    fun rollback() {
        if (ended) return
        candidate.delete(); output.delete(); thumbnail.delete()
        require(source.renameTo(output))
        if (oldThumbnail.exists()) require(oldThumbnail.renameTo(thumbnail))
        ended = true
    }

    /** Used only for an explicit canceled lease, never an encode or device error. */
    fun discard() {
        if (!ended) { output.delete(); thumbnail.delete() }
        candidate.delete(); source.delete(); oldThumbnail.delete()
        ended = true
    }
}
