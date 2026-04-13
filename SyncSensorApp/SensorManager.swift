//
//  SensorManager.swift
//  SyncSensorApp
//
//  Created by Yanxin Luo on 4/3/26.
//

import Foundation
import AVFoundation
import CoreMotion
import Combine
import AudioToolbox
import UIKit

class SensorManager: NSObject, ObservableObject {
    // Recording status
    @Published var isRecording = false
    @Published var hasPermissions = false
    // Added: Warm-up and countdown status
    @Published var isWarmingUp = false
    @Published var countdown: Int = 0

    
    // Recording duration tracking
    @Published var recordingDuration: TimeInterval = 0.0
    private var recordingTimer: Timer?
    
    // Remove @Published to prevent high-frequency (100Hz) data updates from causing global SwiftUI view redraws and freezes
    var currentAudioLevel: Float = 0.0
    var currentIMUAcceleration: (x: Double, y: Double, z: Double) = (0.0, 0.0, 0.0)
    var currentIMUGravity: (x: Double, y: Double, z: Double) = (0.0, 0.0, 0.0)
    var currentIMUGyroscope: (x: Double, y: Double, z: Double) = (0.0, 0.0, 0.0)
    var currentIMUOrientation: (roll: Double, pitch: Double, yaw: Double) = (0.0, 0.0, 0.0)

    // Settings
    @Published var useFrontCamera: Bool = false {
        didSet {
            if hasPermissions {
                switchCamera()
            }
        }
    }
    @Published var videoFrameRateOption: VideoFrameRateOption = .max {
        didSet {
            if hasPermissions { updateVideoFrameRate() }
        }
    }
    @Published var customVideoFrameRate: Double = 30.0 {
        didSet {
            if hasPermissions && videoFrameRateOption == .custom { updateVideoFrameRate() }
        }
    }
    @Published var imuSampleRateOption: IMUSampleRateOption = .hz100 {
        didSet {
            if hasPermissions { updateIMUSampleRate() }
        }
    }
    @Published var customIMUSampleRate: Double = 100.0 {
        didSet {
            if hasPermissions && imuSampleRateOption == .custom { updateIMUSampleRate() }
        }
    }

    // 1. Hardware managers
    let captureSession = AVCaptureSession()
    private let motionManager = CMMotionManager()

    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()

    // 2. Independent data processing queues (to prevent blocking the main thread)
    private let videoQueue = DispatchQueue(label: "com.jeffluo.videoQueue", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "com.jeffluo.audioQueue", qos: .userInteractive)
    private let imuQueue = OperationQueue()
    
    // 3. File writers and queues
    private var currentSessionURL: URL?
    
    // Efficient audio and video writers
    private var assetWriter: AVAssetWriter?
    private var videoWriterInput: AVAssetWriterInput?
    private var audioWriterInput: AVAssetWriterInput?
    private var hasStartedAudioSession = false
    
    private var accFile, gravFile, gyroFile, oriFile: BufferedFileWriter?

    // Metadata
    private var firstTimestamp: Double?
    private var actualVideoFrameRate: Double?
    private let timestampLock = NSLock()
    private var recordingStartTime: Date?
    private var targetStartTime: Double? // Absolute physical start line


    override init() {
        super.init()
        imuQueue.qualityOfService = .userInteractive
    }

    // Video frame rate options
    enum VideoFrameRateOption: String, CaseIterable, Identifiable {
        case max = "Max"
        case s1 = "1s"
        case s10 = "10s"
        case custom = "Custom"
        var id: String { self.rawValue }
    }

    // IMU sample rate options
    enum IMUSampleRateOption: String, CaseIterable, Identifiable {
        case hz100 = "100Hz"
        case hz20 = "20Hz"
        case custom = "Custom"
        var id: String { self.rawValue }
    }
    
    // MARK: - Permission Request
    func requestPermissions() {
        AVCaptureDevice.requestAccess(for: .video) { videoGranted in
            AVCaptureDevice.requestAccess(for: .audio) { audioGranted in
                DispatchQueue.main.async {
                    self.hasPermissions = videoGranted && audioGranted
                    if self.hasPermissions {
                        self.setupHardware()
                    }
                }
            }
        }
    }
    
