// SPDX-License-Identifier: AGPL-3.0-or-later
package pl.personal.chatloom.round

import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.min
import kotlin.math.sin
import java.lang.ref.WeakReference
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

/** Cache-pass sampling for one camera input; see [RoundFrameTransform.forCamera]. */
internal class RoundFrameGeometry(val coordinates: FloatArray, val step: FloatArray,
                                  val uprightWidth: Int, val uprightHeight: Int, val rotation: Int)

/**
 * Camera frame geometry for the GL cache pass (Telegram parity).
 *
 * SurfaceTexture.getTransformMatrix() for a Camera2 output already maps upright
 * coordinates of the device's natural orientation onto the camera buffer: it contains
 * the sensor rotation and, for the front camera (MIRROR_MODE_AUTO), the selfie mirror.
 * The cache pass samples `uMatrix * vCoordinate`, so [coordinates] are in that upright
 * frame and must not rotate by the sensor orientation again. They only:
 * - crop the centred square of the short side, measured in the upright frame (the
 *   buffer's axes are swapped when the transform rotates by 90/270 degrees), and
 * - undo the display rotation frozen at capture start, so the square is upright on
 *   screen (0 for a phone held in portrait).
 * Preview and recorder copy the same cached square, so the file is exactly what the
 * user saw, including the front-camera mirror. MP4 rotation metadata stays 0.
 */
internal object RoundFrameTransform {
    private val RIGHT_ANGLES = listOf(0, 90, 180, 270)

    fun normalizeDegrees(degrees: Int): Int {
        val normalized = ((degrees % 360) + 360) % 360
        require(normalized in RIGHT_ANGLES) { "Unsupported orientation" }
        return normalized
    }

    /** Camera2 rotates a sensor mounted at 90/270 degrees: buffer width becomes upright height. */
    fun sensorSwapsAxes(sensorOrientation: Int): Boolean = normalizeDegrees(sensorOrientation) % 180 == 90

    /**
     * Whether a SurfaceTexture transform (column-major 4x4) maps the upright s axis mostly
     * onto the buffer's t axis, i.e. already contains a 90/270 degree rotation.
     */
    fun matrixSwapsAxes(matrix: FloatArray): Boolean {
        require(matrix.size >= 16)
        return abs(matrix[1]) > abs(matrix[0])
    }

    /** Output-to-upright rotation that undoes Surface.ROTATION_[displayDegrees]. */
    fun displayCompensation(displayDegrees: Int): Int = (360 - normalizeDegrees(displayDegrees)) % 360

    fun forCamera(bufferWidth: Int, bufferHeight: Int, axesSwapped: Boolean, displayDegrees: Int, side: Int): RoundFrameGeometry {
        require(bufferWidth > 0 && bufferHeight > 0 && side > 0)
        val uprightWidth = if (axesSwapped) bufferHeight else bufferWidth
        val uprightHeight = if (axesSwapped) bufferWidth else bufferHeight
        val rotation = displayCompensation(displayDegrees)
        return RoundFrameGeometry(coordinates(uprightWidth, uprightHeight, rotation, false),
            RoundDownsample.step(uprightWidth, uprightHeight, side), uprightWidth, uprightHeight, rotation)
    }

    /** Texture coordinates of a centred min-side square of a [width]x[height] upright frame. */
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

/**
 * Half-output-pixel supersampling offsets (4 bilinear taps). The offsets are added to
 * vCoordinate, i.e. in the UPRIGHT frame, so [width]/[height] are the upright size (not
 * the sensor buffer's). The crop is square in pixels, so each tap is a quarter output
 * pixel along both axes whatever the display rotation.
 */
internal object RoundDownsample {
    fun step(width: Int, height: Int, side: Int): FloatArray {
        require(width > 0 && height > 0 && side > 0)
        val short = min(width, height).toFloat()
        // One output pixel spans (crop / side) of the texture along each upright axis.
        return floatArrayOf(0.25f * short / width / side, 0.25f * short / height / side)
    }
}

/**
 * Telegram freezes the screen orientation while a round is being recorded. One saved
 * request survives overlapping captures: a new capture may take the lock before the
 * previous capture's main-thread release runs, and only the last owner restores it.
 */
internal class RoundOrientationLock<T : Any> {
    private var target: WeakReference<T>? = null
    private var saved = 0
    private var owner: Any? = null

