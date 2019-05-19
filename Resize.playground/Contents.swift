import UIKit

let image = #imageLiteral(resourceName: "nasa.jpg")
let data = image.pngData()!

let imageSource = CGImageSourceCreateWithData(data as CFData, [:] as CFDictionary)!

let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil)
let options: [NSString: Any] = [
  kCGImageSourceThumbnailMaxPixelSize: 100,
  kCGImageSourceCreateThumbnailFromImageAlways: true
]
let scaledImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary)