    // MARK: - Hardware Initialization
    func setupHardware() {
          captureSession.beginConfiguration()

          // Set resolution to 1280x720 (720p)
          if captureSession.canSetSessionPreset(.hd1280x720) {
            captureSession.sessionPreset = .hd1280x720
          }

          // --- Video Configuration ---
          let position: AVCaptureDevice.Position = useFrontCamera ? .front : .back
          guard let videoDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
              let videoInput = try? AVCaptureDeviceInput(device: videoDevice) else { return }
          if captureSession.canAddInput(videoInput) { captureSession.addInput(videoInput) }

          videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
          videoOutput.alwaysDiscardsLateVideoFrames = true
          if captureSession.canAddOutput(videoOutput) { captureSession.addOutput(videoOutput) }

          // --- Audio Configuration ---
          guard let audioDevice = AVCaptureDevice.default(for: .audio),
              let audioInput = try? AVCaptureDeviceInput(device: audioDevice) else { return }
          if captureSession.canAddInput(audioInput) { captureSession.addInput(audioInput) }

          audioOutput.setSampleBufferDelegate(self, queue: audioQueue)
          if captureSession.canAddOutput(audioOutput) { captureSession.addOutput(audioOutput) }

          captureSession.commitConfiguration()

          updateVideoFrameRate()

          // --- IMU Configuration ---
          if motionManager.isDeviceMotionAvailable {
            updateIMUSampleRate()
            // Start IMU data stream early for UI real-time preview
            motionManager.startDeviceMotionUpdates(to: imuQueue) { [weak self] (motion, error) in
                guard let self = self, let motion = motion else { return }
                
                // Update data purely on background thread, freeing up the main thread completely
                self.currentIMUAcceleration = (motion.userAcceleration.x, motion.userAcceleration.y, motion.userAcceleration.z)
                self.currentIMUGravity = (motion.gravity.x, motion.gravity.y, motion.gravity.z)
                self.currentIMUGyroscope = (motion.rotationRate.x, motion.rotationRate.y, motion.rotationRate.z)
                self.currentIMUOrientation = (motion.attitude.roll, motion.attitude.pitch, motion.attitude.yaw)
                
                if self.isRecording || self.isWarmingUp {
                    let imuTime = motion.timestamp
                    
                    // Core gate: Discard dirty IMU data from the 3-second warm-up phase
                    guard let target = self.targetStartTime, imuTime >= target else { return }
                    
                    // First data passing the gate
                    self.timestampLock.lock()
                    if self.firstTimestamp == nil {
                        self.firstTimestamp = imuTime
                    }
                    self.timestampLock.unlock()
                    
                    self.writeIMU(motion, timestamp: imuTime)
                }
            }
        }
    }
    
