// SPDX-License-Identifier: AGPL-3.0-or-later
package pl.personal.chatloom.round

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.hypot
import kotlin.math.min
import kotlin.math.sin

/**
 * End-to-end model of the round camera cache pass:
 * output square -> RoundFrameTransform coordinates (upright frame) -> SurfaceTexture
 * transform (modelled like GLConsumer for a Camera2 stream) -> sensor buffer pixels ->
 * physical directions on the device -> world, for the device held at each display rotation.
 *
 * Physical facts used (independent of the code under test):
 * - SENSOR_ORIENTATION: rotating the buffer image clockwise by it makes it upright in the
 *   device's natural orientation.
 * - A front camera looks at the user, so its unmirrored image is left/right swapped with
 *   respect to the screen; the selfie preview (what the user sees) is screen-consistent.
 * - Surface.ROTATION_r: the device is turned r degrees counter-clockwise.
 */
class RoundFrameTransformTest {
    private data class V(val x: Double, val y: Double) {
        operator fun plus(o: V) = V(x + o.x, y + o.y)
        operator fun minus(o: V) = V(x - o.x, y - o.y)
        operator fun times(k: Double) = V(x * k, y * k)
        fun length() = hypot(x, y)
        fun dot(o: V) = x * o.x + y * o.y
        fun cross(o: V) = x * o.y - y * o.x
        fun unit() = this * (1.0 / length())
    }

    /** Counter-clockwise rotation in a y-up frame. */
    private fun rotate(v: V, degrees: Int): V {
        val r = Math.toRadians(degrees.toDouble())
        return V(v.x * cos(r) - v.y * sin(r), v.x * sin(r) + v.y * cos(r))
    }

    /**
     * SurfaceTexture.getTransformMatrix() for a Camera2 output (AOSP
     * CameraUtils::getRotationTransform + GLConsumer::computeTransformMatrix): maps upright
     * texture coordinates (t up) to buffer texture coordinates (t along memory rows). The
     * display transform is buffer -> rotate CW by sensor -> FLIP_H for the front camera
     * (MIRROR_MODE_AUTO); the matrix is its inverse followed by GLConsumer's vertical flip.
     */
    private fun stMatrix(sensor: Int, front: Boolean): FloatArray {
        fun map(s: Double, t: Double): V {
            var v = V(s - 0.5, t - 0.5)
            if (front) v = V(-v.x, v.y)
            v = rotate(v, sensor) // inverse of a clockwise rotation by `sensor`
            return V(v.x + 0.5, 1.0 - (v.y + 0.5))
        }
        val origin = map(0.0, 0.0)
        val s = map(1.0, 0.0) - origin
        val t = map(0.0, 1.0) - origin
        return floatArrayOf(s.x.toFloat(), s.y.toFloat(), 0f, 0f, t.x.toFloat(), t.y.toFloat(), 0f, 0f,
            0f, 0f, 1f, 0f, origin.x.toFloat(), origin.y.toFloat(), 0f, 1f)
    }

    private fun apply(m: FloatArray, p: V) =
        V(m[0] * p.x + m[4] * p.y + m[12], m[1] * p.x + m[5] * p.y + m[13])

    private class Sampled(val origin: V, val right: V, val up: V, val center: V, val corners: List<V>)

    /** Shader: vCoordinate (interpolated corners) -> uMatrix -> buffer pixels, image y up. */
    private fun sample(coordinates: FloatArray, m: FloatArray, width: Int, height: Int): Sampled {
        val c = (0 until 4).map { V(coordinates[it * 2].toDouble(), coordinates[it * 2 + 1].toDouble()) }
        // Corner order matches the quad (-1,-1), (1,-1), (-1,1), (1,1): an affine parallelogram.
        assertEquals(c[3].x, (c[1] + c[2] - c[0]).x, 1e-5)
        assertEquals(c[3].y, (c[1] + c[2] - c[0]).y, 1e-5)
        fun pixel(o: V): V {
            val tex = c[0] + (c[1] - c[0]) * o.x + (c[2] - c[0]) * o.y
            val buffer = apply(m, tex)
            return V(buffer.x * width, (1.0 - buffer.y) * height)
        }
        val origin = pixel(V(0.0, 0.0))
        return Sampled(origin, pixel(V(1.0, 0.0)) - origin, pixel(V(0.0, 1.0)) - origin,
            pixel(V(0.5, 0.5)), listOf(V(0.0, 0.0), V(1.0, 0.0), V(0.0, 1.0), V(1.0, 1.0)).map { pixel(it) })
    }

