import SwiftUI
import UniformTypeIdentifiers
import ZIPFoundation

struct ZipProgress: Identifiable {
    let id = UUID()
    let blockURL: URL
    var progress: Double
    var isZipping: Bool
    var zipURL: URL?
}

class ZipManager: ObservableObject {
    @Published var progressDict: [URL: ZipProgress] = [:]
    
    func zipBlock(blockURL: URL, completion: @escaping (URL?) -> Void) {
        // Create a new ZIP in the Temp directory for each share to avoid permission and caching issues
        let zipURL = FileManager.default.temporaryDirectory.appendingPathComponent(blockURL.lastPathComponent + ".zip")
        
        // If a file with the same name already exists in the temp directory, delete it first to ensure we create the latest one
        if FileManager.default.fileExists(atPath: zipURL.path) {
            try? FileManager.default.removeItem(at: zipURL)
        }
        
        // Mark as zipping in progress
        progressDict[blockURL] = ZipProgress(blockURL: blockURL, progress: 0, isZipping: true, zipURL: nil)
        
        DispatchQueue.global(qos: .userInitiated).async {
            // Simulate progress (can be replaced with a more granular zip implementation in practice)
            for i in 1...100 {
                usleep(20000) // 0.02s
                DispatchQueue.main.async {
                    self.progressDict[blockURL]?.progress = Double(i) / 100.0
                }
            }
            // Actual zipping (ZIPFoundation implementation)
            let fm = FileManager.default
            do {
                if fm.fileExists(atPath: zipURL.path) {
                    try fm.removeItem(at: zipURL)
                }
                try fm.zipItem(at: blockURL, to: zipURL)
                DispatchQueue.main.async {
                    self.progressDict[blockURL] = ZipProgress(blockURL: blockURL, progress: 1, isZipping: false, zipURL: zipURL)
                    completion(zipURL)
                }
            } catch {
                print("ZIP failed: \(error)")
                DispatchQueue.main.async {
                    self.progressDict[blockURL] = ZipProgress(blockURL: blockURL, progress: 1, isZipping: false, zipURL: nil)
                    completion(nil)
                }
            }
        }
    }
    
    // Clean up generated temporary ZIP files
    func cleanup(url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