    // MARK: - Switch Camera
    func switchCamera() {
        // Execute hardware switching on a background thread to prevent UI freezing during Picker switching
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            self.captureSession.beginConfiguration()
            
            // 1. Find and remove existing video inputs
            let currentVideoInputs = self.captureSession.inputs.compactMap { $0 as? AVCaptureDeviceInput }.filter { $0.device.hasMediaType(.video) }
            for input in currentVideoInputs {
                self.captureSession.removeInput(input)
            }
            
            // 2. Add new video input based on the latest settings
            let position: AVCaptureDevice.Position = self.useFrontCamera ? .front : .back
            guard let videoDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
                  let videoInput = try? AVCaptureDeviceInput(device: videoDevice) else {
                self.captureSession.commitConfiguration()
                return
            }
            
            if self.captureSession.canAddInput(videoInput) { self.captureSession.addInput(videoInput) }
            
            self.captureSession.commitConfiguration()
            
            // Re-apply the current frame rate settings after switching the lens
            self.updateVideoFrameRate()
        }
    }
    
    // MARK: - Dynamically Update Hardware Frequencies
    func updateVideoFrameRate() {
        // 1. Find the video device currently in use
        guard let videoInput = captureSession.inputs.compactMap({ $0 as? AVCaptureDeviceInput }).first(where: { $0.device.hasMediaType(.video) }) else { return }
        let videoDevice = videoInput.device
        
        var targetFPS: Double
        switch videoFrameRateOption {
        case .max: targetFPS = 60.0 // Setting to 60 will automatically clamp to the maximum supported by the current format in the logic below
        case .s1: targetFPS = 1.0
        case .s10: targetFPS = 0.1 // 1 frame per 10 seconds
        case .custom: targetFPS = customVideoFrameRate > 0 ? customVideoFrameRate : 30.0
        }
        
        do {
            try videoDevice.lockForConfiguration()
            
            // 2. Core safety mechanism: Get the supported frame rate range for the camera's current format. Forcing an unsupported frame rate (e.g., 0.1 FPS) will crash the App
            let ranges = videoDevice.activeFormat.videoSupportedFrameRateRanges
            guard let minAllowed = ranges.min(by: { $0.minFrameRate < $1.minFrameRate })?.minFrameRate,
                  let maxAllowed = ranges.max(by: { $0.maxFrameRate < $1.maxFrameRate })?.maxFrameRate else {
                videoDevice.unlockForConfiguration()
                return
            }
            
            // 3. Clamp the target frame rate within the allowed range
            let clampedFPS = max(minAllowed, min(maxAllowed, targetFPS))
            let frameDuration = CMTime(seconds: 1.0 / clampedFPS, preferredTimescale: 600)
            
            videoDevice.activeVideoMinFrameDuration = frameDuration
            videoDevice.activeVideoMaxFrameDuration = frameDuration
            
            videoDevice.unlockForConfiguration()
            print("📷 Video frame rate applied: \(String(format: "%.1f", clampedFPS)) FPS")
        } catch {
            print("📷 Failed to set frame rate: \(error)")
        }
    }
    
    func updateIMUSampleRate() {
        guard motionManager.isDeviceMotionAvailable else { return }
        let targetHz: Double = (imuSampleRateOption == .hz100) ? 100.0 : ((imuSampleRateOption == .hz20) ? 20.0 : (customIMUSampleRate > 0 ? customIMUSampleRate : 100.0))
        motionManager.deviceMotionUpdateInterval = 1.0 / targetHz
        print("📳 IMU sample rate applied: \(targetHz) Hz")
    }
    
    // MARK: - Recording Control
    func startRecording() {
        guard hasPermissions else { return }
        
        // --- 1. Set the future absolute start line (current uptime + 3 seconds) ---
        let absoluteNow = CACurrentMediaTime()
        self.targetStartTime = absoluteNow + 3.0
        
        // Reset status
        self.firstTimestamp = nil
        self.actualVideoFrameRate = nil
        self.recordingStartTime = Date().addingTimeInterval(3.0) // The time displayed on the UI also needs to add 3 seconds
        self.hasStartedAudioSession = false
        
        // --- 2. Create directories, initialize files and writers ---
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let folderName = "Record_" + formatter.string(from: self.recordingStartTime!)
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let sessionURL = docs.appendingPathComponent(folderName)
        try? FileManager.default.createDirectory(at: sessionURL, withIntermediateDirectories: true)
        self.currentSessionURL = sessionURL
        
        // --- 2a. Get actual video frame rate ---
        if let videoInput = captureSession.inputs.compactMap({ $0 as? AVCaptureDeviceInput }).first(where: { $0.device.hasMediaType(.video) }) {
            let videoDevice = videoInput.device
            if videoDevice.activeVideoMinFrameDuration.seconds > 0 {
                self.actualVideoFrameRate = 1.0 / videoDevice.activeVideoMinFrameDuration.seconds
            }
        }
        
        // --- 2b. Configure an efficient AVAssetWriter to write audio and video streams into a single MP4 file ---
        let videoURL = sessionURL.appendingPathComponent("Video.mp4")
        assetWriter = try? AVAssetWriter(url: videoURL, fileType: .mp4)

        // Configure video input
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 1280,
            AVVideoHeightKey: 720,
        ]
        videoWriterInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoWriterInput?.expectsMediaDataInRealTime = true
        if let vwi = videoWriterInput, assetWriter?.canAdd(vwi) == true {
            assetWriter?.add(vwi)
        }

        // Configure audio input
        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 128000
        ]
        audioWriterInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audioWriterInput?.expectsMediaDataInRealTime = true
        if let awi = audioWriterInput, assetWriter?.canAdd(awi) == true {
            assetWriter?.add(awi)
        }
        assetWriter?.startWriting()
        
        // --- 2c. Create IMU CSV handles and write headers ---
        let xyzHeader = "time\tseconds_elapsed\tz\ty\tx\n"
        let rpyHeader = "time\tseconds_elapsed\tyaw\tpitch\troll\n"
        accFile = createCSV(name: "Accelerometer.csv", in: sessionURL, header: xyzHeader)
        gravFile = createCSV(name: "Gravity.csv", in: sessionURL, header: xyzHeader)
        gyroFile = createCSV(name: "Gyroscope.csv", in: sessionURL, header: xyzHeader)
        oriFile = createCSV(name: "Orientation.csv", in: sessionURL, header: rpyHeader)
        
        // --- 3. Start UI countdown and mark as warm-up status ---
        DispatchQueue.main.async {
            self.isWarmingUp = true
            self.countdown = 3
            
            Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
                guard let self = self else { return }
                self.countdown -= 1
                
                // 3-second countdown ends, officially switch to recording status!
                if self.countdown == 0 {
                    timer.invalidate()
                    self.isWarmingUp = false
                    self.isRecording = true
                    self.recordingDuration = 0.0
                    self.recordingTimer?.invalidate()
                    
                    self.recordingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                        self?.recordingDuration += 1.0
                    }
                    RunLoop.main.add(self.recordingTimer!, forMode: .common)
                }
            }
        }
        print("====== ⏳ Hardware started, beginning 3-second warm-up to discard data... ======")
    }
    
    func stopRecording() {
        DispatchQueue.main.async {
            self.isRecording = false
            self.isWarmingUp = false // Added this line
            self.targetStartTime = nil // Added this line
            self.recordingTimer?.invalidate()
            self.recordingTimer = nil
        }
        
        if let sessionURL = self.currentSessionURL {
            createMetadataFile(at: sessionURL)
        }
        
        // Finalize audio and video writing
        videoWriterInput?.markAsFinished()
        audioWriterInput?.markAsFinished()
        assetWriter?.finishWriting { [weak self] in
            self?.assetWriter = nil
            self?.videoWriterInput = nil
            self?.audioWriterInput = nil
        }
        
        // Close IMU handles
        accFile?.close()
        gravFile?.close()
        gyroFile?.close()
        oriFile?.close()
        print("====== 🛑 Recording stopped ======")
    }
    
    private func createCSV(name: String, in folder: URL, header: String) -> BufferedFileWriter? {
        let url = folder.appendingPathComponent(name)
        // 1. Create file and write header. This overwrites any old file with the same name, ensuring a fresh start.
        FileManager.default.createFile(atPath: url.path, contents: header.data(using: .utf8), attributes: nil)
        
        // 2. Open buffered writer (it handles "update" mode and appending internally)
        return BufferedFileWriter(url: url)
    }
    
    private func createMetadataFile(at sessionURL: URL) {
        let metadataURL = sessionURL.appendingPathComponent("Metadata.csv")

        // 1. version
        let version = "3"

        // 2. device name
        let deviceName = UIDevice.current.modelName // Use a more specific phone model

        // 3. recording start uptime (ms)
        let recordingUptimeMs = Int64((firstTimestamp ?? 0) * 1000)

        // 4. recording start uptime (s)
        let recordingUptimeString = String(format: "%.5f", firstTimestamp ?? 0)

        // 5. recording timezone
        let recordingTimezone = TimeZone.current.identifier

        // 6. platform
        let platform = "ios"

        // 7. appVersion
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "N/A"

        // 8. device id
        let deviceId = UIDevice.current.identifierForVendor?.uuidString ?? "N/A"

        // 9. sensors
        let sensors = "Accelerometer|Gravity|Gyroscope|Orientation|Camera|Microphone"

        // 10. sampleRateMs (period in milliseconds)
        let imuIntervalMs = Int(motionManager.deviceMotionUpdateInterval * 1000)
        let videoIntervalMs = Int((actualVideoFrameRate.map { 1.0 / $0 } ?? 0) * 1000)
        let sampleRateMs = "\(imuIntervalMs)|\(imuIntervalMs)|\(imuIntervalMs)|\(imuIntervalMs)|\(videoIntervalMs)|0" // Using 0 for Microphone as its rate is very high

        // 11. standardisation
        let standardisation = "FALSE"

        // 12. platform version
        let platformVersion = UIDevice.current.systemVersion

        // 13. fusion
        let fusion = "system"

        let header = ["version", "device name", "recording start uptime ms", "recording start uptime s", "recording timezone", "platform", "appVersion", "device id", "sensors", "sampleRateMs", "standardisation", "platform version", "fusion"].joined(separator: "\t")
        let data = [version, deviceName, String(recordingUptimeMs), recordingUptimeString, recordingTimezone, platform, appVersion, deviceId, sensors, sampleRateMs, standardisation, platformVersion, fusion].joined(separator: "\t")
        let contents = header + "\n" + data

        try? contents.write(to: metadataURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Extract Audio from MP4 to WAV
    /// Extract audio from MP4 to WAV, callback to main thread upon completion
    func extractAudioFromVideo(videoURL: URL) async throws -> URL {
        let asset = AVURLAsset(url: videoURL)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard let audioTrack = audioTracks.first else {
            throw NSError(domain: "No audio track", code: -1, userInfo: [NSLocalizedDescriptionKey: "The video file does not contain an audio track."])
        }
        
        let worker = try AudioExtractorWorker(videoURL: videoURL, asset: asset, audioTrack: audioTrack)
        return try await withCheckedThrowingContinuation { continuation in
            worker.extract { result in
                continuation.resume(with: result)
            }
        }
    }

    // Audio extraction worker class, using @unchecked Sendable to suppress concurrency warnings from underlying C frameworks
    private final class AudioExtractorWorker: @unchecked Sendable {
        let outputURL: URL
        private let reader: AVAssetReader
        private let writer: AVAssetWriter
        private let input: AVAssetWriterInput
        private let trackOutput: AVAssetReaderTrackOutput

        init(videoURL: URL, asset: AVAsset, audioTrack: AVAssetTrack) throws {
            self.outputURL = videoURL.deletingPathExtension().appendingPathExtension("wav")
            try? FileManager.default.removeItem(at: outputURL)

            // Must use the asset that belongs to the same instance as audioTrack
            self.reader = try AVAssetReader(asset: asset)
            let outputSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false
            ]
            self.trackOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: outputSettings)
            self.reader.add(trackOutput)

            self.writer = try AVAssetWriter(url: outputURL, fileType: .wav)
            self.input = AVAssetWriterInput(mediaType: .audio, outputSettings: outputSettings)
            self.input.expectsMediaDataInRealTime = false
            self.writer.add(input)
            self.writer.shouldOptimizeForNetworkUse = false
        }

        func extract(completion: @escaping (Result<URL, Error>) -> Void) {
            writer.startWriting()
            reader.startReading()
            writer.startSession(atSourceTime: .zero)
            let queue = DispatchQueue(label: "audio-extraction-queue")
            input.requestMediaDataWhenReady(on: queue) {
                while self.input.isReadyForMoreMediaData {
                    if let sampleBuffer = self.trackOutput.copyNextSampleBuffer() {
                        self.input.append(sampleBuffer)
                    } else {
                        self.input.markAsFinished()
                        self.writer.finishWriting {
                            if self.writer.status == .completed { completion(.success(self.outputURL)) }
                            else { completion(.failure(self.writer.error ?? NSError(domain: "AVAssetWriter", code: -2))) }
                        }
                        break
                    }
                }
            }
        }
    }
}