    /** A buffer-image direction as seen in the world while the device is at [display]. */
    private fun world(bufferDirection: V, sensor: Int, front: Boolean, display: Int): V {
        var device = rotate(bufferDirection, -sensor) // upright in the natural orientation
        if (front) device = V(-device.x, device.y)    // what the user sees: screen-consistent selfie
        return rotate(device, display)
    }

    private val sensors = listOf(0, 90, 180, 270)
    private val displays = listOf(0, 90, 180, 270)
    private val streams = listOf(1440 to 1080, 1920 to 1080, 1280 to 960, 1024 to 768, 640 to 480, 1080 to 1080)
    private val side = 384

    private fun forEachCase(block: (sensor: Int, display: Int, front: Boolean, width: Int, height: Int) -> Unit) {
        for (sensor in sensors) for (display in displays) for (front in listOf(false, true))
            for ((width, height) in streams) block(sensor, display, front, width, height)
    }

    private fun geometry(sensor: Int, front: Boolean, display: Int, width: Int, height: Int): RoundFrameGeometry {
        val swapped = RoundFrameTransform.matrixSwapsAxes(stMatrix(sensor, front))
        assertEquals(RoundFrameTransform.sensorSwapsAxes(sensor), swapped)
        return RoundFrameTransform.forCamera(width, height, swapped, display, side)
    }

    @Test fun squareCropIsUndistortedCentredAndInsideTheBuffer() = forEachCase { sensor, display, front, width, height ->
        val case = "sensor=$sensor display=$display front=$front ${width}x$height"
        val g = geometry(sensor, front, display, width, height)
        val s = sample(g.coordinates, stMatrix(sensor, front), width, height)
        val short = min(width, height).toDouble()
        assertEquals(case, short, s.right.length(), 1e-3 * short)
        assertEquals(case, short, s.up.length(), 1e-3 * short)
        assertEquals(case, 1.0, s.right.length() / s.up.length(), 1e-6)       // aspect 1.0
        assertEquals(case, 0.0, s.right.unit().dot(s.up.unit()), 1e-6)       // no shear
        assertEquals(case, width / 2.0, s.center.x, 1e-3 * short)
        assertEquals(case, height / 2.0, s.center.y, 1e-3 * short)
        s.corners.forEach {
            assertTrue(case, it.x >= -1e-3 && it.x <= width + 1e-3 && it.y >= -1e-3 && it.y <= height + 1e-3)
        }
    }

    @Test fun outputIsUprightInTheWorldForEveryDisplayRotation() = forEachCase { sensor, display, front, width, height ->
        val case = "sensor=$sensor display=$display front=$front ${width}x$height"
        val s = sample(geometry(sensor, front, display, width, height).coordinates, stMatrix(sensor, front), width, height)
        val up = world(s.up, sensor, front, display).unit()
        val right = world(s.right, sensor, front, display).unit()
        assertEquals(case, 0.0, up.x, 1e-5); assertEquals(case, 1.0, up.y, 1e-5)
        // Output right == the user's right on screen: the front camera is the selfie mirror.
        assertEquals(case, 1.0, right.x, 1e-5); assertEquals(case, 0.0, right.y, 1e-5)
    }

    @Test fun frontCameraIsRecordedMirroredLikeThePreview() = forEachCase { sensor, display, front, width, height ->
        val s = sample(geometry(sensor, front, display, width, height).coordinates, stMatrix(sensor, front), width, height)
        // Handedness of output -> sensor image: a back camera keeps it, the front one is
        // mirrored. Preview and recorder copy the same cached square (no extra flip).
        val determinant = s.right.cross(s.up)
        if (front) assertTrue(determinant < 0) else assertTrue(determinant > 0)
    }

    @Test fun portraitAddsNoRotation() {
        for (sensor in sensors) for (front in listOf(false, true)) {
            assertEquals(0, geometry(sensor, front, 0, 1440, 1080).rotation)
        }
        assertEquals(270, RoundFrameTransform.displayCompensation(90))
        assertEquals(90, RoundFrameTransform.displayCompensation(270))
        assertEquals(180, RoundFrameTransform.displayCompensation(180))
    }

