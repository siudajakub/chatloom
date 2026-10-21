// SPDX-License-Identifier: AGPL-3.0-or-later
import AVFoundation
import Cocoa
import CoreImage
import Darwin
import FlutterMacOS

/// Camera access is requested only after Dart has frozen an authorized target.
/// All native files stay inside the locked MediaAccess lease supplied by Dart.
final class RoundCapture: NSObject, FlutterTexture,
  AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureFileOutputRecordingDelegate {
  private let channel: FlutterMethodChannel
  private let textures: FlutterTextureRegistry
  private let queue = DispatchQueue(label: "pl.personal.chat.round")
  private let bufferLock = NSLock()
  private var pixelBuffer: CVPixelBuffer?
  private var textureID: Int64 = -1
  private var session: AVCaptureSession?
  private var movie: AVCaptureMovieFileOutput?
  private var videoInput: AVCaptureDeviceInput?
  private var previewOutput: AVCaptureVideoDataOutput?
  private var captureID: String?
  private var directory: URL?
  private var output: URL?
  private var segments: [URL] = []
  private var segmentIndex = 0
  private var writerActive = false
  private var side = 384
  private var maxBytes: Int64 = 0
  private var maxDuration = 60000
  private var recorded = CMTime.zero
  private var stopAction: (() -> Void)?
  private var pendingFinish: FlutterResult?
  private var pendingStop: FlutterResult?
  private var pendingPause: FlutterResult?
  private var exporter: AVAssetExportSession?
  private var canceled = false
  private var interrupted = false
  private var revision = 0
  private var observers: [NSObjectProtocol] = []
  private var sessionObserver: NSObjectProtocol?
  private var focusObserver: NSObjectProtocol?

  init(registrar: FlutterPluginRegistrar) {
    textures = registrar.textures
    channel = FlutterMethodChannel(name: "pl.personal.chat/round_capture",
                                   binaryMessenger: registrar.messenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      self.queue.async { self.handle(call, result) }
    }
    for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification,
                 NSWorkspace.screensDidSleepNotification] {
      observers.append(NSWorkspace.shared.notificationCenter.addObserver(
        forName: name, object: nil, queue: nil
      ) { [weak self] _ in self?.interrupt() })
    }
    focusObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didResignActiveNotification, object: nil, queue: nil
    ) { [weak self] _ in self?.interrupt() }
  }

  private func reply(_ result: @escaping FlutterResult, _ value: Any? = nil) {
    DispatchQueue.main.async { result(value) }
  }

  private func fail(_ result: @escaping FlutterResult, _ code: String) {
    reply(result, FlutterError(code: code, message: nil, details: nil))
  }

  private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any], let id = args["captureId"] as? String else {
      fail(result, "invalid_profile"); return
    }
    if call.method == "initialize" {
      guard captureID == nil else { fail(result, "busy"); return }
      initialize(args, id: id, result: result)
      return
    }
    guard id == captureID else {
      if call.method == "cancel" || call.method == "dispose" { reply(result) }
      else { fail(result, "canceled") }
      return
    }
    switch call.method {
    case "start", "resume":
      guard !writerActive, exporter == nil, stopAction == nil, movie?.isRecording == false else {
        fail(result, "busy"); return
      }
      startSegment(result)
    case "pause":
      guard writerActive, stopAction == nil else { fail(result, "busy"); return }
      pendingPause = result
      stopAction = {
        if let pause = self.pendingPause { self.pendingPause = nil; self.reply(pause) }
      }
      if movie?.isRecording == true { movie?.stopRecording() }
    case "finish":
      guard pendingFinish == nil, exporter == nil, stopAction == nil else {
        fail(result, "busy"); return
      }
      pendingFinish = result
      if writerActive {
        stopAction = { self.prepare() }
        if movie?.isRecording == true { movie?.stopRecording() }
      } else {
        prepare()
      }
    case "trim":
      guard exporter == nil, pendingFinish == nil, let output = output,
            let start = args["startMs"] as? Int, let end = args["endMs"] as? Int,
            start >= 0, end - start >= 800, end <= maxDuration else {
        fail(result, "invalid_output"); return
      }
      pendingFinish = result
      let source = output.deletingLastPathComponent().appendingPathComponent("trim-source.mp4")
      do {
        if FileManager.default.fileExists(atPath: source.path) { try FileManager.default.removeItem(at: source) }
        try FileManager.default.copyItem(at: output, to: source)
        let asset = AVURLAsset(url: source)
        guard end <= Int(CMTimeGetSeconds(asset.duration) * 1000) + 1 else {
          throw NSError(domain: "capture", code: 1)
        }
        export(asset, range: CMTimeRange(start: CMTime(value: Int64(start), timescale: 1000),
                                        duration: CMTime(value: Int64(end - start), timescale: 1000)))
      } catch { finishError("invalid_output") }
    case "switchCamera":
      switchCamera(args, result: result)
    case "setZoom": fail(result, "zoom_unavailable")
    case "setTorch": fail(result, "torch_unavailable")
    case "cancel", "dispose":
      canceled = true
      pendingStop = result
      if let exporter = exporter {
        exporter.cancelExport()
      } else if writerActive {
        // Wait for the writer to close before Dart releases its private lease.
        stopAction = { self.cleanup(); self.completeStop() }
        if movie?.isRecording == true { movie?.stopRecording() }
      } else {
        cleanup(); completeStop()
      }
    default: reply(result, FlutterMethodNotImplemented)
    }
  }

  private func initialize(_ args: [String: Any], id: String, result: @escaping FlutterResult) {
    guard let folder = args["directory"] as? String, let path = args["outputPath"] as? String,
          let requestedSide = args["side"] as? Int, requestedSide >= 128, requestedSide <= 640,
          requestedSide % 2 == 0, let bytes = args["maxBytes"] as? Int, bytes > 0, bytes <= 256 * 1024 * 1024,
          let duration = args["maxDurationMs"] as? Int, duration >= 800, duration <= 60000 else {
      fail(result, "invalid_profile"); return
    }
    let folderURL = URL(fileURLWithPath: folder).standardizedFileURL
    let outputURL = URL(fileURLWithPath: path).standardizedFileURL
    guard folderURL.resolvingSymlinksInPath() == folderURL,
          outputURL.deletingLastPathComponent() == folderURL,
          outputURL.pathExtension == "mp4",
          outputURL.resolvingSymlinksInPath() == outputURL else { fail(result, "invalid_output"); return }
    do {
      let attributes = try FileManager.default.attributesOfItem(atPath: folder)
      guard attributes[.type] as? FileAttributeType == .typeDirectory,
            (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700 else {
        fail(result, "invalid_output"); return
      }
    } catch { fail(result, "invalid_output"); return }
    captureID = id
    directory = folderURL
    output = outputURL
    side = requestedSide
    maxBytes = Int64(bytes)
    maxDuration = duration
    canceled = false
    interrupted = false
    authorize(.video) { video in
      self.queue.async {
        guard !self.canceled, self.captureID == id else { self.fail(result, "canceled"); return }
        guard video else { self.fail(result, "permission_denied"); return }
        self.authorize(.audio) { audio in
          self.queue.async {
            guard !self.canceled, self.captureID == id else { self.fail(result, "canceled"); return }
            guard audio else { self.fail(result, "permission_denied"); return }
            self.openCamera(result)
          }
        }
      }
    }
  }

  private func authorize(_ type: AVMediaType, completion: @escaping (Bool) -> Void) {
    switch AVCaptureDevice.authorizationStatus(for: type) {
    case .authorized: completion(true)
    case .notDetermined: AVCaptureDevice.requestAccess(for: type, completionHandler: completion)
    default: completion(false)
    }
  }

  private var cameras: [AVCaptureDevice] {
    AVCaptureDevice.devices(for: .video)
  }

  private func openCamera(_ result: @escaping FlutterResult) {
    do {
      guard let camera = cameras.first(where: { $0.position == .front }) ?? cameras.first,
            let microphone = AVCaptureDevice.default(for: .audio) else {
        fail(result, "capture"); return
      }
      let capture = AVCaptureSession()
      capture.beginConfiguration()
      if capture.canSetSessionPreset(.vga640x480) { capture.sessionPreset = .vga640x480 }
      let input = try AVCaptureDeviceInput(device: camera)
      let audio = try AVCaptureDeviceInput(device: microphone)
      guard capture.canAddInput(input), capture.canAddInput(audio) else {
        fail(result, "capture"); return
      }
      capture.addInput(input); capture.addInput(audio)
      let preview = AVCaptureVideoDataOutput()
      preview.alwaysDiscardsLateVideoFrames = true
      preview.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
      preview.setSampleBufferDelegate(self, queue: queue)
      let recording = AVCaptureMovieFileOutput()
      guard capture.canAddOutput(preview), capture.canAddOutput(recording) else {
        fail(result, "capture"); return
      }
      capture.addOutput(preview); capture.addOutput(recording)
      if let connection = recording.connection(with: .video) {
        recording.setOutputSettings([AVVideoCodecKey: AVVideoCodecType.h264], for: connection)
      }
      capture.commitConfiguration()
      session = capture; movie = recording; videoInput = input; previewOutput = preview
      sessionObserver = NotificationCenter.default.addObserver(
        forName: AVCaptureSession.runtimeErrorNotification, object: capture, queue: nil
      ) { [weak self] _ in self?.interrupt() }
      capture.startRunning()
      DispatchQueue.main.async {
        self.textureID = self.textures.register(self)
        result(self.previewDescriptor())
      }
    } catch { fail(result, "capture") }
  }

  private func previewDescriptor() -> [String: Any] {
    let format = videoInput?.device.activeFormat.formatDescription
    let dimensions = format.map { CMVideoFormatDescriptionGetDimensions($0) }
    return ["captureId": captureID ?? "", "textureId": textureID,
            "width": Int(dimensions?.width ?? 640), "height": Int(dimensions?.height ?? 480),
            "rotation": 0, "mirrored": true, "canSwitchDuringRecording": false,
            "canSwitchCamera": cameras.count > 1, "cameraRevision": revision,
            "minZoom": 1.0, "maxZoom": 1.0, "zoom": 1.0,
            "torchAvailable": false, "torchEnabled": false]
  }

  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    bufferLock.lock(); defer { bufferLock.unlock() }
    return pixelBuffer.map { Unmanaged.passRetained($0) }
  }

  func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                     from connection: AVCaptureConnection) {
    guard let preview = previewOutput, output === preview else { return }
    guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
    bufferLock.lock(); pixelBuffer = buffer; bufferLock.unlock()
    DispatchQueue.main.async {
      if self.textureID >= 0 { self.textures.textureFrameAvailable(self.textureID) }
    }
  }

  private func startSegment(_ result: @escaping FlutterResult) {
    guard let directory = directory, let movie = movie, session?.isRunning == true else {
      fail(result, "capture"); return
    }
    let remaining = maxDuration - Int(CMTimeGetSeconds(recorded) * 1000)
      guard remaining >= 100 else { fail(result, "recording_too_short"); return }
    segmentIndex += 1
    let url = directory.appendingPathComponent("segment-\(segmentIndex).mov")
    movie.maxRecordedDuration = CMTime(value: Int64(remaining), timescale: 1000)
    movie.maxRecordedFileSize = min(maxBytes * 8, 128 * 1024 * 1024)
    writerActive = true
    movie.startRecording(to: url, recordingDelegate: self)
    reply(result)
  }

  func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo url: URL,
                  from connections: [AVCaptureConnection]) {
    queue.async {
      guard let current = self.movie, output === current else { return }
      if self.canceled || self.stopAction != nil { current.stopRecording() }
    }
  }

  func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo url: URL,
                  from connections: [AVCaptureConnection], error: Error?) {
    queue.async {
      guard let current = self.movie, output === current else { return }
      self.writerActive = false
      if self.canceled { self.cleanup(); self.completeStop(); return }
      if let error = error as NSError?,
         error.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool != true {
        if let pause = self.pendingPause { self.pendingPause = nil; self.fail(pause, "capture") }
        self.stopAction = nil
        self.finishError("capture"); return
      }
      self.segments.append(url)
      self.recorded = CMTimeAdd(self.recorded, AVURLAsset(url: url).duration)
      try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
      let action = self.stopAction
      self.stopAction = nil
      if let action = action { action() } else {
        // A native duration limit or interruption never sends automatically.
        self.interrupted = true
        self.event("preparing")
        self.prepare()
      }
    }
  }

  private func prepare() {
    session?.stopRunning()
    do {
      let composition = AVMutableComposition()
      guard let video = composition.addMutableTrack(withMediaType: .video,
                    preferredTrackID: kCMPersistentTrackID_Invalid),
            let audio = composition.addMutableTrack(withMediaType: .audio,
                    preferredTrackID: kCMPersistentTrackID_Invalid) else {
        finishError("capture"); return
      }
      var cursor = CMTime.zero
      for url in segments {
        let asset = AVURLAsset(url: url)
        guard let v = asset.tracks(withMediaType: .video).first,
              let a = asset.tracks(withMediaType: .audio).first else {
          finishError("invalid_output"); return
        }
        let range = CMTimeRangeGetIntersection(v.timeRange, otherRange: a.timeRange)
        let length = range.duration
        try video.insertTimeRange(range, of: v, at: cursor)
        try audio.insertTimeRange(range, of: a, at: cursor)
        video.preferredTransform = v.preferredTransform
        cursor = CMTimeAdd(cursor, length)
      }
      let duration = CMTimeMinimum(cursor, CMTime(value: Int64(maxDuration), timescale: 1000))
      guard CMTimeGetSeconds(duration) >= 0.8 else { finishError("recording_too_short"); return }
      export(composition, range: CMTimeRange(start: .zero, duration: duration))
    } catch { finishError("capture") }
  }

  private func export(_ asset: AVAsset, range: CMTimeRange) {
    guard let directory = directory,
          let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetMediumQuality) else {
      finishError("capture"); return
    }
    let staging = directory.appendingPathComponent("export.mp4")
    try? FileManager.default.removeItem(at: staging)
    export.outputURL = staging
    export.outputFileType = .mp4
    export.shouldOptimizeForNetworkUse = true
    export.timeRange = range
    let size = CGFloat(side)
    let bounds = CGRect(x: 0, y: 0, width: size, height: size)
    guard let maskContext = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                     bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
      finishError("capture"); return
    }
    maskContext.setFillColor(NSColor.black.cgColor); maskContext.fill(bounds)
    maskContext.setFillColor(NSColor.white.cgColor); maskContext.fillEllipse(in: bounds)
    guard let maskImage = maskContext.makeImage() else { finishError("capture"); return }
    let mask = CIImage(cgImage: maskImage)
    let black = CIImage(color: .black).cropped(to: bounds)
    let video = AVMutableVideoComposition(asset: asset) { request in
      let source = request.sourceImage
      let extent = source.extent
      let scale = size / min(extent.width, extent.height)
      let square = source.transformed(by: CGAffineTransform(translationX: -extent.midX, y: -extent.midY))
        .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        .transformed(by: CGAffineTransform(translationX: size / 2, y: size / 2)).cropped(to: bounds)
      let sanitized = square.applyingFilter("CIBlendWithMask", parameters: [
        kCIInputBackgroundImageKey: black, kCIInputMaskImageKey: mask])
      request.finish(with: sanitized, context: nil)
    }
    video.renderSize = bounds.size
    video.frameDuration = CMTime(value: 1, timescale: 30)
    export.videoComposition = video
    exporter = export
    export.exportAsynchronously {
      self.queue.async {
        self.exporter = nil
        if self.canceled { self.cleanup(); self.completeStop(); return }
        guard export.status == .completed else { self.finishError("capture"); return }
        self.validateAndPublish(staging)
      }
    }
  }

  private func validateAndPublish(_ staging: URL) {
    guard let output = output else { finishError("canceled"); return }
    do {
      let asset = AVURLAsset(url: staging)
      guard let video = asset.tracks(withMediaType: .video).first,
            let audio = asset.tracks(withMediaType: .audio).first,
            let videoFormat = video.formatDescriptions.first,
            let audioFormat = audio.formatDescriptions.first else {
        finishError("invalid_output"); return
      }
      let v = videoFormat as! CMFormatDescription
      let a = audioFormat as! CMFormatDescription
      let size = try FileManager.default.attributesOfItem(atPath: staging.path)[.size] as? NSNumber
      let dimensions = CMVideoFormatDescriptionGetDimensions(v)
      let duration = Int((CMTimeGetSeconds(asset.duration) * 1000).rounded())
      guard CMFormatDescriptionGetMediaSubType(v) == kCMVideoCodecType_H264,
            CMFormatDescriptionGetMediaSubType(a) == kAudioFormatMPEG4AAC,
            Int(dimensions.width) == side, Int(dimensions.height) == side,
            duration >= 800, duration <= maxDuration,
            let bytes = size?.int64Value, bytes > 0, bytes <= maxBytes,
            try hasFastStart(staging) else {
        finishError("invalid_output"); return
      }
      // A failed trim leaves the last validated file in place.
      guard rename(staging.path, output.path) == 0 else {
        finishError("capture"); return
      }
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
      var descriptor: [String: Any] = [
        "captureId": captureID ?? "", "path": output.path,
        "width": side, "height": side, "durationMs": duration, "sizeBytes": bytes,
        "videoCodec": "h264", "audioCodec": "aac", "cornersSanitized": true,
        "fastStart": true, "wasInterrupted": interrupted]
      let generator = AVAssetImageGenerator(asset: AVURLAsset(url: output))
      generator.appliesPreferredTrackTransform = true
      if let image = try? generator.copyCGImage(at: .zero, actualTime: nil),
         let jpeg = NSBitmapImageRep(cgImage: image).representation(
            using: .jpeg, properties: [.compressionFactor: 0.8]) {
        let thumbnail = output.deletingLastPathComponent().appendingPathComponent("thumb.jpg")
        do {
          try jpeg.write(to: thumbnail, options: .atomic)
          try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: thumbnail.path)
          descriptor["thumbnailPath"] = thumbnail.path
        } catch { /* A thumbnail failure must not discard the validated video. */ }
      }
      if let result = pendingFinish {
        pendingFinish = nil; reply(result, descriptor)
      } else {
        event("completed", descriptor)
      }
    } catch { finishError("capture") }
  }

  /// Do not claim fast-start based only on the encoder's optimization hint.
  private func hasFastStart(_ url: URL) throws -> Bool {
    let data = try Data(contentsOf: url, options: .mappedIfSafe)
    var offset = 0
    func integer(_ start: Int, _ count: Int) -> UInt64 {
      data[start..<(start + count)].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }
    while offset + 8 <= data.count {
      var length = integer(offset, 4)
      let type = String(bytes: data[(offset + 4)..<(offset + 8)], encoding: .ascii)
      let header = length == 1 ? 16 : 8
      if length == 1 {
        guard offset + 16 <= data.count else { return false }
        length = integer(offset + 8, 8)
      } else if length == 0 {
        length = UInt64(data.count - offset)
      }
      guard length >= UInt64(header), length <= UInt64(data.count - offset) else { return false }
      if type == "moov" { return true }
      if type == "mdat" { return false }
      offset += Int(length)
    }
    return false
  }

  private func switchCamera(_ args: [String: Any], result: @escaping FlutterResult) {
    guard args["cameraRevision"] as? Int == revision else { fail(result, "stale_camera"); return }
    guard !writerActive, exporter == nil, stopAction == nil,
          let capture = session, let old = videoInput, cameras.count > 1,
          let device = cameras.first(where: { $0.uniqueID != old.device.uniqueID }) else {
      fail(result, "camera_switch_failed"); return
    }
    do {
      let replacement = try AVCaptureDeviceInput(device: device)
      capture.beginConfiguration(); capture.removeInput(old)
      guard capture.canAddInput(replacement) else {
        capture.addInput(old); capture.commitConfiguration()
        fail(result, "camera_switch_failed"); return
      }
      capture.addInput(replacement); capture.commitConfiguration()
      videoInput = replacement; revision += 1
      reply(result, previewDescriptor())
    } catch { fail(result, "camera_switch_failed") }
  }

  private func interrupt() {
    queue.async {
      guard self.writerActive, self.stopAction == nil else { return }
      self.interrupted = true
      self.event("preparing")
      self.stopAction = { self.prepare() }
      if self.movie?.isRecording == true { self.movie?.stopRecording() }
    }
  }

  private func event(_ type: String, _ values: [String: Any] = [:]) {
    let data = values.merging(["captureId": captureID ?? "", "type": type,
                               "wasInterrupted": interrupted]) { _, new in new }
    DispatchQueue.main.async { self.channel.invokeMethod("event", arguments: data) }
  }

  private func finishError(_ code: String) {
    if let result = pendingFinish { pendingFinish = nil; fail(result, code) }
    else { event("error", ["code": code]) }
  }

  private func completeStop() {
    if let pause = pendingPause { pendingPause = nil; fail(pause, "canceled") }
    if let result = pendingFinish { pendingFinish = nil; fail(result, "canceled") }
    if let result = pendingStop { pendingStop = nil; reply(result) }
  }

  private func cleanup() {
    if let observer = sessionObserver {
      NotificationCenter.default.removeObserver(observer); sessionObserver = nil
    }
    session?.stopRunning(); session = nil; movie = nil; videoInput = nil; previewOutput = nil
    writerActive = false
    for url in segments { try? FileManager.default.removeItem(at: url) }
    segments = []; recorded = .zero; stopAction = nil
    captureID = nil
    bufferLock.lock(); pixelBuffer = nil; bufferLock.unlock()
    DispatchQueue.main.async {
      if self.textureID >= 0 { self.textures.unregisterTexture(self.textureID); self.textureID = -1 }
    }
  }

  deinit {
    if let observer = focusObserver { NotificationCenter.default.removeObserver(observer) }
    for observer in observers {
      NotificationCenter.default.removeObserver(observer)
      NSWorkspace.shared.notificationCenter.removeObserver(observer)
    }
  }
}
