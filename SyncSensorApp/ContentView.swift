//
//  ContentView.swift
//  SyncSensorApp
//
//  Created by Yanxin Luo on 3/26/26.
//

import SwiftUI

import UniformTypeIdentifiers

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
    @State private var audioLevels: [Float] = Array(repeating: 0, count: 80)
    @State private var imuXRaw: [Double] = Array(repeating: 0, count: 80)
    @State private var imuYRaw: [Double] = Array(repeating: 0, count: 80)
    @State private var imuZRaw: [Double] = Array(repeating: 0, count: 80)
    // MARK: 延迟补偿后的IMU数据
    private var imuDelayFrames: Int { 0 } // 0.05s*4=0.2s，实际可调
    private var imuX: [Double] { Array(imuXRaw.dropFirst(imuDelayFrames)) + Array(repeating: 0, count: imuDelayFrames) }
    private var imuY: [Double] { Array(imuYRaw.dropFirst(imuDelayFrames)) + Array(repeating: 0, count: imuDelayFrames) }
    private var imuZ: [Double] { Array(imuZRaw.dropFirst(imuDelayFrames)) + Array(repeating: 0, count: imuDelayFrames) }

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
                    .aspectRatio(3.0 / 4.0, contentMode: .fit) 
                    .cornerRadius(12)
                
                // 🌟 新增：3秒全屏倒计时 UI
                if sensorManager.isWarmingUp {
                    Text("\(sensorManager.countdown)")
                        .font(.system(size: 120, weight: .black, design: .rounded))
                        .foregroundColor(.white)
                        .shadow(color: .black, radius: 10, x: 0, y: 5)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                        .background(Color.black.opacity(0.3)) // 加一层半透明黑色遮罩
                        .cornerRadius(12)
                }
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
                    .padding(.horizontal, 8) // 让波形更宽
            }

            // IMU三轴折线图
            VStack(alignment: .leading) {
                HStack {
                    Text("IMU Waveform (XYZ)")
                        .font(.caption)
                    Spacer()
                    HStack(spacing: 12) {
                        HStack(spacing: 4) {
                            Circle().fill(Color.red).frame(width: 8, height: 8)
                            Text("X").font(.caption2).foregroundColor(.secondary)
                        }
                        HStack(spacing: 4) {
                            Circle().fill(Color.green).frame(width: 8, height: 8)
                            Text("Y").font(.caption2).foregroundColor(.secondary)
                        }
                        HStack(spacing: 4) {
                            Circle().fill(Color.blue).frame(width: 8, height: 8)
                            Text("Z").font(.caption2).foregroundColor(.secondary)
                        }
                    }
                }
                IMULineChartView(x: imuX, y: imuY, z: imuZ)
                    .frame(height: 80)
                    .background(Color(.systemGray6))
                    .cornerRadius(8)
            }.padding(.horizontal)

            Spacer()
            
            // 录制/停止 按钮
            Button(action: {
                if sensorManager.isRecording {
                    sensorManager.stopRecording()
                    isBlinking = false // 重置闪烁状态
                } else {
                    sensorManager.startRecording()
                }
            }) {
                ZStack {
                    Circle() // 外圈
                        .stroke(sensorManager.isRecording ? Color.red : Color.gray, lineWidth: 3)
                        .frame(width: 68, height: 68)
                    
                    if sensorManager.isRecording {
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
        .onReceive(timer) { _ in
            // 采样音频电平
            audioLevels.append(sensorManager.currentAudioLevel)
            if audioLevels.count > 80 { audioLevels.removeFirst() }
            // 采样IMU三轴（原始）
            imuXRaw.append(sensorManager.currentIMUAcceleration.x)
            if imuXRaw.count > 80 { imuXRaw.removeFirst() }
            imuYRaw.append(sensorManager.currentIMUAcceleration.y)
            if imuYRaw.count > 80 { imuYRaw.removeFirst() }
            imuZRaw.append(sensorManager.currentIMUAcceleration.z)
            if imuZRaw.count > 80 { imuZRaw.removeFirst() }
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
            let spacing: CGFloat = 0.5 // 更细的间隔
            let totalSpacing = spacing * CGFloat(values.count - 1)
            let width = max(1, (geo.size.width - totalSpacing) / CGFloat(values.count))
            HStack(alignment: .center, spacing: spacing) {
                ForEach(0..<values.count, id: \ .self) { i in
                    Capsule()
                        .fill(Color.accentColor) // 使用主题色，更美观
                        .frame(width: width, height: max(1, CGFloat(values[i]) * geo.size.height))
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
    }
}

// IMU三轴折线图
struct IMULineChartView: View {
    let x: [Double]
    let y: [Double]
    let z: [Double]

    private func points(_ arr: [Double], w: CGFloat, h: CGFloat, maxAbs: Double) -> [CGPoint] {
        let count = arr.count
        guard count > 1 else { return [] }
        return (0..<count).map { i in
            let px = CGFloat(i) / CGFloat(count-1) * w
            return CGPoint(x: px, y: h/2 - CGFloat(arr[i]) / CGFloat(maxAbs) * h/2)
        }
    }

    var body: some View {
        GeometryReader { geo in
            let count = min(x.count, y.count, z.count)
            let w = geo.size.width
            let h = geo.size.height
            let maxX = x.map{abs($0)}.max() ?? 1
            let maxY = y.map{abs($0)}.max() ?? 1
            let maxZ = z.map{abs($0)}.max() ?? 1
            let maxAbs = max(maxX, maxY, maxZ, 1)
            let px = points(Array(x.suffix(count)), w: w, h: h, maxAbs: maxAbs)
            let py = points(Array(y.suffix(count)), w: w, h: h, maxAbs: maxAbs)
            let pz = points(Array(z.suffix(count)), w: w, h: h, maxAbs: maxAbs)
            ZStack {
                if px.count > 1 {
                    Path { path in
                        path.move(to: px[0])
                        for p in px { path.addLine(to: p) }
                    }.stroke(Color.red, lineWidth: 2)
                }
                if py.count > 1 {
                    Path { path in
                        path.move(to: py[0])
                        for p in py { path.addLine(to: p) }
                    }.stroke(Color.green, lineWidth: 2)
                }
                if pz.count > 1 {
                    Path { path in
                        path.move(to: pz[0])
                        for p in pz { path.addLine(to: p) }
                    }.stroke(Color.blue, lineWidth: 2)
                }
            }
        }
    }
}

// MARK: - DataView

// 定义自定义分享包装器：在点击分享时，瞬间将选中的 Block 文件夹压缩为 .zip
struct ZipDirectory: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .zip) { zipDir in
            let coordinator = NSFileCoordinator()
            var zippedURL: URL!
            var error: NSError?
            coordinator.coordinate(readingItemAt: zipDir.url, options: .forUploading, error: &error) { tempURL in
                let destination = FileManager.default.temporaryDirectory.appendingPathComponent(zipDir.url.lastPathComponent + ".zip")
                try? FileManager.default.removeItem(at: destination)
                try? FileManager.default.copyItem(at: tempURL, to: destination)
                zippedURL = destination
            }
            return SentTransferredFile(zippedURL)
        }
    }
}

struct DataView: View {
    @EnvironmentObject var sensorManager: SensorManager
    @State private var recordedFiles: [URL] = []
    @State private var itemToRename: URL?
    @State private var newName: String = ""
    @State private var showingRenameAlert = false

    @StateObject private var zipManager = ZipManager()
    @State private var zipBlockURL: URL? = nil
    @State private var showZipProgress = false
    @State private var zipProgress: Double = 0
    @State private var zipResultURL: URL? = nil
    @State private var showShareSheet = false
    @State private var showZipError = false

    var body: some View {
        NavigationView {
            List {
                if recordedFiles.isEmpty {
                    Text("暂无录制数据，请先前往 Measurement 录制。")
                        .foregroundColor(.gray)
                } else {
                    ForEach(recordedFiles, id: \.self) { fileURL in
                        HStack {
                            NavigationLink(destination: BlockDetailView(blockURL: fileURL).environmentObject(sensorManager)) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(fileURL.lastPathComponent)
                                        .font(.headline)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Text(getDirectorySize(url: fileURL))
                                        .font(.caption)
                                        .foregroundColor(.gray)
                                }
                            }
                            Spacer()
                            Button {
                                zipBlockURL = fileURL
                                showZipProgress = true
                                zipProgress = 0
                                zipResultURL = nil
                                showShareSheet = false
                                showZipError = false
                                zipManager.zipBlock(blockURL: fileURL) { url in
                                    DispatchQueue.main.async {
                                        zipResultURL = url
                                        showZipProgress = false
                                        if url != nil {
                                            showShareSheet = true
                                        } else {
                                            showZipError = true
                                        }
                                    }
                                }
                            } label: {
                                Image(systemName: "archivebox")
                                    .font(.title2)
                                    .foregroundColor(.blue)
                            }
                            .buttonStyle(PlainButtonStyle()) // 允许多个按钮在同一行
                        }
                        .padding(.vertical, 4)
                        .swipeActions(edge: .leading) {
                            Button {
                                itemToRename = fileURL
                                newName = fileURL.lastPathComponent
                                showingRenameAlert = true
                            } label: {
                                Label("Rename", systemImage: "pencil")
                            }.tint(.blue)
                        }
                    }
                    .onDelete(perform: deleteFiles)
                }
            }
            .navigationTitle("Data Records")
            .onAppear {
                loadFiles()
            }
            .alert("Rename Block", isPresented: $showingRenameAlert) {
                TextField("New Name", text: $newName)
                Button("Save", action: renameItem)
                Button("Cancel", role: .cancel) { }
            }
            // 打包进度弹窗
            .sheet(isPresented: $showZipProgress) {
                VStack(spacing: 20) {
                    Text("正在打包为ZIP...")
                    ProgressView(value: zipManager.progressDict[zipBlockURL ?? URL(fileURLWithPath:"")]?.progress ?? 0)
                        .progressViewStyle(LinearProgressViewStyle())
                        .frame(width: 200)
                    Button("取消") {
                        showZipProgress = false
                    }
                }
                .padding()
            }
            // 打包完成后弹窗询问是否分享
            .alert("ZIP已生成，是否分享？", isPresented: $showShareSheet, actions: {
                if let url = zipResultURL {
                    Button("分享") {
                        shareZip(url: url)
                    }
                }
                Button("关闭", role: .cancel) {}
            }, message: {
                if let url = zipResultURL {
                    Text(url.lastPathComponent)
                }
            })
            // 打包失败弹窗
            .alert("打包失败", isPresented: $showZipError) {}
        }
    }

    // 分享zip
    func shareZip(url: URL) {
        let av = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let root = windowScene.windows.first?.rootViewController {
            root.present(av, animated: true)
        }
    }
    
    // MARK: - 文件管理逻辑
    
        // 1. 读取沙盒 Documents 目录下的文件夹 Block
        private func loadFiles() {
            guard let documentDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
            do {
                let files = try FileManager.default.contentsOfDirectory(at: documentDirectory, includingPropertiesForKeys: [.creationDateKey, .isDirectoryKey], options: .skipsHiddenFiles)
                recordedFiles = files.filter { url in
                    var isDir: ObjCBool = false
                    FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
                    return isDir.boolValue
                }
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
    
    // 3. 重命名 Block
    private func renameItem() {
        guard let oldURL = itemToRename, !newName.isEmpty else { return }
        let newURL = oldURL.deletingLastPathComponent().appendingPathComponent(newName)
        do {
            try FileManager.default.moveItem(at: oldURL, to: newURL)
            loadFiles()
        } catch {
            print("重命名失败: \(error)")
        }
    }
    
    // 4. 递归计算整个 Block 文件夹的体积并格式化
    private func getDirectorySize(url: URL) -> String {
        var size: Int64 = 0
        if let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let fileURL as URL in enumerator {
                if let fileSize = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize { size += Int64(fileSize) }
            }
            let formatter = ByteCountFormatter()
            formatter.allowedUnits = [.useMB, .useKB, .useGB]
            formatter.countStyle = .file
            return formatter.string(fromByteCount: size)
        }
        return "未知大小"
    }
}

