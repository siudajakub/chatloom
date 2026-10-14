// SPDX-License-Identifier: AGPL-3.0-or-later
package chat.fluffy.fluffychat.round

import java.io.File
import java.nio.file.Files

private val originalMedia = "validated synthetic MP4 bytes; no account media".toByteArray()
private val originalThumbnail = "validated synthetic thumbnail bytes".toByteArray()
private var checks = 0

private fun verify(condition: Boolean, label: String) {
    checks++
    check(condition) { label }
}

private fun rejected(label: String, action: () -> Unit) {
    var failed = false
    try { action() } catch (_: IllegalStateException) { failed = true }
    catch (_: IllegalArgumentException) { failed = true }
    verify(failed, label)
}

private fun fixture(root: File, name: String, action: (File, File, File) -> Unit) {
    val directory = File(root, name).apply { check(mkdir()) }
    val output = File(directory, "media.mp4").apply { writeBytes(originalMedia) }
    val thumbnail = File(directory, "thumb.jpg").apply { writeBytes(originalThumbnail) }
    action(directory, output, thumbnail)
}

/** Filesystem fault/commit behavior of the production trim transaction.
 * Byte strings are synthetic; this test makes no codec or playback claim. */
fun main() {
    val root = Files.createTempDirectory("round-trim-fixture-").toFile()
    try {
        fixture(root, "rollback", action = { directory, output, thumbnail ->
            val transaction = RoundTrimTransaction(output, thumbnail)
            verify(transaction.source.readBytes().contentEquals(originalMedia), "original media survives begin")
            verify(File(directory, "trim.source.jpg").readBytes().contentEquals(originalThumbnail), "original thumbnail survives begin")
            transaction.candidate.writeText("partial failed encoder output")
            thumbnail.writeText("candidate thumbnail before encoder/probe failure")
            transaction.rollback()
            verify(output.readBytes().contentEquals(originalMedia), "encode failure restores validated bytes")
            verify(thumbnail.readBytes().contentEquals(originalThumbnail), "encode failure restores validated thumbnail")
            verify(directory.list()!!.toSet() == setOf("media.mp4", "thumb.jpg"), "rollback removes candidate/backup residue")
            transaction.rollback()
            verify(output.readBytes().contentEquals(originalMedia), "late duplicate rollback cannot lose restored bytes")
        })
        fixture(root, "commit", action = { directory, output, thumbnail ->
            val transaction = RoundTrimTransaction(output, thumbnail)
            val trimmed = "validated synthetic trimmed MP4".toByteArray()
            val trimmedThumbnail = "validated synthetic trimmed thumbnail".toByteArray()
            transaction.candidate.writeBytes(trimmed)
            thumbnail.writeBytes(trimmedThumbnail)
            transaction.commit()
            verify(output.readBytes().contentEquals(trimmed), "successful trim publishes candidate bytes")
            verify(thumbnail.readBytes().contentEquals(trimmedThumbnail), "successful trim publishes candidate thumbnail")
            verify(directory.list()!!.toSet() == setOf("media.mp4", "thumb.jpg"), "commit removes originals only after replacement")
            transaction.rollback()
            verify(output.readBytes().contentEquals(trimmed), "late failure cannot roll back an accepted commit")
            rejected("duplicate commit rejected") { transaction.commit() }
            verify(output.readBytes().contentEquals(trimmed), "duplicate commit retains accepted bytes")
        })
        fixture(root, "not-valid", action = { _, output, thumbnail ->
            val transaction = RoundTrimTransaction(output, thumbnail)
            rejected("commit without candidate/thumbnail rejected") { transaction.commit() }
            verify(transaction.source.readBytes().contentEquals(originalMedia), "invalid candidate cannot consume original")
            transaction.candidate.writeText("candidate without validated thumbnail")
            rejected("commit without thumbnail rejected") { transaction.commit() }
            transaction.rollback()
            verify(output.readBytes().contentEquals(originalMedia) && thumbnail.readBytes().contentEquals(originalThumbnail),
                "validation failure retains both review assets")
        })
        fixture(root, "cancel", action = { directory, output, thumbnail ->
            val transaction = RoundTrimTransaction(output, thumbnail)
            transaction.candidate.writeText("late candidate")
            thumbnail.writeText("late candidate thumbnail")
            transaction.discard()
            verify(directory.list()!!.isEmpty(), "explicit cancel removes original/candidate/thumbnail bytes")
            transaction.rollback()
            verify(!output.exists() && !thumbnail.exists(), "late rollback after cancel cannot revive review")
            rejected("late commit after cancel rejected") { transaction.commit() }
            verify(directory.list()!!.isEmpty(), "late commit after cancel cannot revive bytes")
        })
        fixture(root, "stale-backup", action = { directory, output, thumbnail ->
            val stale = File(directory, "trim.source.mp4").apply { writeText("other transaction bytes") }
            rejected("existing transaction backup rejected") { RoundTrimTransaction(output, thumbnail) }
            verify(output.readBytes().contentEquals(originalMedia) && thumbnail.readBytes().contentEquals(originalThumbnail),
                "refused transaction preserves original review")
            verify(stale.readText() == "other transaction bytes", "refused transaction never overwrites pending backup")
        })
        println("PASS native trim retention: $checks assertions; byte/thumbnail rollback, accepted commit, invalid candidate, cancel/late callbacks, stale backup preservation")
    } finally { root.deleteRecursively() }
}
