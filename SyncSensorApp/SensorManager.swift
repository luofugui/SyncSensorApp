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
        
        // =========================================================
        // 核心拦截闸门 (Data Gate)：丢弃预热期的脏数据
        // =========================================================
        if let target = targetStartTime, timestampInSeconds < target {
            // 时间还没到 3 秒！说明底层的相机和麦克风还在疯狂初始化。
            // 此时的数据充满延迟和抖动，我们直接 return，把它无情扔掉！
            return
        }
        // =========================================================
        
        // --- 首次冲过闸门的数据！它将决定整个宇宙的绝对起跑时间 (T0) ---
        timestampLock.lock()
        if self.firstTimestamp == nil {
            self.firstTimestamp = timestampInSeconds
            print("[音视频流] 预热结束！首帧冲过闸门，绝对起跑时间：\(String(format: "%.5f", timestampInSeconds))")
        }
        timestampLock.unlock()
        
        // --- 写入音视频流 (MP4) ---
        guard let writer = assetWriter, writer.status == .writing else { return }
        
        // 首次有效数据帧抵达时，用它的真实物理时间戳(pts)作为 MP4 的起始时间！
        if !hasStartedAudioSession {
            writer.startSession(atSourceTime: pts)
            hasStartedAudioSession = true
            print("🎬 MP4 容器正式在此时刻开启写入！")
        }
        
        // 将视频帧和音频帧分别喂给对应的写入器输入
        if output == videoOutput, let input = videoWriterInput, input.isReadyForMoreMediaData {
            input.append(sampleBuffer)
        } else if output == audioOutput, let input = audioWriterInput, input.isReadyForMoreMediaData {
            input.append(sampleBuffer)
        }
    }
    
    // 供 IMU 回调使用，安全写入文件
    func writeIMU(_ motion: CMDeviceMotion, timestamp: Double) {
        let elapsed = timestamp - (firstTimestamp ?? timestamp) // seconds_elapsed 保持不变
        let timeStr = String(format: "%.5f", timestamp)
        let elapsedStr = String(format: "%.5f", elapsed)
        try? accFile?.write(contentsOf: Data("\(timeStr)\t\(elapsedStr)\t\(motion.userAcceleration.z)\t\(motion.userAcceleration.y)\t\(motion.userAcceleration.x)\n".utf8))
        try? gravFile?.write(contentsOf: Data("\(timeStr)\t\(elapsedStr)\t\(motion.gravity.z)\t\(motion.gravity.y)\t\(motion.gravity.x)\n".utf8))
        try? gyroFile?.write(contentsOf: Data("\(timeStr)\t\(elapsedStr)\t\(motion.rotationRate.z)\t\(motion.rotationRate.y)\t\(motion.rotationRate.x)\n".utf8))
        try? oriFile?.write(contentsOf: Data("\(timeStr)\t\(elapsedStr)\t\(motion.attitude.yaw)\t\(motion.attitude.pitch)\t\(motion.attitude.roll)\n".utf8))
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
