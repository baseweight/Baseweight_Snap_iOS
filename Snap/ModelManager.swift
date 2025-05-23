import Foundation
import Network
import UIKit

enum DownloadStatus {
    case pending
    case downloading
    case completed
    case error(String)
}

struct DownloadProgress {
    let progress: Int // 0-100
    let bytesDownloaded: Int64
    let totalBytes: Int64
    let status: DownloadStatus
    let message: String
}

struct Model {
    let id: String
    let name: String
    let size: Int64 // in bytes
    let isDefault: Bool
    let isLanguage: Bool
}

struct MTMDModelPair {
    let name: String
    let language: Model
    let vision: Model
    
    var languageId: String { language.id }
    var visionId: String { vision.id }
}

class ModelManager: NSObject, ObservableObject, URLSessionDownloadDelegate {
    static let shared = ModelManager()
    
    @Published var isDownloading = false
    @Published var downloadProgress: DownloadProgress?
    @Published var isModelLoaded = false
    
    private let baseURL = "https://api.baseweight.ai/api"
    private let modelsDirectory: URL
    private var currentDownloadTotalBytes: Int64 = 0
    private var currentDownloadBytesReceived: Int64 = 0
    
    private let defaultModelName = "SmolVLM-2.2B-Instruct"
    private let mtmdManager = MTMDManager.shared
    
    // List of available models
    let availableModels: [MTMDModelPair] = [
        MTMDModelPair(
            name: "SmolVLM-2.2B-Instruct",
            language: Model(
                id: "8ccd519a-620a-4a1d-98ba-a9712a95a1b4",
                name: "SmolVLM",
                size: 1_927_933_984, // 1838.62 MB
                isDefault: true,
                isLanguage: true
            ),
            vision: Model(
                id: "e3e8315b-99cd-4ae5-8cc9-c8738ae8aa1e",
                name: "SmolVLM",
                size: 592_523_200, // 565.07 MB
                isDefault: true,
                isLanguage: false
            )
        )
    ]
    
    private override init() {
        // Get the documents directory
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        modelsDirectory = documentsPath.appendingPathComponent("models")
        
        super.init()
        
        // Create models directory if it doesn't exist
        try? FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        
        // Check if models are already loaded
        isModelLoaded = isModelPairDownloaded(modelName: defaultModelName)
    }
    
    func getMTMDModel(name: String) -> MTMDModelPair? {
        return availableModels.first { $0.name == name }
    }
    
    func getModel(modelId: String) -> Model? {
        return availableModels
            .flatMap { [$0.language, $0.vision] }
            .first { $0.id == modelId }
    }
    
    func isModelPairDownloaded(modelName: String) -> Bool {
        guard let model = getMTMDModel(name: modelName) else { return false }
        
        let languageFile = getModelPath(model.languageId)
        let visionFile = getModelPath(model.visionId)
        
        let languageExists = FileManager.default.fileExists(atPath: languageFile.path) &&
            (try? FileManager.default.attributesOfItem(atPath: languageFile.path)[.size] as? Int64 ?? 0) ?? 0 > 0
        
        let visionExists = FileManager.default.fileExists(atPath: visionFile.path) &&
            (try? FileManager.default.attributesOfItem(atPath: visionFile.path)[.size] as? Int64 ?? 0) ?? 0 > 0
        
        return languageExists && visionExists
    }
    
    func getModelPath(_ modelId: String) -> URL {
        return modelsDirectory.appendingPathComponent("\(modelId).gguf")
    }
    
    func isOnWiFi() -> Bool {
        let monitor = NWPathMonitor(requiredInterfaceType: .wifi)
        var isWiFi = false
        let semaphore = DispatchSemaphore(value: 0)
        
        monitor.pathUpdateHandler = { path in
            isWiFi = path.status == .satisfied
            semaphore.signal()
        }
        
        let queue = DispatchQueue(label: "NetworkMonitor")
        monitor.start(queue: queue)
        _ = semaphore.wait(timeout: .now() + 1.0)
        monitor.cancel()
        
        return isWiFi
    }
    
    func downloadModelPair(modelName: String) async throws {
        guard let mtmdModel = getMTMDModel(name: modelName) else {
            throw NSError(domain: "ModelManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid model name"])
        }
        
        print("Downloading model pair: \(modelName)")
        print("Language model ID: \(mtmdModel.languageId)")
        print("Vision model ID: \(mtmdModel.visionId)")
        
