#ifndef Snap_Bridging_Header_h
#define Snap_Bridging_Header_h

#ifdef __cplusplus
extern "C" {
#endif

// Callback type for streaming tokens
typedef void (*TokenCallback)(const char* token, void* user_data);

// Model Manager wrapper functions
void* create_model_manager(void);
void destroy_model_manager(void* manager);
bool load_language_model(void* manager, const char* model_path);
bool load_vision_model(void* manager, const char* mmproj_path);
bool initialize_context(void* manager);
bool initialize_batch(void* manager);
bool initialize_sampler(void* manager);
bool initialize_chat_template(void* manager, const char* template_name);
bool process_image(void* manager, const char* image_path);
char* generate_response(void* manager, const char* prompt, int max_tokens);
void free_response(char* response);
bool generate_response_stream(void* manager, const char* prompt, int max_tokens, TokenCallback callback, void* user_data);

#ifdef __cplusplus
}
#endif

#endif /* Snap_Bridging_Header_h */ 