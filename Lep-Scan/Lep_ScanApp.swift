import SwiftUI
import PhotosUI
import Vision
import ImageIO
import CoreLocation

@main
struct PhotosMetadataApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var jsonOutput = ""
    @State private var isProcessing = false
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Photos Metadata Extractor")
                .font(.title)
                .padding()
            
            PhotosPicker(
                selection: $selectedPhotos,
                maxSelectionCount: 10,
                matching: .images
            ) {
                Text("Select Photos")
                    .padding()
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(8)
            }
            .onChange(of: selectedPhotos) { _, newPhotos in
                if !newPhotos.isEmpty {
                    processPhotos()
                }
            }
            
            if isProcessing {
                ProgressView("Processing...")
                    .padding()
            }
            
            if !jsonOutput.isEmpty {
                ScrollView {
                    Text(jsonOutput)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .padding()
                        .background(Color.gray.opacity(0.1))
                        .cornerRadius(8)
                }
            }
        }
        .padding()
        .frame(minWidth: 600, minHeight: 400)
    }
    
    private func processPhotos() {
        isProcessing = true
        jsonOutput = ""
        
        Task {
            var results: [[String: Any]] = []
            
            for photo in selectedPhotos {
                if let data = try? await photo.loadTransferable(type: Data.self) {
                    let result = await extractMetadata(from: data)
                    results.append(result)
                }
            }
            
            await MainActor.run {
                do {
                    let jsonData = try JSONSerialization.data(withJSONObject: results, options: .prettyPrinted)
                    jsonOutput = String(data: jsonData, encoding: .utf8) ?? "Error formatting JSON"
                    
                    // Save JSON to predetermined file
                    saveJSONToFile(jsonData)
                    
                    // Call predetermined bash script
                    callBashScript()
                    
                } catch {
                    jsonOutput = "Error: \(error.localizedDescription)"
                }
                isProcessing = false
            }
        }
    }
  
  private func saveJSONToFile(_ jsonData: Data) {
    
    // Use the actual user's Documents folder, not sandboxed
    let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
    let documentsPath = homeDirectory.appendingPathComponent("Documents")
    let filePath = documentsPath.appendingPathComponent("photo_metadata.json")
      
      do {
          try jsonData.write(to: filePath)
          print("JSON saved to: \(filePath.path)")
      } catch {
          print("Failed to save JSON: \(error)")
      }
  }
  
  private func callBashScript() {
    // Use the actual user's Documents folder
    let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
    let documentsPath = homeDirectory.appendingPathComponent("Documents")
    let scriptPath = documentsPath.appendingPathComponent("process_photos.sh")

      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/bin/bash")
      process.arguments = [scriptPath.path]
      
      do {
          try process.run()
          print("Bash script executed: \(scriptPath.path)")
      } catch {
          print("Failed to execute bash script: \(error)")
      }
  }

    private func extractMetadata(from imageData: Data) async -> [String: Any] {
        var result: [String: Any] = [:]
        
        // Extract EXIF data
        if let imageSource = CGImageSourceCreateWithData(imageData as CFData, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [String: Any] {
            
            // Get datetime original
            if let exifDict = properties[kCGImagePropertyExifDictionary as String] as? [String: Any],
               let dateTime = exifDict[kCGImagePropertyExifDateTimeOriginal as String] as? String {
                result["datetimeoriginal"] = dateTime
            }
            
            // Get GPS coordinates
            if let gpsDict = properties[kCGImagePropertyGPSDictionary as String] as? [String: Any],
               let latitude = gpsDict[kCGImagePropertyGPSLatitude as String] as? Double,
               let longitude = gpsDict[kCGImagePropertyGPSLongitude as String] as? Double,
               let latRef = gpsDict[kCGImagePropertyGPSLatitudeRef as String] as? String,
               let lonRef = gpsDict[kCGImagePropertyGPSLongitudeRef as String] as? String {
                
                let finalLatitude = (latRef == "S") ? -latitude : latitude
                let finalLongitude = (lonRef == "W") ? -longitude : longitude
                
                result["latitude"] = finalLatitude
                result["longitude"] = finalLongitude
            }
        }
        
        // Scan for QR codes
        if let ciImage = CIImage(data: imageData) {
            let qrCodes = await scanQRCodes(in: ciImage)
            if !qrCodes.isEmpty {
                result["qrcodes"] = qrCodes
            }
        }
        
        return result
    }
    
    private func scanQRCodes(in image: CIImage) async -> [String] {
        return await withCheckedContinuation { continuation in
            let request = VNDetectBarcodesRequest { request, error in
                guard error == nil,
                      let results = request.results as? [VNBarcodeObservation] else {
                    continuation.resume(returning: [])
                    return
                }
                
                let qrCodes = results.compactMap { $0.payloadStringValue }
                continuation.resume(returning: qrCodes)
            }
            
            request.symbologies = [.QR]
            
            let handler = VNImageRequestHandler(ciImage: image, options: [:])
            DispatchQueue.global(qos: .userInitiated).async {
                try? handler.perform([request])
            }
        }
    }
}

#Preview {
    ContentView()
}
