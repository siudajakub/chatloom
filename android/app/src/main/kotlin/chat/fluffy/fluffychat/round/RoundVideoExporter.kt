// SPDX-License-Identifier: AGPL-3.0-or-later
package chat.fluffy.fluffychat.round

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.PorterDuff
import android.graphics.PorterDuffXfermode
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.media.MediaMuxer
import java.io.File
import java.nio.ByteBuffer
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.min

data class RoundProfile(val side: Int, val maxBytes: Long, val maxDurationMs: Int, val videoBitrate: Int, val audioBitrate: Int) {
    fun validate() {
        require(side in 128..640 && side % 2 == 0)
        require(maxDurationMs in 800..60000 && maxBytes > 0)
        require(videoBitrate >= 100000 && audioBitrate >= 16000)
    }
}

/** Camera source is never exposed to Dart or uploaded. Every frame is decoded,
 * center-cropped, oriented and circle-masked on the encoder's actual surface. */
object RoundVideoExporter {
    private const val MAX_DURATION_US = 60000000L

    fun export(source: File, output: File, profile: RoundProfile, canceled: AtomicBoolean, startMs: Int, endMs: Int): Map<String, Any> {
        profile.validate()
        require(startMs >= 0 && endMs - startMs >= 800)
        val intermediate = File(output.parentFile, "export.muxed.mp4")
        val rangeUs = min((endMs - startMs) * 1000L, min(profile.maxDurationMs * 1000L, MAX_DURATION_US))
        // AAC passthrough is bounded by the negotiated recorder bitrate. Account
        // for container/index overhead and reject final oversize after probing.
        val budgetBitrate = ((profile.maxBytes * 8L * 1000000L / rangeUs) * 85L / 100L - profile.audioBitrate).toInt()
        require(budgetBitrate >= 100000)
        var bitrate = min(profile.videoBitrate, budgetBitrate)
        try {
            repeat(2) {
                if (canceled.get()) error("Canceled")
                transcode(source, intermediate, profile.side, bitrate, canceled, startMs * 1000L, startMs * 1000L + rangeUs, profile.maxDurationMs * 1000L)
                RoundMp4FastStart.relocate(intermediate, output)
                intermediate.delete()
                if (output.length() <= profile.maxBytes) {
                    val descriptor = probe(output, profile)
                    val thumbnail = thumbnail(output)
                    require(!canceled.get())
                    return descriptor + mapOf(
                        "path" to output.path,
                        "thumbnailPath" to thumbnail.path,
                        "cornersSanitized" to true,
                        "fastStart" to true,
                    )
                }
                bitrate = (bitrate * profile.maxBytes / output.length() * 80L / 100L).toInt()
                output.delete()
                require(bitrate >= 100000)
            }
            error("Media budget exceeded")
        } finally {
            intermediate.delete()
            if (canceled.get()) {
                output.delete()
                File(output.parentFile, "thumb.jpg").delete()
            }
        }
    }

