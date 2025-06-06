//
//  ContentView.swift
//  Snap
//
//  Created by Joe Bowser on 2025-05-15.
//

import SwiftUI
import AVFoundation

struct ContentView: View {
    @State private var isSplashActive = true
    @State private var showCamera = false
    @StateObject private var modelManager = ModelManager.shared
    
    var body: some View {
        ZStack {
            if isSplashActive {
                SplashView(isActive: $isSplashActive, modelManager: modelManager)
            } else {
                CameraView()
            }
        }
    }
}

struct SplashView: View {
    @Binding var isActive: Bool
    @ObservedObject var modelManager: ModelManager
    @State private var showCellularWarning = false
    @State private var showErrorAlert = false
    @State private var errorMessage = ""
    
    var body: some View {
        VStack(spacing: 20) {
            Image("Snap_Icon")
                .resizable()
                .scaledToFit()
                .frame(width: 200, height: 200)
                .padding(.top, 50)
                .shadow(radius: 5)
            
            Text("Baseweight Snap")
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .foregroundColor(.primary)
            
            if modelManager.isDownloading {
                VStack(spacing: 10) {
                    ProgressView(value: Double(modelManager.downloadProgress?.progress ?? 0), total: 100)
                        .progressViewStyle(LinearProgressViewStyle())
                        .frame(width: 200)
                    
                    Text("\(modelManager.downloadProgress?.progress ?? 0)%")
                        .font(.caption)
                        .foregroundColor(.gray)
                }
            } else {
                ProgressView()
                    .padding()
            }
            
            Text(modelManager.downloadProgress?.message ?? "Loading models...")
                .font(.subheadline)
                .foregroundColor(.gray)
            
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .onAppear {
            Task {
                await checkAndLoadModels()
            }
        }
        .alert("Error", isPresented: $showErrorAlert) {
            Button("OK") {
                // Exit the app
                exit(0)
            }
        } message: {
            Text(errorMessage)
        }
        .alert("Large File Download Warning", isPresented: $showCellularWarning) {
            Button("Continue") {
                Task {
                    await downloadModels()
                }
            }
            Button("Exit", role: .destructive) {
                exit(0)
            }
        } message: {
            Text("These are large files (total ~2.4GB). Please connect to WiFi for the best experience.\n\nWould you like to continue downloading anyway?")
        }
    }
    
    private func checkAndLoadModels() async {
        do {
            // Check if models are already downloaded
            let defaultModelName = modelManager.availableModels[0].name
            let modelsDownloaded = modelManager.isModelPairDownloaded(modelName: defaultModelName)
            
            if modelsDownloaded {
                // Load the downloaded models
                try await modelManager.loadDownloadedModels()
                
                // Only proceed to main screen after models are loaded
                if modelManager.isModelLoaded {
                    await MainActor.run {
                        withAnimation {
                            isActive = false
                        }
                    }
                } else {
                    showError("Failed to load models")
                }
            } else {
                // Check if on WiFi
                let isOnWifi = modelManager.isOnWiFi()
                if isOnWifi {
                    await downloadModels()
                } else {
                    showCellularWarning = true
                }
            }
        } catch {
            showError(error.localizedDescription)
        }
    }
    
    private func downloadModels() async {
        do {
            let defaultModelName = modelManager.availableModels[0].name
            try await modelManager.downloadModelPair(modelName: defaultModelName)
            
            // Models downloaded successfully, now load them
            try await modelManager.loadModelPair(modelName: defaultModelName)
            
            // Only proceed to main screen after models are loaded
            if modelManager.isModelLoaded {
                await MainActor.run {
                    withAnimation {
                        isActive = false
                    }
                }
            } else {
                showError("Failed to load models")
            }
        } catch {
            showError(error.localizedDescription)
        }
    }
    
    private func showError(_ message: String) {
        errorMessage = message
        showErrorAlert = true
    }
}

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    @Binding var isConfigured: Bool
    
    func makeUIView(context: Context) -> UIView {
        print("Creating preview view")
        let view = UIView()
        view.backgroundColor = .black
        
        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(previewLayer)
        
        print("Preview layer added to view")
        return view
    }
    
    func updateUIView(_ uiView: UIView, context: Context) {
        print("Updating preview view")
        if let previewLayer = uiView.layer.sublayers?.first as? AVCaptureVideoPreviewLayer {
            CATransaction.begin()
            CATransaction.setAnimationDuration(0)
            previewLayer.frame = uiView.bounds
            CATransaction.commit()
            print("Preview layer frame updated: \(uiView.bounds)")
        }
    }
}

