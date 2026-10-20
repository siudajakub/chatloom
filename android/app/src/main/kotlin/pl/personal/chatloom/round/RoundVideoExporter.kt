// SPDX-License-Identifier: AGPL-3.0-or-later
package pl.personal.chatloom.round

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Matrix
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

/** Missing quality flags keep the previous behaviour: no stabilization, plain camcorder audio. */
data class RoundProfile(val side: Int, val maxBytes: Long, val maxDurationMs: Int, val videoBitrate: Int, val audioBitrate: Int,
                        val stabilize: Boolean = false, val noiseReduction: Boolean = false,
                        val highQuality: Boolean = false) {
    fun validate() {
        require(side in 128..640 && side % 2 == 0)
        require(maxDurationMs in TELEGRAM_MIN_DURATION_MS..TELEGRAM_MAX_DURATION_MS && maxBytes > 0)
        require(videoBitrate in 100000..MAX_VIDEO_BITRATE && audioBitrate in 16000..MAX_AUDIO_BITRATE)
    }

    /**
     * Telegram parity: the recorder encodes the final file once, during recording.
     * Its size cap is the final budget, so a full take can never need a second pass.
     */
    val rawCapBytes: Long get() = maxBytes

    /**
     * Final video bitrate written by MediaRecorder: the profile bitrate, lowered only
     * when a full-length take at that rate would not fit [maxBytes] (15 % headroom
     * for container overhead and VBR overshoot, as in [RoundVideoExporter.export]).
     */
    val recorderVideoBitrate: Int get() = directVideoBitrate(maxDurationMs)

    fun directVideoBitrate(durationMs: Int): Int {
        val budget = maxBytes * 8L * 1000L / maxOf(durationMs, TELEGRAM_MIN_DURATION_MS) * 85L / 100L - audioBitrate
        return maxOf(MIN_VIDEO_BITRATE.toLong(), minOf(videoBitrate.toLong(), budget)).toInt()
    }

    val recorderAudioBitrate: Int get() = audioBitrate

    companion object {
        const val MIN_VIDEO_BITRATE = 100_000
        const val MAX_VIDEO_BITRATE = 8_000_000
        const val MAX_AUDIO_BITRATE = 256_000
        /** Telegram round audio: AAC-LC (MediaRecorder AAC), mono, 48 kHz. */
        const val AUDIO_SAMPLE_RATE = 48_000
        const val AUDIO_CHANNELS = 1
        /** Telegram round video: H.264 at a 30 fps hint with a 1 s keyframe interval. */
        const val FRAME_RATE = 30
        const val I_FRAME_INTERVAL_SECONDS = 1
        /** Telegram defaults (roundVideoSize, 1000 * 1024, 64 * 1024); Dart/bridge supply the actual profile. */
        const val TELEGRAM_SIDE = 384
        const val TELEGRAM_VIDEO_BITRATE = 1_024_000
        const val TELEGRAM_AUDIO_BITRATE = 65_536
        const val TELEGRAM_MAX_DURATION_MS = 60_000
        const val TELEGRAM_MIN_DURATION_MS = 800
    }
}

/**
 * Camera pixels are only ever encoded through the GL compositor, which crops, orients and
 * circle-masks every frame before MediaRecorder sees it. The untrimmed recording is
 * already the final file ([finalizeRecording]); [export] re-encodes only a trimmed span
 * or a recording that fails the final-profile check.
 */
object RoundVideoExporter {
    private const val MAX_DURATION_US = 60000000L

    /** Thumbnail the compositor writes from the first recorded frame (Telegram parity). */
    const val LIVE_THUMBNAIL = "thumb.live.jpg"
    private const val THUMBNAIL = "thumb.jpg"

    /**
     * Telegram fast path: no second encode. MediaRecorder wrote square H.264/AAC at the
     * final bitrate, rotation 0, from the masked GL frames. The file is validated with
     * one sync-frame decode (square, side, rotation, duration, size, black corners) and
     * moved into place; the live thumbnail is reused. Returns null when the recording
     * does not meet the final profile: the caller then transcodes it as before, from
     * the untouched [source].
     */
    fun finalizeRecording(source: File, output: File, profile: RoundProfile, canceled: AtomicBoolean): Map<String, Any>? {
        profile.validate()
        val directory = output.parentFile ?: return null
        val live = File(directory, LIVE_THUMBNAIL)
        val thumb = File(directory, THUMBNAIL)
        if (!source.isFile || source.length() !in 1..profile.maxBytes) return null
        val useLive = live.isFile && live.length() > 0
        val inspected = try { inspect(source, profile, keepFrame = !useLive) } catch (_: Exception) { return null }
        try {
            require(!canceled.get())
            thumb.delete()
            if (inspected.second != null) writeThumbnail(inspected.second!!, thumb)
            else require(live.renameTo(thumb))
        } catch (error: Exception) {
            thumb.delete()
            if (canceled.get()) throw error
            return null
        } finally { inspected.second?.recycle() }
        try {
            RoundMp4FastStart.finalize(source, output)
        } catch (error: Exception) {
            // The strict relocation never touches the source; transcode from it instead.
            if (source.isFile) output.delete()
            if (canceled.get() || !source.isFile) throw error
            return null
        }
        require(!canceled.get())
        return inspected.first + mapOf(
            "path" to output.path,
            "sizeBytes" to output.length(),
            "thumbnailPath" to thumb.path,
            "cornersSanitized" to true,
            "fastStart" to true,
            "pipeline" to "direct",
        )
    }