// MARK: - Audio and Video Frame Underlying Callbacks
extension SensorManager: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        
        // --- 1. Real-time UI data update (also needed in non-recording and non-warming-up states to keep the screen waveform moving) ---
        if output == audioOutput, let channel = connection.audioChannels.first {
            let power = channel.averagePowerLevel
            let level = max(0.0, min(1.0, (power + 50) / 50))
            self.currentAudioLevel = level
        }
        
        // --- 2. Status pass: Continue only when "recording" or "warming up" ---
        guard isRecording || isWarmingUp else { return }
        
        // Extract absolute presentation time at the hardware level (Presentation Timestamp)
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let timestampInSeconds = CMTimeGetSeconds(pts)
        
        // =========================================================
        // Core Interception Gate (Data Gate): Discard dirty data from the warm-up period
        // =========================================================
        if let target = targetStartTime, timestampInSeconds < target {
            // Less than 3 seconds elapsed! The underlying camera and microphone are still initializing.
            // The data at this time is full of latency and jitter, we directly return and discard it ruthlessly!
            return
        }
        // =========================================================
        
        // --- First data to pass through the gate! It will determine the absolute start time (T0) of the entire session ---
        timestampLock.lock()
        if self.firstTimestamp == nil {
            self.firstTimestamp = timestampInSeconds
            print("[A/V Stream] Warm-up finished! First frame passed the gate, absolute start time: \(String(format: "%.5f", timestampInSeconds))")
        }
        timestampLock.unlock()
        
        // --- Write audio and video streams (MP4) ---
        guard let writer = assetWriter, writer.status == .writing else { return }
        
        // When the first valid data frame arrives, use its true physical timestamp (pts) as the MP4 start time!
        if !hasStartedAudioSession {
            writer.startSession(atSourceTime: pts)
            hasStartedAudioSession = true
            print("🎬 MP4 container officially starts writing at this moment!")
        }
        
        // Feed video frames and audio frames to their corresponding writer inputs
        if output == videoOutput, let input = videoWriterInput, input.isReadyForMoreMediaData {
            input.append(sampleBuffer)
        } else if output == audioOutput, let input = audioWriterInput, input.isReadyForMoreMediaData {
            input.append(sampleBuffer)
        }
    }
    
    // For use by the IMU callback, safely write to file
    func writeIMU(_ motion: CMDeviceMotion, timestamp: Double) {
        let elapsed = timestamp - (firstTimestamp ?? timestamp) // seconds_elapsed remains unchanged
        let timeStr = String(format: "%.5f", timestamp)
        let elapsedStr = String(format: "%.5f", elapsed)
        accFile?.write("\(timeStr)\t\(elapsedStr)\t\(motion.userAcceleration.z)\t\(motion.userAcceleration.y)\t\(motion.userAcceleration.x)\n")
        gravFile?.write("\(timeStr)\t\(elapsedStr)\t\(motion.gravity.z)\t\(motion.gravity.y)\t\(motion.gravity.x)\n")
        gyroFile?.write("\(timeStr)\t\(elapsedStr)\t\(motion.rotationRate.z)\t\(motion.rotationRate.y)\t\(motion.rotationRate.x)\n")
        oriFile?.write("\(timeStr)\t\(elapsedStr)\t\(motion.attitude.yaw)\t\(motion.attitude.pitch)\t\(motion.attitude.roll)\n")
    }
}