class CameraManager: NSObject, ObservableObject {
    @Published var session = AVCaptureSession()
    @Published var isAuthorized = false
    @Published var currentPosition: AVCaptureDevice.Position = .back
    @Published var capturedImage: UIImage?
    @Published var isConfigured = false
    
    private var videoDeviceInput: AVCaptureDeviceInput?
    private let photoOutput = AVCapturePhotoOutput()
    private let sessionQueue = DispatchQueue(label: "sessionQueue")
    
    override init() {
        super.init()
        print("CameraManager initialized")
        checkPermissions()
    }
    
    func checkPermissions() {
        print("Checking camera permissions")
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            print("Camera authorized")
            DispatchQueue.main.async {
                self.isAuthorized = true
            }
        case .notDetermined:
            print("Requesting camera authorization")
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                print("Camera authorization response: \(granted)")
                DispatchQueue.main.async {
                    self?.isAuthorized = granted
                }
            }
        default:
            print("Camera not authorized")
            DispatchQueue.main.async {
                self.isAuthorized = false
            }
        }
    }
    
    func configure() {
        guard !isConfigured else { return }
        print("Configuring camera")
        setupCamera()
    }
    
    private func setupCamera() {
        print("Setting up camera")
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            
            print("Starting camera configuration")
            self.session.beginConfiguration()
            
            // Remove existing inputs and outputs
            self.session.inputs.forEach { self.session.removeInput($0) }
            self.session.outputs.forEach { self.session.removeOutput($0) }
            
            // Configure video input
            guard let videoDevice = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                           for: .video,
                                                           position: self.currentPosition) else {
                print("Failed to get video device")
                self.session.commitConfiguration()
                return
            }
            
            print("Got video device: \(videoDevice.localizedName)")
            
            do {
                let videoDeviceInput = try AVCaptureDeviceInput(device: videoDevice)
                if self.session.canAddInput(videoDeviceInput) {
                    self.session.addInput(videoDeviceInput)
                    self.videoDeviceInput = videoDeviceInput
                    print("Added video input")
                } else {
                    print("Could not add video input")
                }
                
                // Configure photo output
                if self.session.canAddOutput(self.photoOutput) {
                    self.session.addOutput(self.photoOutput)
                    self.photoOutput.isHighResolutionCaptureEnabled = true
                    self.photoOutput.maxPhotoQualityPrioritization = .quality
                    print("Added photo output")
                } else {
                    print("Could not add photo output")
                }
            } catch {
                print("Error setting up camera: \(error.localizedDescription)")
                self.session.commitConfiguration()
                return
            }
            
            self.session.commitConfiguration()
            print("Camera configuration committed")
            
            DispatchQueue.main.async {
                self.isConfigured = true
            }
        }
    }
    
    func startSession() {
        guard !session.isRunning else { return }
        sessionQueue.async { [weak self] in
            print("Starting capture session")
            self?.session.startRunning()
            print("Capture session running: \(self?.session.isRunning ?? false)")
        }
    }
    
    func stopSession() {
        guard session.isRunning else { return }
        sessionQueue.async { [weak self] in
            print("Stopping capture session")
            self?.session.stopRunning()
        }
    }
    
    func switchCamera() {
        print("Switching camera")
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            
            let newPosition = self.currentPosition == .back ? AVCaptureDevice.Position.front : AVCaptureDevice.Position.back
            print("Switching to camera position: \(newPosition == .front ? "front" : "back")")
            
            self.session.beginConfiguration()
            
            // Remove existing input
            if let currentInput = self.videoDeviceInput {
                self.session.removeInput(currentInput)
                print("Removed existing input")
            }
            
            // Configure new input
            guard let videoDevice = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                           for: .video,
                                                           position: newPosition) else {
                print("Failed to get video device for new position")
                self.session.commitConfiguration()
                return
            }
            
            do {
                let videoDeviceInput = try AVCaptureDeviceInput(device: videoDevice)
                if self.session.canAddInput(videoDeviceInput) {
                    self.session.addInput(videoDeviceInput)
                    self.videoDeviceInput = videoDeviceInput
                    print("Added new video input")
                } else {
                    print("Could not add new video input")
                }
            } catch {
                print("Error switching camera: \(error.localizedDescription)")
            }
            
            self.session.commitConfiguration()
            print("Camera switch configuration committed")
            
            DispatchQueue.main.async {
                self.currentPosition = newPosition
            }
        }
    }
    
    func capturePhoto() {
        print("Capturing photo")
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            let settings = AVCapturePhotoSettings()
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }
}