    /**
     * Compositor snapshot ([side]x[side] RGBA rows, bottom-up as glReadPixels returns
     * them) to the live thumbnail. Runs off the GL and camera threads; the corners are
     * checked on the encoded JPEG before it becomes visible under [LIVE_THUMBNAIL].
     */
    fun writeLiveThumbnail(pixels: ByteBuffer, side: Int, directory: File, canceled: AtomicBoolean) {
        if (canceled.get() || !directory.isDirectory) return
        val raw = Bitmap.createBitmap(side, side, Bitmap.Config.ARGB_8888)
        try {
            pixels.position(0)
            raw.copyPixelsFromBuffer(pixels)
            val upright = Bitmap.createBitmap(raw, 0, 0, side, side, Matrix().apply { preScale(1f, -1f) }, false)
            val temporary = File(directory, "$LIVE_THUMBNAIL.tmp")
            try {
                writeThumbnail(upright, temporary)
                if (canceled.get()) return
                require(temporary.renameTo(File(directory, LIVE_THUMBNAIL)))
            } finally {
                temporary.delete()
                if (upright !== raw) upright.recycle()
            }
        } finally {
            raw.recycle()
            if (canceled.get()) File(directory, LIVE_THUMBNAIL).delete()
        }
    }

    fun export(source: File, output: File, profile: RoundProfile, canceled: AtomicBoolean, startMs: Int, endMs: Int): Map<String, Any> {
        profile.validate()
        require(startMs >= 0 && endMs - startMs >= RoundProfile.TELEGRAM_MIN_DURATION_MS)
        val intermediate = File(output.parentFile, "export.muxed.mp4")
        val rangeUs = min((endMs - startMs) * 1000L, min(profile.maxDurationMs * 1000L, MAX_DURATION_US))
        // AAC passthrough is bounded by the negotiated recorder bitrate. Account
        // for container/index overhead and reject final oversize after probing.
        val budgetBitrate = ((profile.maxBytes * 8L * 1000000L / rangeUs) * 85L / 100L - profile.audioBitrate).toInt()
        require(budgetBitrate >= 100000)
        var bitrate = min(profile.videoBitrate, budgetBitrate)
        try {
            repeat(2) { attempt ->
                if (canceled.get()) error("Canceled")
                // First pass uses VBR where available; the budget retry asks for CBR.
                transcode(source, intermediate, profile.side, bitrate, canceled, startMs * 1000L, startMs * 1000L + rangeUs, profile.maxDurationMs * 1000L,
                    strict = attempt > 0)
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
                        "pipeline" to "transcode",
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

    private fun transcode(source: File, output: File, side: Int, bitrate: Int, canceled: AtomicBoolean, startUs: Long, endUs: Long, maxOutputDurationUs: Long,
                          strict: Boolean) {
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
            encoder = configureEncoder(side, bitrate, strict)
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

    /** H.264 stays the bridge format (mp4/avc/yuv420p). Codec-specific extras are
     * requested only when advertised, and any rejection falls back to the plain format. */
    private fun configureEncoder(side: Int, bitrate: Int, strict: Boolean): MediaCodec {
        // Telegram parity: 30 fps hint and a 1 s keyframe interval for every encoder path.
        fun format() = MediaFormat.createVideoFormat("video/avc", side, side).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
            setInteger(MediaFormat.KEY_BIT_RATE, bitrate)
            setInteger(MediaFormat.KEY_FRAME_RATE, RoundProfile.FRAME_RATE)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, RoundProfile.I_FRAME_INTERVAL_SECONDS)
        }
        val encoder = MediaCodec.createEncoderByType("video/avc")
        try {
            val enhanced = format()
            val capabilities = encoder.codecInfo.getCapabilitiesForType("video/avc")
            val levels = capabilities.profileLevels ?: emptyArray()
            fun supports(profile: Int) = levels.any { it.profile == profile && it.level >= MediaCodecInfo.CodecProfileLevel.AVCLevel31 }
            val avcProfile = when {
                supports(MediaCodecInfo.CodecProfileLevel.AVCProfileHigh) -> MediaCodecInfo.CodecProfileLevel.AVCProfileHigh
                supports(MediaCodecInfo.CodecProfileLevel.AVCProfileMain) -> MediaCodecInfo.CodecProfileLevel.AVCProfileMain
                else -> null
            }
            if (avcProfile != null) {
                enhanced.setInteger(MediaFormat.KEY_PROFILE, avcProfile)
                enhanced.setInteger(MediaFormat.KEY_LEVEL, MediaCodecInfo.CodecProfileLevel.AVCLevel31)
            }
            // Keep decode order == presentation order for the muxer and old players.
            if (android.os.Build.VERSION.SDK_INT >= 29) enhanced.setInteger(MediaFormat.KEY_MAX_B_FRAMES, 0)
            val modes = capabilities.encoderCapabilities
            val mode = if (strict) MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_CBR
                else MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_VBR
            if (modes?.isBitrateModeSupported(mode) == true) enhanced.setInteger(MediaFormat.KEY_BITRATE_MODE, mode)
            encoder.configure(enhanced, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            return encoder
        } catch (_: Exception) {
            encoder.release()
        }
        val plain = MediaCodec.createEncoderByType("video/avc")
        try {
            plain.configure(format(), null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        } catch (error: Exception) { plain.release(); throw error }
        return plain
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
            require(duration in RoundProfile.TELEGRAM_MIN_DURATION_MS..profile.maxDurationMs)
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

    /**
     * Fast-path probe: the same container/profile checks as [probe] and one sync-frame
     * decode for the corner mask (every frame comes from the same masking shader).
     * Returns the decoded frame only when [keepFrame] (no live thumbnail to reuse).
     */
    private fun inspect(file: File, profile: RoundProfile, keepFrame: Boolean): Pair<Map<String, Any>, Bitmap?> {
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
            require(duration in RoundProfile.TELEGRAM_MIN_DURATION_MS..profile.maxDurationMs)
            require(file.length() in 1..profile.maxBytes)
            val frame = retriever.getFrameAtTime(0, MediaMetadataRetriever.OPTION_CLOSEST_SYNC) ?: error("decode")
            try { requireSanitizedCorners(frame) } catch (error: Exception) { frame.recycle(); throw error }
            val descriptor = mapOf<String, Any>("width" to width, "height" to height, "durationMs" to duration,
                "sizeBytes" to file.length(), "videoCodec" to "h264", "audioCodec" to "aac")
            if (keepFrame) return descriptor to frame
            frame.recycle()
            return descriptor to null
        } finally { extractor.release(); retriever.release() }
    }

    private fun thumbnail(file: File): File {
        val retriever = MediaMetadataRetriever()
        try {
            retriever.setDataSource(file.path)
            val decoded = retriever.getFrameAtTime(0, MediaMetadataRetriever.OPTION_CLOSEST_SYNC) ?: error("thumbnail")
            val thumb = File(file.parentFile, THUMBNAIL)
            try { writeThumbnail(decoded, thumb) } finally { decoded.recycle() }
            return thumb
        } finally { retriever.release() }
    }

    /** Circle-masked JPEG of [frame]; the encoded file's corners are verified black. */
    private fun writeThumbnail(frame: Bitmap, thumb: File) {
        val bitmap = Bitmap.createBitmap(frame.width, frame.height, Bitmap.Config.ARGB_8888)
        try {
            val canvas = Canvas(bitmap)
            canvas.drawColor(Color.BLACK)
            val layer = canvas.saveLayer(0f, 0f, bitmap.width.toFloat(), bitmap.height.toFloat(), null)
            canvas.drawCircle(bitmap.width / 2f, bitmap.height / 2f, bitmap.width / 2f, Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.WHITE })
            val mask = Paint(Paint.ANTI_ALIAS_FLAG).apply { xfermode = PorterDuffXfermode(PorterDuff.Mode.SRC_IN) }
            canvas.drawBitmap(frame, 0f, 0f, mask)
            canvas.restoreToCount(layer)
            thumb.outputStream().use { require(bitmap.compress(Bitmap.CompressFormat.JPEG, 90, it)) }
        } finally { bitmap.recycle() }
        val encodedThumb = BitmapFactory.decodeFile(thumb.path) ?: error("thumbnail")
        try { requireSanitizedCorners(encodedThumb) } finally { encodedThumb.recycle() }
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