    /** Returns the orientation to request on [target]; remembers [requested] once. */
    fun acquire(owner: Any, target: T, requested: Int): Int {
        if (this.target?.get() !== target) {
            this.target = WeakReference(target)
            saved = requested
        }
        this.owner = owner
        return LOCKED
    }

    /**
     * Returns the target and request to restore, or null when [owner] no longer holds the
     * lock or something else already changed the target's requested orientation.
     */
    fun release(owner: Any, requestedOf: (T) -> Int): Pair<T, Int>? {
        if (this.owner == null || this.owner !== owner) return null
        val locked = target?.get()
        target = null; this.owner = null
        if (locked == null || requestedOf(locked) != LOCKED) return null
        return locked to saved
    }

    companion object {
        /** ActivityInfo.SCREEN_ORIENTATION_LOCKED: keep the current rotation, whatever it is. */
        const val LOCKED = 14
    }
}

/**
 * Camera stream size: the smallest size that still oversamples the round (short side
 * at least min(2 * side, 1080)), never wider than 1920, preferring 4:3 (full sensor
 * height, widest square field of view), then 16:9, and sizes that sustain 30 fps. GL
 * then centre-crops the short side in the upright frame and downsamples to the square.
 */
internal object RoundStreamSize {
    private const val MAX_LONG = 1920
    private const val FRAME_30_NS = 33_366_667L // 29.97 fps tolerance

    private fun fourThree(width: Int, height: Int): Boolean =
        maxOf(width, height).toLong() * 3 == min(width, height).toLong() * 4
    private fun sixteenNine(width: Int, height: Int): Boolean =
        maxOf(width, height).toLong() * 9 == min(width, height).toLong() * 16

    /** [minFrameNs] returns 0 when unknown. Returns the index of the chosen size. */
    fun select(sizes: List<Pair<Int, Int>>, side: Int, minFrameNs: (Int) -> Long = { 0L }): Int {
        require(sizes.isNotEmpty() && side > 0)
        val target = min(side * 2, 1080)
        val indices = sizes.indices.filter { sizes[it].first > 0 && sizes[it].second > 0 }
        require(indices.isNotEmpty())
        fun area(index: Int) = sizes[index].first.toLong() * sizes[index].second
        fun short(index: Int) = min(sizes[index].first, sizes[index].second)
        fun long(index: Int) = maxOf(sizes[index].first, sizes[index].second)
        fun fast(index: Int) = minFrameNs(index).let { it <= 0L || it <= FRAME_30_NS }
        val bounded = indices.filter { long(it) <= MAX_LONG }
        val oversampled = bounded.filter { short(it) >= target }
        listOf(
            oversampled.filter { fourThree(sizes[it].first, sizes[it].second) && fast(it) },
            oversampled.filter { sixteenNine(sizes[it].first, sizes[it].second) && fast(it) },
            oversampled.filter { fast(it) },
            oversampled,
        ).firstOrNull { it.isNotEmpty() }?.let { candidates -> return candidates.minBy { area(it) } }
        // Nothing reaches the target: take the most detail that stays bounded and,
        // ideally, at least the output side; otherwise the smallest available size.
        val usable = bounded.filter { short(it) >= side }
        listOf(usable.filter { fast(it) }, usable, bounded.filter { fast(it) }, bounded)
            .firstOrNull { it.isNotEmpty() }?.let { candidates -> return candidates.maxBy { area(it) } }
        return indices.minBy { area(it) }
    }
}

/** AE target fps: a fixed 30 fps range first for a stable timeline, then the closest fallback. */
internal object RoundFpsRange {
    fun select(ranges: List<Pair<Int, Int>>): Pair<Int, Int>? {
        val valid = ranges.filter { it.first > 0 && it.second >= it.first }
        valid.firstOrNull { it.first == 30 && it.second == 30 }?.let { return it }
        // Variable ranges ending at 30 keep 30 fps in good light; highest floor wins.
        valid.filter { it.second == 30 }.maxByOrNull { it.first }?.let { return it }
        // Ranges containing 30 with the lowest ceiling (e.g. [24,60] before [7,120]).
        valid.filter { it.first <= 30 && it.second > 30 }
            .minWithOrNull(compareBy<Pair<Int, Int>> { it.second }.thenByDescending { it.first })?.let { return it }
        // Devices without 30: the fastest range below it.
        return valid.filter { it.second < 30 }
            .maxWithOrNull(compareBy<Pair<Int, Int>> { it.second }.thenBy { it.first })
    }
}