    @Test fun uprightSizeSwapsForRotatedSensors() {
        val back = RoundFrameTransform.forCamera(1440, 1080, RoundFrameTransform.sensorSwapsAxes(90), 0, side)
        assertEquals(1080, back.uprightWidth); assertEquals(1440, back.uprightHeight)
        val flat = RoundFrameTransform.forCamera(1440, 1080, RoundFrameTransform.sensorSwapsAxes(180), 0, side)
        assertEquals(1440, flat.uprightWidth); assertEquals(1080, flat.uprightHeight)
        assertTrue(RoundFrameTransform.sensorSwapsAxes(-90))
    }

    @Test fun downsampleTapsAreIsotropicQuarterOutputPixels() = forEachCase { sensor, display, front, width, height ->
        val case = "sensor=$sensor display=$display front=$front ${width}x$height"
        val m = stMatrix(sensor, front)
        val g = geometry(sensor, front, display, width, height)
        fun pixels(offset: V): Double {
            val a = apply(m, V(0.5, 0.5)); val b = apply(m, V(0.5, 0.5) + offset)
            return V((b.x - a.x) * width, (b.y - a.y) * height).length()
        }
        val expected = 0.25 * min(width, height) / side
        assertEquals(case, expected, pixels(V(g.step[0].toDouble(), 0.0)), 1e-4 * expected)
        assertEquals(case, expected, pixels(V(0.0, g.step[1].toDouble())), 1e-4 * expected)
    }

    /** Guards the harness itself: the pre-fix double rotation and buffer-frame crop fail it. */
    @Test fun legacySensorRotationIsDetectedAsBroken() {
        val sensor = 90; val width = 1440; val height = 1080
        val legacy = RoundFrameTransform.coordinates(width, height, sensor, false)
        val s = sample(legacy, stMatrix(sensor, false), width, height)
        val anisotropy = maxOf(s.right.length(), s.up.length()) / min(s.right.length(), s.up.length())
        assertEquals(16.0 / 9.0, anisotropy, 1e-3)
        val up = world(s.up, sensor, false, 0).unit()
        assertFalse(abs(up.y - 1.0) < 1e-3)
    }

    @Test fun streamSizePrefersFourThreeThenSixteenNine() {
        val sizes = listOf(1366 to 768, 1280 to 960, 1280 to 720, 640 to 480)
        assertEquals(1, RoundStreamSize.select(sizes, side))
        val wide = listOf(1920 to 1080, 1280 to 720, 1000 to 800, 640 to 480)
        assertEquals(0, RoundStreamSize.select(wide, side))
        // Short side never below the round when anything reaches it.
        val small = listOf(640 to 480, 352 to 288, 320 to 240)
        assertEquals(0, RoundStreamSize.select(small, side))
    }

    @Test fun orientationLockRestoresOnceForTheLastOwner() {
        val activity = Any()
        val lock = RoundOrientationLock<Any>()
        var requested = -1 // SCREEN_ORIENTATION_UNSPECIFIED
        val first = Any(); val second = Any()
        requested = lock.acquire(first, activity, requested)
        assertEquals(RoundOrientationLock.LOCKED, requested)
        // A new capture locks before the previous release ran: the original is kept.
        requested = lock.acquire(second, activity, requested)
        assertNull(lock.release(first) { requested })
        val restored = lock.release(second) { requested }!!
        assertSame(activity, restored.first)
        assertEquals(-1, restored.second)
        assertNull(lock.release(second) { requested })
    }

    @Test fun orientationLockLeavesForeignChangesAlone() {
        val activity = Any()
        val lock = RoundOrientationLock<Any>()
        val owner = Any()
        lock.acquire(owner, activity, 1)
        assertNull(lock.release(owner) { 0 }) // someone else requested landscape meanwhile
    }

    @Test fun telegramEncoderDefaultsAreAValidProfile() {
        val profile = RoundProfile(RoundProfile.TELEGRAM_SIDE, 16L * 1024 * 1024,
            RoundProfile.TELEGRAM_MAX_DURATION_MS, RoundProfile.TELEGRAM_VIDEO_BITRATE,
            RoundProfile.TELEGRAM_AUDIO_BITRATE)
        profile.validate()
        assertEquals(384, profile.side)
        assertEquals(1000 * 1024, profile.videoBitrate)
        assertEquals(64 * 1024, profile.audioBitrate)
        assertEquals(30, RoundProfile.FRAME_RATE)
        assertEquals(1, RoundProfile.I_FRAME_INTERVAL_SECONDS)
        assertEquals(48_000, RoundProfile.AUDIO_SAMPLE_RATE)
        assertEquals(1, RoundProfile.AUDIO_CHANNELS)
        assertEquals(800, RoundProfile.TELEGRAM_MIN_DURATION_MS)
    }
}
