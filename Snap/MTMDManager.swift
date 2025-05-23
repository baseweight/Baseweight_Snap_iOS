import Foundation
import llama
import UIKit

enum MTMDError: Error {
    case couldNotInitializeContext
    case couldNotLoadModel
    case couldNotLoadVisionModel
    case couldNotInitializeSampler
    case couldNotProcessImage
    case couldNotEvaluateMessage
}

// MARK: - Batch Helpers

func llama_batch_clear(_ batch: inout llama_batch) {
    batch.n_tokens = 0
}

func llama_batch_add(_ batch: inout llama_batch, _ id: llama_token, _ pos: llama_pos, _ seq_ids: [llama_seq_id], _ logits: Bool) {
    batch.token[Int(batch.n_tokens)] = id
    batch.pos[Int(batch.n_tokens)] = pos
    batch.n_seq_id[Int(batch.n_tokens)] = Int32(seq_ids.count)
    for i in 0..<seq_ids.count {
        batch.seq_id[Int(batch.n_tokens)]![Int(i)] = seq_ids[i]
    }
    batch.logits[Int(batch.n_tokens)] = logits ? 1 : 0
    batch.n_tokens += 1
}

// MARK: - MTMD Types

struct MTMDInputText {
    let text: String
    let addSpecial: Bool
    let parseSpecial: Bool
}

class MTMDBitmap {
    var bitmap: OpaquePointer
    
    init(bitmap: OpaquePointer) {
        self.bitmap = bitmap
    }
    
    init?(fromFile path: String) {
        guard let bitmap = mtmd_helper_bitmap_init_from_file(path) else {
            return nil
        }
        self.bitmap = bitmap
    }
    
    deinit {
        mtmd_bitmap_free(bitmap)
    }
    
    var width: UInt32 {
        mtmd_bitmap_get_nx(bitmap)
    }
    
    var height: UInt32 {
        mtmd_bitmap_get_ny(bitmap)
    }
    
    var data: UnsafePointer<UInt8> {
        mtmd_bitmap_get_data(bitmap)
    }
}

// MARK: - MTMD Manager