extension CameraManager: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error = error {
            print("Error capturing photo: \(error.localizedDescription)")
            return
        }
        
        guard let imageData = photo.fileDataRepresentation(),
              let image = UIImage(data: imageData) else {
            print("Error converting photo data to image")
            return
        }
        
        print("Photo captured successfully")
        DispatchQueue.main.async { [weak self] in
            self?.capturedImage = image
        }
    }
}

struct CameraView: View {
    @StateObject private var cameraManager = CameraManager()
    @State private var showImagePicker = false
    @State private var showPreview = false
    @State private var isShowingTextInput = false
    @State private var inputText = ""
    @State private var showResponse = false
    @State private var responseText = ""
    @State private var showWelcomeDialog = true
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if cameraManager.isAuthorized {
                    CameraPreviewView(session: cameraManager.session, isConfigured: $cameraManager.isConfigured)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .edgesIgnoringSafeArea(.all)
                        .onAppear {
                            print("Camera preview appeared")
                            cameraManager.configure()
                            cameraManager.startSession()
                        }
                        .onDisappear {
                            print("Camera preview disappeared")
                            cameraManager.stopSession()
                        }
                    
                    VStack {
                        Spacer()
                        
                        HStack(spacing: 20) {
                            Button(action: { showImagePicker = true }) {
                                Image(systemName: "photo.on.rectangle")
                                    .font(.system(size: 24))
                                    .foregroundColor(.white)
                            }
                            
                            Button(action: {
                                cameraManager.capturePhoto()
                            }) {
                                Circle()
                                    .fill(Color.white)
                                    .frame(width: 70, height: 70)
                            }
                            
                            Button(action: { cameraManager.switchCamera() }) {
                                Image(systemName: "camera.rotate")
                                    .font(.system(size: 24))
                                    .foregroundColor(.white)
                            }
                        }
                        .padding(.bottom, 30)
                    }
                } else {
                    VStack {
                        Text("Camera access is required")
                            .font(.headline)
                        Text("Please enable camera access in Settings")
                            .font(.subheadline)
                            .foregroundColor(.gray)
                    }
                }
            }
        }
        .sheet(isPresented: $showImagePicker) {
            ImagePicker(image: $cameraManager.capturedImage)
        }
        .onChange(of: cameraManager.capturedImage) { newImage in
            if newImage != nil {
                showPreview = true
            }
        }
        .sheet(isPresented: $showPreview) {
            if let image = cameraManager.capturedImage {
                PreviewView(image: image)
            }
        }
        .sheet(isPresented: $showWelcomeDialog) {
            WelcomeDialogView(isPresented: $showWelcomeDialog)
        }
    }
}

struct ImagePicker: UIViewControllerRepresentable {
    @Binding var image: UIImage?
    @Environment(\.presentationMode) var presentationMode
    
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.delegate = context.coordinator
        return picker
    }
    
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: ImagePicker
        
        init(_ parent: ImagePicker) {
            self.parent = parent
        }
        
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
            if let image = info[.originalImage] as? UIImage {
                parent.image = image
            }
            parent.presentationMode.wrappedValue.dismiss()
        }
    }
}

class StreamState: ObservableObject {
    @Published var text: String = ""
    @Published var updateCount: Int = 0  // Force view updates
    
    func append(_ token: String) {
        text += token
        updateCount += 1  // Force view update
    }
    
    func clear() {
        text = ""
        updateCount += 1
    }
}

struct PreviewView: View {
    let image: UIImage
    @State private var showTextInput = false
    @State private var inputText = ""
    @State private var isGenerating = false
    @State private var isProcessingImage = false
    @Environment(\.dismiss) private var dismiss
    @StateObject private var modelManager = ModelManager.shared
    @State private var responseText = ""
    @State private var updateCount = 0  // Force view updates
    