// MARK: - Buffered File Writer (Performance Optimization)
private final class BufferedFileWriter {
    private let fileHandle: FileHandle
    private var buffer: Data
    private let capacity: Int
    private let lock = NSLock() // Ensure thread safety between IMU queue and main thread closures

    init?(url: URL, capacity: Int = 32768) { // Default capacity is 32KB
        do {
            self.fileHandle = try FileHandle(forUpdating: url)
            self.fileHandle.seekToEndOfFile()
            self.capacity = capacity
            self.buffer = Data(capacity: capacity)
        } catch {
            return nil
        }
    }

    func write(_ string: String) {
        guard let data = string.data(using: .utf8) else { return }
        lock.lock()
        buffer.append(data)
        if buffer.count >= capacity {
            flushUnsafe()
        }
        lock.unlock()
    }

    private func flushUnsafe() {
        if !buffer.isEmpty {
            try? fileHandle.write(contentsOf: buffer)
            buffer.removeAll(keepingCapacity: true) // Keep memory allocated for performance
        }
    }

    func flush() {
        lock.lock()
        flushUnsafe()
        lock.unlock()
    }

    func close() {
        lock.lock()
        flushUnsafe()
        try? fileHandle.close()
        lock.unlock()
    }
}

// MARK: - UIDevice Extension for Specific Model Name
extension UIDevice {
    var modelIdentifier: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machineMirror = Mirror(reflecting: systemInfo.machine)
        let identifier = machineMirror.children.reduce("") { identifier, element in
            guard let value = element.value as? Int8, value != 0 else { return identifier }
            return identifier + String(UnicodeScalar(UInt8(value)))
        }
        return identifier
    }

    var modelName: String {
        let identifier = modelIdentifier
        switch identifier {
        case "iPod9,1":                                 return "iPod touch (7th generation)"
        case "iPhone8,1":                               return "iPhone 6s"
        case "iPhone8,2":                               return "iPhone 6s Plus"
        case "iPhone8,4":                               return "iPhone SE (1st generation)"
        case "iPhone9,1", "iPhone9,3":                  return "iPhone 7"
        case "iPhone9,2", "iPhone9,4":                  return "iPhone 7 Plus"
        case "iPhone10,1", "iPhone10,4":                return "iPhone 8"
        case "iPhone10,2", "iPhone10,5":                return "iPhone 8 Plus"
        case "iPhone10,3", "iPhone10,6":                return "iPhone X"
        case "iPhone11,2":                              return "iPhone XS"
        case "iPhone11,4", "iPhone11,6":                return "iPhone XS Max"
        case "iPhone11,8":                              return "iPhone XR"
        case "iPhone12,1":                              return "iPhone 11"
        case "iPhone12,3":                              return "iPhone 11 Pro"
        case "iPhone12,5":                              return "iPhone 11 Pro Max"
        case "iPhone12,8":                              return "iPhone SE (2nd generation)"
        case "iPhone13,1":                              return "iPhone 12 mini"
        case "iPhone13,2":                              return "iPhone 12"
        case "iPhone13,3":                              return "iPhone 12 Pro"
        case "iPhone13,4":                              return "iPhone 12 Pro Max"
        case "iPhone14,2":                              return "iPhone 13 Pro"
        case "iPhone14,3":                              return "iPhone 13 Pro Max"
        case "iPhone14,4":                              return "iPhone 13 mini"
        case "iPhone14,5":                              return "iPhone 13"
        case "iPhone14,6":                              return "iPhone SE (3rd generation)"
        case "iPhone14,7":                              return "iPhone 14"
        case "iPhone14,8":                              return "iPhone 14 Plus"
        case "iPhone15,2":                              return "iPhone 14 Pro"
        case "iPhone15,3":                              return "iPhone 14 Pro Max"
        case "iPhone15,4":                              return "iPhone 15"
        case "iPhone15,5":                              return "iPhone 15 Plus"
        case "iPhone16,1":                              return "iPhone 15 Pro"
        case "iPhone16,2":                              return "iPhone 15 Pro Max"
        case "iPad2,1", "iPad2,2", "iPad2,3", "iPad2,4":return "iPad 2"
        case "iPad3,1", "iPad3,2", "iPad3,3":           return "iPad (3rd generation)"
        case "iPad3,4", "iPad3,5", "iPad3,6":           return "iPad (4th generation)"
        case "iPad6,11", "iPad6,12":                    return "iPad (5th generation)"
        case "iPad7,5", "iPad7,6":                      return "iPad (6th generation)"
        case "iPad7,11", "iPad7,12":                    return "iPad (7th generation)"
        case "iPad11,6", "iPad11,7":                    return "iPad (8th generation)"
        case "iPad12,1", "iPad12,2":                    return "iPad (9th generation)"
        case "iPad13,18", "iPad13,19":                  return "iPad (10th generation)"
        case "iPad4,1", "iPad4,2", "iPad4,3":           return "iPad Air"
        case "iPad5,3", "iPad5,4":                      return "iPad Air 2"
        case "iPad11,3", "iPad11,4":                    return "iPad Air (3rd generation)"
        case "iPad13,1", "iPad13,2":                    return "iPad Air (4th generation)"
        case "iPad13,16", "iPad13,17":                  return "iPad Air (5th generation)"
        case "iPad2,5", "iPad2,6", "iPad2,7":           return "iPad mini"
        case "iPad4,4", "iPad4,5", "iPad4,6":           return "iPad mini 2"
        case "iPad4,7", "iPad4,8", "iPad4,9":           return "iPad mini 3"
        case "iPad5,1", "iPad5,2":                      return "iPad mini 4"
        case "iPad11,1", "iPad11,2":                    return "iPad mini (5th generation)"
        case "iPad14,1", "iPad14,2":                    return "iPad mini (6th generation)"
        case "iPad6,3", "iPad6,4":                      return "iPad Pro (9.7-inch)"
        case "iPad6,7", "iPad6,8":                      return "iPad Pro (12.9-inch)"
        case "iPad7,1", "iPad7,2":                      return "iPad Pro (12.9-inch) (2nd generation)"
        case "iPad7,3", "iPad7,4":                      return "iPad Pro (10.5-inch)"
        case "iPad8,1", "iPad8,2", "iPad8,3", "iPad8,4":return "iPad Pro (11-inch)"
        case "iPad8,5", "iPad8,6", "iPad8,7", "iPad8,8":return "iPad Pro (12.9-inch) (3rd generation)"
        case "iPad8,9", "iPad8,10":                     return "iPad Pro (11-inch) (2nd generation)"
        case "iPad8,11", "iPad8,12":                    return "iPad Pro (12.9-inch) (4th generation)"
        case "iPad13,4", "iPad13,5", "iPad13,6", "iPad13,7":return "iPad Pro (11-inch) (3rd generation)"
        case "iPad13,8", "iPad13,9", "iPad13,10", "iPad13,11":return "iPad Pro (12.9-inch) (5th generation)"
        case "iPad14,3", "iPad14,4":                    return "iPad Pro (11-inch) (4th generation)"
        case "iPad14,5", "iPad14,6":                    return "iPad Pro (12.9-inch) (6th generation)"
        case "AppleTV5,3":                              return "Apple TV (4th generation)"
        case "AppleTV6,2":                              return "Apple TV 4K"
        case "AppleTV11,1":                             return "Apple TV 4K (2nd generation)"
        case "AppleTV14,1":                             return "Apple TV 4K (3rd generation)"
        case "AudioAccessory1,1":                       return "HomePod"
        case "AudioAccessory5,1":                       return "HomePod mini"
        case "Watch1,1", "Watch1,2":                    return "Apple Watch (1st generation)"
        case "Watch2,6", "Watch2,7":                    return "Apple Watch Series 1"
        case "Watch2,3", "Watch2,4":                    return "Apple Watch Series 2"
        case "Watch3,1", "Watch3,2", "Watch3,3", "Watch3,4":return "Apple Watch Series 3"
        case "Watch4,1", "Watch4,2", "Watch4,3", "Watch4,4":return "Apple Watch Series 4"
        case "Watch5,1", "Watch5,2", "Watch5,3", "Watch5,4":return "Apple Watch Series 5"
        case "Watch5,9", "Watch5,10", "Watch5,11", "Watch5,12":return "Apple Watch SE"
        case "Watch6,1", "Watch6,2", "Watch6,3", "Watch6,4":return "Apple Watch Series 6"
        case "Watch6,6", "Watch6,7", "Watch6,8", "Watch6,9":return "Apple Watch SE (2nd generation)"
        case "Watch6,10", "Watch6,11", "Watch6,12", "Watch6,13":return "Apple Watch Series 7"
        case "Watch6,14", "Watch6,15", "Watch6,16", "Watch6,17":return "Apple Watch Series 8"
        case "Watch6,18":                               return "Apple Watch Ultra"
        case "Watch7,1", "Watch7,2", "Watch7,3", "Watch7,4":return "Apple Watch Series 9"
        case "Watch7,5":                                return "Apple Watch Ultra 2"
        case "AirPods1,1":                              return "AirPods (1st generation)"
        case "AirPods2,1":                              return "AirPods (2nd generation)"
        case "AirPods3,1":                              return "AirPods (3rd generation)"
        case "AirPodsPro1,1":                           return "AirPods Pro (1st generation)"
        case "AirPodsPro2,1":                           return "AirPods Pro (2nd generation)"
        case "AirPodsMax1,1":                           return "AirPods Max"
        case "AudioAccessory2,1":                       return "HomePod" // Older identifier for HomePod
        case "i386", "x86_64", "arm64":                 return "Simulator \(UIDevice.current.model)"
        default:                                        return identifier // Fallback to identifier if not found
        }
    }
}
