import CoreImage

public enum CoreImageInspector {
  
  public static func hasIOSurface(image: CIImage) -> Bool {
    let debugDescription = image.debugDescription
    let result = debugDescription.contains("IOSurface")
    return result
  }
  
  public static func hasCGImage(image: CIImage) -> Bool {
    return image.cgImage != nil
  }
  
}
