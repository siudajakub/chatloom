// SPDX-License-Identifier: AGPL-3.0-or-later
package pl.personal.chatloom.round

import android.Manifest
import android.app.Activity
import android.app.Application
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.Rect
import android.graphics.SurfaceTexture
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CaptureRequest
import android.media.MediaRecorder
import android.media.AudioManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.HandlerThread
import android.os.SystemClock
import android.util.Log
import android.util.Size
import android.view.Surface
import android.view.WindowManager
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import io.flutter.view.TextureRegistry
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.Callable
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.FutureTask
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.roundToInt

/** Native capture runs only inside a locked MediaAccess lease owned by Dart. */
class TelegramRoundPlugin : FlutterPlugin, ActivityAware, MethodChannel.MethodCallHandler,
    PluginRegistry.RequestPermissionsResultListener, Application.ActivityLifecycleCallbacks {
    private lateinit var context: Context
    private lateinit var textures: TextureRegistry
    private lateinit var channel: MethodChannel
    private val main = Handler(android.os.Looper.getMainLooper())
    private val cameraThread = HandlerThread("PersonalRoundCamera").apply { start() }
    private val cameraHandler = Handler(cameraThread.looper)
    private val exporter = Executors.newSingleThreadExecutor()
    private var activity: Activity? = null
    private var activityBinding: ActivityPluginBinding? = null
    private var permissionCall: Pair<MethodCall, MethodChannel.Result>? = null
    @Volatile private var session: Capture? = null
    private var permissionRequestInFlight = false
    private var permissionGrantedWaiting = false
    @Volatile private var activityVisible = false
    @Volatile private var attached = false
    /** Main thread only. */
    private val orientationLock = RoundOrientationLock<Activity>()
    /**
     * Static per-lens metadata. Each CameraManager lookup is a binder round trip; a
     * flip used to make about a dozen of them on the critical path.
     */
    private val characteristics = ConcurrentHashMap<String, CameraCharacteristics>()

    private fun characteristicsOf(id: String): CameraCharacteristics =
        characteristics[id] ?: cameraManager().getCameraCharacteristics(id).also { characteristics[id] = it }

    /** All asynchronous cancel/failure/callback paths may complete a call only once. */
    private inner class OnceResult(private val delegate: MethodChannel.Result) : MethodChannel.Result {
        private val completed = AtomicBoolean(false)
        override fun success(value: Any?) { if (completed.compareAndSet(false, true)) main.post { delegate.success(value) } }
        override fun error(code: String, message: String?, details: Any?) {
            if (completed.compareAndSet(false, true)) main.post { delegate.error(code, message, details) }
        }
        override fun notImplemented() { if (completed.compareAndSet(false, true)) main.post { delegate.notImplemented() } }
    }

    private class CaptureFailure(val code: String) : Exception()

    private data class Controls(val zoom: RoundZoomRange, val ratio: Boolean, val activeArray: Rect?,
                                val torch: Boolean)

    private class Capture(val id: String, val directory: File, val output: File, val profile: RoundProfile) {
        /** Display rotation frozen when the round opens; the activity orientation is locked with it. */
        var displayDegrees = 0
        val canceled = AtomicBoolean(false)
        var texture: TextureRegistry.SurfaceTextureEntry? = null
        var previewSurface: Surface? = null
        var compositor: RoundCameraSurface? = null
        val previewGate = RoundPreviewGate()
        var input: RoundCameraSurface.Input? = null
        var camera: CameraDevice? = null
        var cameraSession: CameraCaptureSession? = null
        var recorder: MediaRecorder? = null
        var recorderSurface: Surface? = null
        var front = true
        var size = Size(640, 480)
        var sensorOrientation = 0
        val epoch = RoundCameraEpoch()
        var cameraRevision = 0L
        var cameraId: String? = null
        var closingCamera: CameraDevice? = null
        val devices = mutableSetOf<CameraDevice>()
        var retiringHardware = false
        var hardwareCloseTimeout: Runnable? = null
        var releaseTextureWhenClosed = false
        var cameraReady = false
        var zoom = 1.0
        var torch = false
        var zoomDisabled = false
        var torchDisabled = false
        var enhancementsDisabled = false
        var pendingResult: MethodChannel.Result? = null
        var openingFailure: (() -> Unit)? = null
        var openingTimeout: Runnable? = null
        var firstFrameTimeout: Runnable? = null
        var closingContinuation: (() -> Unit)? = null
        var closeTimeout: Runnable? = null
        var recording = false
        var paused = false
        var interrupted = false
        var stopFailed = false
        var preparing = false
        var prepared: Map<String, Any>? = null
        var trimTransaction: RoundTrimTransaction? = null
        var preparationResult: MethodChannel.Result? = null
        val finishWaiters = mutableListOf<MethodChannel.Result>()
        var focusListener: AudioManager.OnAudioFocusChangeListener? = null
        var stopMs = 0L
        val raw get() = File(directory, "capture.raw.mp4")
        val liveThumbnail get() = File(directory, RoundVideoExporter.LIVE_THUMBNAIL)
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        attached = true
        context = binding.applicationContext
        textures = binding.textureRegistry
        channel = MethodChannel(binding.binaryMessenger, "pl.personal.chat/round_capture")
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        attached = false
        channel.setMethodCallHandler(null)
        permissionCall?.let { failure(it.second, "interrupted") }; permissionCall = null
        cameraHandler.post {
            val capture = session
            abandon()
            if (capture == null || capture.devices.isEmpty()) cameraThread.quitSafely()
            else cameraHandler.postDelayed({ releasePreview(capture); cameraThread.quitSafely() }, 5500)
        }
        exporter.shutdown()
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        activityVisible = true
        activityBinding = binding
        binding.addRequestPermissionsResultListener(this)
        binding.activity.application.registerActivityLifecycleCallbacks(this)
    }

    private fun detachActivity() {
        activityBinding?.removeRequestPermissionsResultListener(this)
        activity?.application?.unregisterActivityLifecycleCallbacks(this)
        activityBinding = null
        activityVisible = false
        activity = null
        permissionCall?.let { failure(it.second, "interrupted") }
        permissionCall = null
        permissionGrantedWaiting = false
        cameraHandler.post {
            session?.let {
                if (it.recording || it.paused) { it.interrupted = true; finish(it, null) }
                else if (!it.preparing && it.prepared == null) abandon()
            }
        }
    }
    override fun onDetachedFromActivity() = detachActivity()
    override fun onDetachedFromActivityForConfigChanges() = detachActivity()
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) =
        onAttachedToActivity(binding)

    override fun onMethodCall(call: MethodCall, rawResult: MethodChannel.Result) {
        val result = OnceResult(rawResult)
        if (Build.VERSION.SDK_INT < 24) {
            failure(result, "unsupported_android")
            return
        }
        if (call.method == "cancel" || call.method == "dispose") {
            if (permissionCall?.first?.argument<String>("captureId") == call.argument<String>("captureId")) {
                permissionCall?.let { failure(it.second, "canceled") }
                permissionCall = null
                permissionGrantedWaiting = false
            }
        }
        if (call.method == "initialize") {
            val requestedId = call.argument<String>("captureId")
            if (requestedId.isNullOrBlank() || requestedId.length > 128) {
                failure(result, "stale_capture")
                return
            }
            if (session != null || permissionRequestInFlight || permissionCall != null) {
                failure(result, "busy")
                return
            }
            val targetActivity = activity
            if (targetActivity == null || !activityVisible) {
                failure(result, "no_activity")
                return
            }
            val missing = listOf(Manifest.permission.CAMERA, Manifest.permission.RECORD_AUDIO)
                .filter { targetActivity.checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED }
            if (missing.isNotEmpty()) {
                if (permissionRequestInFlight) {
                    failure(result, "busy")
                    return
                }
                permissionCall = call to result
                permissionRequestInFlight = true
                try { targetActivity.requestPermissions(missing.toTypedArray(), PERMISSION_REQUEST) }
                catch (_: Exception) {
                    permissionCall = null; permissionRequestInFlight = false
                    failure(result, "permission_denied")
                }
                return
            }
        }
        cameraHandler.post {
            try {
                if (!attached) throw CaptureFailure("interrupted")
                when (call.method) {
                    "initialize" -> initialize(call, result)
                    "start" -> start(requireSession(call), result)
                    "pause" -> {
                        val capture = requireSession(call)
                        requireIdle(capture)
                        if (capture.paused) { success(result, null); return@post }
                        if (!capture.recording) throw CaptureFailure("not_recording")
                        capture.compositor!!.encoding(false)
                        capture.recorder!!.pause()
                        capture.paused = true
                        capture.recording = false
                        success(result, null)
                    }
                    "resume" -> {
                        val capture = requireSession(call)
                        requireIdle(capture)
                        if (capture.recording) { success(result, null); return@post }
                        if (!capture.paused) throw CaptureFailure("not_recording")
                        capture.recorder!!.resume()
                        capture.compositor!!.encoding(true)
                        capture.paused = false
                        capture.recording = true
                        success(result, null)
                    }
                    "finish" -> finish(requireSession(call), result)
                    "trim" -> trim(requireSession(call), call, result)
                    "switchCamera" -> switchCamera(requireSession(call), call, result)
                    "setZoom" -> setZoom(requireSession(call), call, result)
                    "setTorch" -> setTorch(requireSession(call), call, result)
                    "cancel" -> {
                        if (session?.id == call.argument<String>("captureId")) abandon()
                        success(result, null)
                    }
                    "dispose" -> {
                        val keep = call.argument<Boolean>("keepPrepared") == true
                        if (session?.id == call.argument<String>("captureId")) abandon(keep)
                        success(result, null)
                    }
                    else -> main.post { result.notImplemented() }
                }
            } catch (error: Exception) {
                val current = session?.takeIf { it.id == call.argument<String>("captureId") }
                var safelyFinishing = false
                if (current != null && error !is CaptureFailure) {
                    if (call.method in listOf("start", "pause", "resume") && (current.recording || current.paused)) {
                        current.interrupted = true
                        finish(current, null)
                        safelyFinishing = true
                    } else if (call.method in listOf("switchCamera", "setZoom", "setTorch")) {
                        current.cameraReady = false
                        if (current.recording || current.paused) {
                            current.interrupted = true
                            finish(current, null)
                            safelyFinishing = true
                        } else {
                            emit(current, mapOf("type" to "error", "code" to "camera_unavailable"))
                            abandon()
                        }
                    } else if (call.method == "initialize" || call.method == "start") abandon()
                }
                failure(result, if (safelyFinishing) "interrupted" else if (error is CaptureFailure) error.code else "capture_failed")
            }
        }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray): Boolean {
        if (requestCode != PERMISSION_REQUEST) return false
        permissionRequestInFlight = false
        val pending = permissionCall ?: return true
        permissionCall = null
        if (grantResults.isEmpty() || grantResults.any { it != PackageManager.PERMISSION_GRANTED }) {
            failure(pending.second, "permission_denied")
        } else if (!activityVisible) {
            permissionCall = pending
            permissionGrantedWaiting = true
        } else {
            onMethodCall(pending.first, pending.second)
        }
        return true
    }

    private fun requireSession(call: MethodCall): Capture {
        val capture = session ?: throw CaptureFailure("stale_capture")
        if (capture.id != call.argument<String>("captureId")) throw CaptureFailure("stale_capture")
        return capture
    }

    private fun requireIdle(capture: Capture) {
        if (capture.preparing || capture.prepared != null) throw CaptureFailure("not_recording")
        val permissionDenied = context.checkSelfPermission(Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED ||
            context.checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED
        if (!activityVisible || permissionDenied) {
            val code = if (permissionDenied) "permission_denied" else "interrupted"
            capture.cameraReady = false
            if (capture.recording || capture.paused) {
                capture.interrupted = true
                finish(capture, null)
                throw CaptureFailure("interrupted")
            }
            emit(capture, mapOf("type" to "error", "code" to code))
            abandon()
            throw CaptureFailure(code)
        }
        if (capture.pendingResult != null || !capture.cameraReady) throw CaptureFailure("busy")
    }

    private fun requireRevision(capture: Capture, call: MethodCall) {
        requireIdle(capture)
        if (call.argument<Number>("cameraRevision")?.toLong() != capture.cameraRevision)
            throw CaptureFailure("stale_camera")
    }

    private fun initialize(call: MethodCall, result: MethodChannel.Result) {
        if (session != null) throw CaptureFailure("busy")
        if (!activityVisible || activity == null) throw CaptureFailure("interrupted")
        val id = call.argument<String>("captureId") ?: throw CaptureFailure("stale_capture")
        require(id.isNotBlank() && id.length <= 128)
        val directory = File(call.argument<String>("directory") ?: error("directory")).canonicalFile
        val privateRoot = context.filesDir.parentFile!!.canonicalFile
        require(directory.path.startsWith(privateRoot.path + File.separator))
        require(directory.isDirectory && File(directory, ".lock").isFile)
        require(directory.name.startsWith("lease_"))
        val output = File(call.argument<String>("outputPath") ?: error("output")).canonicalFile
        require(output == File(directory, "media.mp4").canonicalFile)
        val profile = RoundProfile(
            call.argument<Number>("side")!!.toInt(),
            call.argument<Number>("maxBytes")!!.toLong(),
            call.argument<Number>("maxDurationMs")!!.toInt(),
            call.argument<Number>("videoBitrate")!!.toInt(),
            call.argument<Number>("audioBitrate")!!.toInt(),
            // Absent/unknown quality flags keep the previous capture behaviour.
            stabilize = call.argument<Any>("stabilize") == true,
            noiseReduction = call.argument<Any>("noiseReduction") == true,
            highQuality = call.argument<Any>("highQuality") == true,
        )
        profile.validate()
        val capture = Capture(id, directory, output, profile)
        session = capture
        // Like Telegram, freeze the screen orientation for the round and keep the
        // display rotation read under that lock for every camera of this capture.
        capture.displayDegrees = onMain { lockOrientation(capture) }
        main.post { if (session === capture && !capture.canceled.get())
            activity?.window?.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON) }
        capture.texture = onMain { textures.createSurfaceTexture().also { entry ->
            entry.setOnFrameConsumedListener { capture.previewGate.consumed() }
        } }
        capture.texture!!.surfaceTexture().setDefaultBufferSize(profile.side, profile.side)
        capture.previewSurface = Surface(capture.texture!!.surfaceTexture())
        capture.compositor = RoundCameraSurface(capture.previewSurface!!, profile.side, capture.previewGate) {
            cameraHandler.post {
                if (session === capture && !capture.canceled.get() && !capture.preparing && capture.prepared == null) {
                    // GL failure is fatal to future recording; leave already-recorded bytes
                    // available for export whenever MediaRecorder can stop successfully.
                    if (capture.recording || capture.paused) {
                        capture.interrupted = true
                        finish(capture, null)
                    } else {
                        emit(capture, mapOf("type" to "error", "code" to "capture_failed"))
                        abandon()
                    }
                }
            }
        }
        capture.pendingResult = result
        val manager = cameraManager()
        val selected = selectCamera(manager, true) ?: selectCamera(manager, false)
        if (selected == null) { abandon(); throw CaptureFailure("camera_unavailable") }
        openCamera(capture, selected, {
            capture.pendingResult = null
            success(result, preview(capture))
        }, {
            capture.pendingResult = null
            failure(result, "camera_unavailable")
            abandon()
        })
    }

    private fun cameraManager() = context.getSystemService(Context.CAMERA_SERVICE) as CameraManager

    private fun selectCamera(manager: CameraManager, front: Boolean): String? {
        val lens = if (front) CameraCharacteristics.LENS_FACING_FRONT else CameraCharacteristics.LENS_FACING_BACK
        return manager.cameraIdList.firstOrNull { id ->
            try {
                val info = characteristicsOf(id)
                info.get(CameraCharacteristics.LENS_FACING) == lens &&
                    !info.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
                        ?.getOutputSizes(SurfaceTexture::class.java).isNullOrEmpty()
            } catch (_: Exception) { false }
        }
    }

    private fun controls(capture: Capture): Controls {
        val id = capture.cameraId ?: throw CaptureFailure("camera_unavailable")
        val info = characteristicsOf(id)
        val keys = info.availableCaptureRequestKeys ?: emptyList()
        val ratioRange = if (Build.VERSION.SDK_INT >= 30 && keys.contains(CaptureRequest.CONTROL_ZOOM_RATIO))
            info.get(CameraCharacteristics.CONTROL_ZOOM_RATIO_RANGE) else null
        val active = info.get(CameraCharacteristics.SENSOR_INFO_ACTIVE_ARRAY_SIZE)
        val digital = info.get(CameraCharacteristics.SCALER_AVAILABLE_MAX_DIGITAL_ZOOM)?.toDouble() ?: 1.0
        val validRatio = ratioRange != null && ratioRange.lower.isFinite() && ratioRange.upper.isFinite() &&
            ratioRange.lower > 0 && ratioRange.upper >= ratioRange.lower
        val range = if (validRatio)
            RoundZoomRange(ratioRange.lower.toDouble(), ratioRange.upper.toDouble())
        else if (active != null && active.width() > 0 && active.height() > 0 &&
            keys.contains(CaptureRequest.SCALER_CROP_REGION) && digital.isFinite() && digital >= 1)
            RoundZoomRange(1.0, digital)
        else RoundZoomRange(1.0, 1.0)
        val torch = info.get(CameraCharacteristics.FLASH_INFO_AVAILABLE) == true &&
            keys.contains(CaptureRequest.FLASH_MODE) &&
            info.get(CameraCharacteristics.CONTROL_AE_AVAILABLE_MODES)
                ?.contains(CaptureRequest.CONTROL_AE_MODE_ON) == true
        return Controls(if (capture.zoomDisabled) RoundZoomRange(1.0, 1.0) else range,
            validRatio, active, torch && !capture.torchDisabled)
    }

    /** Every input and Camera2 callback has its own epoch, independent of the capture lease. */
    @Suppress("MissingPermission", "DEPRECATION")
    private fun openCamera(capture: Capture, cameraId: String, ready: () -> Unit, failed: () -> Unit) {
        val token = capture.epoch.advance()
        capture.cameraRevision++
        capture.cameraReady = false
        capture.openingFailure = failed
        val timeout = Runnable { if (alive(capture, token)) failOpen(capture, token) }
        capture.openingTimeout = timeout
        cameraHandler.postDelayed(timeout, 5000)
        try {
            if (context.checkSelfPermission(Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED)
                throw CaptureFailure("permission_denied")
            val manager = cameraManager()
            val info = characteristicsOf(cameraId)
            val map = info.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)!!
            val sizes = map.getOutputSizes(SurfaceTexture::class.java)
            capture.size = sizes[RoundStreamSize.select(sizes.map { it.width to it.height }, capture.profile.side) { index ->
                try { map.getOutputMinFrameDuration(SurfaceTexture::class.java, sizes[index]) } catch (_: Exception) { 0L }
            }]
            capture.front = info.get(CameraCharacteristics.LENS_FACING) == CameraCharacteristics.LENS_FACING_FRONT
            // The SurfaceTexture transform applies the sensor rotation (and the front
            // mirror); the compositor must not rotate by it again. See RoundFrameTransform.
            capture.sensorOrientation = info.get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 0
            capture.cameraId = cameraId
            capture.zoomDisabled = false; capture.torchDisabled = false; capture.enhancementsDisabled = false
            val available = controls(capture)
            capture.zoom = capture.zoom.coerceIn(available.zoom.minimum, available.zoom.maximum)
            capture.torch = capture.torch && available.torch
            val input = capture.compositor!!.newInput(capture.size.width, capture.size.height,
                capture.sensorOrientation, capture.displayDegrees)
            capture.input = input
            manager.openCamera(cameraId, object : CameraDevice.StateCallback() {
                override fun onOpened(camera: CameraDevice) {
                    if (!alive(capture, token)) { camera.close(); return }
                    capture.devices += camera
                    capture.camera = camera
                    try {
                        camera.createCaptureSession(listOf(input.surface), object : CameraCaptureSession.StateCallback() {
                            override fun onConfigured(configured: CameraCaptureSession) {
                                if (!alive(capture, token) || capture.camera !== camera || capture.input !== input) {
                                    configured.close(); return
                                }
                                try {
                                    capture.cameraSession = configured
                                    repeating(capture)
                                    reportWhenVisible(capture, token, camera, input, ready)
                                } catch (_: Exception) { failOpen(capture, token) }
                            }
                            override fun onConfigureFailed(configured: CameraCaptureSession) {
                                configured.close()
                                if (alive(capture, token)) failOpen(capture, token)
                            }
                        }, cameraHandler)
                    } catch (_: Exception) { failOpen(capture, token) }
                }
                override fun onDisconnected(camera: CameraDevice) {
                    camera.close()
                    if (alive(capture, token)) {
                        if (capture.openingFailure != null) failOpen(capture, token) else cameraLost(capture)
                    }
                }
                override fun onError(camera: CameraDevice, error: Int) {
                    camera.close()
                    if (alive(capture, token)) {
                        if (capture.openingFailure != null) failOpen(capture, token) else cameraLost(capture)
                    }
                }
                override fun onClosed(camera: CameraDevice) {
                    capture.devices.remove(camera)
                    try { capture.compositor?.releaseInput(input) } catch (_: Exception) { }
                    if (capture.retiringHardware && capture.devices.isEmpty()) releasePreview(capture)
                    if (capture.closingCamera === camera) {
                        capture.closingCamera = null
                        capture.closeTimeout?.let { cameraHandler.removeCallbacks(it) }
                        capture.closeTimeout = null
                        val continuation = capture.closingContinuation
                        capture.closingContinuation = null
                        if (session === capture && !capture.canceled.get() && !capture.preparing)
                            continuation?.invoke()
                    }
                }
            }, cameraHandler)
        } catch (_: Exception) { failOpen(capture, token) }
    }

    /**
     * Open and flip complete when the new lens is visible (its first frame is in the
     * GL cache), not merely configured: Dart ends the flip on the live image and a
     * recording never starts on black frames. A slow first frame is bounded by
     * [FIRST_FRAME_TIMEOUT_MS], after which the open completes as before.
     */
    private fun reportWhenVisible(capture: Capture, token: Long, camera: CameraDevice,
                                  input: RoundCameraSurface.Input, ready: () -> Unit) {
        var reported = false
        val report = Runnable {
            if (reported || !alive(capture, token) || capture.camera !== camera || capture.input !== input)
                return@Runnable
            reported = true
            capture.firstFrameTimeout?.let { cameraHandler.removeCallbacks(it) }; capture.firstFrameTimeout = null
            try {
                capture.cameraReady = true
                ready()
                capture.openingTimeout?.let { cameraHandler.removeCallbacks(it) }
                capture.openingTimeout = null; capture.openingFailure = null
            } catch (_: Exception) { failOpen(capture, token) }
        }
        capture.firstFrameTimeout?.let { cameraHandler.removeCallbacks(it) }
        capture.firstFrameTimeout = report
        cameraHandler.postDelayed(report, FIRST_FRAME_TIMEOUT_MS)
        capture.compositor?.whenFrame(input) { cameraHandler.post(report) }
    }

    private fun alive(capture: Capture, token: Long) = session === capture &&
        !capture.canceled.get() && !capture.preparing && capture.prepared == null && capture.epoch.isCurrent(token)

    private fun failOpen(capture: Capture, token: Long) {
        if (!alive(capture, token)) return
        val failed = capture.openingFailure ?: return
        capture.openingFailure = null
        capture.openingTimeout?.let { cameraHandler.removeCallbacks(it) }; capture.openingTimeout = null
        capture.epoch.advance()
        capture.cameraReady = false
        failed()
    }

    private fun cameraLost(capture: Capture) {
        capture.cameraReady = false
        if (capture.recording || capture.paused) {
            capture.interrupted = true
            finish(capture, null)
        } else {
            emit(capture, mapOf("type" to "error", "code" to "camera_unavailable"))
            abandon()
        }
    }

    private fun repeating(capture: Capture) {
        if (!capture.enhancementsDisabled) {
            try { repeating(capture, true); return } catch (_: Exception) { }
            // A device may reject an advertised fps/stabilization/scene combination.
            // Only when the plain request works is the camera marked as such; other
            // failures (zoom/torch/closed camera) still propagate to their callers.
            repeating(capture, false)
            capture.enhancementsDisabled = true
            return
        }
        repeating(capture, false)
    }

    private fun repeating(capture: Capture, enhanced: Boolean) {
        val camera = capture.camera ?: throw CaptureFailure("camera_unavailable")
        val configured = capture.cameraSession ?: throw CaptureFailure("camera_unavailable")
        val available = controls(capture) // Capabilities (and disabled controls) before EVERY operation.
        val info = characteristicsOf(capture.cameraId!!)
        val request = camera.createCaptureRequest(CameraDevice.TEMPLATE_RECORD)
        request.addTarget(capture.input!!.surface)
        request.set(CaptureRequest.CONTROL_MODE, CaptureRequest.CONTROL_MODE_AUTO)
        if (info.get(CameraCharacteristics.CONTROL_AF_AVAILABLE_MODES)
            ?.contains(CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_VIDEO) == true)
            request.set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_VIDEO)
        request.set(CaptureRequest.CONTROL_AE_MODE, CaptureRequest.CONTROL_AE_MODE_ON)
        if (info.availableCaptureRequestKeys?.contains(CaptureRequest.FLASH_MODE) == true)
            request.set(CaptureRequest.FLASH_MODE, if (capture.torch && available.torch)
                CaptureRequest.FLASH_MODE_TORCH else CaptureRequest.FLASH_MODE_OFF)
        val zoom = available.zoom.validate(capture.zoom)
        if (Build.VERSION.SDK_INT >= 30 && available.ratio)
            request.set(CaptureRequest.CONTROL_ZOOM_RATIO, zoom.toFloat())
        else available.activeArray?.let { rect ->
            if (info.availableCaptureRequestKeys?.contains(CaptureRequest.SCALER_CROP_REGION) == true) {
                val width = maxOf(1, (rect.width() / zoom).roundToInt())
                val height = maxOf(1, (rect.height() / zoom).roundToInt())
                val left = rect.left + (rect.width() - width) / 2
                val top = rect.top + (rect.height() - height) / 2
                request.set(CaptureRequest.SCALER_CROP_REGION, Rect(left, top, left + width, top + height))
            }
        }
        if (Build.VERSION.SDK_INT >= 31 && info.get(CameraCharacteristics.SCALER_AVAILABLE_ROTATE_AND_CROP_MODES)
            ?.contains(CaptureRequest.SCALER_ROTATE_AND_CROP_NONE) == true)
            request.set(CaptureRequest.SCALER_ROTATE_AND_CROP, CaptureRequest.SCALER_ROTATE_AND_CROP_NONE)
        if (enhanced) enhance(capture, info, request)
        configured.setRepeatingRequest(request.build(), null, cameraHandler)
    }

    /** Quality-only request keys, each applied only when the hardware advertises it. */
    private fun enhance(capture: Capture, info: CameraCharacteristics, request: CaptureRequest.Builder) {
        val keys = info.availableCaptureRequestKeys ?: emptyList()
        info.get(CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES)?.let { ranges ->
            RoundFpsRange.select(ranges.map { it.lower to it.upper })?.let { (lower, upper) ->
                request.set(CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE, android.util.Range(lower, upper))
            }
        }
        if (capture.profile.stabilize) {
            val electronic = keys.contains(CaptureRequest.CONTROL_VIDEO_STABILIZATION_MODE) &&
                info.get(CameraCharacteristics.CONTROL_AVAILABLE_VIDEO_STABILIZATION_MODES)
                    ?.contains(CaptureRequest.CONTROL_VIDEO_STABILIZATION_MODE_ON) == true
            val optical = keys.contains(CaptureRequest.LENS_OPTICAL_STABILIZATION_MODE) &&
                info.get(CameraCharacteristics.LENS_INFO_AVAILABLE_OPTICAL_STABILIZATION)
                    ?.contains(CaptureRequest.LENS_OPTICAL_STABILIZATION_MODE_ON) == true
            // Camera2 advises against enabling EIS and OIS together. The back lens
            // prefers OIS (no extra crop, sharper in low light), selfie lenses use EIS.
            if (optical && (!capture.front || !electronic)) {
                request.set(CaptureRequest.LENS_OPTICAL_STABILIZATION_MODE, CaptureRequest.LENS_OPTICAL_STABILIZATION_MODE_ON)
                if (electronic) request.set(CaptureRequest.CONTROL_VIDEO_STABILIZATION_MODE,
                    CaptureRequest.CONTROL_VIDEO_STABILIZATION_MODE_OFF)
            } else if (electronic) {
                request.set(CaptureRequest.CONTROL_VIDEO_STABILIZATION_MODE, CaptureRequest.CONTROL_VIDEO_STABILIZATION_MODE_ON)
            }
        }
        // Face priority keeps the requested AE/AF/AWB modes and only biases metering to faces.
        if (capture.front && keys.contains(CaptureRequest.CONTROL_SCENE_MODE) &&
            info.get(CameraCharacteristics.CONTROL_AVAILABLE_SCENE_MODES)
                ?.contains(CaptureRequest.CONTROL_SCENE_MODE_FACE_PRIORITY) == true) {
            request.set(CaptureRequest.CONTROL_MODE, CaptureRequest.CONTROL_MODE_USE_SCENE_MODE)
            request.set(CaptureRequest.CONTROL_SCENE_MODE, CaptureRequest.CONTROL_SCENE_MODE_FACE_PRIORITY)
        }
    }

    /** Camera-only close: never releases recorder/audio/encoder ownership. */
    private fun closeCamera(capture: Capture, closed: (() -> Unit)? = null, timedOut: (() -> Unit)? = null) {
        capture.epoch.advance(); capture.cameraReady = false
        capture.openingTimeout?.let { cameraHandler.removeCallbacks(it) }; capture.openingTimeout = null
        capture.openingFailure = null
        capture.closeTimeout?.let { cameraHandler.removeCallbacks(it) }; capture.closeTimeout = null
        capture.closingContinuation = null
        capture.firstFrameTimeout?.let { cameraHandler.removeCallbacks(it) }; capture.firstFrameTimeout = null
        // abortCaptures (flush) instead of stopRepeating: in-flight requests are dropped
        // rather than drained, so the device closes and a flip reopens sooner.
        try { capture.cameraSession?.abortCaptures() } catch (_: Exception) {
            try { capture.cameraSession?.stopRepeating() } catch (_: Exception) { }
        }
        capture.cameraSession?.close(); capture.cameraSession = null
        val camera = capture.camera
        capture.camera = null; capture.input = null
        if (camera == null) { closed?.invoke(); return }
        capture.closingCamera = camera
        capture.closingContinuation = closed
        if (timedOut != null) {
            val timeout = Runnable {
                if (session === capture && capture.closingCamera === camera) {
                    capture.closingContinuation = null; capture.closeTimeout = null
                    timedOut()
                }
            }
            capture.closeTimeout = timeout; cameraHandler.postDelayed(timeout, 3000)
        }
        camera.close()
    }

    private fun switchCamera(capture: Capture, call: MethodCall, result: MethodChannel.Result) {
        requireRevision(capture, call)
        val manager = cameraManager()
        val previous = capture.cameraId!!
        val next = selectCamera(manager, !capture.front)
        if (next == null || next == previous) {
            emit(capture, preview(capture) + ("type" to "controls"))
            throw CaptureFailure("camera_switch_unavailable")
        }
        val previousZoom = capture.zoom
        capture.pendingResult = result
        capture.torch = false
        fun fatal() {
            capture.pendingResult = null
            failure(result, "camera_unavailable")
            if (capture.recording || capture.paused) {
                capture.interrupted = true
                finish(capture, null)
            } else {
                emit(capture, mapOf("type" to "error", "code" to "camera_unavailable"))
                abandon()
            }
        }
        fun restore() {
            capture.zoom = previousZoom; capture.torch = false
            closeCamera(capture, {
                openCamera(capture, previous, {
                    capture.pendingResult = null
                    emit(capture, preview(capture) + ("type" to "controls"))
                    failure(result, "camera_switch_failed")
                }, { fatal() })
            }, { fatal() })
        }
        closeCamera(capture, {
            capture.zoom = 1.0
            openCamera(capture, next, {
                capture.pendingResult = null
                val state = preview(capture)
                success(result, state)
                emit(capture, state + ("type" to "controls"))
            }, { restore() })
        }, { fatal() })
    }

    private fun setZoom(capture: Capture, call: MethodCall, result: MethodChannel.Result) {
        requireRevision(capture, call)
        val available = controls(capture)
        if (!available.zoom.supported) {
            capture.zoom = capture.zoom.coerceIn(available.zoom.minimum, available.zoom.maximum)
            capture.torch = capture.torch && available.torch
            repeating(capture)
            emit(capture, preview(capture) + ("type" to "controls"))
            throw CaptureFailure("zoom_unavailable")
        }
        val requested = call.argument<Number>("zoom")?.toDouble() ?: throw CaptureFailure("invalid_zoom")
        try { available.zoom.validate(requested) } catch (_: Exception) { throw CaptureFailure("invalid_zoom") }
        capture.zoom = requested
        try { repeating(capture) } catch (_: Exception) {
            capture.zoomDisabled = true
            // Keep a valid default request when a device rejects an advertised control.
            capture.zoom = 1.0
            try { repeating(capture) } catch (_: Exception) { cameraLost(capture) }
            if (session === capture && capture.cameraReady) emit(capture, preview(capture) + ("type" to "controls"))
            throw CaptureFailure("zoom_unavailable")
        }
        success(result, preview(capture))
    }

    private fun setTorch(capture: Capture, call: MethodCall, result: MethodChannel.Result) {
        requireRevision(capture, call)
        val available = controls(capture)
        if (!available.torch) {
            capture.torch = false
            capture.zoom = capture.zoom.coerceIn(available.zoom.minimum, available.zoom.maximum)
            repeating(capture)
            emit(capture, preview(capture) + ("type" to "controls"))
            throw CaptureFailure("torch_unavailable")
        }
        val enabled = call.argument<Boolean>("enabled") ?: throw CaptureFailure("torch_unavailable")
        capture.torch = enabled
        try { repeating(capture) } catch (_: Exception) {
            capture.torch = false; capture.torchDisabled = true
            try { repeating(capture) } catch (_: Exception) { cameraLost(capture) }
            if (session === capture && capture.cameraReady) emit(capture, preview(capture) + ("type" to "controls"))
            throw CaptureFailure("torch_unavailable")
        }
        success(result, preview(capture))
    }

    @Suppress("DEPRECATION")
    private fun start(capture: Capture, result: MethodChannel.Result) {
        requireIdle(capture)
        if (capture.recording || capture.paused || capture.recorder != null) throw CaptureFailure("busy")
        val audio = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val focus = AudioManager.OnAudioFocusChangeListener { change ->
            if (change < 0) cameraHandler.post {
                if (session === capture && (capture.recording || capture.paused)) {
                    capture.interrupted = true
                    finish(capture, null)
                }
            }
        }
        capture.focusListener = focus
        require(audio.requestAudioFocus(focus, AudioManager.STREAM_MUSIC, AudioManager.AUDIOFOCUS_GAIN_TRANSIENT) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED)
        val recorder = MediaRecorder()
        capture.recorder = recorder
        // DEFAULT (Telegram's plain microphone) unless noise reduction asks for the
        // VOICE_COMMUNICATION noise suppressor/AGC/AEC chain.
        recorder.setAudioSource(capture.profile.audioSource)
        recorder.setVideoSource(MediaRecorder.VideoSource.SURFACE)
        recorder.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
        recorder.setOutputFile(capture.raw.path)
        recorder.setVideoEncoder(MediaRecorder.VideoEncoder.H264)
        recorder.setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
        recorder.setVideoSize(capture.profile.side, capture.profile.side)
        recorder.setVideoFrameRate(RoundProfile.FRAME_RATE)
        recorder.setVideoEncodingBitRate(capture.profile.recorderVideoBitrate)
        recorder.setAudioChannels(RoundProfile.AUDIO_CHANNELS)
        recorder.setAudioSamplingRate(RoundProfile.AUDIO_SAMPLE_RATE)
        recorder.setAudioEncodingBitRate(capture.profile.recorderAudioBitrate)
        recorder.setOrientationHint(0) // GL writes upright, display-compensated pixels; no MP4 rotation.
        recorder.setMaxDuration(capture.profile.maxDurationMs)
        // Raw is temporary and cannot exceed a bounded capture budget either.
        recorder.setMaxFileSize(capture.profile.rawCapBytes)
        recorder.setOnInfoListener { _, what, _ ->
            if (what == MediaRecorder.MEDIA_RECORDER_INFO_MAX_DURATION_REACHED || what == MediaRecorder.MEDIA_RECORDER_INFO_MAX_FILESIZE_REACHED) {
                cameraHandler.post { if (session === capture && !capture.preparing && (capture.recording || capture.paused)) {
                    capture.interrupted = true
                    finish(capture, null)
                } }
            }
        }
        recorder.setOnErrorListener { _, _, _ ->
            cameraHandler.post { if (session === capture && !capture.preparing) {
                if (capture.recording || capture.paused) { capture.interrupted = true; finish(capture, null) }
                else { emit(capture, mapOf("type" to "error", "code" to "capture_failed")); abandon() }
            } }
        }
        recorder.prepare()
        capture.recorderSurface = recorder.surface
        capture.compositor!!.attachRecorder(capture.recorderSurface!!)
        recorder.start()
        capture.recording = true
        capture.compositor!!.encoding(true)
        requestLiveThumbnail(capture)
        success(result, null)
    }

    /** First recorded frame -> thumbnail, written off the GL/camera threads while recording. */
    private fun requestLiveThumbnail(capture: Capture) {
        val directory = capture.directory
        val side = capture.profile.side
        val canceled = capture.canceled
        try {
            capture.compositor?.snapshotNextRecordedFrame { pixels ->
                try {
                    exporter.execute {
                        try { RoundVideoExporter.writeLiveThumbnail(pixels, side, directory, canceled) }
                        catch (_: Exception) { File(directory, RoundVideoExporter.LIVE_THUMBNAIL).delete() }
                    }
                } catch (_: Exception) { /* exporter shut down: the finish path decodes a frame */ }
            }
        } catch (_: Exception) { /* the finish path decodes a frame instead */ }
    }

    private fun preview(capture: Capture): Map<String, Any> {
        val available = controls(capture)
        val ready = capture.cameraReady && capture.pendingResult == null && !capture.preparing && capture.prepared == null
        val alternate = try { selectCamera(cameraManager(), !capture.front) != null } catch (_: Exception) { false }
        return mapOf(
            "captureId" to capture.id, "textureId" to capture.texture!!.id(),
            "width" to capture.profile.side, "height" to capture.profile.side, "rotation" to 0,
            "mirrored" to false, "isFrontCamera" to capture.front,
            "canSwitchCamera" to (ready && alternate), "canSwitchDuringRecording" to (ready && alternate),
            "minZoom" to available.zoom.minimum, "maxZoom" to available.zoom.maximum,
            "zoom" to capture.zoom, "torchAvailable" to (ready && available.torch),
            "torchEnabled" to (ready && available.torch && capture.torch),
            "cameraRevision" to capture.cameraRevision,
        )
    }

    private fun finish(capture: Capture, result: MethodChannel.Result?) {
        if (capture.preparing) { if (result != null) capture.finishWaiters += result; return }
        capture.prepared?.let { if (result != null) success(result, it); return }
        if (!capture.recording && !capture.paused) { if (result != null) failure(result, "not_recording"); return }
        capture.preparing = true
        capture.pendingResult?.let { failure(it, "interrupted") }; capture.pendingResult = null
        // Invalidate async open/configure/rollback before anything can end this capture.
        closeCamera(capture)
        emit(capture, mapOf("type" to "preparing", "wasInterrupted" to capture.interrupted))
        try { capture.compositor?.encoding(false) } catch (_: Exception) { }
        val stopping = SystemClock.elapsedRealtime()
        try { capture.recorder?.stop() } catch (_: RuntimeException) {
            // Some devices finalize the file before reporting a stop/hardware error.
            // Let the strict exporter validate existing bytes before rejecting them.
            capture.interrupted = true; capture.stopFailed = true
        }
        capture.stopMs = SystemClock.elapsedRealtime() - stopping
        capture.recording = false
        capture.paused = false
        closeHardware(capture)
        if (capture.stopFailed && (!capture.raw.isFile || capture.raw.length() == 0L)) {
            capture.preparing = false
            if (result != null) failure(result, "recording_too_short")
            else emit(capture, mapOf("type" to "error", "code" to "recording_too_short"))
            return
        }
        prepare(capture, capture.raw, 0, capture.profile.maxDurationMs, result)
    }

    private fun trim(capture: Capture, call: MethodCall, result: MethodChannel.Result) {
        if (capture.preparing) throw CaptureFailure("busy")
        if (capture.prepared == null) throw CaptureFailure("not_recording")
        val start = call.argument<Number>("startMs")!!.toInt()
        val end = call.argument<Number>("endMs")!!.toInt()
        require(start >= 0 && end > start && end <= (capture.prepared!!["durationMs"] as Number).toInt())
        val transaction = try { RoundTrimTransaction(capture.output, File(capture.directory, "thumb.jpg")) }
            catch (_: Exception) { throw CaptureFailure("trim_failed") }
        capture.trimTransaction = transaction
        capture.preparing = true
        prepare(capture, transaction.source, start, end, result, transaction)
    }

    private fun prepare(capture: Capture, source: File, startMs: Int, endMs: Int, result: MethodChannel.Result?,
                        transaction: RoundTrimTransaction? = null) {
        capture.preparationResult = result
        val queued = SystemClock.elapsedRealtime()
        exporter.execute {
            try {
                val began = SystemClock.elapsedRealtime()
                // Untrimmed: the recording already is the final file (no re-encode).
                // Trim, or a recording that fails the final profile: transcode as before.
                val descriptor = (if (transaction == null)
                    RoundVideoExporter.finalizeRecording(source, capture.output, capture.profile, capture.canceled)
                else null) ?: RoundVideoExporter.export(source, transaction?.candidate ?: capture.output,
                    capture.profile, capture.canceled, startMs, endMs)
                // Phase timings only: no paths, identifiers or content.
                Log.i(TAG, "Round prepared: pipeline=${descriptor["pipeline"]} stop_ms=${capture.stopMs} " +
                    "queue_ms=${began - queued} prepare_ms=${SystemClock.elapsedRealtime() - began} " +
                    "duration_ms=${descriptor["durationMs"]} size_kb=${(descriptor["sizeBytes"] as Number).toLong() / 1024}")
                cameraHandler.post {
                    if (session === capture && !capture.canceled.get()) {
                        try {
                            transaction?.commit()
                            if (transaction == null) source.delete()
                            capture.trimTransaction = null
                            capture.preparationResult = null
                            capture.preparing = false
                            val scoped = descriptor + mapOf("path" to capture.output.path,
                                "captureId" to capture.id, "wasInterrupted" to capture.interrupted)
                            capture.prepared = scoped
                            if (result != null) success(result, scoped)
                            else emit(capture, scoped + ("type" to "completed"))
                            capture.finishWaiters.forEach { success(it, scoped) }; capture.finishWaiters.clear()
                        } catch (_: Exception) { prepareFailed(capture, source, result, transaction) }
                    } else {
                        transaction?.discard()
                        source.delete(); capture.output.delete(); File(capture.directory, "thumb.jpg").delete()
                        capture.liveThumbnail.delete()
                        if (result != null) failure(result, "canceled")
                    }
                }
            } catch (_: Exception) {
                cameraHandler.post { prepareFailed(capture, source, result, transaction) }
            }
        }
    }

    private fun prepareFailed(capture: Capture, source: File, result: MethodChannel.Result?,
                              transaction: RoundTrimTransaction?) {
        val canceled = capture.canceled.get() || session !== capture
        val restored = if (!canceled && transaction != null) try { transaction.rollback(); true }
            catch (_: Exception) { false } else false
        if (canceled) transaction?.discard()
        if (transaction == null) { source.delete(); capture.output.delete() }
        capture.trimTransaction = null; capture.preparing = false
        capture.preparationResult = null
        val code = if (canceled) "canceled" else if (restored) "trim_failed"
            else if (capture.stopFailed) "recording_too_short" else "encode_failed"
        if (result != null) failure(result, code)
        else if (!canceled) emit(capture, mapOf("type" to "error", "code" to code))
        capture.finishWaiters.forEach {
            if (restored && capture.prepared != null) success(it, capture.prepared) else failure(it, code)
        }
        capture.finishWaiters.clear()
    }

    private fun closeHardware(capture: Capture) {
        capture.retiringHardware = true
        closeCamera(capture)
        try { capture.compositor?.encoding(false) } catch (_: Exception) { }
        try { capture.compositor?.detachRecorder() } catch (_: Exception) { }
        capture.recorderSurface?.release(); capture.recorderSurface = null
        capture.recorder?.release(); capture.recorder = null
        capture.focusListener?.let {
            @Suppress("DEPRECATION")
            (context.getSystemService(Context.AUDIO_SERVICE) as AudioManager).abandonAudioFocus(it)
        }
        capture.focusListener = null
        try { capture.compositor?.retire() } catch (_: Exception) { }
        if (capture.devices.isEmpty()) releasePreview(capture)
        else if (capture.hardwareCloseTimeout == null) {
            // A broken driver must not keep a lease/GL context forever. Camera.close
            // has already canceled requests; this fallback bounds terminal cleanup.
            val timeout = Runnable { capture.hardwareCloseTimeout = null; releasePreview(capture) }
            capture.hardwareCloseTimeout = timeout
            cameraHandler.postDelayed(timeout, 5000)
        }
        main.post {
            if (session == null || session === capture)
                activity?.window?.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            unlockOrientation(capture)
        }
    }

    /** Main thread. Returns the display rotation (0/90/180/270) after locking it. */
    private fun lockOrientation(capture: Capture): Int {
        val target = activity ?: return 0
        if (session === capture && !capture.canceled.get()) try {
            target.requestedOrientation = orientationLock.acquire(capture, target, target.requestedOrientation)
        } catch (_: Exception) { }
        @Suppress("DEPRECATION")
        val rotation = try { target.windowManager.defaultDisplay.rotation } catch (_: Exception) { Surface.ROTATION_0 }
        return when (rotation) { Surface.ROTATION_90 -> 90; Surface.ROTATION_180 -> 180; Surface.ROTATION_270 -> 270; else -> 0 }
    }

    /** Main thread. Restores the request saved by the last capture that locked it. */
    private fun unlockOrientation(capture: Capture) {
        try {
            orientationLock.release(capture) { it.requestedOrientation }?.let { (target, previous) ->
                target.requestedOrientation = previous
            }
        } catch (_: Exception) { }
    }

    private fun releasePreview(capture: Capture) {
        capture.hardwareCloseTimeout?.let { cameraHandler.removeCallbacks(it) }; capture.hardwareCloseTimeout = null
        try { capture.compositor?.close() } catch (_: Exception) { }
        capture.compositor = null
        capture.previewSurface?.release(); capture.previewSurface = null
        if (capture.releaseTextureWhenClosed) {
            capture.texture?.let { texture -> main.post { try {
                texture.setOnFrameConsumedListener(null)
                texture.release()
            } catch (_: Exception) { } } }
            capture.texture = null
        }
    }

    private fun abandon(keepPrepared: Boolean = false) {
        val capture = session ?: return
        session = null
        capture.canceled.set(true)
        capture.finishWaiters.forEach { failure(it, "canceled") }; capture.finishWaiters.clear()
        capture.pendingResult?.let { failure(it, "canceled") }; capture.pendingResult = null
        capture.preparationResult?.let { failure(it, "canceled") }; capture.preparationResult = null
        capture.releaseTextureWhenClosed = true
        closeHardware(capture)
        capture.raw.delete()
        capture.liveThumbnail.delete()
        capture.trimTransaction?.discard(); capture.trimTransaction = null
        if (!keepPrepared) {
            capture.output.delete()
            File(capture.directory, "thumb.jpg").delete()
        }
    }

    private fun success(result: MethodChannel.Result, value: Any?) = result.success(value)
    private fun failure(result: MethodChannel.Result, code: String) = result.error(code, "Round capture unavailable", null)
    private fun emit(capture: Capture, value: Map<String, Any>) = main.post {
        val current = session
        val terminalError = value["type"] == "error" && current == null
        if (attached && (current === capture && !capture.canceled.get() || terminalError))
            channel.invokeMethod("event", value + ("captureId" to capture.id))
    }

    private fun <T> onMain(action: () -> T): T {
        if (android.os.Looper.myLooper() == main.looper) return action()
        val pending = FutureTask(Callable { action() })
        main.post(pending)
        return pending.get(5, TimeUnit.SECONDS)
    }

    override fun onActivityPaused(pausedActivity: Activity) {
        if (pausedActivity !== activity) return
        activityVisible = false
        if (permissionCall != null) return
        cameraHandler.post {
            session?.let {
                if (it.recording || it.paused) { it.interrupted = true; finish(it, null) }
                else if (!it.preparing && it.prepared == null) {
                    abandon()
                    emit(it, mapOf("type" to "error", "code" to "interrupted"))
                }
            }
        }
    }
    override fun onActivityCreated(activity: Activity, state: Bundle?) { }
    override fun onActivityStarted(activity: Activity) { }
    override fun onActivityResumed(activity: Activity) {
        if (activity !== this.activity) return
        activityVisible = true
        if (permissionGrantedWaiting) {
            val pending = permissionCall
            permissionCall = null; permissionGrantedWaiting = false
            if (pending != null) onMethodCall(pending.first, pending.second)
        }
    }
    override fun onActivityStopped(activity: Activity) { }
    override fun onActivitySaveInstanceState(activity: Activity, state: Bundle) { }
    override fun onActivityDestroyed(activity: Activity) { }

    companion object {
        private const val PERMISSION_REQUEST = 7361
        private const val TAG = "PersonalRound"
        /** Upper bound between a configured session and its first visible frame. */
        private const val FIRST_FRAME_TIMEOUT_MS = 500L
    }
}
