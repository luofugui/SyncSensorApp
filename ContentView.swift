//
//  ContentView.swift
//  SyncSensorApp
//
//  Created by Yanxin Luo on 3/26/26.
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var sensorManager: SensorManager
    var body: some View {
        TabView {
            SettingView()
                .tabItem {
                    Image(systemName: "gearshape")
                    Text("Setting")
                }
            MeasurementView()
                .tabItem {
                    Image(systemName: "waveform.path.ecg")
                    Text("Measurement")
                }
            DataView()
                .tabItem {
                    Image(systemName: "tray.full")
                    Text("Data")
                }
        }
        .onAppear {
            // 1. App 加载时主动申请摄像头和麦克风权限
            sensorManager.requestPermissions()
        }
    }
}

// MARK: - SettingView
struct SettingView: View {
    @EnvironmentObject var sensorManager: SensorManager
    @State private var customVideoFrameRateText: String = ""
    @State private var customIMUSampleRateText: String = ""

    var body: some View {
        NavigationView {
            Form {
                // 摄像头选择
                Section(header: Text("Camera Selection")) {
                    Picker("Camera", selection: $sensorManager.useFrontCamera) {
                        Text("Rear").tag(false)
                        Text("Front").tag(true)
                    }
                    .pickerStyle(SegmentedPickerStyle())
                }

                // 视频帧率
                Section(header: Text("Video Frame Rate")) {
                    Picker("Frame Rate", selection: $sensorManager.videoFrameRateOption) {
                        ForEach(SensorManager.VideoFrameRateOption.allCases) { option in
                            Text(option.rawValue).tag(option)
                        }
                    }
                    .pickerStyle(SegmentedPickerStyle())
                    if sensorManager.videoFrameRateOption == .custom {
                        TextField("Custom (Hz)", text: Binding(
                            get: { String(sensorManager.customVideoFrameRate) },
                            set: { val in
                                if let v = Double(val) { sensorManager.customVideoFrameRate = v }
                            })
                        )
                        .keyboardType(.decimalPad)
                    }
                }

                // IMU采样率
                Section(header: Text("IMU Sample Rate")) {
                    Picker("IMU Rate", selection: $sensorManager.imuSampleRateOption) {
                        ForEach(SensorManager.IMUSampleRateOption.allCases) { option in
                            Text(option.rawValue).tag(option)
                        }
                    }
                    .pickerStyle(SegmentedPickerStyle())
                    if sensorManager.imuSampleRateOption == .custom {
                        TextField("Custom (Hz)", text: Binding(
                            get: { String(sensorManager.customIMUSampleRate) },
                            set: { val in
                                if let v = Double(val) { sensorManager.customIMUSampleRate = v }
                            })
                        )
                        .keyboardType(.decimalPad)
                    }
                }
            }
            .navigationTitle("Settings")
        }
    }
}

// MARK: - MeasurementView
import AVFoundation

struct MeasurementView: View {
    @EnvironmentObject var sensorManager: SensorManager
    @State private var audioLevels: [Float] = Array(repeating: 0, count: 50)
    @State private var imuValues: [Double] = Array(repeating: 0, count: 50)
    
    // 闪烁红点动画控制
    @State private var isBlinking: Bool = false

    // 使用定时器以20FPS(0.05秒)拉取并刷新波形，避免主线程被卡死
    let timer = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()

    // 将秒数转为 MM:SS 格式
    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    var body: some View {
        VStack(spacing: 16) {
            // 摄像头画面与录制指示器叠加
            ZStack(alignment: .top) {
                CameraPreview(session: sensorManager.captureSession)
                    .aspectRatio(3.0 / 4.0, contentMode: .fit) // 恢复手机原生镜头的 3:4 标准竖屏比例
                    .cornerRadius(12)
                
                // 录制时的悬浮窗
                if sensorManager.isRecording {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 10, height: 10)
                            .opacity(isBlinking ? 0.2 : 1)
                            .onAppear {
                                withAnimation(Animation.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                                    isBlinking = true
                                }
                            }
                        
                        Text(formatDuration(sensorManager.recordingDuration))
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.black.opacity(0.5))
                    .cornerRadius(8)
                    .padding(.top, 12)
                }
                
                // 倒计时全屏提示
                if sensorManager.isCountingDown {
                    VStack {
                        Spacer()
                        Text("\(sensorManager.countdownValue)")
                            .font(.system(size: 80, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                            .shadow(color: .black.opacity(0.5), radius: 5, x: 0, y: 5)
                        Spacer()
                    }
                }
            }
            .padding(.horizontal)

            // 麦克风波形
            VStack(alignment: .leading) {
                Text("Microphone Waveform")
                    .font(.caption)
                WaveformView(values: audioLevels)
                    .frame(height: 60)
                    .background(Color(.systemGray6))
                    .cornerRadius(8)
            }.padding(.horizontal)

            // IMU波形
            VStack(alignment: .leading) {
                Text("IMU Waveform (Z-Acc)")
                    .font(.caption)
                WaveformView(values: imuValues.map{ Float($0) })
                    .frame(height: 60)
                    .background(Color(.systemGray6))
                    .cornerRadius(8)
            }.padding(.horizontal)

            Spacer()
            
            // 录制/停止 按钮
            Button(action: {
                if sensorManager.isRecording || sensorManager.isCountingDown {
                    sensorManager.stopRecording()
                    isBlinking = false // 重置闪烁状态
                } else {
                    sensorManager.startCountdown() // 改为调用倒计时
                }
            }) {
                ZStack {
                    Circle() // 外圈
                        .stroke((sensorManager.isRecording || sensorManager.isCountingDown) ? Color.red : Color.gray, lineWidth: 3)
                        .frame(width: 68, height: 68)
                    
                    if sensorManager.isRecording || sensorManager.isCountingDown {
                        RoundedRectangle(cornerRadius: 6) // 停止方块
                            .fill(Color.red)
                            .frame(width: 24, height: 24)
                    } else {
                        Circle() // 录制圆点
                            .fill(Color.red)
                            .frame(width: 56, height: 56)
                    }
                }
            }
            .padding(.bottom, 20)
        }
        .onAppear {
            // 如果有权限但session未配置，主动配置
            if sensorManager.hasPermissions && sensorManager.captureSession.inputs.isEmpty {
                sensorManager.setupHardware()
            }
            // 自动启动摄像头画面
            if sensorManager.hasPermissions && !sensorManager.captureSession.isRunning {
                DispatchQueue.global(qos: .userInitiated).async {
                    sensorManager.captureSession.startRunning()
                }
            }
        }
        // 修复 iOS 17 的 onChange 弃用警告
        .onChange(of: sensorManager.hasPermissions) { _, newValue in
            // 监听到权限被授予后，若 session 未运行则启动它
            if newValue && !sensorManager.captureSession.isRunning {
                DispatchQueue.global(qos: .userInitiated).async {
                    sensorManager.captureSession.startRunning()
                }
            }
        }
    }
}

