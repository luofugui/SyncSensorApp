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

class SensorManager: NSObject, ObservableObject {
    // 录制状态
    @Published var isRecording = false
    @Published var hasPermissions = false
    
    // 录制时长跟踪
    @Published var recordingDuration: TimeInterval = 0.0
    private var recordingTimer: Timer?
    
    // 移除 @Published，防止高频(100Hz)数据更新导致 SwiftUI 界面全局疯狂重绘而卡死
    var currentAudioLevel: Float = 0.0
    var currentIMUAcceleration: (x: Double, y: Double, z: Double) = (0.0, 0.0, 0.0)

    // 设置项
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

    // 1. 硬件管理器
    let captureSession = AVCaptureSession()
    private let motionManager = CMMotionManager()

    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()

    // 2. 独立的数据处理队列（防止阻塞主线程）
    private let videoQueue = DispatchQueue(label: "com.jeffluo.videoQueue", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "com.jeffluo.audioQueue", qos: .userInteractive)
    private let imuQueue = OperationQueue()

    override init() {
        super.init()
        imuQueue.qualityOfService = .userInteractive
    }

    // 视频帧率选项
    enum VideoFrameRateOption: String, CaseIterable, Identifiable {
        case max = "最大"
        case s1 = "1s"
        case s10 = "10s"
        case custom = "自定义"
        var id: String { self.rawValue }
    }

    // IMU采样率选项
    enum IMUSampleRateOption: String, CaseIterable, Identifiable {
        case hz100 = "100Hz"
        case hz20 = "20Hz"
        case custom = "自定义"
        var id: String { self.rawValue }
    }
    
    // MARK: - 权限申请
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
    
    // MARK: - 硬件初始化
    func setupHardware() {
        captureSession.beginConfiguration()
        
        // --- 视频配置 ---
        let position: AVCaptureDevice.Position = useFrontCamera ? .front : .back
        guard let videoDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
              let videoInput = try? AVCaptureDeviceInput(device: videoDevice) else { return }
        if captureSession.canAddInput(videoInput) { captureSession.addInput(videoInput) }
        
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        videoOutput.alwaysDiscardsLateVideoFrames = true
        if captureSession.canAddOutput(videoOutput) { captureSession.addOutput(videoOutput) }
        
        // --- 音频配置 ---
        guard let audioDevice = AVCaptureDevice.default(for: .audio),
              let audioInput = try? AVCaptureDeviceInput(device: audioDevice) else { return }
        if captureSession.canAddInput(audioInput) { captureSession.addInput(audioInput) }
        
        audioOutput.setSampleBufferDelegate(self, queue: audioQueue)
        if captureSession.canAddOutput(audioOutput) { captureSession.addOutput(audioOutput) }
        
        captureSession.commitConfiguration()
        
        updateVideoFrameRate()
        
        // --- IMU 配置 ---
        if motionManager.isDeviceMotionAvailable {
            updateIMUSampleRate()
            
            // 提前启动 IMU 数据流以供 UI 实时预览
            motionManager.startDeviceMotionUpdates(to: imuQueue) { [weak self] (motion, error) in
                guard let self = self, let motion = motion else { return }
                
                // 纯后台线程更新数据，彻底放过主线程
                self.currentIMUAcceleration = (motion.userAcceleration.x, motion.userAcceleration.y, motion.userAcceleration.z)
                
                if self.isRecording {
                    let imuTime = motion.timestamp
                    print("[\(String(format: "%.5f", imuTime))] 📳 IMU Acc: X:\(String(format: "%.3f", motion.userAcceleration.x)) Y:\(String(format: "%.3f", motion.userAcceleration.y)) Z:\(String(format: "%.3f", motion.userAcceleration.z))")
                }
            }
        }
    }
    