    var body: some View {
        VStack {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
            
            ScrollViewReader { proxy in
                ScrollView {
                    Text(responseText.isEmpty ? " " : responseText)  // Keep height when empty
                        .padding()
                        .id(updateCount)  // Force view update on each token
                        .id("bottom")  // ID for scrolling
                }
                .frame(maxHeight: 200)
                .background(Color(.systemBackground))
                .cornerRadius(10)
                .shadow(radius: 2)
                .padding()
                .onChange(of: responseText) { _ in
                    withAnimation {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
            }
            
            HStack(spacing: 20) {
                Button(action: { showTextInput = true }) {
                    Image(systemName: "text.bubble")
                        .font(.system(size: 24))
                }
                
                Button(action: { generateDescription() }) {
                    Image(systemName: "text.magnifyingglass")
                        .font(.system(size: 24))
                }
                
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 24))
                }
            }
            .padding()
            
            if isProcessingImage {
                VStack {
                    ProgressView()
                        .padding()
                    Text("Processing image...")
                        .font(.caption)
                        .foregroundColor(.gray)
                }
            } else if isGenerating {
                VStack {
                    ProgressView()
                        .padding()
                    Text("Generating response...")
                        .font(.caption)
                        .foregroundColor(.gray)
                }
            }
        }
        .sheet(isPresented: $showTextInput) {
            TextInputView(text: $inputText, isPresented: $showTextInput, onSubmit: { prompt in
                generateResponse(prompt: prompt)
            })
        }
    }
    
    private func generateDescription() {
        print("Generating description")
        generateResponse(prompt: "Can you describe this image")
    }
    
    private func generateResponse(prompt: String) {
        guard !isGenerating && !isProcessingImage else {
            print("Already generating response")
            return
        }
        
        guard modelManager.isModelLoaded else {
            print("Model not loaded")
            responseText = "Error: Model not loaded"
            return
        }
        
        print("Starting response generation with prompt: \(prompt)")
        isProcessingImage = true
        responseText = ""
        updateCount = 0
        
        Task {
            do {
                print("Processing image with prompt")
                try await modelManager.processImage(image, prompt: prompt)
                print("Image processed, starting text generation")
                
                isProcessingImage = false
                isGenerating = true
                
                // Use streaming for text generation
                _ = modelManager.generateResponseStream(
                    prompt: prompt,
                    maxTokens: 512,
                    onToken: { token in
                        print("Received token in UI: \(token)")
                        withAnimation {
                            responseText += token
                            updateCount += 1  // Force view update
                        }
                        print("Updated UI with token: \(token), new count: \(updateCount)")
                    },
                    onComplete: {
                        print("Generation complete")
                        isGenerating = false
                    }
                )
            } catch {
                print("Error generating response: \(error)")
                responseText = "Error: \(error.localizedDescription)"
                isProcessingImage = false
                isGenerating = false
            }
        }
    }
}

struct TextInputView: View {
    @Binding var text: String
    @Binding var isPresented: Bool
    var onSubmit: (String) -> Void
    
    var body: some View {
        NavigationView {
            VStack {
                TextField("Enter prompt...", text: $text)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .padding()
                
                Button("Submit") {
                    print("Submitting prompt: \(text)")
                    onSubmit(text)
                    isPresented = false
                }
                .padding()
            }
            .navigationTitle("Add Prompt")
            .navigationBarItems(trailing: Button("Cancel") {
                isPresented = false
            })
        }
    }
}

struct WelcomeDialogView: View {
    @Binding var isPresented: Bool
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Welcome to Baseweight Snap")
                        .font(.title)
                        .fontWeight(.bold)
                        .padding(.bottom, 10)
                    
                    Text("Here's how to use the app:")
                        .font(.headline)
                    
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .top) {
                            Text("•")
                            Text("Take a photo or select one from your gallery")
                        }
                        HStack(alignment: .top) {
                            Text("•")
                            Text("Add a prompt, or click the magnifying glass to describe")
                        }
                    }
                    .padding(.leading)
                    
                    Text("Copyright 2025 Baseweight Solutions Inc")
                        .font(.subheadline)
                        .foregroundColor(.gray)
                        .padding(.top, 20)
                    
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Powered by:")
                            .font(.caption)
                            .foregroundColor(.gray)
                        
                        HStack(alignment: .top) {
                            Text("•")
                            Text("llama.cpp - Copyright 2025 ggml.ai (MIT)")
                        }
                        .font(.caption)
                        .foregroundColor(.gray)
                        
                        HStack(alignment: .top) {
                            Text("•")
                            Text("SmolVLM2 - Copyright 2025 Hugging Face Inc (Apache 2)")
                        }
                        .font(.caption)
                        .foregroundColor(.gray)
                    }
                    .padding(.top, 10)
                }
                .padding()
            }
            .navigationBarItems(trailing: Button("Got it!") {
                isPresented = false
            })
        }
    }
}

#Preview {
    ContentView()
}
