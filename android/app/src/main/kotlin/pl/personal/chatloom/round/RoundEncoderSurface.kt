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
import android.view.Surface
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.min

/** The mask is applied here to encoded pixels, never only to the Flutter UI. */
internal class RoundEncoderSurface(private val encoderSurface: Surface, private val side: Int, width: Int, height: Int, rotation: Int) {
    private val display = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
    private val eglContext: android.opengl.EGLContext
    private val window: android.opengl.EGLSurface
    private val program: Int
    private val texture: Int
    private val frameLock = Object()
    private val callbacks: HandlerThread
    private var frameAvailable = false
    private val source: SurfaceTexture
    val decoderSurface: Surface
    private val matrix = FloatArray(16)
    private val vertices = ByteBuffer.allocateDirect(8 * 4).order(ByteOrder.nativeOrder()).asFloatBuffer().apply {
        put(floatArrayOf(-1f, -1f, 1f, -1f, -1f, 1f, 1f, 1f)); position(0)
    }
    private val textureCoordinates = ByteBuffer.allocateDirect(8 * 4).order(ByteOrder.nativeOrder()).asFloatBuffer().apply {
        put(floatArrayOf(0f, 0f, 1f, 0f, 0f, 1f, 1f, 1f)); position(0)
    }
    private val cropX = min(width, height).toFloat() / width
    private val cropY = min(width, height).toFloat() / height
    private val radians = Math.toRadians(rotation.toDouble()).toFloat()

    init {
        val version = IntArray(2)
        check(EGL14.eglInitialize(display, version, 0, version, 1))
        val configAttributes = intArrayOf(EGL14.EGL_RED_SIZE, 8, EGL14.EGL_GREEN_SIZE, 8,
            EGL14.EGL_BLUE_SIZE, 8, EGL14.EGL_ALPHA_SIZE, 8,
            EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT,
            EGL14.EGL_SURFACE_TYPE, EGL14.EGL_WINDOW_BIT, 0x3142, 1, EGL14.EGL_NONE)
        val configs = arrayOfNulls<EGLConfig>(1)
        val count = IntArray(1)
        check(EGL14.eglChooseConfig(display, configAttributes, 0, configs, 0, 1, count, 0) && count[0] > 0)
        eglContext = EGL14.eglCreateContext(display, configs[0], EGL14.EGL_NO_CONTEXT,
            intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 2, EGL14.EGL_NONE), 0)
        window = EGL14.eglCreateWindowSurface(display, configs[0], encoderSurface, intArrayOf(EGL14.EGL_NONE), 0)
        check(eglContext != EGL14.EGL_NO_CONTEXT && window != EGL14.EGL_NO_SURFACE)
        check(EGL14.eglMakeCurrent(display, window, window, eglContext))
        program = GLES20.glCreateProgram()
        GLES20.glAttachShader(program, shader(GLES20.GL_VERTEX_SHADER, VERTEX))
        GLES20.glAttachShader(program, shader(GLES20.GL_FRAGMENT_SHADER, FRAGMENT))
        GLES20.glLinkProgram(program)
        val linked = IntArray(1)
        GLES20.glGetProgramiv(program, GLES20.GL_LINK_STATUS, linked, 0)
        check(linked[0] == GLES20.GL_TRUE)
        val textures = IntArray(1)
        GLES20.glGenTextures(1, textures, 0)
        texture = textures[0]
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, texture)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)
        source = SurfaceTexture(texture)
        callbacks = HandlerThread("PersonalRoundExport").apply { start() }
        // A private callback thread: trim/fallback exports never wait for a busy
        // UI (main) looper between decoded frames.
        source.setOnFrameAvailableListener({
            synchronized(frameLock) { frameAvailable = true; frameLock.notifyAll() }
        }, Handler(callbacks.looper))
        decoderSurface = Surface(source)
    }

    fun awaitFrame(canceled: AtomicBoolean) {
        synchronized(frameLock) {
            val end = System.nanoTime() + 5000000000L
            while (!frameAvailable) {
                require(!canceled.get() && System.nanoTime() < end)
                frameLock.wait(100)
            }
            frameAvailable = false
        }
        source.updateTexImage()
        source.getTransformMatrix(matrix)
    }

    fun draw(timestampNs: Long) {
        GLES20.glViewport(0, 0, side, side)
        GLES20.glUseProgram(program)
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, texture)
        GLES20.glUniform1i(GLES20.glGetUniformLocation(program, "uTexture"), 0)
        GLES20.glUniformMatrix4fv(GLES20.glGetUniformLocation(program, "uMatrix"), 1, false, matrix, 0)
        GLES20.glUniform2f(GLES20.glGetUniformLocation(program, "uCrop"), cropX, cropY)
        GLES20.glUniform1f(GLES20.glGetUniformLocation(program, "uRotation"), radians)
        val position = GLES20.glGetAttribLocation(program, "aPosition")
        val coordinate = GLES20.glGetAttribLocation(program, "aCoordinate")
        vertices.position(0); textureCoordinates.position(0)
        GLES20.glEnableVertexAttribArray(position)
        GLES20.glVertexAttribPointer(position, 2, GLES20.GL_FLOAT, false, 0, vertices)
        GLES20.glEnableVertexAttribArray(coordinate)
        GLES20.glVertexAttribPointer(coordinate, 2, GLES20.GL_FLOAT, false, 0, textureCoordinates)
        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
        check(GLES20.glGetError() == GLES20.GL_NO_ERROR)
        check(EGLExt.eglPresentationTimeANDROID(display, window, timestampNs))
        check(EGL14.eglSwapBuffers(display, window))
    }

    fun close() {
        callbacks.quitSafely()
        decoderSurface.release(); source.release()
        GLES20.glDeleteProgram(program)
        GLES20.glDeleteTextures(1, intArrayOf(texture), 0)
        EGL14.eglMakeCurrent(display, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT)
        EGL14.eglDestroySurface(display, window)
        EGL14.eglDestroyContext(display, eglContext)
        EGL14.eglReleaseThread(); EGL14.eglTerminate(display)
        encoderSurface.release()
    }

    private fun shader(type: Int, code: String): Int {
        val result = GLES20.glCreateShader(type)
        GLES20.glShaderSource(result, code)
        GLES20.glCompileShader(result)
        val compiled = IntArray(1)
        GLES20.glGetShaderiv(result, GLES20.GL_COMPILE_STATUS, compiled, 0)
        check(compiled[0] == GLES20.GL_TRUE)
        return result
    }

    companion object {
        private const val VERTEX = """
            attribute vec2 aPosition;
            attribute vec2 aCoordinate;
            varying vec2 vCoordinate;
            void main() { gl_Position = vec4(aPosition, 0.0, 1.0); vCoordinate = aCoordinate; }
        """
        private const val FRAGMENT = """
            #extension GL_OES_EGL_image_external : require
            precision mediump float;
            uniform samplerExternalOES uTexture;
            uniform mat4 uMatrix;
            uniform vec2 uCrop;
            uniform float uRotation;
            varying vec2 vCoordinate;
            void main() {
                vec2 point = vCoordinate - vec2(0.5);
                if (dot(point, point) > 0.25) { gl_FragColor = vec4(0.0, 0.0, 0.0, 1.0); return; }
                float c = cos(uRotation); float s = sin(uRotation);
                vec2 rotated = mat2(c, s, -s, c) * point;
                vec2 cropped = rotated * uCrop + vec2(0.5);
                vec2 coordinate = (uMatrix * vec4(cropped, 0.0, 1.0)).xy;
                gl_FragColor = texture2D(uTexture, coordinate);
            }
        """
    }
}
