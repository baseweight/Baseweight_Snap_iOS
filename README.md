# BaseWeightSnap

BaseWeight Snap is an  application that atttempts to recreate the functionality of the the HuggingFace Snap application using llama.cpp,
originally implemented on Android, this was an exercise in seeing how cross-platform llama.cpp and libmtmd could be.

## Features

- Real-time inference of SmolVLM-256M  
- Native C++ processing for optimal performance

## Technical Details

### Dependencies

- llama.cpp with libmtmd for VLM functionality, we use this fork for building llama.xc_framework including libmtmd

### Build Requirements

- XCode

## Building the Project

1. Clone the repository
2. Build llama.xcframework using the llama.cpp fork found here

## License

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
