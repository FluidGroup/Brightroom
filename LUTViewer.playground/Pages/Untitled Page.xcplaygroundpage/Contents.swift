import UIKit
import PixelEngine

let lutImage = #imageLiteral(resourceName: "LUT_A4_safe.png")
let target = #imageLiteral(resourceName: "sample.jpg")

let filter = FilterColorCube(
  name: "Filter",
  identifier: "1",
  lutImage: lutImage,
  dimension: 64
)

let source = CIImage(image: target)!
let result = filter.apply(to: source, sourceImage: source)
let uiimage = UIImage(ciImage: result)

let imageView = UIImageView(frame: .init(origin: .zero, size: source.extent.size))
imageView.contentMode = .scaleAspectFit
imageView.image = uiimage

source
imageView
