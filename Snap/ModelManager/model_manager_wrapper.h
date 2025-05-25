// Callback type for C wrapper
typedef void (*TokenCallback)(const char* token, void* user_data);

bool generate_response_stream(void* manager, const char* prompt, int max_tokens, TokenCallback callback, void* user_data); 