    // MARK: - 切换摄像头
    func switchCamera() {
        // 切换硬件放在后台线程执行，防止 Picker 切换时界面卡顿
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            self.captureSession.beginConfiguration()
            
            // 1. 找到并移除现有的视频输入
            let currentVideoInputs = self.captureSession.inputs.compactMap { $0 as? AVCaptureDeviceInput }.filter { $0.device.hasMediaType(.video) }
            for input in currentVideoInputs {
                self.captureSession.removeInput(input)
            }
            
            // 2. 根据最新设置添加新的视频输入
            let position: AVCaptureDevice.Position = self.useFrontCamera ? .front : .back
            guard let videoDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
                  let videoInput = try? AVCaptureDeviceInput(device: videoDevice) else {
                self.captureSession.commitConfiguration()
                return
            }
            
            if self.captureSession.canAddInput(videoInput) { self.captureSession.addInput(videoInput) }
            
            self.captureSession.commitConfiguration()
            
            // 切换镜头后，重新应用当前的帧率设置
            self.updateVideoFrameRate()
        }
    }
    
    // MARK: - 动态更新硬件频率
    func updateVideoFrameRate() {
        // 1. 找到当前正在使用的视频设备
        guard let videoInput = captureSession.inputs.compactMap({ $0 as? AVCaptureDeviceInput }).first(where: { $0.device.hasMediaType(.video) }) else { return }
        let videoDevice = videoInput.device
        
        var targetFPS: Double
        switch videoFrameRateOption {
        case .max: targetFPS = 60.0 // 设为 60 会在下方逻辑中自动限制回当前格式支持的最大值
        case .s1: targetFPS = 1.0
        case .s10: targetFPS = 0.1 // 10秒1帧
        case .custom: targetFPS = customVideoFrameRate > 0 ? customVideoFrameRate : 30.0
        }
        
        do {
            try videoDevice.lockForConfiguration()
            
            // 2. 核心安全机制：获取摄像头当前格式支持的帧率范围。如果强行设置不支持的帧率（比如 0.1 FPS）会导致 App 崩溃
            let ranges = videoDevice.activeFormat.videoSupportedFrameRateRanges
            guard let minAllowed = ranges.min(by: { $0.minFrameRate < $1.minFrameRate })?.minFrameRate,
                  let maxAllowed = ranges.max(by: { $0.maxFrameRate < $1.maxFrameRate })?.maxFrameRate else {
                videoDevice.unlockForConfiguration()
                return
            }
            
            // 3. 将目标帧率钳制在允许的范围内
            let clampedFPS = max(minAllowed, min(maxAllowed, targetFPS))
            let frameDuration = CMTime(seconds: 1.0 / clampedFPS, preferredTimescale: 600)
            
            videoDevice.activeVideoMinFrameDuration = frameDuration
            videoDevice.activeVideoMaxFrameDuration = frameDuration
            
            videoDevice.unlockForConfiguration()
            print("📷 视频帧率已生效: \(String(format: "%.1f", clampedFPS)) FPS")
        } catch {
            print("📷 设置帧率失败: \(error)")
        }
    }
    
    func updateIMUSampleRate() {
        guard motionManager.isDeviceMotionAvailable else { return }
        let targetHz: Double = (imuSampleRateOption == .hz100) ? 100.0 : ((imuSampleRateOption == .hz20) ? 20.0 : (customIMUSampleRate > 0 ? customIMUSampleRate : 100.0))
        motionManager.deviceMotionUpdateInterval = 1.0 / targetHz
        print("📳 IMU 采样率已生效: \(targetHz) Hz")
    }
    
    // MARK: - 录制控制
    func startRecording() {
        guard hasPermissions else { return }
        
        DispatchQueue.main.async {
            self.isRecording = true
            self.recordingDuration = 0.0
            self.recordingTimer?.invalidate()
            
            // 录制秒表：使用 scheduledTimer 并加入 .common 模式（秒表需要长时间累加防漂移，Timer 更适合）
            let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                self?.recordingDuration += 1.0
            }
            RunLoop.main.add(timer, forMode: .common)
            self.recordingTimer = timer
        }
        print("====== 🚀 开始录制 (纳秒级时间戳同步测试) ======")
        
        // 1. 启动音视频流
        DispatchQueue.global(qos: .userInitiated).async {
            self.captureSession.startRunning()
        }
    }
    
    func stopRecording() {
        DispatchQueue.main.async {
            self.isRecording = false
            self.recordingTimer?.invalidate()
            self.recordingTimer = nil
        }
        // 注释掉停止代码：保证停止录制后，画面和波形依然可以实时预览
        // captureSession.stopRunning()
        // motionManager.stopDeviceMotionUpdates()
        print("====== 🛑 停止录制 ======")
    }
}

// MARK: - 音视频帧底层回调
extension SensorManager: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        
        // --- 1. UI 数据实时更新（非录制状态也需要） ---
        if output == audioOutput, let channel = connection.audioChannels.first {
            let power = channel.averagePowerLevel // 范围大约在 -120dB 到 0dB 之间
            let level = max(0.0, min(1.0, (power + 50) / 50)) // 映射 -50~0dB 为 0.0~1.0 供波形显示
            // 纯后台线程更新数据，彻底放过主线程
            self.currentAudioLevel = level
        }
        
        // --- 2. 录制状态下才打印/保存数据 ---
        guard isRecording else { return }
        
        // 提取硬件层面的绝对呈现时间 (Presentation Timestamp)
        // 这个时间戳与 IMU 的 timestamp 共享同一个底层硬件时钟！
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let timestampInSeconds = CMTimeGetSeconds(pts)
        
        if output == videoOutput {
            print("[\(String(format: "%.5f", timestampInSeconds))] 📷 视频帧")
        } else if output == audioOutput {
            print("[\(String(format: "%.5f", timestampInSeconds))] 🎙️ 音频采样")
        }
    }
}
