// SPDX-License-Identifier: AGPL-3.0-or-later
package pl.personal.chatloom.round

import kotlin.math.abs

private var checks = 0

private fun verify(condition: Boolean, label: String) {
    checks++
    check(condition) { label }
}

private fun rejected(label: String, action: () -> Unit) {
    var didReject = false
    try { action() } catch (_: IllegalArgumentException) { didReject = true }
    verify(didReject, label)
}

/** Pure quality policies used by Camera2/MediaRecorder; no device or codec is exercised. */
fun main() {
    val phone = listOf(4032 to 3024, 1920 to 1080, 1440 to 1080, 1280 to 960, 1280 to 720,
        1024 to 768, 960 to 720, 800 to 600, 640 to 480, 320 to 240)
    fun pick(sizes: List<Pair<Int, Int>>, side: Int, frame: (Int) -> Long = { 0L }) =
        sizes[RoundStreamSize.select(sizes, side, frame)]
    verify(pick(phone, 384) == (1024 to 768), "384 round oversamples 2x at 4:3: ${pick(phone, 384)}")
    verify(pick(phone, 480) == (1280 to 960), "480 HQ round oversamples 2x: ${pick(phone, 480)}")
    verify(pick(phone, 640) == (1440 to 1080), "large round capped at 1080 short side: ${pick(phone, 640)}")
    val portrait = phone.map { it.second to it.first }
    verify(pick(portrait, 384) == (768 to 1024), "orientation independent")
    // Uncommon aspect only when nothing standard qualifies; never above 1920 long side.
    verify(pick(listOf(2560 to 1440, 1000 to 800, 1920 to 1080), 384) == (1920 to 1080), "prefers 16:9 over odd aspect")
    verify(pick(listOf(2560 to 1440, 1000 to 800), 384) == (1000 to 800), "odd aspect fallback")
    verify(pick(listOf(4000 to 3000, 2560 to 1920), 384) == (2560 to 1920), "nothing bounded: smallest available")
    // Sizes that cannot sustain 30 fps are skipped when an alternative exists.
    val slow = phone.indexOf(1024 to 768)
    verify(pick(phone, 384) { if (it == slow) 50_000_000L else 33_333_333L } == (1280 to 960), "skips sub-30fps size")
    // Low-resolution sensor: most detail that stays bounded.
    verify(pick(listOf(640 to 480, 352 to 288, 320 to 240), 384) == (640 to 480), "low-res sensor keeps the best size")
    verify(pick(listOf(352 to 288, 320 to 240), 384) == (352 to 288), "tiny sensor still works")
    rejected("empty size list") { RoundStreamSize.select(emptyList(), 384) }

    verify(RoundFpsRange.select(listOf(15 to 15, 15 to 30, 30 to 30, 7 to 30)) == (30 to 30), "fixed 30 first")
    verify(RoundFpsRange.select(listOf(15 to 15, 7 to 30, 15 to 30, 24 to 24)) == (15 to 30), "variable ending at 30")
    verify(RoundFpsRange.select(listOf(7 to 120, 24 to 60, 15 to 15)) == (24 to 60), "lowest ceiling containing 30")
    verify(RoundFpsRange.select(listOf(15 to 15, 15 to 24, 24 to 24)) == (24 to 24), "fastest below 30")
    verify(RoundFpsRange.select(emptyList()) == null, "no ranges: leave AE default")
    verify(RoundFpsRange.select(listOf(0 to 30, 30 to 15)) == null, "invalid ranges ignored")

    val step = RoundDownsample.step(1024, 768, 384)
    verify(abs(step[0] - 0.25f * 768f / 1024f / 384f) < 1e-9f && abs(step[1] - 0.25f / 384f) < 1e-9f,
        "quarter output pixel in cropped texture space")
    rejected("invalid downsample input") { RoundDownsample.step(0, 768, 384) }

    // Profile: old 5-argument callers keep plain behaviour; new flags validate the same limits.
    val legacy = RoundProfile(384, 25_000_000, 60000, 1_000_000, 64000)
    legacy.validate()
    verify(!legacy.stabilize && !legacy.noiseReduction && !legacy.highQuality, "missing flags default to old behaviour")
    // Telegram parity: the recorder writes the final bitrate once (no 4x intermediate).
    verify(legacy.recorderVideoBitrate == 1_000_000, "direct final bitrate: ${legacy.recorderVideoBitrate}")
    val hq = RoundProfile(480, 25_000_000, 60000, 2_000_000, 96000, stabilize = true, noiseReduction = true, highQuality = true)
    hq.validate()
    verify(hq.recorderVideoBitrate == 2_000_000, "HQ direct bitrate: ${hq.recorderVideoBitrate}")
    // A small budget lowers the direct bitrate so a full take fits the final cap.
    val small = RoundProfile(384, 5_000_000, 60000, 1_000_000, 64000)
    val rawBytes = (small.recorderVideoBitrate.toLong() + small.recorderAudioBitrate) * 60 / 8
    verify(small.recorderVideoBitrate < 1_000_000, "budget lowers the direct bitrate: ${small.recorderVideoBitrate}")
    verify(rawBytes <= small.rawCapBytes * 90 / 100, "full take fits the final cap: $rawBytes / ${small.rawCapBytes}")
    verify(RoundProfile(384, 100_000, 60000, 1_000_000, 64000).recorderVideoBitrate == RoundProfile.MIN_VIDEO_BITRATE,
        "never below the validated minimum")
    verify(RoundProfile(384, 25_000_000, 60000, 1_000_000, 64000).rawCapBytes == 25_000_000L, "recorder cap = final budget")
    verify(small.directVideoBitrate(10_000) == 1_000_000, "short trims keep the profile bitrate")
    rejected("excessive video bitrate") { RoundProfile(384, 25_000_000, 60000, 8_000_001, 64000).validate() }
    rejected("excessive audio bitrate") { RoundProfile(384, 25_000_000, 60000, 1_000_000, 256_001).validate() }
    rejected("odd side even in HQ") { RoundProfile(481, 25_000_000, 60000, 2_000_000, 96000, highQuality = true).validate() }
    verify(RoundProfile.AUDIO_SAMPLE_RATE == 48_000, "48 kHz recorder audio")
    // Telegram's InstantCameraView: AudioSource.DEFAULT (0); noise reduction opts into
    // VOICE_COMMUNICATION (7). Never CAMCORDER (5).
    verify(legacy.audioSource == 0, "plain microphone by default: ${legacy.audioSource}")
    verify(hq.audioSource == 7, "noise reduction uses the call path: ${hq.audioSource}")
    println("PASS native quality: $checks assertions; stream size, AE fps range, downsample step, profile/bitrate limits, audio source")
}
