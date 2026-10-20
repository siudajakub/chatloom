// SPDX-License-Identifier: AGPL-3.0-or-later
package pl.personal.chatloom.round

import kotlin.math.abs
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

private var checks = 0

private fun verify(condition: Boolean, label: String) {
    checks++
    check(condition) { label }
}

private fun reject(label: String, action: () -> Unit) {
    var rejected = false
    try { action() } catch (_: IllegalArgumentException) { rejected = true }
    verify(rejected, label)
}

private fun mapped(width: Int, height: Int, rotation: Int, mirrored: Boolean, expected: FloatArray) {
    val actual = RoundFrameTransform.coordinates(width, height, rotation, mirrored)
    verify(actual.size == expected.size && actual.indices.all { abs(actual[it] - expected[it]) < 0.00001f },
        "UV mapping $width x $height, rotation=$rotation, mirror=$mirrored: ${actual.toList()}")
}

/** These fixtures execute the same pure helpers used by Camera2/GL.
 * They do not instantiate Android stubs or claim device/codec acceptance. */
fun main() {
    val camera = RoundCameraEpoch()
    val firstOpen = camera.advance()
    verify(camera.isCurrent(firstOpen), "first open current")
    val switchOpen = camera.advance()
    verify(!camera.isCurrent(firstOpen) && camera.isCurrent(switchOpen), "switch invalidates old lens callbacks")
    val rollbackOpen = camera.advance()
    verify(!camera.isCurrent(firstOpen) && !camera.isCurrent(switchOpen) && camera.isCurrent(rollbackOpen),
        "rollback cannot accept failed target callbacks")
    camera.advance()
    verify(!camera.isCurrent(rollbackOpen), "cancel/finish invalidates pending open")
    val replacement = camera.advance()
    verify(camera.isCurrent(replacement) && !camera.isCurrent(firstOpen), "new open cannot revive old token")
    // Each callback/session/control token owner gets its own epoch.
    val controls = RoundCameraEpoch()
    val oldControl = controls.advance()
    controls.advance()
    verify(!controls.isCurrent(oldControl) && camera.isCurrent(replacement), "control revision is isolated from camera identity")

    val zoom = RoundZoomRange(0.5, 8.0)
    verify(zoom.supported, "optical/digital fractional range supported")
    for (value in listOf(0.5, 0.75, 1.0, 2.125, 8.0)) {
        verify(zoom.validate(value) == value, "in-range zoom remains exact: $value")
    }
    for (value in listOf(0.4999, 8.0001, 0.0, -1.0, Double.NaN, Double.NEGATIVE_INFINITY, Double.POSITIVE_INFINITY)) {
        reject("invalid/outside zoom rejected: $value") { zoom.validate(value) }
    }
    val noZoom = RoundZoomRange(1.0, 1.0)
    verify(!noZoom.supported && noZoom.validate(1.0) == 1.0, "fixed camera has no enabled zoom control")
    reject("front fixed zoom cannot inherit previous back limit") { noZoom.validate(2.0) }
    for ((minimum, maximum) in listOf(0.0 to 1.0, -1.0 to 4.0, 2.0 to 1.0,
        Double.NaN to 4.0, 1.0 to Double.POSITIVE_INFINITY)) {
        reject("invalid hardware zoom range rejected") { RoundZoomRange(minimum, maximum) }
    }

    // Explicit source corner expectations, in GL bottom-left/right then top-left/right order.
    mapped(640, 480, 0, false, floatArrayOf(0.125f, 0f, 0.875f, 0f, 0.125f, 1f, 0.875f, 1f))
    mapped(640, 480, 90, false, floatArrayOf(0.875f, 0f, 0.875f, 1f, 0.125f, 0f, 0.125f, 1f))
    mapped(640, 480, 180, false, floatArrayOf(0.875f, 1f, 0.125f, 1f, 0.875f, 0f, 0.125f, 0f))
    mapped(640, 480, 270, false, floatArrayOf(0.125f, 1f, 0.125f, 0f, 0.875f, 1f, 0.875f, 0f))
    mapped(640, 480, 0, true, floatArrayOf(0.875f, 0f, 0.125f, 0f, 0.875f, 1f, 0.125f, 1f))
    mapped(640, 480, 90, true, floatArrayOf(0.875f, 1f, 0.875f, 0f, 0.125f, 1f, 0.125f, 0f))
    mapped(1920, 1080, 0, false, floatArrayOf(0.21875f, 0f, 0.78125f, 0f, 0.21875f, 1f, 0.78125f, 1f))
    mapped(480, 640, 0, false, floatArrayOf(0f, 0.125f, 1f, 0.125f, 0f, 0.875f, 1f, 0.875f))
    mapped(384, 384, 0, false, floatArrayOf(0f, 0f, 1f, 0f, 0f, 1f, 1f, 1f))
    mapped(384, 384, 0, true, floatArrayOf(1f, 0f, 0f, 0f, 1f, 1f, 0f, 1f))
    for ((width, height) in listOf(640 to 480, 1920 to 1080, 480 to 640, 384 to 384)) {
        for (rotation in listOf(0, 90, 180, 270)) {
            val saved = RoundFrameTransform.coordinates(width, height, rotation, false)
            val selfie = RoundFrameTransform.coordinates(width, height, rotation, true)
            verify((saved + selfie).all { it.isFinite() && it in -0.00001f..1.00001f }, "UVs stay in source bounds")
            verify(abs(saved.filterIndexed { index, _ -> index % 2 == 0 }.average() - 0.5) < 0.00001 &&
                abs(saved.filterIndexed { index, _ -> index % 2 == 1 }.average() - 0.5) < 0.00001, "center crop remains centered")
            verify(selfie.copyOfRange(0, 2).contentEquals(saved.copyOfRange(2, 4)) &&
                selfie.copyOfRange(4, 6).contentEquals(saved.copyOfRange(6, 8)), "selfie mirrors output X rather than source Y")
        }
    }
    reject("zero width rejected") { RoundFrameTransform.coordinates(0, 480, 0, false) }
    reject("negative height rejected") { RoundFrameTransform.coordinates(640, -1, 0, false) }
    reject("non-quarter rotation rejected") { RoundFrameTransform.coordinates(640, 480, 45, false) }

    val clock = RoundFrameClock()
    val origin = 4_000_000_000_000L
    verify(clock.next(origin) == origin, "absolute wall origin preserved")
    verify(clock.next(origin) == origin + 1, "duplicate pump timestamp advances")
    verify(clock.next(origin - 100) == origin + 2, "regressed timestamp cannot regress encoder PTS")
    verify(clock.next(origin + 33_000_000) == origin + 33_000_000, "normal frame wall interval preserved")
    verify(clock.next(origin + 633_000_000) == origin + 633_000_000, "switch gap does not reset time origin")
    verify(clock.next(origin + 3_633_000_000) == origin + 3_633_000_000,
        "pause wall gap is left for MediaRecorder to remove exactly once")
    reject("negative wall timestamp rejected") { clock.next(-1) }
    verify(clock.next(origin + 3_666_000_000) == origin + 3_666_000_000, "invalid timestamp cannot corrupt next frame")

    val preview = RoundPreviewGate()
    verify(preview.acquire(), "initial preview frame obtains one buffer permit")
    verify(!preview.acquire(), "unconsumed frame blocks another preview submission")
    verify((1..1000).none { preview.acquire() }, "offscreen/no-consume preview cannot fill its BufferQueue")
    preview.consumed()
    verify(preview.acquire() && !preview.acquire(), "actual Flutter consumption permits exactly one next frame")
    preview.consumed(); preview.consumed()
    verify(preview.acquire() && !preview.acquire(), "duplicate consumption callback does not accumulate permits")
    val executor = Executors.newFixedThreadPool(8)
    try {
        repeat(4) { round ->
            preview.consumed()
            val start = CountDownLatch(1)
            val ready = CountDownLatch(8)
            val winners = AtomicInteger()
            val jobs = (1..64).map {
                executor.submit {
                    ready.countDown()
                    start.await()
                    if (preview.acquire()) winners.incrementAndGet()
                }
            }
            try {
                verify(ready.await(5, TimeUnit.SECONDS), "preview contenders ready")
            } finally { start.countDown() }
            jobs.forEach { it.get(5, TimeUnit.SECONDS) }
            verify(winners.get() == 1, "concurrent preview submissions have one winner: round $round")
            verify(!preview.acquire(), "concurrent winner still requires actual consumption callback")
        }
    } finally { executor.shutdownNow() }
    println("PASS native controls: $checks assertions; camera/control epochs, zoom limits, rotated center-crop/selfie UVs, absolute monotonic wall timeline, concurrent offscreen preview gate")
}
