// SPDX-License-Identifier: AGPL-3.0-or-later
package chat.fluffy.fluffychat.round

import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** Strict relocation of the MediaMuxer MP4 index. Reject unfamiliar structures
 * rather than label an unverified container as streamable. No network inputs. */
object RoundMp4FastStart {
    private data class Box(val offset: Long, val size: Long, val type: String, val header: Int)
    private val containers = setOf("moov", "trak", "mdia", "minf", "stbl")

    fun relocate(source: File, destination: File) {
        RandomAccessFile(source, "r").use { input ->
            val boxes = mutableListOf<Box>()
            var offset = 0L
            while (offset < input.length()) {
                val box = readBox(input, offset)
                boxes += box
                offset += box.size
            }
            require(offset == input.length())
            require(boxes.first().type == "ftyp")
            val moov = boxes.single { it.type == "moov" }
            val mdat = boxes.single { it.type == "mdat" }
            require(boxes.none { it.type in setOf("moof", "sidx", "mfra") })
            destination.outputStream().use { output ->
                if (moov.offset < mdat.offset) {
                    copy(input, 0, input.length(), output)
                    return
                }
                require(moov == boxes.last() && moov.size <= 4L * 1024 * 1024)
                val index = ByteArray(moov.size.toInt())
                input.seek(moov.offset); input.readFully(index)
                patch(index, 0, index.size, moov.size, mdat.offset + mdat.header, mdat.offset + mdat.size)
                val ftyp = boxes.first()
                copy(input, ftyp.offset, ftyp.size, output)
                output.write(index)
                boxes.drop(1).filter { it !== moov }.forEach {
                    copy(input, it.offset, it.size, output)
                }
            }
        }
        require(destination.length() == source.length())
    }

    private fun readBox(input: RandomAccessFile, offset: Long): Box {
        require(input.length() - offset >= 8)
        input.seek(offset)
        val length = input.readInt().toLong() and 0xffffffffL
        val name = ByteArray(4); input.readFully(name)
        val header = if (length == 1L) 16 else 8
        val size = when (length) { 0L -> input.length() - offset; 1L -> input.readLong(); else -> length }
        require(size >= header && size <= input.length() - offset)
        return Box(offset, size, String(name, Charsets.US_ASCII), header)
    }

    private fun patch(data: ByteArray, begin: Int, end: Int, delta: Long, mediaBegin: Long, mediaEnd: Long) {
        val bytes = ByteBuffer.wrap(data).order(ByteOrder.BIG_ENDIAN)
        var offset = begin
        while (offset < end) {
            require(end - offset >= 8)
            val length = bytes.getInt(offset).toLong() and 0xffffffffL
            val type = String(data, offset + 4, 4, Charsets.US_ASCII)
            val header = if (length == 1L) 16 else 8
            val size = when (length) { 0L -> (end - offset).toLong(); 1L -> bytes.getLong(offset + 8); else -> length }
            require(size >= header && size <= end - offset)
            val boxEnd = offset + size.toInt()
            val payload = offset + header
            when (type) {
                in containers -> patch(data, payload, boxEnd, delta, mediaBegin, mediaEnd)
                "stco", "co64" -> {
                    require(boxEnd - payload >= 8)
                    require(bytes.getInt(payload) == 0)
                    val count = bytes.getInt(payload + 4)
                    val width = if (type == "stco") 4 else 8
                    require(count >= 0 && count.toLong() * width == boxEnd - payload - 8L)
                    repeat(count) { index ->
                        val location = payload + 8 + index * width
                        val old = if (width == 4) bytes.getInt(location).toLong() and 0xffffffffL else bytes.getLong(location)
                        require(old >= mediaBegin && old < mediaEnd)
                        val next = old + delta
                        require(next >= old)
                        if (width == 4) { require(next <= 0xffffffffL); bytes.putInt(location, next.toInt()) }
                        else bytes.putLong(location, next)
                    }
                }
                "cmov", "moof" -> error("Unsupported MP4 index")
            }
            offset = boxEnd
        }
        require(offset == end)
    }

    private fun copy(input: RandomAccessFile, offset: Long, size: Long, output: java.io.OutputStream) {
        input.seek(offset)
        var remaining = size
        val buffer = ByteArray(65536)
        while (remaining > 0) {
            val count = input.read(buffer, 0, minOf(buffer.size.toLong(), remaining).toInt())
            require(count > 0)
            output.write(buffer, 0, count)
            remaining -= count
        }
    }
}