actor MTMDManager {
    static let shared = MTMDManager()
    
    private var model: OpaquePointer?
    private var context: OpaquePointer?
    private var visionContext: OpaquePointer?
    private var vocab: OpaquePointer?
    private var sampling: UnsafeMutablePointer<llama_sampler>?
    private var batch: llama_batch
    private var bitmaps: [MTMDBitmap] = []
    
    private var n_batch: Int32 = 512
    private var n_past: llama_pos = 0
    
    private var tmpls: common_chat_templates_ptr?
    
    private init() {
        self.batch = llama_batch_init(n_batch, 0, 1)
    }
    
    deinit {
        cleanup()
    }
    
    private func cleanup() {
        if let sampling = sampling {
            llama_sampler_free(sampling)
        }
        llama_batch_free(batch)
        if let model = model {
            llama_model_free(model)
        }
        if let context = context {
            llama_free(context)
        }
        if let visionContext = visionContext {
            mtmd_free(visionContext)
        }
        llama_backend_free()
    }
    
    func loadLanguageModel(_ path: String) throws {
        cleanup()
        
        llama_backend_init()
        var model_params = llama_model_default_params()
        
#if targetEnvironment(simulator)
        model_params.n_gpu_layers = 0
        print("Running on simulator, force use n_gpu_layers = 0")
#endif
        
        guard let model = llama_model_load_from_file(path, model_params) else {
            throw MTMDError.couldNotLoadModel
        }
        self.model = model
        self.vocab = llama_model_get_vocab(model)
        
        // Initialize chat templates
        let emptyString = std.string()
        tmpls = common_chat_templates_init(model, "vicuna", emptyString, emptyString)  // Use vicuna template by default
        if tmpls == nil {
            throw MTMDError.couldNotInitializeContext
        }
        
        let n_threads = max(1, min(8, ProcessInfo.processInfo.processorCount - 2))
        print("Using \(n_threads) threads")
        
        var ctx_params = llama_context_default_params()
        ctx_params.n_ctx = 4096
        ctx_params.n_threads = Int32(n_threads)
        ctx_params.n_threads_batch = Int32(n_threads)
        
        guard let context = llama_init_from_model(model, ctx_params) else {
            throw MTMDError.couldNotInitializeContext
        }
        self.context = context
        
        // Initialize sampler
        let sparams = llama_sampler_chain_default_params()
        guard let sampling = llama_sampler_chain_init(sparams) else {
            throw MTMDError.couldNotInitializeSampler
        }
        llama_sampler_chain_add(sampling, llama_sampler_init_temp(0.2))
        llama_sampler_chain_add(sampling, llama_sampler_init_dist(1234))
        self.sampling = sampling
    }
    
    func loadVisionModel(_ mmprojPath: String) throws {
        guard let model = model else {
            throw MTMDError.couldNotLoadModel
        }
        
        var params = mtmd_context_params_default()
        params.use_gpu = true
        params.print_timings = true
        params.n_threads = Int32(max(1, ProcessInfo.processInfo.processorCount - 2))
        
        guard let visionContext = mtmd_init_from_file(mmprojPath, model, params) else {
            throw MTMDError.couldNotLoadVisionModel
        }
        self.visionContext = visionContext
    }
    
    func processImage(_ image: UIImage) throws {
        // Convert UIImage to bitmap
        guard let cgImage = image.cgImage else {
            throw MTMDError.couldNotProcessImage
        }
        
        let width = cgImage.width
        let height = cgImage.height
        
        // Create a temporary buffer for RGBA data
        let rgbaBufferSize = width * height * 4
        let rgbaBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: rgbaBufferSize)
        defer { rgbaBuffer.deallocate() }
        
        // Create color space and context for RGBA
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: rgbaBuffer,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw MTMDError.couldNotProcessImage
        }
        
        // Draw image into context
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        
        // Create RGB buffer
        let rgbBufferSize = width * height * 3
        let rgbBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: rgbBufferSize)
        defer { rgbBuffer.deallocate() }
        
        // Convert RGBA to RGB
        for y in 0..<height {
            for x in 0..<width {
                let rgbaIndex = (y * width + x) * 4
                let rgbIndex = (y * width + x) * 3
                
                // Copy RGB channels, skip alpha
                rgbBuffer[rgbIndex] = rgbaBuffer[rgbaIndex]     // R
                rgbBuffer[rgbIndex + 1] = rgbaBuffer[rgbaIndex + 1] // G
                rgbBuffer[rgbIndex + 2] = rgbaBuffer[rgbaIndex + 2] // B
            }
        }
        
        // Create bitmap with the RGB data
        guard let bitmap = mtmd_bitmap_init(UInt32(width), UInt32(height), rgbBuffer) else {
            throw MTMDError.couldNotProcessImage
        }
        
        // Create MTMDBitmap wrapper
        let mtmdBitmap = MTMDBitmap(bitmap: bitmap)
        bitmaps.append(mtmdBitmap)
    }
    
    func clearBitmaps() {
        bitmaps.removeAll()
    }
    
    func evalMessage(_ msg: common_chat_msg, addBos: Bool = false) throws {
        guard let visionContext = visionContext, let context = context else {
            throw MTMDError.couldNotInitializeContext
        }
        
        // Format chat message using templates
        var tmpl_inputs = common_chat_templates_inputs()
        tmpl_inputs.messages = [msg]
        tmpl_inputs.add_generation_prompt = true
        tmpl_inputs.use_jinja = false  // jinja is buggy here
        
        let formatted_chat = withUnsafeMutablePointer(to: &tmpls!) { ptr in
            let rawPtr = UnsafeRawPointer(ptr).assumingMemoryBound(to: OpaquePointer.self).pointee
            return common_chat_templates_apply(rawPtr, tmpl_inputs)
        }
        let promptStr = withUnsafePointer(to: formatted_chat.prompt) { ptr in
            String(cString: UnsafeRawPointer(ptr).assumingMemoryBound(to: Int8.self))
        }
        print("formatted_chat.prompt: \(promptStr)")
        
        // Create input text
        var inputText = mtmd_input_text(
            text: promptStr,
            add_special: addBos,
            parse_special: true
        )
        
        // Create input chunks
        let chunks = mtmd_input_chunks_init()
        defer { mtmd_input_chunks_free(chunks) }
        
        // Convert bitmaps to C array
        let bitmapCount = bitmaps.count
        let bitmapPtrs = UnsafeMutablePointer<OpaquePointer?>.allocate(capacity: bitmapCount)
        defer { bitmapPtrs.deallocate() }
        
        for (index, bitmap) in bitmaps.enumerated() {
            bitmapPtrs[index] = bitmap.bitmap
        }
        
        // Tokenize
        let res = mtmd_tokenize(visionContext, chunks, &inputText, bitmapPtrs, bitmapCount)
        if res != 0 {
            throw MTMDError.couldNotEvaluateMessage
        }
        
        // Clear bitmaps after tokenization
        clearBitmaps()
        
        // Evaluate chunks
        var new_n_past: llama_pos = 0
        if mtmd_helper_eval_chunks(visionContext,
                                 context,
                                 chunks,
                                 n_past,
                                 0,  // seq_id
                                 n_batch,
                                 true,  // logits_last
                                 &new_n_past) != 0 {
            throw MTMDError.couldNotEvaluateMessage
        }
        
        n_past = new_n_past
    }
    
    func generateResponse(_ prompt: String, maxTokens: Int) throws -> String {
        var result = ""
        
        // Create chat message with <__Image__> token
        var msg = common_chat_msg()
        msg.role = "user"
        let promptString = std.string("<__Image__>\n" + prompt)
        msg.content = promptString
        
        try evalMessage(msg, addBos: true)
        
        var generated_tokens: [llama_token] = []
        
        for _ in 0..<maxTokens {
            guard let sampling = sampling, let context = context else {
                throw MTMDError.couldNotInitializeContext
            }
            
            let token_id = llama_sampler_sample(sampling, context, -1)
            
            generated_tokens.append(token_id)
            
            if llama_vocab_is_eog(vocab, token_id) {
                break
            }
            
            // Convert token to text
            let token_text = String(cString: token_to_piece(token: token_id) + [0])
            if !token_text.isEmpty {
                result += token_text
            }
            
            // Evaluate the token
            llama_batch_clear(&batch)
            llama_batch_add(&batch, token_id, n_past, [0], true)
            
            if llama_decode(context, batch) != 0 {
                throw MTMDError.couldNotEvaluateMessage
            }
            
            n_past += 1
        }
        
        return result
    }
    
    private func token_to_piece(token: llama_token) -> [CChar] {
        let result = UnsafeMutablePointer<Int8>.allocate(capacity: 8)
        result.initialize(repeating: Int8(0), count: 8)
        defer {
            result.deallocate()
        }
        let nTokens = llama_token_to_piece(vocab, token, result, 8, 0, false)
        
        if nTokens < 0 {
            let newResult = UnsafeMutablePointer<Int8>.allocate(capacity: Int(-nTokens))
            newResult.initialize(repeating: Int8(0), count: Int(-nTokens))
            defer {
                newResult.deallocate()
            }
            let nNewTokens = llama_token_to_piece(vocab, token, newResult, -nTokens, 0, false)
            let bufferPointer = UnsafeBufferPointer(start: newResult, count: Int(nNewTokens))
            return Array(bufferPointer)
        } else {
            let bufferPointer = UnsafeBufferPointer(start: result, count: Int(nTokens))
            return Array(bufferPointer)
        }
    }
} 
 