    private fun transcode(source: File, output: File, side: Int, bitrate: Int, canceled: AtomicBoolean, startUs: Long, endUs: Long, maxOutputDurationUs: Long) {
        val video = MediaExtractor()
        val audio = MediaExtractor()
        var decoder: MediaCodec? = null
        var encoder: MediaCodec? = null
        var gl: RoundEncoderSurface? = null
        var muxer: MediaMuxer? = null
        var muxerStarted = false
        try {
            video.setDataSource(source.path)
            audio.setDataSource(source.path)
            val videoTrack = (0 until video.trackCount).first { video.getTrackFormat(it).getString(MediaFormat.KEY_MIME) == "video/avc" }
            val audioTrack = (0 until audio.trackCount).first { audio.getTrackFormat(it).getString(MediaFormat.KEY_MIME) == "audio/mp4a-latm" }
            val sourceFormat = video.getTrackFormat(videoTrack)
            val sourceWidth = sourceFormat.getInteger(MediaFormat.KEY_WIDTH)
            val sourceHeight = sourceFormat.getInteger(MediaFormat.KEY_HEIGHT)
            val rotation = if (sourceFormat.containsKey(MediaFormat.KEY_ROTATION)) sourceFormat.getInteger(MediaFormat.KEY_ROTATION) else 0
            // Disable decoder rotation: the shader physically writes it, rather
            // than depending on a player honouring an MP4 display matrix.
            sourceFormat.setInteger(MediaFormat.KEY_ROTATION, 0)
            video.selectTrack(videoTrack)
            video.seekTo(startUs, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
            audio.selectTrack(audioTrack)
            audio.seekTo(startUs, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
            val outputFormat = MediaFormat.createVideoFormat("video/avc", side, side).apply {
                setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
                setInteger(MediaFormat.KEY_BIT_RATE, bitrate)
                setInteger(MediaFormat.KEY_FRAME_RATE, 30)
                setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
            }
            encoder = MediaCodec.createEncoderByType("video/avc")
            encoder.configure(outputFormat, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            val encoderInput = encoder.createInputSurface()
            gl = RoundEncoderSurface(encoderInput, side, sourceWidth, sourceHeight, rotation)
            encoder.start()
            decoder = MediaCodec.createDecoderByType("video/avc")
            decoder.configure(sourceFormat, gl.decoderSurface, null, 0)
            decoder.start()
            muxer = MediaMuxer(output.path, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
            val muxAudio = muxer.addTrack(audio.getTrackFormat(audioTrack))
            var muxVideo = -1
            var inputDone = false
            var decoderDone = false
            var encoderDone = false
            var baseTimestamp = -1L
            var lastVideoPts = -1L
            var lastProgress = System.nanoTime()
            val decodedInfo = MediaCodec.BufferInfo()
            val encodedInfo = MediaCodec.BufferInfo()
            while (!encoderDone) {
                require(!canceled.get())
                var progress = false
                if (!inputDone) {
                    val index = decoder.dequeueInputBuffer(1000)
                    if (index >= 0) {
                        val buffer = decoder.getInputBuffer(index)!!
                        val size = video.readSampleData(buffer, 0)
                        val time = video.sampleTime
                        if (size < 0 || time >= endUs) {
                            decoder.queueInputBuffer(index, 0, 0, maxOf(0L, time), MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            inputDone = true
                        } else {
                            decoder.queueInputBuffer(index, 0, size, time, 0)
                            video.advance()
                        }
                        progress = true
                    }
                }
                if (!decoderDone) {
                    val index = decoder.dequeueOutputBuffer(decodedInfo, 1000)
                    if (index >= 0) {
                        // Reserve a final nominal frame only at the hard cap;
                        // short clips/trim need their full selected interval.
                        val renderEnd = min(endUs, startUs + maxOutputDurationUs - 33334L)
                        val render = decodedInfo.size > 0 && decodedInfo.presentationTimeUs >= startUs && decodedInfo.presentationTimeUs < renderEnd
                        decoder.releaseOutputBuffer(index, render)
                        if (render) {
                            gl.awaitFrame(canceled)
                            if (baseTimestamp < 0) baseTimestamp = decodedInfo.presentationTimeUs
                            val timestamp = decodedInfo.presentationTimeUs - baseTimestamp
                            if (timestamp > lastVideoPts) {
                                gl.draw(timestamp * 1000L)
                                lastVideoPts = timestamp
                            }
                        }
                        if (decodedInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) {
                            decoderDone = true
                            encoder.signalEndOfInputStream()
                        }
                        progress = true
                    }
                }
                var draining = true
                while (draining) {
                    val index = encoder.dequeueOutputBuffer(encodedInfo, 1000)
                    when {
                        index == MediaCodec.INFO_TRY_AGAIN_LATER -> draining = false
                        index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                            check(!muxerStarted)
                            muxVideo = muxer.addTrack(encoder.outputFormat)
                            muxer.start()
                            muxerStarted = true
                            progress = true
                        }
                        index >= 0 -> {
                            val buffer = encoder.getOutputBuffer(index)!!
                            if (encodedInfo.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) encodedInfo.size = 0
                            if (encodedInfo.size > 0) {
                                check(muxerStarted)
                                buffer.position(encodedInfo.offset)
                                buffer.limit(encodedInfo.offset + encodedInfo.size)
                                muxer.writeSampleData(muxVideo, buffer, encodedInfo)
                            }
                            encoderDone = encodedInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0
                            encoder.releaseOutputBuffer(index, false)
                            progress = true
                        }
                    }
                }
                if (progress) lastProgress = System.nanoTime()
                require(System.nanoTime() - lastProgress < 15000000000L)
            }
            require(baseTimestamp >= 0 && lastVideoPts > 0 && muxerStarted)
            // Use the actual first video frame as the common timeline origin;
            // paused intervals were already removed by MediaRecorder.
            val audioFormat = audio.getTrackFormat(audioTrack)
            val maxInput = if (audioFormat.containsKey(MediaFormat.KEY_MAX_INPUT_SIZE)) audioFormat.getInteger(MediaFormat.KEY_MAX_INPUT_SIZE) else 65536
            val audioBuffer = ByteBuffer.allocate(maxOf(maxInput, 65536))
            val audioInfo = MediaCodec.BufferInfo()
            var audioSamples = 0
            var lastAudioPts = -1L
            val audioFrameUs = 1024000000L / audioFormat.getInteger(MediaFormat.KEY_SAMPLE_RATE) + 1
            while (audio.sampleTime >= 0 && audio.sampleTime < endUs) {
                require(!canceled.get())
                val time = audio.sampleTime
                val size = audio.readSampleData(audioBuffer, 0)
                if (size < 0) break
                val pts = time - baseTimestamp
                if (pts >= 0 && pts > lastAudioPts && pts + audioFrameUs <= min(endUs - baseTimestamp, lastVideoPts + 33333)) {
                    audioInfo.set(0, size, pts, if (audio.sampleFlags and MediaExtractor.SAMPLE_FLAG_SYNC != 0) MediaCodec.BUFFER_FLAG_KEY_FRAME else 0)
                    audioBuffer.position(0); audioBuffer.limit(size)
                    muxer.writeSampleData(muxAudio, audioBuffer, audioInfo)
                    lastAudioPts = pts
                    audioSamples++
                }
                audio.advance()
                audioBuffer.clear()
            }
            require(audioSamples > 0)
        } finally {
            try { decoder?.stop() } catch (_: Exception) { }
            decoder?.release()
            try { encoder?.stop() } catch (_: Exception) { }
            encoder?.release()
            gl?.close()
            if (muxerStarted) try { muxer?.stop() } catch (_: Exception) { }
            muxer?.release()
            video.release(); audio.release()
        }
    }

    private fun probe(file: File, profile: RoundProfile): Map<String, Any> {
        val extractor = MediaExtractor()
        val retriever = MediaMetadataRetriever()
        try {
            extractor.setDataSource(file.path)
            val formats = (0 until extractor.trackCount).map { extractor.getTrackFormat(it) }
            require(formats.size == 2)
            val video = formats.single { it.getString(MediaFormat.KEY_MIME) == "video/avc" }
            formats.single { it.getString(MediaFormat.KEY_MIME) == "audio/mp4a-latm" }
            val width = video.getInteger(MediaFormat.KEY_WIDTH)
            val height = video.getInteger(MediaFormat.KEY_HEIGHT)
            retriever.setDataSource(file.path)
            val duration = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)!!.toInt()
            val rotation = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)?.toIntOrNull() ?: 0
            require(width == height && width == profile.side && rotation == 0)
            require(duration in 800..profile.maxDurationMs)
            require(file.length() in 1..profile.maxBytes)
            // Decode actual encoded output, including a middle and final frame.
            // Fail closed if a codec/surface implementation bypasses the mask.
            listOf(0L, duration * 500L, maxOf(0, duration - 100) * 1000L).forEach { time ->
                val frame = retriever.getFrameAtTime(time, MediaMetadataRetriever.OPTION_CLOSEST) ?: error("decode")
                try { requireSanitizedCorners(frame) } finally { frame.recycle() }
            }
            return mapOf("width" to width, "height" to height, "durationMs" to duration,
                "sizeBytes" to file.length(), "videoCodec" to "h264", "audioCodec" to "aac")
        } finally { extractor.release(); retriever.release() }
    }

    private fun thumbnail(file: File): File {
        val retriever = MediaMetadataRetriever()
        try {
            retriever.setDataSource(file.path)
            val decoded = retriever.getFrameAtTime(0, MediaMetadataRetriever.OPTION_CLOSEST_SYNC) ?: error("thumbnail")
            val bitmap = Bitmap.createBitmap(decoded.width, decoded.height, Bitmap.Config.ARGB_8888)
            val canvas = Canvas(bitmap)
            canvas.drawColor(Color.BLACK)
            val layer = canvas.saveLayer(0f, 0f, bitmap.width.toFloat(), bitmap.height.toFloat(), null)
            canvas.drawCircle(bitmap.width / 2f, bitmap.height / 2f, bitmap.width / 2f, Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.WHITE })
            val mask = Paint(Paint.ANTI_ALIAS_FLAG).apply { xfermode = PorterDuffXfermode(PorterDuff.Mode.SRC_IN) }
            canvas.drawBitmap(decoded, 0f, 0f, mask)
            canvas.restoreToCount(layer)
            val thumb = File(file.parentFile, "thumb.jpg")
            thumb.outputStream().use { require(bitmap.compress(Bitmap.CompressFormat.JPEG, 90, it)) }
            decoded.recycle(); bitmap.recycle()
            val encodedThumb = BitmapFactory.decodeFile(thumb.path) ?: error("thumbnail")
            try { requireSanitizedCorners(encodedThumb) } finally { encodedThumb.recycle() }
            return thumb
        } finally { retriever.release() }
    }

    private fun requireSanitizedCorners(bitmap: Bitmap) {
        val points = listOf(2 to 2, bitmap.width - 3 to 2,
            2 to bitmap.height - 3, bitmap.width - 3 to bitmap.height - 3)
        points.forEach { (x, y) ->
            val color = bitmap.getPixel(x, y)
            require(Color.red(color) <= 24 && Color.green(color) <= 24 && Color.blue(color) <= 24)
        }
    }
}
