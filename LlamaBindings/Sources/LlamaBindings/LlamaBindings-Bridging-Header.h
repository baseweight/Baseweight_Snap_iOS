#ifndef LlamaBindings_Bridging_Header_h
#define LlamaBindings_Bridging_Header_h

#include "model_manager.h"
#include "llama.h"
#include "mtmd.h"
#include "common.h"

// Expose C++ types to Swift
typedef struct mtmd_bitmap {
    int32_t width;
    int32_t height;
    uint8_t* data;
} mtmd_bitmap;

typedef struct mtmd_input_text {
    const char* text;
    bool add_special;
    bool parse_special;
} mtmd_input_text;

// Function declarations
void llama_backend_init(void);
void llama_backend_free(void);
void llama_log_set(void (*callback)(ggml_log_level level, const char* text, void* user_data), void* user_data);

#endif /* LlamaBindings_Bridging_Header_h */ 