struct WaveformView: View {
    let values: [Float]
    var body: some View {
        GeometryReader { geo in
            // 修正宽度计算，避免加上 HStack 的间距(spacing)后总宽度溢出屏幕
            let spacing: CGFloat = 1
            let totalSpacing = spacing * CGFloat(values.count - 1)
            let width = max(0, (geo.size.width - totalSpacing) / CGFloat(values.count))
            
            HStack(alignment: .center, spacing: spacing) {
                ForEach(0..<values.count, id: \ .self) { i in
                    Capsule()
                        .fill(Color.blue)
                        // 修复：先乘50，再限制最小高度为2。同时增加 min(geo.size.height, ...) 防止用力晃动手机时波形超出容器界限
                        .frame(width: width, height: min(geo.size.height, max(2, CGFloat(abs(values[i])) * 50)))
                }
            }
            .frame(maxHeight: .infinity, alignment: .center) // 确保波形整体垂直居中
        }
    }
}

// MARK: - DataView
struct DataView: View {
    @State private var recordedFiles: [URL] = []
    
    var body: some View {
        NavigationView {
            List {
                if recordedFiles.isEmpty {
                    Text("暂无录制数据，请先前往 Measurement 录制。")
                        .foregroundColor(.gray)
                } else {
                    ForEach(recordedFiles, id: \.self) { fileURL in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(fileURL.lastPathComponent)
                                    .font(.headline)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                
                                Text(getFileSize(url: fileURL))
                                    .font(.caption)
                                    .foregroundColor(.gray)
                            }
                            
                            Spacer()
                            
                            // iOS 16+ 原生分享按钮，支持 AirDrop、保存到文件等
                            ShareLink(item: fileURL) {
                                Image(systemName: "square.and.arrow.up")
                                    .font(.title2)
                                    .foregroundColor(.blue)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .onDelete(perform: deleteFiles) // 支持左滑删除
                }
            }
            .navigationTitle("Data Records")
            .onAppear {
                loadFiles() // 每次切换到 Data Tab 时刷新文件列表
            }
        }
    }
    
    // MARK: - 文件管理逻辑
    
    // 1. 读取沙盒 Documents 目录下的文件
    private func loadFiles() {
        guard let documentDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        do {
            let files = try FileManager.default.contentsOfDirectory(at: documentDirectory, includingPropertiesForKeys: [.creationDateKey], options: .skipsHiddenFiles)
            
            // 过滤 mp4 和 csv，并按时间倒序排列（最新的在最上面）
            recordedFiles = files.filter { $0.pathExtension == "mp4" || $0.pathExtension == "csv" }
                .sorted { u1, u2 in
                    let date1 = (try? u1.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date.distantPast
                    let date2 = (try? u2.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date.distantPast
                    return date1 > date2
                }
        } catch {
            print("加载文件失败: \(error)")
        }
    }
    
    // 2. 删除文件
    private func deleteFiles(at offsets: IndexSet) {
        for index in offsets {
            let fileURL = recordedFiles[index]
            do {
                try FileManager.default.removeItem(at: fileURL)
            } catch {
                print("删除文件失败: \(error)")
            }
        }
        recordedFiles.remove(atOffsets: offsets)
    }
    
    // 3. 获取文件大小并格式化为 KB/MB
    private func getFileSize(url: URL) -> String {
        do {
            let resources = try url.resourceValues(forKeys: [.fileSizeKey])
            if let fileSize = resources.fileSize {
                let formatter = ByteCountFormatter()
                formatter.allowedUnits = [.useMB, .useKB]
                formatter.countStyle = .file
                return formatter.string(fromByteCount: Int64(fileSize))
            }
        } catch {
            print("获取文件大小失败: \(error)")
        }
        return "未知大小"
    }
}
