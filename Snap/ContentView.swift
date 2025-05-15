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
    
    var body: some View {
        ZStack {
            if isSplashActive {
                SplashView(isActive: $isSplashActive)
            } else {
                CameraView()
            }
        }
    }
}

struct SplashView: View {
    @Binding var isActive: Bool
    @State private var loadingText = "Loading models..."
    
    var body: some View {
        VStack {
            Text("BaseweightSnap")
                .font(.largeTitle)
                .fontWeight(.bold)
            
            ProgressView()
                .padding()
            
            Text(loadingText)
                .font(.subheadline)
                .foregroundColor(.gray)
        }
        .onAppear {
            // Simulate model loading
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                withAnimation {
                    isActive = false
                }
            }
        }
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

struct PreviewView: View {
    let image: UIImage
    @State private var showTextInput = false
    @State private var inputText = ""
    @State private var showResponse = false
    @State private var responseText = ""
    
    var body: some View {
        VStack {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
            
            HStack(spacing: 20) {
                Button(action: { showTextInput = true }) {
                    Image(systemName: "text.bubble")
                        .font(.system(size: 24))
                }
                
                Button(action: { /* Generate description */ }) {
                    Image(systemName: "text.magnifyingglass")
                        .font(.system(size: 24))
                }
            }
            .padding()
        }
        .sheet(isPresented: $showTextInput) {
            TextInputView(text: $inputText, isPresented: $showTextInput)
        }
    }
}

struct TextInputView: View {
    @Binding var text: String
    @Binding var isPresented: Bool
    
    var body: some View {
        NavigationView {
            VStack {
                TextField("Enter text...", text: $text)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .padding()
                
                Button("Submit") {
                    // Handle text submission
                    isPresented = false
                }
                .padding()
            }
            .navigationTitle("Add Text")
            .navigationBarItems(trailing: Button("Cancel") {
                isPresented = false
            })
        }
    }
}

#Preview {
    ContentView()
}
