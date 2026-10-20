// SPDX-License-Identifier: AGPL-3.0-or-later
package pl.personal.chatloom.round

import android.graphics.SurfaceTexture
import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLExt
import android.opengl.GLES11Ext
import android.opengl.GLES20
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import android.view.Surface
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.Callable
import java.util.concurrent.FutureTask
import java.util.concurrent.TimeUnit

/**
 * Camera2 owns only [Input.surface]. GL owns both output EGL windows and its cached
 * square frame. The recorder/audio and encoder window survive camera replacement.
 * A 30fps pump repeats the last image during replacement, preserving the live A/V
 * timeline without pausing the microphone. Real pause stops encoder submissions.
 */
internal class RoundCameraSurface(private val preview: Surface, private val side: Int,
                                  private val previewGate: RoundPreviewGate,
                                  private val onFailure: () -> Unit) {
    class Input internal constructor(val surface: Surface, internal val source: SurfaceTexture,
                                     internal val texture: Int, internal val bufferWidth: Int,
                                     internal val bufferHeight: Int, internal val expectedSwap: Boolean,
                                     internal val displayDegrees: Int, geometry: RoundFrameGeometry) {
        internal var geometry = geometry
            set(value) { field = value; coordinates = buffer(value.coordinates) }
        internal var coordinates = buffer(geometry.coordinates)
            private set
        internal var verified = false
        /** GL thread only: a frame of this input reached the cache. */
        internal var delivered = false
        /** GL thread only: runs once, after the first cached frame ([whenFrame]). */
        internal var firstFrame: (() -> Unit)? = null
    }
    private val thread = HandlerThread("PersonalRoundGL").apply { start() }
    private val handler = Handler(thread.looper)
    private var display = EGL14.EGL_NO_DISPLAY
    private var context = EGL14.EGL_NO_CONTEXT
    private var config: EGLConfig? = null
    private var previewWindow = EGL14.EGL_NO_SURFACE
    private var recorderWindow = EGL14.EGL_NO_SURFACE
    private var cameraProgram = 0
    private var copyProgram = 0
    private var cacheTexture = 0
    private var framebuffer = 0
    private var current: Input? = null
    private val inputs = mutableSetOf<Input>()
    private var hasImage = false
    private var encoding = false
    @Volatile private var closed = false
    private var failed = false
    private var retired = false
    private val clock = RoundFrameClock()
    /**
     * Receives the next recorded frame's pixels once ([snapshotNextRecordedFrame]).
     * Written and read only on the GL thread (writers post through [handler]);
     * volatile as well, so no other thread can ever observe a stale value.
     */
    @Volatile private var snapshot: ((ByteBuffer) -> Unit)? = null
    private val matrix = FloatArray(16)
    private val corners = buffer(floatArrayOf(-1f, -1f, 1f, -1f, -1f, 1f, 1f, 1f))
    private val ordinary = buffer(floatArrayOf(0f, 0f, 1f, 0f, 0f, 1f, 1f, 1f))

    /**
     * [width]x[height] is the Camera2 stream (sensor buffer) size. The SurfaceTexture
     * transform already rotates by [sensorOrientation] and mirrors the front camera, so
     * the cache pass only crops in the upright frame and undoes [displayDegrees].
     */
    fun newInput(width: Int, height: Int, sensorOrientation: Int, displayDegrees: Int): Input = run {
        check(!closed)
        makePreviewCurrent()
        val texture = IntArray(1)
        GLES20.glGenTextures(1, texture, 0)
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, texture[0])
        parameters(GLES11Ext.GL_TEXTURE_EXTERNAL_OES)
        val source = SurfaceTexture(texture[0])
        source.setDefaultBufferSize(width, height)
        val swapped = RoundFrameTransform.sensorSwapsAxes(sensorOrientation)
        val input = Input(Surface(source), source, texture[0], width, height, swapped, displayDegrees,
            RoundFrameTransform.forCamera(width, height, swapped, displayDegrees, side))
        inputs += input
        current = input
        source.setOnFrameAvailableListener({
            if (!closed && !failed && !retired && current === input) try {
                makePreviewCurrent()
                source.updateTexImage()
                source.getTransformMatrix(matrix)
                verify(input)
                cache(input)
                if (!input.delivered) {
                    input.delivered = true
                    input.firstFrame?.let { action -> input.firstFrame = null; action() }
                }
            } catch (_: Exception) { fail() }
        }, handler)
        input
    }

    /**
     * Runs [action] on the GL thread once [input] has cached a frame (immediately when
     * it already has). Camera opens and flips report "ready" when the new lens is
     * visible, not merely configured. Never runs after [close].
     */
    fun whenFrame(input: Input, action: () -> Unit) {
        if (closed) return
        handler.post {
            if (closed || failed) return@post
            if (input.delivered) action() else input.firstFrame = action
        }
    }

    /**
     * Telegram takes the round thumbnail from the first camera frame. Hands the next
     * frame that is sent to the recorder ([side]x[side] RGBA, rows bottom-up) to
     * [consumer] once, on the GL thread; the consumer must hand heavy work off.
     */
    fun snapshotNextRecordedFrame(consumer: (ByteBuffer) -> Unit) {
        if (closed) return
        // Posted to the GL thread (the only reader) instead of a blocking hand-off:
        // the camera thread never waits on GL work for a thumbnail.
        handler.post { if (!closed && !failed && !retired) snapshot = consumer }
    }

    /**
     * The crop must be measured in the frame the transform actually outputs. A device
     * whose transform disagrees with SENSOR_ORIENTATION keeps an undistorted square
     * (its orientation is then the vendor's); the mismatch is logged once per input.
     */
    private fun verify(input: Input) {
        if (input.verified) return
        input.verified = true
        val swapped = RoundFrameTransform.matrixSwapsAxes(matrix)
        if (swapped == input.expectedSwap) return
        Log.w(TAG, "Camera transform rotation differs from sensor orientation; cropping in the transform's frame")
        input.geometry = RoundFrameTransform.forCamera(input.bufferWidth, input.bufferHeight, swapped,
            input.displayDegrees, side)
    }

    /** Retired inputs are released only after their CameraDevice.onClosed callback. */
    fun releaseInput(input: Input) {
        if (closed) return
        run {
        if (inputs.remove(input)) {
            if (current === input) current = null
            makePreviewCurrent()
            input.source.setOnFrameAvailableListener(null)
            input.surface.release(); input.source.release()
            GLES20.glDeleteTextures(1, intArrayOf(input.texture), 0)
        }
        }
    }

    fun attachRecorder(surface: Surface) = run {
        check(!closed && recorderWindow == EGL14.EGL_NO_SURFACE)
        recorderWindow = EGL14.eglCreateWindowSurface(display, config, surface, intArrayOf(EGL14.EGL_NONE), 0)
        check(recorderWindow != EGL14.EGL_NO_SURFACE)
        // The caller/MediaRecorder owns surface; this class destroys only its EGL window.
    }

    fun encoding(enabled: Boolean) = run { check(!closed); encoding = enabled }

    fun detachRecorder() = run {
        encoding = false
        if (recorderWindow != EGL14.EGL_NO_SURFACE) {
            makePreviewCurrent()
            EGL14.eglDestroySurface(display, recorderWindow)
            recorderWindow = EGL14.EGL_NO_SURFACE
        }
    }

    /** Stop display/encoder work while terminal CameraDevice.onClosed retires inputs. */
    fun retire() = run {
        encoding = false; retired = true; current = null; snapshot = null
        handler.removeCallbacks(pump)
    }

    private val pump = object : Runnable {
        override fun run() {
            if (closed || failed || retired) return
            try {
                makePreviewCurrent()
                if (encoding && recorderWindow != EGL14.EGL_NO_SURFACE) {
                    if (hasImage) snapshot?.let { consumer -> snapshot = null; deliverSnapshot(consumer) }
                    copy(recorderWindow, clock.next(System.nanoTime()))
                }
                // Flutter consumes one preview buffer before another is submitted.
                // Its visibility/lifecycle cannot block the independent encoder pump.
                if (previewGate.acquire()) copy(previewWindow)
            } catch (_: Exception) { fail(); return }
            handler.postDelayed(this, 33)
        }
    }

    // The pump must be initialized before initialize() can post it to its thread.
    init { try { run { initialize() } } catch (error: Exception) { close(); throw error } }

    /** A failed thumbnail read never affects the recording: the exporter decodes one instead. */
    private fun deliverSnapshot(consumer: (ByteBuffer) -> Unit) {
        try {
            val pixels = ByteBuffer.allocateDirect(side * side * 4).order(ByteOrder.nativeOrder())
            GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, framebuffer)
            GLES20.glReadPixels(0, 0, side, side, GLES20.GL_RGBA, GLES20.GL_UNSIGNED_BYTE, pixels)
            GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, 0)
            val ok = GLES20.glGetError() == GLES20.GL_NO_ERROR
            drainErrors()
            if (ok) consumer(pixels)
        } catch (_: Exception) {
            try { GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, 0) } catch (_: Exception) { }
            drainErrors()
        }
    }

    private fun drainErrors() {
        var remaining = 16
        while (remaining-- > 0 && GLES20.glGetError() != GLES20.GL_NO_ERROR) { /* bounded */ }
    }

    private fun fail() {
        if (!closed && !failed) { failed = true; encoding = false; handler.removeCallbacks(pump); onFailure() }
    }

    private fun initialize() {
        display = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
        val version = IntArray(2)
        check(EGL14.eglInitialize(display, version, 0, version, 1))
        val configs = arrayOfNulls<EGLConfig>(1)
        val count = IntArray(1)
        check(EGL14.eglChooseConfig(display, intArrayOf(EGL14.EGL_RED_SIZE, 8,
            EGL14.EGL_GREEN_SIZE, 8, EGL14.EGL_BLUE_SIZE, 8, EGL14.EGL_ALPHA_SIZE, 8,
            EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT,
            EGL14.EGL_SURFACE_TYPE, EGL14.EGL_WINDOW_BIT, 0x3142, 1, EGL14.EGL_NONE),
            0, configs, 0, 1, count, 0) && count[0] > 0)
        config = configs[0]
        context = EGL14.eglCreateContext(display, config, EGL14.EGL_NO_CONTEXT,
            intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 2, EGL14.EGL_NONE), 0)
        previewWindow = EGL14.eglCreateWindowSurface(display, config, preview, intArrayOf(EGL14.EGL_NONE), 0)
        check(context != EGL14.EGL_NO_CONTEXT && previewWindow != EGL14.EGL_NO_SURFACE)
        makePreviewCurrent()
        cameraProgram = program(CAMERA_FRAGMENT)
        copyProgram = program(COPY_FRAGMENT)
        val ids = IntArray(1)
        GLES20.glGenTextures(1, ids, 0); cacheTexture = ids[0]
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, cacheTexture)
        parameters(GLES20.GL_TEXTURE_2D)
        GLES20.glTexImage2D(GLES20.GL_TEXTURE_2D, 0, GLES20.GL_RGBA, side, side, 0,
            GLES20.GL_RGBA, GLES20.GL_UNSIGNED_BYTE, null)
        GLES20.glGenFramebuffers(1, ids, 0); framebuffer = ids[0]
        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, framebuffer)
        GLES20.glFramebufferTexture2D(GLES20.GL_FRAMEBUFFER, GLES20.GL_COLOR_ATTACHMENT0,
            GLES20.GL_TEXTURE_2D, cacheTexture, 0)
        check(GLES20.glCheckFramebufferStatus(GLES20.GL_FRAMEBUFFER) == GLES20.GL_FRAMEBUFFER_COMPLETE)
        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, 0)
        handler.post(pump)
    }

    private fun cache(input: Input) {
        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, framebuffer)
        GLES20.glViewport(0, 0, side, side)
        GLES20.glUseProgram(cameraProgram)
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, input.texture)
        GLES20.glUniform1i(GLES20.glGetUniformLocation(cameraProgram, "uTexture"), 0)
        GLES20.glUniformMatrix4fv(GLES20.glGetUniformLocation(cameraProgram, "uMatrix"), 1, false, matrix, 0)
        val step = input.geometry.step
        GLES20.glUniform2f(GLES20.glGetUniformLocation(cameraProgram, "uStep"), step[0], step[1])
        draw(cameraProgram, input.coordinates)
        check(GLES20.glGetError() == GLES20.GL_NO_ERROR)
        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, 0)
        hasImage = true
    }

    private fun copy(window: android.opengl.EGLSurface, timestamp: Long? = null) {
        check(EGL14.eglMakeCurrent(display, window, window, context))
        GLES20.glViewport(0, 0, side, side)
        GLES20.glClearColor(0f, 0f, 0f, 1f)
        GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)
        if (hasImage) {
            GLES20.glUseProgram(copyProgram)
            GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
            GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, cacheTexture)
            GLES20.glUniform1i(GLES20.glGetUniformLocation(copyProgram, "uTexture"), 0)
            // Preview and recorder get the identical cached square: a front-camera round
            // is saved mirrored, exactly as previewed (Telegram parity).
            draw(copyProgram, ordinary)
        }
        check(GLES20.glGetError() == GLES20.GL_NO_ERROR)
        if (timestamp != null) check(EGLExt.eglPresentationTimeANDROID(display, window, timestamp))
        check(EGL14.eglSwapBuffers(display, window))
    }

    private fun draw(program: Int, coordinates: java.nio.FloatBuffer) {
        val position = GLES20.glGetAttribLocation(program, "aPosition")
        val coordinate = GLES20.glGetAttribLocation(program, "aCoordinate")
        corners.position(0); coordinates.position(0)
        GLES20.glEnableVertexAttribArray(position)
        GLES20.glVertexAttribPointer(position, 2, GLES20.GL_FLOAT, false, 0, corners)
        GLES20.glEnableVertexAttribArray(coordinate)
        GLES20.glVertexAttribPointer(coordinate, 2, GLES20.GL_FLOAT, false, 0, coordinates)
        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
    }

    private fun makePreviewCurrent() {
        check(EGL14.eglMakeCurrent(display, previewWindow, previewWindow, context))
    }

    fun close() {
        if (closed) return
        try { run {
            if (closed) return@run
            closed = true; encoding = false
            handler.removeCallbacksAndMessages(null)
            if (context != EGL14.EGL_NO_CONTEXT && previewWindow != EGL14.EGL_NO_SURFACE) {
                makePreviewCurrent()
                inputs.toList().forEach { input ->
                    input.source.setOnFrameAvailableListener(null)
                    input.surface.release(); input.source.release()
                    GLES20.glDeleteTextures(1, intArrayOf(input.texture), 0)
                }
                inputs.clear(); current = null
                GLES20.glDeleteProgram(cameraProgram); GLES20.glDeleteProgram(copyProgram)
                GLES20.glDeleteTextures(1, intArrayOf(cacheTexture), 0)
                GLES20.glDeleteFramebuffers(1, intArrayOf(framebuffer), 0)
            }
            EGL14.eglMakeCurrent(display, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT)
            if (recorderWindow != EGL14.EGL_NO_SURFACE) EGL14.eglDestroySurface(display, recorderWindow)
            if (previewWindow != EGL14.EGL_NO_SURFACE) EGL14.eglDestroySurface(display, previewWindow)
            if (context != EGL14.EGL_NO_CONTEXT) EGL14.eglDestroyContext(display, context)
            if (display != EGL14.EGL_NO_DISPLAY) EGL14.eglTerminate(display)
            EGL14.eglReleaseThread()
        } } finally { thread.quitSafely() }
    }

    private fun <T> run(action: () -> T): T {
        if (android.os.Looper.myLooper() == handler.looper) return action()
        val pending = FutureTask(Callable { action() })
        check(handler.post(pending))
        return pending.get(5, TimeUnit.SECONDS)
    }

    companion object {
        private const val TAG = "PersonalRound"
        private fun buffer(values: FloatArray) = ByteBuffer.allocateDirect(values.size * 4)
            .order(ByteOrder.nativeOrder()).asFloatBuffer().apply { put(values); position(0) }
        private fun parameters(target: Int) {
            GLES20.glTexParameteri(target, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
            GLES20.glTexParameteri(target, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
            GLES20.glTexParameteri(target, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
            GLES20.glTexParameteri(target, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)
        }
        private fun program(fragment: String): Int {
            val program = GLES20.glCreateProgram()
            listOf(GLES20.GL_VERTEX_SHADER to VERTEX, GLES20.GL_FRAGMENT_SHADER to fragment).forEach { (type, code) ->
                val shader = GLES20.glCreateShader(type)
                GLES20.glShaderSource(shader, code); GLES20.glCompileShader(shader)
                val ok = IntArray(1); GLES20.glGetShaderiv(shader, GLES20.GL_COMPILE_STATUS, ok, 0)
                check(ok[0] == GLES20.GL_TRUE)
                GLES20.glAttachShader(program, shader); GLES20.glDeleteShader(shader)
            }
            GLES20.glLinkProgram(program)
            val ok = IntArray(1); GLES20.glGetProgramiv(program, GLES20.GL_LINK_STATUS, ok, 0)
            check(ok[0] == GLES20.GL_TRUE)
            return program
        }
        // Camera streams are up to 1920 px: mediump (fp16) texture coordinates would
        // quantise sampling to blocks, so coordinates use highp where available.
        private const val VERTEX = """
            attribute vec2 aPosition; attribute vec2 aCoordinate;
            varying vec2 vCoordinate; varying vec2 vOutput;
            void main() { gl_Position = vec4(aPosition, 0.0, 1.0);
                vCoordinate = aCoordinate; vOutput = aPosition * 0.5; }
        """
        private const val CAMERA_FRAGMENT = """
            #extension GL_OES_EGL_image_external : require
            #ifdef GL_FRAGMENT_PRECISION_HIGH
            precision highp float;
            #else
            precision mediump float;
            #endif
            uniform samplerExternalOES uTexture; uniform mat4 uMatrix; uniform vec2 uStep;
            varying vec2 vCoordinate; varying vec2 vOutput;
            vec4 tap(vec2 offset) { return texture2D(uTexture, (uMatrix * vec4(vCoordinate + offset, 0.0, 1.0)).xy); }
            void main() {
                if (dot(vOutput, vOutput) > 0.25) { gl_FragColor = vec4(0.0, 0.0, 0.0, 1.0); return; }
                // Four bilinear taps cover the output pixel: an area filter for the
                // oversampled camera stream instead of aliasing single-tap minification.
                gl_FragColor = 0.25 * (tap(vec2(-uStep.x, -uStep.y)) + tap(vec2(uStep.x, -uStep.y)) +
                    tap(vec2(-uStep.x, uStep.y)) + tap(uStep));
            }
        """
        private const val COPY_FRAGMENT = """
            precision mediump float; uniform sampler2D uTexture; varying vec2 vCoordinate;
            void main() { gl_FragColor = texture2D(uTexture, vCoordinate); }
        """
    }
}