// MARK: - BlockDetailView

struct BlockDetailView: View {
    let blockURL: URL
    @EnvironmentObject var sensorManager: SensorManager // Add this
    @State private var files: [URL] = []

    var body: some View {
        List {
            if files.isEmpty {
                Text("This directory is empty.")
                    .foregroundColor(.gray)
            } else {
                ForEach(files, id: \.self) { fileURL in
                        if isDirectory(url: fileURL) {
                            NavigationLink(destination: BlockDetailView(blockURL: fileURL).environmentObject(sensorManager)) {
                                FileRow(fileURL: fileURL, refreshAction: loadContents).environmentObject(sensorManager)
                            }
                        } else if isMP4(url: fileURL) {
                            NavigationLink(destination: VideoPlayerView(videoURL: fileURL)) {
                                FileRow(fileURL: fileURL, refreshAction: loadContents).environmentObject(sensorManager)
                            }
                        } else if isCSV(url: fileURL) {
                            NavigationLink(destination: CSVPreviewView(fileURL: fileURL).environmentObject(sensorManager)) {
                                FileRow(fileURL: fileURL, refreshAction: loadContents).environmentObject(sensorManager)
                            }
                        } else {
                            FileRow(fileURL: fileURL, refreshAction: loadContents).environmentObject(sensorManager)
                        }
                }
            }
        }
        .navigationTitle(blockURL.lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: loadContents)
    }

