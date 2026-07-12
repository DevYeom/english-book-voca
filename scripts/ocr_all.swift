import Foundation
import Vision
import ImageIO

func transformBoundingBox(_ box: CGRect, for orientation: CGImagePropertyOrientation) -> CGRect {
    switch orientation {
    case .up:
        return CGRect(x: box.origin.x, y: 1.0 - box.origin.y - box.size.height, width: box.size.width, height: box.size.height)
    case .down:
        return CGRect(x: 1.0 - box.origin.x - box.size.width, y: 1.0 - box.origin.y - box.size.height, width: box.size.width, height: box.size.height)
    case .right: // 6
        return CGRect(
            x: 1.0 - box.origin.y - box.size.height,
            y: 1.0 - box.origin.x - box.size.width,
            width: box.size.height,
            height: box.size.width
        )
    case .left: // 8
        return CGRect(
            x: box.origin.y,
            y: box.origin.x,
            width: box.size.height,
            height: box.size.width
        )
    default:
        return CGRect(x: box.origin.x, y: 1.0 - box.origin.y - box.size.height, width: box.size.width, height: box.size.height)
    }
}

func cleanText(_ lines: [String]) -> [String] {
    var cleaned: [String] = []
    let noiseWords = ["EXIT", "OFFY", "DELIVERIES", "IFFY", "FREE", "NO!", "LEVEL"]
    
    for line in lines {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { continue }
        
        // Skip purely numeric lines (page numbers)
        if CharacterSet.decimalDigits.isSuperset(of: CharacterSet(charactersIn: trimmed)) {
            continue
        }
        
        // Skip common page number formats like "I# 005", "010 BI", "IM 015", "INID 017" etc.
        let lower = trimmed.lowercased()
        if lower.contains("00") || lower.contains("01") || lower.contains("02") || lower.contains("03") || lower.contains("04") {
            if trimmed.count <= 10 {
                continue
            }
        }
        
        // Skip known short noise words (case insensitive)
        let upperTrimmed = trimmed.uppercased()
        if noiseWords.contains(upperTrimmed) {
            continue
        }
        
        // Skip line if it's just garbage chars or very short non-word symbols like "<0", "<°"
        if trimmed.count <= 2 {
            let cleanWord = trimmed.components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
            if cleanWord.isEmpty {
                continue
            }
        }
        
        cleaned.append(trimmed)
    }
    return cleaned
}

func performOCR(on imagePath: String) -> String {
    let url = URL(fileURLWithPath: imagePath)
    
    // Get orientation from image properties
    var orientation: CGImagePropertyOrientation = .up
    if let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
       let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
       let orientationValue = properties[kCGImagePropertyOrientation] as? UInt32 {
        orientation = CGImagePropertyOrientation(rawValue: orientationValue) ?? .up
    }
    
    var resultText = ""
    let semaphore = DispatchSemaphore(value: 0)
    
    let requestHandler = VNImageRequestHandler(url: url, orientation: orientation, options: [:])
    let request = VNRecognizeTextRequest { (request, error) in
        defer { semaphore.signal() }
        if let error = error {
            resultText = "Error: \(error.localizedDescription)"
            return
        }
        guard let observations = request.results as? [VNRecognizedTextObservation] else { return }
        
        struct TransformedObs {
            let text: String
            let visualBox: CGRect
        }
        
        let transformed = observations.map { obs -> TransformedObs in
            let text = obs.topCandidates(1).first?.string ?? ""
            let visualBox = transformBoundingBox(obs.boundingBox, for: orientation)
            return TransformedObs(text: text, visualBox: visualBox)
        }
        
        // Sort transformed observations:
        // 1. By page: left page (visualBox.origin.x < 0.5) first, then right page (visualBox.origin.x >= 0.5)
        // 2. Within each page: top-to-bottom (visualBox.origin.y)
        // 3. If y is very close: left-to-right (visualBox.origin.x)
        let sorted = transformed.sorted { (obs1, obs2) -> Bool in
            let isLeft1 = obs1.visualBox.origin.x < 0.5
            let isLeft2 = obs2.visualBox.origin.x < 0.5
            
            if isLeft1 != isLeft2 {
                return isLeft1
            }
            
            let box1 = obs1.visualBox
            let box2 = obs2.visualBox
            if abs(box1.origin.y - box2.origin.y) < 0.03 {
                return box1.origin.x < box2.origin.x
            }
            return box1.origin.y < box2.origin.y
        }
        
        let recognizedStrings = sorted.map { $0.text }
        let cleanedLines = cleanText(recognizedStrings)
        resultText = cleanedLines.joined(separator: "\n")
    }
    
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    
    do {
        try requestHandler.perform([request])
        semaphore.wait()
    } catch {
        resultText = "Error: \(error.localizedDescription)"
    }
    
    return resultText
}

let fileManager = FileManager.default
let path = "/Users/flip/workspace/english-study/converted"
do {
    let items = try fileManager.contentsOfDirectory(atPath: path)
    let jpgFiles = items.filter { $0.hasSuffix(".jpg") }
    
    // Sort files numerically by extracting digits (e.g. IMG_1371.jpg -> 1371)
    let sortedFiles = jpgFiles.sorted { (file1, file2) -> Bool in
        let num1 = Int(file1.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()) ?? 0
        let num2 = Int(file2.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()) ?? 0
        return num1 < num2
    }
    
    var outputContent = ""
    for file in sortedFiles {
        let fullPath = (path as NSString).appendingPathComponent(file)
        print("Processing \(file)...")
        let ocrResult = performOCR(on: fullPath)
        
        outputContent += "## \(file.replacingOccurrences(of: ".jpg", with: ""))\n\n"
        outputContent += ocrResult + "\n\n"
    }
    
    let outputPath = "/Users/flip/workspace/english-study/cowboy-and-birdbrain.md"
    try outputContent.write(toFile: outputPath, atomically: true, encoding: .utf8)
    print("Done! Saved to \(outputPath)")
} catch {
    print("Error: \(error)")
}