        await MainActor.run {
            isDownloading = true
            downloadProgress = DownloadProgress(
                progress: 0,
                bytesDownloaded: 0,
                totalBytes: mtmdModel.language.size + mtmdModel.vision.size,
                status: .pending,
                message: "Starting download..."
            )
        }
        
        // Download language model first
        try await downloadModel(mtmdModel.languageId)
        
        // Download vision model
        try await downloadModel(mtmdModel.visionId)
        
        // Verify both files are present
        let languageFile = getModelPath(mtmdModel.languageId)
        let visionFile = getModelPath(mtmdModel.visionId)
        
        let languageExists = FileManager.default.fileExists(atPath: languageFile.path)
        let visionExists = FileManager.default.fileExists(atPath: visionFile.path)
        
        let totalSize = mtmdModel.language.size + mtmdModel.vision.size
        
        if languageExists && visionExists {
            // Load the models
            try await loadModelPair(languagePath: languageFile.path, visionPath: visionFile.path)
            
            await MainActor.run {
                downloadProgress = DownloadProgress(
                    progress: 100,
                    bytesDownloaded: totalSize,
                    totalBytes: totalSize,
                    status: .completed,
                    message: "Both models downloaded and loaded successfully"
                )
                isModelLoaded = true
                isDownloading = false
            }
        } else {
            // Clean up if either file is missing
            if !languageExists { try? FileManager.default.removeItem(at: languageFile) }
            if !visionExists { try? FileManager.default.removeItem(at: visionFile) }
            
            await MainActor.run {
                isDownloading = false
            }
            
            throw NSError(domain: "ModelManager", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to verify downloaded files"])
        }
    }
    
    private func loadModelPair(languagePath: String, visionPath: String) async throws {
        do {
            // Load language model first
            try await mtmdManager.loadLanguageModel(languagePath)
            
            // Then load vision model
            try await mtmdManager.loadVisionModel(visionPath)
            
            print("Successfully loaded both models")
        } catch {
            print("Failed to load models: \(error)")
            throw NSError(domain: "ModelManager", code: 6, userInfo: [NSLocalizedDescriptionKey: "Failed to load models: \(error.localizedDescription)"])
        }
    }
    
    // Add a function to load models if they're already downloaded
    func loadDownloadedModels() async throws {
        guard let mtmdModel = getMTMDModel(name: defaultModelName) else {
            throw NSError(domain: "ModelManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid model name"])
        }
        
        let languageFile = getModelPath(mtmdModel.languageId)
        let visionFile = getModelPath(mtmdModel.visionId)
        