    private func isDirectory(url: URL) -> Bool {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        return isDir.boolValue
    }

    private func isCSV(url: URL) -> Bool {
        return url.pathExtension.lowercased() == "csv"
    }

    private func isMP4(url: URL) -> Bool {
        return url.pathExtension.lowercased() == "mp4"
    }


    private func loadContents() {
        do {
            let contents = try FileManager.default.contentsOfDirectory(at: blockURL, includingPropertiesForKeys: [.creationDateKey, .isDirectoryKey], options: .skipsHiddenFiles)
            
            files = contents.sorted { u1, u2 in
                var isDir1: ObjCBool = false
                var isDir2: ObjCBool = false
                FileManager.default.fileExists(atPath: u1.path, isDirectory: &isDir1)
                FileManager.default.fileExists(atPath: u2.path, isDirectory: &isDir2)

                if isDir1.boolValue != isDir2.boolValue {
                    return isDir1.boolValue // 文件夹优先
                }
                return u1.lastPathComponent.localizedStandardCompare(u2.lastPathComponent) == .orderedAscending
            }
        } catch {
            print("Failed to load contents of \(blockURL.path): \(error)")
        }
    }
}

struct FileRow: View {
    @EnvironmentObject var sensorManager: SensorManager
    let fileURL: URL
    let refreshAction: () -> Void // Add this closure
    @State var isExtractingAudio: Bool = false
    @State var showExtractionAlert: Bool = false
    @State var extractionMessage: String = ""
    var body: some View {
        HStack {
            Image(systemName: isDirectory() ? "folder.fill" : "doc")
                .foregroundColor(isDirectory() ? .accentColor : .secondary)
            Text(fileURL.lastPathComponent)
            Spacer()
            if isMP4() {
                if isExtractingAudio {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle())
                } else {
                    Button(action: {
                        Task {
                            isExtractingAudio = true
                            do {
                                let audioURL = try await sensorManager.extractAudioFromVideo(videoURL: fileURL)
                                await MainActor.run {
                                    extractionMessage = "音频已成功提取到:\n\(audioURL.lastPathComponent)"
                                    refreshAction()
                                }
                            } catch {
                                await MainActor.run {
                                    extractionMessage = "音频提取失败:\n\(error.localizedDescription)"
                                }
                            }
                            await MainActor.run {
                                isExtractingAudio = false
                                showExtractionAlert = true
                            }
                        }
                    }) {
                        Image(systemName: "waveform.badge.plus")
                            .foregroundColor(.blue)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .alert("音频提取", isPresented: $showExtractionAlert) {
                        Button("OK") { }
                    } message: {
                        Text(extractionMessage)
                    }
                }
            } else if !isDirectory() { // Show file size for other non-directory files
                Text(getFileSize(url: fileURL))
                    .font(.caption)
                    .foregroundColor(.gray)
            }
        }
    }

