#include "model_manager.h"
#include <cstring>

extern "C" {

void* create_model_manager(void) {
    return &ModelManager::getInstance();
}

void destroy_model_manager(void* manager) {
    if (manager) {
        static_cast<ModelManager*>(manager)->cleanup();
    }
}

bool load_language_model(void* manager, const char* model_path) {
    if (!manager || !model_path) return false;
    return static_cast<ModelManager*>(manager)->loadLanguageModel(model_path);
}

bool load_vision_model(void* manager, const char* mmproj_path) {
    if (!manager || !mmproj_path) return false;
    return static_cast<ModelManager*>(manager)->loadVisionModel(mmproj_path);
}

bool initialize_context(void* manager) {
    if (!manager) return false;
    return static_cast<ModelManager*>(manager)->initializeContext();
}

bool initialize_batch(void* manager) {
    if (!manager) return false;
    return static_cast<ModelManager*>(manager)->initializeBatch();
}

bool initialize_sampler(void* manager) {
    if (!manager) return false;
    return static_cast<ModelManager*>(manager)->initializeSampler();
}

bool initialize_chat_template(void* manager, const char* template_name) {
    if (!manager) return false;
    return static_cast<ModelManager*>(manager)->initializeChatTemplate(template_name);
}

bool process_image(void* manager, const char* image_path) {
    if (!manager || !image_path) return false;
    return static_cast<ModelManager*>(manager)->processImage(image_path);
}

char* generate_response(void* manager, const char* prompt, int max_tokens) {
    if (!manager || !prompt) return nullptr;
    
    std::string response = static_cast<ModelManager*>(manager)->generateResponse(prompt, max_tokens);
    char* result = static_cast<char*>(malloc(response.length() + 1));
    if (result) {
        strcpy(result, response.c_str());
    }
    return result;
}

void free_response(char* response) {
    if (response) {
        free(response);
    }
}

} // extern "C" 