        if isModelPairDownloaded(modelName: defaultModelName) {
            try await loadModelPair(languagePath: languageFile.path, visionPath: visionFile.path)
            await MainActor.run {
                isModelLoaded = true
            }
        }
    }
    
    private func downloadModel(_ modelId: String) async throws {
        print("Downloading model with ID: \(modelId)")
        guard let model = getModel(modelId: modelId) else {
            print("Failed to find model with ID: \(modelId)")
            throw NSError(domain: "ModelManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid model ID"])
        }
        
        let modelFile = getModelPath(modelId)
        
        // Create parent directories if they don't exist
        try? FileManager.default.createDirectory(at: modelFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        
        await MainActor.run {
            isDownloading = true
            currentDownloadTotalBytes = model.size
            currentDownloadBytesReceived = 0
            downloadProgress = DownloadProgress(
                progress: 0,
                bytesDownloaded: 0,
                totalBytes: model.size,
                status: .pending,
                message: "Requesting download URL..."
            )
        }
        
        // Get the pre-signed URL
        let apiUrl = "\(baseURL)/models/\(modelId)/download"
        print("Constructed API URL: \(apiUrl)")
        guard let url = URL(string: apiUrl) else {
            print("Failed to create URL from: \(apiUrl)")
            throw NSError(domain: "ModelManager", code: 3, userInfo: [NSLocalizedDescriptionKey: "Invalid API URL"])
        }
        
        var request = URLRequest(url: url)
        request.setValue("Bearer \(Config.apiKey)", forHTTPHeaderField: "Authorization")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            print("Invalid response type: \(type(of: response))")
            throw NSError(domain: "ModelManager", code: 4, userInfo: [NSLocalizedDescriptionKey: "Invalid response type"])
        }
        
        print("API Response Status: \(httpResponse.statusCode)")
        if let responseString = String(data: data, encoding: .utf8) {
            print("API Response Body: \(responseString)")
        }
        
        guard httpResponse.statusCode == 200 else {
            throw NSError(domain: "ModelManager", code: 4, userInfo: [NSLocalizedDescriptionKey: "API request failed with status \(httpResponse.statusCode)"])
        }
        
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let downloadUrl = json["download_url"] as? String,
              let downloadURL = URL(string: downloadUrl) else {
            throw NSError(domain: "ModelManager", code: 5, userInfo: [NSLocalizedDescriptionKey: "Invalid API response"])
        }
        
        await MainActor.run {
            downloadProgress = DownloadProgress(
                progress: 0,
                bytesDownloaded: 0,
                totalBytes: model.size,
                status: .downloading,
                message: "Downloading model..."
            )
        }
        
        // Create a URLSession with our delegate
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        
        // Download the file using downloadTask
        let (tempFileURL, downloadResponse) = try await session.download(from: downloadURL)
        
        guard let downloadHttpResponse = downloadResponse as? HTTPURLResponse, downloadHttpResponse.statusCode == 200 else {
            throw NSError(domain: "ModelManager", code: 6, userInfo: [NSLocalizedDescriptionKey: "Download failed"])
        }
        
        // Move the downloaded file to our target location
        try? FileManager.default.removeItem(at: modelFile) // Remove existing file if any
        try FileManager.default.moveItem(at: tempFileURL, to: modelFile)
        
        // Verify file size
        let attributes = try FileManager.default.attributesOfItem(atPath: modelFile.path)
        let fileSize = attributes[.size] as? Int64 ?? 0
        
        print("File size verification:")
        print("Expected size: \(model.size) bytes")
        print("Actual size: \(fileSize) bytes")
        
        if fileSize != model.size {
            print("Size mismatch! Difference: \(model.size - fileSize) bytes")
            try? FileManager.default.removeItem(at: modelFile)
            throw NSError(domain: "ModelManager", code: 7, userInfo: [NSLocalizedDescriptionKey: "Downloaded file size mismatch"])
        }
        
        await MainActor.run {
            downloadProgress = DownloadProgress(
                progress: 100,
                bytesDownloaded: model.size,
                totalBytes: model.size,
                status: .completed,
                message: "Download completed"
            )
            isDownloading = false
        }
    }
    
    // MARK: - URLSessionDownloadDelegate
    
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        Task { @MainActor in
            currentDownloadBytesReceived = totalBytesWritten
            let progress = Int((Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) * 100)
            downloadProgress = DownloadProgress(
                progress: progress,
                bytesDownloaded: totalBytesWritten,
                totalBytes: totalBytesExpectedToWrite,
                status: .downloading,
                message: "Downloading: \(progress)%"
            )
        }
    }
    
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        print("Download finished to: \(location)")
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            print("Download error: \(error.localizedDescription)")
            Task { @MainActor in
                downloadProgress = DownloadProgress(
                    progress: 0,
                    bytesDownloaded: currentDownloadBytesReceived,
                    totalBytes: currentDownloadTotalBytes,
                    status: .error(error.localizedDescription),
                    message: "Download failed: \(error.localizedDescription)"
                )
                isDownloading = false
            }
        }
    }
    
    func processImage(_ image: UIImage, prompt: String) async throws -> String {
        guard isModelLoaded else {
            throw NSError(domain: "ModelManager", code: 8, userInfo: [NSLocalizedDescriptionKey: "Model not loaded"])
        }
        
        do {
            // Process the image
            try await mtmdManager.processImage(image)
            
            // Generate response
            let response = try await mtmdManager.generateResponse(prompt, maxTokens: 512)
            
            return response
        } catch {
            print("Error processing image: \(error)")
            throw error
        }
    }
    
    func loadModelPair(modelName: String) async throws {
        guard let mtmdModel = getMTMDModel(name: modelName) else {
            throw NSError(domain: "ModelManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid model name"])
        }
        
        let languagePath = getModelPath(mtmdModel.languageId).path
        let visionPath = getModelPath(mtmdModel.visionId).path
        
        // Load the language model
        try await mtmdManager.loadLanguageModel(languagePath)
        
        // Load the vision model
        try await mtmdManager.loadVisionModel(visionPath)
        
        isModelLoaded = true
    }
    
    func cleanup() {
        isModelLoaded = false
    }
} 