    private func isMP4() -> Bool {
        return fileURL.pathExtension.lowercased() == "mp4"
    }

    private func isDirectory() -> Bool {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDir)
        return isDir.boolValue
    }

    private func getFileSize(url: URL) -> String {
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            return formatter.string(fromByteCount: Int64(size))
        }
        return "..."
    }
}

// MARK: - VideoPlayerView
import AVKit

struct VideoPlayerView: View {
    let videoURL: URL
    @State private var player: AVPlayer?

    var body: some View {
        VStack {
            if let player = player {
                VideoPlayer(player: player)
                    .onAppear {
                        player.play()
                    }
                    .onDisappear {
                        player.pause()
                    }
            } else {
                Text("无法加载视频")
                    .foregroundColor(.gray)
            }
        }
        .navigationTitle(videoURL.lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            player = AVPlayer(url: videoURL)
        }
    }
}

// MARK: - CSVPreviewView

struct CSVPreviewView: View {
    let fileURL: URL
    @State private var header: [String] = [] // Store header separately
    @State private var rows: [CSVRow] = [] // Store rows as CSVRow objects
    @State private var isLoading: Bool = true
    @State private var errorMessage: String?
    
    private let maxRowsToDisplay = 20 // 显示表头 + 19行数据

    var body: some View {
        VStack {
            if isLoading {
                ProgressView("加载中...")
            } else if let errorMessage = errorMessage {
                Text(errorMessage)
                    .foregroundColor(.red)
                    .padding()
            } else if rows.isEmpty {
                Text("文件内容为空或无法解析。")
                    .foregroundColor(.gray)
                    .padding()
            } else {
                // 使用 ScrollView + LazyVStack 构建高可靠性的数据网格
                ScrollView(.horizontal) {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        // 表头
                        HStack(spacing: 16) {
                            ForEach(0..<header.count, id: \.self) { index in
                                Text(header[index])
                                    .font(.system(.caption, design: .monospaced).bold())
                                    .frame(width: 80, alignment: .leading)
                            }
                        }
                        Divider()
                        // 数据行
                        ForEach(rows) { row in
                            HStack(spacing: 16) {
                                ForEach(0..<header.count, id: \.self) { index in
                                    Text(row.columns.indices.contains(index) ? row.columns[index] : "")
                                        .font(.system(.caption, design: .monospaced))
                                        .lineLimit(1)
                                        .frame(width: 80, alignment: .leading)
                                }
                            }
                        }
                    }
                    .padding()
                }
                
                if rows.count >= maxRowsToDisplay {
                    Text("仅显示前 \(maxRowsToDisplay) 行数据，完整内容请导出查看。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.top, 5)
                }
            }
        }
        .navigationTitle(fileURL.lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: loadContent)
    }

