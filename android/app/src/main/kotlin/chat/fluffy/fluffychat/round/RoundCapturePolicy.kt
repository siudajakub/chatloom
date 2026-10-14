// SPDX-License-Identifier: AGPL-3.0-or-later
package chat.fluffy.fluffychat.round

import kotlin.math.cos
import kotlin.math.min
import kotlin.math.sin
import java.util.concurrent.atomic.AtomicBoolean

/** Open/session callbacks must belong to the current camera, even within one capture. */
internal class RoundCameraEpoch {
    private var value = 0L
    fun advance(): Long = ++value
    fun isCurrent(token: Long): Boolean = token == value
}

internal data class RoundZoomRange(val minimum: Double, val maximum: Double) {
    init { require(minimum.isFinite() && maximum.isFinite() && minimum > 0 && maximum >= minimum) }
    val supported get() = maximum - minimum > 0.0001
    fun validate(value: Double): Double {
        require(value.isFinite() && value >= minimum && value <= maximum)
        return value
    }
}

/** Output is already upright, mirrored consistently, cropped and square before recording. */
internal object RoundFrameTransform {
    fun coordinates(width: Int, height: Int, rotation: Int, mirrored: Boolean): FloatArray {
        require(width > 0 && height > 0 && rotation in listOf(0, 90, 180, 270))
        val radians = Math.toRadians(rotation.toDouble())
        val c = cos(radians).toFloat()
        val s = sin(radians).toFloat()
        val cropX = min(width, height).toFloat() / width
        val cropY = min(width, height).toFloat() / height
        val corners = floatArrayOf(-0.5f, -0.5f, 0.5f, -0.5f, -0.5f, 0.5f, 0.5f, 0.5f)
        return FloatArray(8) { index ->
            val corner = index / 2 * 2
            val x = corners[corner] * if (mirrored) -1f else 1f
            val y = corners[corner + 1]
            if (index % 2 == 0) (c * x - s * y) * cropX + 0.5f
            else (s * x + c * y) * cropY + 0.5f
        }
    }
}

/** One monotonic wall clock, never a camera sensor's potentially unrelated clock. */
internal class RoundFrameClock {
    private var previous = -1L
    fun next(nowNs: Long): Long {
        require(nowNs >= 0)
        val next = maxOf(nowNs, previous + 1)
        previous = next
        return next
    }
}

/** Flutter may stop sampling an offscreen Texture. Never fill its BufferQueue. */
internal class RoundPreviewGate {
    private val available = AtomicBoolean(true)
    fun acquire(): Boolean = available.compareAndSet(true, false)
    fun consumed() { available.set(true) }
}
