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
    @Binding var session: AVCaptureSession
    
    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: UIScreen.main.bounds)
        view.backgroundColor = .black
        
        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.frame = view.frame
        previewLayer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(previewLayer)
        
        return view
    }
    
    func updateUIView(_ uiView: UIView, context: Context) {
        if let previewLayer = uiView.layer.sublayers?.first as? AVCaptureVideoPreviewLayer {
            previewLayer.frame = uiView.frame
        }
    }
}

class CameraManager: ObservableObject {
    @Published var session = AVCaptureSession()
    @Published var isAuthorized = false
    @Published var currentPosition: AVCaptureDevice.Position = .back
    
    private var videoDeviceInput: AVCaptureDeviceInput?
    
    init() {
        checkPermissions()
    }
    
    func checkPermissions() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            self.isAuthorized = true
            self.setupCamera()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    self?.isAuthorized = granted
                    if granted {
                        self?.setupCamera()
                    }
                }
            }
        default:
            self.isAuthorized = false
        }
    }
    
    func setupCamera() {
        session.beginConfiguration()
        
        // Add video input
        guard let videoDevice = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                       for: .video,
                                                       position: currentPosition) else {
            session.commitConfiguration()
            return
        }
        
        do {
            let videoDeviceInput = try AVCaptureDeviceInput(device: videoDevice)
            if session.canAddInput(videoDeviceInput) {
                session.addInput(videoDeviceInput)
                self.videoDeviceInput = videoDeviceInput
            }
        } catch {
            print("Error setting up camera: \(error.localizedDescription)")
            session.commitConfiguration()
            return
        }
        
        session.commitConfiguration()
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.session.startRunning()
        }
    }
    
    func switchCamera() {
        session.beginConfiguration()
        
        // Remove existing input
        if let currentInput = videoDeviceInput {
            session.removeInput(currentInput)
        }
        
        // Switch camera position
        currentPosition = currentPosition == .back ? .front : .back
        
        // Add new input
        guard let videoDevice = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                       for: .video,
                                                       position: currentPosition) else {
            session.commitConfiguration()
            return
        }
        
        do {
            let videoDeviceInput = try AVCaptureDeviceInput(device: videoDevice)
            if session.canAddInput(videoDeviceInput) {
                session.addInput(videoDeviceInput)
                self.videoDeviceInput = videoDeviceInput
            }
        } catch {
            print("Error switching camera: \(error.localizedDescription)")
        }
        
        session.commitConfiguration()
    }
}

struct CameraView: View {
    @StateObject private var cameraManager = CameraManager()
    @State private var showImagePicker = false
    @State private var showPreview = false
    @State private var capturedImage: UIImage?
    @State private var isShowingTextInput = false
    @State private var inputText = ""
    @State private var showResponse = false
    @State private var responseText = ""
    
    var body: some View {
        ZStack {
            if cameraManager.isAuthorized {
                CameraPreviewView(session: $cameraManager.session)
                    .edgesIgnoringSafeArea(.all)
                
                VStack {
                    Spacer()
                    
                    HStack(spacing: 20) {
                        Button(action: { showImagePicker = true }) {
                            Image(systemName: "photo.on.rectangle")
                                .font(.system(size: 24))
                                .foregroundColor(.white)
                        }
                        
                        Button(action: { /* Capture photo */ }) {
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
        .sheet(isPresented: $showImagePicker) {
            ImagePicker(image: $capturedImage)
        }
        .sheet(isPresented: $showPreview) {
            if let image = capturedImage {
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