    // 辅助结构体，用于 Table 的 Identifiable 行
    struct CSVRow: Identifiable {
        let id = UUID()
        let columns: [String]
    }

    private func loadContent() {
        isLoading = true
        errorMessage = nil
        header = []
        rows = []

        // Perform file loading on a background thread
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let rawContent = try String(contentsOf: fileURL, encoding: .utf8)
                let lines = rawContent.split(separator: "\n", omittingEmptySubsequences: true)
                
                guard !lines.isEmpty else {
                    DispatchQueue.main.async {
                        self.errorMessage = "文件为空。"
                        self.isLoading = false
                    }
                    return
                }
                
                // 解析表头 (第一行)
                let parsedHeader = lines[0].split(separator: "\t").map(String.init)
                
                // 解析数据行，限制数量 (maxRowsToDisplay + 1 to include the header in the count for min)
                var parsedRows: [CSVRow] = []
                for i in 1..<min(lines.count, self.maxRowsToDisplay + 1) {
                    let columns = lines[i].split(separator: "\t").map(String.init)
                    // 确保每行数据列数与表头一致，避免 Table 崩溃
                    if columns.count == parsedHeader.count {
                        parsedRows.append(CSVRow(columns: columns))
                    } else {
                        print("Warning: CSV row \(i+1) has \(columns.count) columns, expected \(parsedHeader.count). Skipping.")
                    }
                }
                
                DispatchQueue.main.async {
                    self.header = parsedHeader
                    self.rows = parsedRows
                    self.isLoading = false
                }
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = "加载文件内容失败:\n\(error.localizedDescription)"
                    self.isLoading = false
                }
            }
        }
    }
}
