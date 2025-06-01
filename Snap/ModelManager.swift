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

typealias TokenCallback = @convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void

class ModelManager: NSObject, ObservableObject, URLSessionDownloadDelegate {
    static let shared = ModelManager()
    
    @Published var isDownloading = false
    @Published var downloadProgress: DownloadProgress?
    @Published var isModelLoaded = false
    
    private let baseURL = "https://huggingface.co/ggml-org/SmolVLM2-256M-Video-Instruct-GGUF/resolve/main"
    private let modelsDirectory: URL
    private var currentDownloadTotalBytes: Int64 = 0
    private var currentDownloadBytesReceived: Int64 = 0
    
    private let defaultModelName = "SmolVLM2-256M-Video-Instruct"
    private var manager: UnsafeMutableRawPointer?
    
    // List of available models
    let availableModels: [MTMDModelPair] = [
        MTMDModelPair(
            name: "SmolVLM2-256M-Video-Instruct",
            language: Model(
                id: "SmolVLM2-256M-Video-Instruct-Q8_0.gguf",
                name: "SmolVLM2",
                size: 175_056_352, // 175 MB
                isDefault: true,
                isLanguage: true
            ),
            vision: Model(
                id: "mmproj-SmolVLM2-256M-Video-Instruct-Q8_0.gguf",
                name: "SmolVLM2",
                size: 104_000_000, // 104 MB
                isDefault: true,
                isLanguage: false
            )
        )
    ]
    
    private var currentModelFile: URL?
    private var currentModelSize: Int64 = 0
    
    override init() {
        // Get the documents directory
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        modelsDirectory = documentsPath.appendingPathComponent("models")
        
        super.init()
        
        // Create models directory if it doesn't exist
        do {
            try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true, attributes: nil)
            print("Models directory created/verified at: \(modelsDirectory.path)")
        } catch {
            print("Error creating models directory: \(error)")
        }
        
        // Check if models are already loaded
        isModelLoaded = isModelPairDownloaded(modelName: defaultModelName)
        
