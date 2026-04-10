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
        // 每次分享都创建一个新的ZIP到Temp目录，以避免权限和缓存问题
        let zipURL = FileManager.default.temporaryDirectory.appendingPathComponent(blockURL.lastPathComponent + ".zip")
        
        // 如果临时目录中已存在同名文件，先删除它，确保我们创建的是最新的
        if FileManager.default.fileExists(atPath: zipURL.path) {
            try? FileManager.default.removeItem(at: zipURL)
        }
        
        // 标记为正在打包
        progressDict[blockURL] = ZipProgress(blockURL: blockURL, progress: 0, isZipping: true, zipURL: nil)
        
        DispatchQueue.global(qos: .userInitiated).async {
            // 模拟进度（实际可用更细粒度的zip实现替换）
            for i in 1...100 {
                usleep(20000) // 0.02s
                DispatchQueue.main.async {
                    self.progressDict[blockURL]?.progress = Double(i) / 100.0
                }
            }
            // 真正打包（ZIPFoundation实现）
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
                print("ZIP失败: \(error)")
                DispatchQueue.main.async {
                    self.progressDict[blockURL] = ZipProgress(blockURL: blockURL, progress: 1, isZipping: false, zipURL: nil)
                    completion(nil)
                }
            }
        }
    }
}
