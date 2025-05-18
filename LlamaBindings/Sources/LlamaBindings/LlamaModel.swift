import Foundation

public class LlamaModel {
    private let modelManager = ModelManager.getInstance()
    
    public init() {
        // Initialize backend
        llama_backend_init()
        llama_log_set { level, message, _ in
            print("[\(level)] \(String(cString: message))")
        }
    }
    
    deinit {
        modelManager.cleanup()
        llama_backend_free()
    }
    
    public func loadModels(languageModelPath: String, visionModelPath: String) -> Bool {
        return modelManager.loadLanguageModel(languageModelPath) &&
               modelManager.loadVisionModel(visionModelPath) &&
               modelManager.initializeContext() &&
               modelManager.initializeBatch() &&
               modelManager.initializeSampler() &&
               modelManager.initializeChatTemplate("vicuna")
    }
    
    public func processImage(path: String) -> Bool {
        return modelManager.processImage(path)
    }
    
    public func processImageFromBuffer(_ buffer: UnsafePointer<UInt8>, width: Int, height: Int) -> Bool {
        let len = width * height * 3
        let rgbBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: len)
        defer { rgbBuffer.deallocate() }
        
        // Convert BGRA to RGB
        for i in 0..<(width * height) {
            let srcIdx = i * 4
            let dstIdx = i * 3
            rgbBuffer[dstIdx + 0] = buffer[srcIdx + 2] // R
            rgbBuffer[dstIdx + 1] = buffer[srcIdx + 1] // G
            rgbBuffer[dstIdx + 2] = buffer[srcIdx + 0] // B
        }
        
        let bitmap = mtmd_bitmap(width: Int32(width), height: Int32(height), data: rgbBuffer)
        modelManager.addBitmap(bitmap)
        return true
    }
    
    public func generateResponse(prompt: String, maxTokens: Int = 128) -> String {
        return modelManager.generateResponse(prompt, maxTokens)
    }
    
    public func getTokenCount(text: String) -> Int {
        let inputText = mtmd_input_text(text: text, add_special: false, parse_special: true)
        let chunks = mtmd_input_chunks_init()
        let bitmaps = modelManager.getBitmaps()
        let bitmapsPtr = bitmaps.c_ptr()
        
        let res = mtmd_tokenize(modelManager.getVisionContext(),
                              chunks,
                              &inputText,
                              bitmapsPtr.data(),
                              bitmapsPtr.size())
        
        return res == 0 ? 0 : -1 // TODO: Implement actual token counting
    }
} 