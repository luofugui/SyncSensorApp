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
            // 1. Proactively request camera and microphone permissions when the App loads
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
                // Camera selection
                Section(header: Text("Camera Selection")) {
                    Picker("Camera", selection: $sensorManager.useFrontCamera) {
                        Text("Rear").tag(false)
                        Text("Front").tag(true)
                    }
                    .pickerStyle(SegmentedPickerStyle())
                }

                // Video frame rate
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

                // IMU sample rate
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
    // MARK: IMU data after delay compensation
    private var imuDelayFrames: Int { 0 } // 0.05s*4=0.2s, adjustable in practice
    private var imuX: [Double] { Array(imuXRaw.dropFirst(imuDelayFrames)) + Array(repeating: 0, count: imuDelayFrames) }
    private var imuY: [Double] { Array(imuYRaw.dropFirst(imuDelayFrames)) + Array(repeating: 0, count: imuDelayFrames) }
    private var imuZ: [Double] { Array(imuZRaw.dropFirst(imuDelayFrames)) + Array(repeating: 0, count: imuDelayFrames) }

    // Blinking red dot animation control
    @State private var isBlinking: Bool = false

    // Use a timer to fetch and refresh the waveform at 20FPS (0.05 seconds) to avoid freezing the main thread
    let timer = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()

    // Convert seconds to MM:SS format
    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    var body: some View {
        VStack(spacing: 16) {
            // Camera preview overlaid with recording indicators
            ZStack(alignment: .top) {
                CameraPreview(session: sensorManager.captureSession)
                    .aspectRatio(3.0 / 4.0, contentMode: .fit) 
                    .cornerRadius(12)
                
                // 🌟 Added: 3-second full-screen countdown UI
                if sensorManager.isWarmingUp {
                    Text("\(sensorManager.countdown)")
                        .font(.system(size: 120, weight: .black, design: .rounded))
                        .foregroundColor(.white)
                        .shadow(color: .black, radius: 10, x: 0, y: 5)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                        .background(Color.black.opacity(0.3)) // Add a semi-transparent black overlay
                        .cornerRadius(12)
                }
                // Floating window during recording
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

            // Microphone waveform
            VStack(alignment: .leading) {
                Text("Microphone Waveform")
                    .font(.caption)
                WaveformView(values: audioLevels)
                    .frame(height: 60)
                    .background(Color(.systemGray6))
                    .cornerRadius(8)
                    .padding(.horizontal, 8) // Make waveform wider
            }

            // IMU 3-axis line chart
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
            
            // Record/Stop button
            Button(action: {
                if sensorManager.isRecording {
                    sensorManager.stopRecording()
                    isBlinking = false // 重置闪烁状态
                } else {
                    sensorManager.startRecording()
                }
            }) {
                ZStack {
                    Circle() // Outer circle
                        .stroke(sensorManager.isRecording ? Color.red : Color.gray, lineWidth: 3)
                        .frame(width: 68, height: 68)
                    
                    if sensorManager.isRecording {
                        RoundedRectangle(cornerRadius: 6) // Stop square
                            .fill(Color.red)
                            .frame(width: 24, height: 24)
                    } else {
                        Circle() // Record dot
                            .fill(Color.red)
                            .frame(width: 56, height: 56)
                    }
                }
            }
            .padding(.bottom, 20)
        }
        .onAppear {
            // Actively configure if permissions are granted but session is not configured
            if sensorManager.hasPermissions && sensorManager.captureSession.inputs.isEmpty {
                sensorManager.setupHardware()
            }
            // Automatically start the camera preview
            if sensorManager.hasPermissions && !sensorManager.captureSession.isRunning {
                DispatchQueue.global(qos: .userInitiated).async {
                    sensorManager.captureSession.startRunning()
                }
            }
        }
        .onReceive(timer) { _ in
            // Sample audio level
            audioLevels.append(sensorManager.currentAudioLevel)
            if audioLevels.count > 80 { audioLevels.removeFirst() }
            // Sample IMU 3-axis (raw)
            imuXRaw.append(sensorManager.currentIMUAcceleration.x)
            if imuXRaw.count > 80 { imuXRaw.removeFirst() }
            imuYRaw.append(sensorManager.currentIMUAcceleration.y)
            if imuYRaw.count > 80 { imuYRaw.removeFirst() }
            imuZRaw.append(sensorManager.currentIMUAcceleration.z)
            if imuZRaw.count > 80 { imuZRaw.removeFirst() }
        }
        // Fix onChange deprecation warning for iOS 17
        .onChange(of: sensorManager.hasPermissions) { _, newValue in
            // Start the session if it's not running after detecting permissions are granted
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
            let spacing: CGFloat = 0.5 // Finer spacing
            let totalSpacing = spacing * CGFloat(values.count - 1)
            let width = max(1, (geo.size.width - totalSpacing) / CGFloat(values.count))
            HStack(alignment: .center, spacing: spacing) {
                ForEach(0..<values.count, id: \ .self) { i in
                    Capsule()
                        .fill(Color.accentColor) // Use accent color for a better look
                        .frame(width: width, height: max(1, CGFloat(values[i]) * geo.size.height))
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
    }
}

// IMU 3-axis line chart
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

// Define custom share wrapper: Instantly compress the selected Block folder into a .zip when sharing is clicked
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
                    Text("No recorded data, please go to Measurement to record.")
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
                            .buttonStyle(PlainButtonStyle()) // Allow multiple buttons on the same line
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
            // Zipping progress popup
            .sheet(isPresented: $showZipProgress) {
                VStack(spacing: 20) {
                    Text("Zipping into ZIP...")
                    ProgressView(value: zipManager.progressDict[zipBlockURL ?? URL(fileURLWithPath:"")]?.progress ?? 0)
                        .progressViewStyle(LinearProgressViewStyle())
                        .frame(width: 200)
                    Button("Cancel") {
                        showZipProgress = false
                    }
                }
                .padding()
            }
            // Popup asking whether to share after zipping is complete
            .alert("ZIP generated, share?", isPresented: $showShareSheet, actions: {
                if let url = zipResultURL {
                    Button("Share") {
                        shareZip(url: url)
                    }
                }
                Button("Close", role: .cancel) {
                    if let url = zipResultURL {
                        zipManager.cleanup(url: url)
                    }
                }
            }, message: {
                if let url = zipResultURL {
                    Text(url.lastPathComponent)
                }
            })
            // Zipping failed popup
            .alert("Zipping failed", isPresented: $showZipError) {}
        }
    }

    // Share zip
    func shareZip(url: URL) {
        let av = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        
        // Automatically clean up the temporary zip file after the share panel is closed (whether successful or cancelled)
        av.completionWithItemsHandler = { [weak zipManager] _, _, _, _ in
            zipManager?.cleanup(url: url)
        }
        
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let root = windowScene.windows.first?.rootViewController {
            root.present(av, animated: true)
        }
    }
    
    // MARK: - File Management Logic
    
        // 1. Read Block folders under the sandbox Documents directory
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
                print("Failed to load files: \(error)")
            }
        }
    
    // 2. Delete files
    private func deleteFiles(at offsets: IndexSet) {
        for index in offsets {
            let fileURL = recordedFiles[index]
            do {
                try FileManager.default.removeItem(at: fileURL)
            } catch {
                print("Failed to delete files: \(error)")
            }
        }
        recordedFiles.remove(atOffsets: offsets)
    }
    
    // 3. Rename Block
    private func renameItem() {
        guard let oldURL = itemToRename, !newName.isEmpty else { return }
        let newURL = oldURL.deletingLastPathComponent().appendingPathComponent(newName)
        do {
            try FileManager.default.moveItem(at: oldURL, to: newURL)
            loadFiles()
        } catch {
            print("Failed to rename: \(error)")
        }
    }
    
    // 4. Recursively calculate the volume of the entire Block folder and format it
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
        return "Unknown size"
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
                    return isDir1.boolValue // Folders first
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
                                    extractionMessage = "Audio successfully extracted to:\n\(audioURL.lastPathComponent)"
                                    refreshAction()
                                }
                            } catch {
                                await MainActor.run {
                                    extractionMessage = "Audio extraction failed:\n\(error.localizedDescription)"
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
                    .alert("Audio Extraction", isPresented: $showExtractionAlert) {
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
                Text("Unable to load video")
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
    
    private let maxRowsToDisplay = 20 // Show header + 19 data rows

    var body: some View {
        VStack {
            if isLoading {
                ProgressView("Loading...")
            } else if let errorMessage = errorMessage {
                Text(errorMessage)
                    .foregroundColor(.red)
                    .padding()
            } else if rows.isEmpty {
                Text("File content is empty or cannot be parsed.")
                    .foregroundColor(.gray)
                    .padding()
            } else {
                // Use ScrollView + LazyVStack to build a highly reliable data grid
                ScrollView(.horizontal) {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        // Header
                        HStack(spacing: 16) {
                            ForEach(0..<header.count, id: \.self) { index in
                                Text(header[index])
                                    .font(.system(.caption, design: .monospaced).bold())
                                    .frame(width: 80, alignment: .leading)
                            }
                        }
                        Divider()
                        // Data rows
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
                    Text("Only showing the first \(maxRowsToDisplay) rows, please export to view full content.")
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

    // Auxiliary struct for Identifiable rows in Table
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
                        self.errorMessage = "File is empty."
                        self.isLoading = false
                    }
                    return
                }
                
                // Parse header (first row)
                let parsedHeader = lines[0].split(separator: "\t").map(String.init)
                
                // Parse data rows, limit the number (maxRowsToDisplay + 1 to include the header in the count for min)
                var parsedRows: [CSVRow] = []
                for i in 1..<min(lines.count, self.maxRowsToDisplay + 1) {
                    let columns = lines[i].split(separator: "\t").map(String.init)
                    // Ensure the number of columns in each row matches the header to prevent Table crashes
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
                    self.errorMessage = "Failed to load file content:\n\(error.localizedDescription)"
                    self.isLoading = false
                }
            }
        }
    }
}