        manager = create_model_manager()
    }
    
    deinit {
        if let manager = manager {
            destroy_model_manager(manager)
        }
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
        _ = semaphore.wait(timeout: .now() + 5.0) // Increase timeout to 5 seconds
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
            guard loadLanguageModel(path: languagePath) else {
                throw NSError(domain: "ModelManager", code: 6, userInfo: [NSLocalizedDescriptionKey: "Failed to load language model"])
            }
            
            // Then load vision model
            guard loadVisionModel(path: visionPath) else {
                throw NSError(domain: "ModelManager", code: 6, userInfo: [NSLocalizedDescriptionKey: "Failed to load vision model"])
            }
            
            // Initialize the context and other components
            guard initializeContext() else {
                throw NSError(domain: "ModelManager", code: 6, userInfo: [NSLocalizedDescriptionKey: "Failed to initialize context"])
            }
            
            guard initializeBatch() else {
                throw NSError(domain: "ModelManager", code: 6, userInfo: [NSLocalizedDescriptionKey: "Failed to initialize batch"])
            }
            
            guard initializeSampler() else {
                throw NSError(domain: "ModelManager", code: 6, userInfo: [NSLocalizedDescriptionKey: "Failed to initialize sampler"])
            }
            
            guard initializeChatTemplate() else {
                throw NSError(domain: "ModelManager", code: 6, userInfo: [NSLocalizedDescriptionKey: "Failed to initialize chat template"])
            }
            
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
    
    // Add property to store the download continuation
    private var downloadContinuation: CheckedContinuation<(URL, URLResponse), Error>?
    private var downloadTask: URLSessionDownloadTask?
    private var isDownloadComplete = false
    
    private func downloadModel(_ modelId: String) async throws {
        print("Downloading model with ID: \(modelId)")
        guard let model = getModel(modelId: modelId) else {
            print("Failed to find model with ID: \(modelId)")
            throw NSError(domain: "ModelManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid model ID"])
        }
        
        let modelFile = getModelPath(modelId)
        currentModelFile = modelFile
        
        // Ensure models directory exists
        do {
            try FileManager.default.createDirectory(at: modelFile.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)
            print("Verified models directory exists at: \(modelFile.deletingLastPathComponent().path)")
        } catch {
            print("Error creating models directory: \(error)")
            throw NSError(domain: "ModelManager", code: 10, userInfo: [NSLocalizedDescriptionKey: "Failed to create models directory: \(error.localizedDescription)"])
        }
        
        await MainActor.run {
            isDownloading = true
            isDownloadComplete = false
            downloadProgress = DownloadProgress(
                progress: 0,
                bytesDownloaded: 0,
                totalBytes: model.size,
                status: .downloading,
                message: "Starting download..."
            )
        }
        
        // Construct direct download URL
        let downloadURL = URL(string: "\(baseURL)/\(modelId)")!
        print("Downloading from URL: \(downloadURL)")
        
        // Create a URLSession configuration with timeouts
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300 // 5 minutes timeout for each chunk
        config.timeoutIntervalForResource = 3600 // 1 hour total timeout
        config.waitsForConnectivity = true
        
        // Create a URLSession with our delegate and configuration
        let session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
        
        // Add a timeout task
        let timeoutTask = Task {
            try await Task.sleep(nanoseconds: 3600 * 1_000_000_000) // 1 hour timeout
            session.invalidateAndCancel()
            throw NSError(domain: "ModelManager", code: 8, userInfo: [NSLocalizedDescriptionKey: "Download timed out after 1 hour"])
        }
        
        // Download the file using downloadTask
        do {
            print("Starting download task...")
            downloadTask = session.downloadTask(with: downloadURL)
            print("Created download task: \(String(describing: downloadTask))")
            downloadTask?.resume()
            print("Resumed download task")
            
            // Wait for the download to complete using async/await
            let (finalFileURL, downloadResponse) = try await withCheckedThrowingContinuation { continuation in
                self.downloadContinuation = continuation
            }
            
            print("Download continuation completed")
            print("Final file URL: \(finalFileURL)")
            print("Download response: \(downloadResponse)")
            
            timeoutTask.cancel() // Cancel timeout task if download completes
            
            print("Download completed, verifying response...")
            guard let downloadHttpResponse = downloadResponse as? HTTPURLResponse, downloadHttpResponse.statusCode == 200 else {
                throw NSError(domain: "ModelManager", code: 6, userInfo: [NSLocalizedDescriptionKey: "Download failed"])
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
                isDownloadComplete = true
            }
            
            // Clear the current model file reference
            currentModelFile = nil
            
        } catch {
            print("Download error: \(error)")
            timeoutTask.cancel() // Cancel timeout task if error occurs
            session.invalidateAndCancel()
            
            // Clear the current model file reference
            currentModelFile = nil
            
            throw error
        }
    }
    
    // MARK: - URLSessionDownloadDelegate
    
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        print("Download progress: \(totalBytesWritten)/\(totalBytesExpectedToWrite) bytes")
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
        print("Download task state: \(downloadTask.state.rawValue)")
        print("Download task response: \(String(describing: downloadTask.response))")
        print("Download task error: \(String(describing: downloadTask.error))")
        
        // Immediately copy the file to our target location
        if let modelFile = currentModelFile {
            do {
                print("Immediately copying file from \(location.path) to \(modelFile.path)")
                
                // Remove existing file if it exists
                if FileManager.default.fileExists(atPath: modelFile.path) {
                    try FileManager.default.removeItem(at: modelFile)
                }
                
                // Copy the file
                try FileManager.default.copyItem(at: location, to: modelFile)
                print("File copied successfully")
                isDownloadComplete = true
                if let continuation = downloadContinuation {
                    continuation.resume(returning: (modelFile, downloadTask.response!))
                    downloadContinuation = nil
                }
            } catch {
                print("Error copying file: \(error)")
                if let continuation = downloadContinuation {
                    continuation.resume(throwing: error)
                    downloadContinuation = nil
                }
            }
        } else {
            print("Error: No target model file URL set")
            if let continuation = downloadContinuation {
                continuation.resume(throwing: NSError(domain: "ModelManager", code: 16, userInfo: [NSLocalizedDescriptionKey: "No target model file URL set"]))
                downloadContinuation = nil
            }
        }
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            print("Download error: \(error.localizedDescription)")
            print("Task state: \(task.state.rawValue)")
            print("Task response: \(String(describing: task.response))")
            
            if let downloadTask = task as? URLSessionDownloadTask {
                print("Download task error: \(String(describing: downloadTask.error))")
            }
            
            if let continuation = downloadContinuation {
                continuation.resume(throwing: error)
                downloadContinuation = nil
            }
            Task { @MainActor in
                downloadProgress = DownloadProgress(
                    progress: 0,
                    bytesDownloaded: currentDownloadBytesReceived,
                    totalBytes: currentDownloadTotalBytes,
                    status: .error(error.localizedDescription),
                    message: "Download failed: \(error.localizedDescription)"
                )
                isDownloading = false
                isDownloadComplete = false
            }
        }
    }
    
    func processImage(_ image: UIImage, prompt: String) async throws -> String {
        guard isModelLoaded else {
            throw NSError(domain: "ModelManager", code: 8, userInfo: [NSLocalizedDescriptionKey: "Model not loaded"])
        }
        
        do {
            // Save image to temporary file
            let tempDir = FileManager.default.temporaryDirectory
            let imagePath = tempDir.appendingPathComponent(UUID().uuidString + ".jpg")
            if let imageData = image.jpegData(compressionQuality: 0.8) {
                try imageData.write(to: imagePath)
                
                print("Processing image at path: \(imagePath.path)")
                
                // Process the image
                guard processImage(path: imagePath.path) else {
                    print("Failed to process image at path: \(imagePath.path)")
                    throw NSError(domain: "ModelManager", code: 9, userInfo: [NSLocalizedDescriptionKey: "Failed to process image"])
                }
                
                print("Image processed successfully")
                
                // Clean up temporary file
                try? FileManager.default.removeItem(at: imagePath)
                
                return ""  // Return empty string since we're using streaming now
            } else {
                throw NSError(domain: "ModelManager", code: 11, userInfo: [NSLocalizedDescriptionKey: "Failed to convert image to JPEG"])
            }
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
        try await loadModelPair(languagePath: languagePath, visionPath: visionPath)
        
        isModelLoaded = true
    }
    
    func cleanup() {
        isModelLoaded = false
    }
    
    func loadLanguageModel(path: String) -> Bool {
        guard let manager = manager else { return false }
        return load_language_model(manager, path)
    }
    
    func loadVisionModel(path: String) -> Bool {
        guard let manager = manager else { return false }
        return load_vision_model(manager, path)
    }
    
    func initializeContext() -> Bool {
        guard let manager = manager else { return false }
        return initialize_context(manager)
    }
    
    func initializeBatch() -> Bool {
        guard let manager = manager else { return false }
        return initialize_batch(manager)
    }
    
    func initializeSampler() -> Bool {
        guard let manager = manager else { return false }
        return initialize_sampler(manager)
    }
    
    // This can't be null, the deafult is vicuna
    func initializeChatTemplate(templateName: String? = "vicuna") -> Bool {
        guard let manager = manager else { return false }
        return initialize_chat_template(manager, templateName)
    }
    
    func processImage(path: String) -> Bool {
        guard let manager = manager else { return false }
        return process_image(manager, path)
    }
    
    func generateResponse(prompt: String, maxTokens: Int) -> String? {
        guard let manager = manager else { return nil }
        guard let response = generate_response(manager, prompt, Int32(maxTokens)) else { return nil }
        defer { free_response(response) }
        return String(cString: response)
    }
    
    func generateResponseStream(prompt: String, maxTokens: Int, onToken: @escaping (String) -> Void, onComplete: @escaping () -> Void) -> Bool {
        guard let manager = manager else { return false }
        
        print("Starting response stream with prompt: \(prompt)")
        
        // Create a context object to hold our callback
        class CallbackContext {
            let callback: (String) -> Void
            let onComplete: () -> Void
            init(_ callback: @escaping (String) -> Void, _ onComplete: @escaping () -> Void) {
                self.callback = callback
                self.onComplete = onComplete
            }
        }
        
        // Create a strong reference to the context
        let context = CallbackContext(onToken, onComplete)
        let contextPtr = Unmanaged.passUnretained(context).toOpaque()
        
        // Create the C callback
        let callback: TokenCallback = { token, userData in
            guard let token = token else { return }
            print("C callback received token: \(String(cString: token))")
            
            // Get the context without consuming it
            let context = Unmanaged<CallbackContext>.fromOpaque(userData!).takeUnretainedValue()
            
            // Always dispatch to main thread for UI updates
            DispatchQueue.main.async {
                print("Executing callback on main thread")
                context.callback(String(cString: token))
                print("C callback completed for token: \(String(cString: token))")
            }
        }
        
        // Run generation on background thread
        DispatchQueue.global(qos: .userInitiated).async {
            let success = generate_response_stream(manager, prompt, Int32(maxTokens), callback, contextPtr)
            DispatchQueue.main.async {
                if !success {
                    onToken("Error: Failed to generate response")
                }
                context.onComplete()
            }
        }
        
        // Store the context to keep it alive
        self._callbackContext = context
        
        return true
    }
    
    // Add a property to store the callback context
    private var _callbackContext: Any?
} 
