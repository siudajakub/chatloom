// SPDX-License-Identifier: AGPL-3.0-or-later
package pl.personal.chatloom.round

import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.file.Files

private fun atom(type: String, bytes: ByteArray): ByteArray =
    ByteBuffer.allocate(bytes.size + 8).order(ByteOrder.BIG_ENDIAN).putInt(bytes.size + 8)
        .put(type.toByteArray(Charsets.US_ASCII)).put(bytes).array()

private fun index(offset: Long, wide: Boolean = false): ByteArray {
    val bytes = ByteBuffer.allocate(if (wide) 16 else 12).order(ByteOrder.BIG_ENDIAN).putInt(0).putInt(1)
    if (wide) bytes.putLong(offset) else bytes.putInt(offset.toInt())
    var nested = atom(if (wide) "co64" else "stco", bytes.array())
    listOf("stbl", "minf", "mdia", "trak", "moov").forEach { nested = atom(it, nested) }
    return nested
}

private fun rejected(block: () -> Unit) {
    var didReject = false
    try { block() } catch (_: IllegalArgumentException) { didReject = true }
    check(didReject)
}

fun main() {
    val root = Files.createTempDirectory("round-mp4-fixture-").toFile()
    try {
        val ftyp = atom("ftyp", "isom0000".toByteArray())
        val sample = "synthetic video sample only".toByteArray()
        val mdat = atom("mdat", sample)
        val source = File(root, "source.mp4")
        val output = File(root, "ready.mp4")
        for (wide in listOf(false, true)) {
            val moov = index(ftyp.size + 8L, wide)
            source.writeBytes(ftyp + mdat + moov)
            RoundMp4FastStart.relocate(source, output)
            val result = output.readBytes()
            check(String(result, ftyp.size + 4, 4) == "moov")
            check(result.copyOfRange(ftyp.size + moov.size + 8, result.size).contentEquals(sample))
            val marker = if (wide) "co64" else "stco"
            val markerOffset = result.toString(Charsets.ISO_8859_1).indexOf(marker)
            val bytes = ByteBuffer.wrap(result).order(ByteOrder.BIG_ENDIAN)
            val chunkOffset = if (wide) bytes.getLong(markerOffset + 12) else bytes.getInt(markerOffset + 12).toLong()
            check(chunkOffset == ftyp.size + moov.size + 8L)
            source.writeBytes(result)
            RoundMp4FastStart.relocate(source, output)
            check(output.readBytes().contentEquals(result))
        }
        source.writeBytes(ftyp + mdat + index(1))
        rejected { RoundMp4FastStart.relocate(source, output) }
        source.writeBytes(ftyp + mdat + index(ftyp.size + 8L).dropLast(1).toByteArray())
        rejected { RoundMp4FastStart.relocate(source, output) }
        source.writeBytes(ftyp + atom("moof", byteArrayOf()) + mdat + index(ftyp.size + 16L))
        rejected { RoundMp4FastStart.relocate(source, output) }
        RoundProfile(384, 25000000, 60000, 1000000, 64000).validate()
        RoundProfile(384, 25000000, 800, 1000000, 64000).validate()
        rejected { RoundProfile(384, 25000000, 799, 1000000, 64000).validate() }
        rejected { RoundProfile(641, 25000000, 60000, 1000000, 64000).validate() }
        rejected { RoundProfile(384, 25000000, 60001, 1000000, 64000).validate() }
        rejected { RoundProfile(384, 0, 60000, 1000000, 64000).validate() }

        // Direct recording finalize: MediaRecorder's reserved-header layout (moov, free,
        // mdat) is moved by rename, byte for byte; a trailing index is relocated; any
        // malformed or fragmented layout is rejected without touching the source.
        val headerFirst = ftyp + index(ftyp.size + 24L) + atom("free", ByteArray(8)) + mdat
        source.writeBytes(headerFirst)
        output.writeBytes("stale".toByteArray())
        RoundMp4FastStart.finalize(source, output)
        check(!source.exists() && output.readBytes().contentEquals(headerFirst)) { "moov-first finalize must rename unchanged" }
        val trailing = ftyp + mdat + index(ftyp.size + 8L)
        source.writeBytes(trailing)
        RoundMp4FastStart.finalize(source, output)
        val finalized = output.readBytes()
        check(!source.exists() && finalized.size == trailing.size && String(finalized, ftyp.size + 4, 4) == "moov") {
            "trailing index must be relocated"
        }
        val fragmented = ftyp + atom("moof", byteArrayOf()) + mdat + index(ftyp.size + 16L)
        source.writeBytes(fragmented)
        output.delete()
        rejected { RoundMp4FastStart.finalize(source, output) }
        check(source.readBytes().contentEquals(fragmented) && !output.exists()) { "rejected finalize keeps the source" }
        source.writeBytes(ftyp + index(ftyp.size + 8L) + mdat + index(ftyp.size + 8L))
        rejected { RoundMp4FastStart.finalize(source, output) }
        println("PASS native round: stco/co64 relocation, preserved sample offsets, faststart identity, malformed/outside/fragment rejection, profile limits, direct finalize rename/relocate/reject")
    } finally { root.deleteRecursively() }
}
