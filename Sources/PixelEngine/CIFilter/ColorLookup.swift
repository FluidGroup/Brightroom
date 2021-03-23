
import CoreImage

public final class ColorLookup: CIFilter {
  private let kernel: CIKernel

  public var inputImage: CIImage?

  override public init() {
    let url = _pixelengine_bundle.url(forResource: "default", withExtension: "metallib")!
    let data = try! Data(contentsOf: url)
    kernel = try! CIKernel(functionName: "colorLookup", fromMetalLibraryData: data)
    super.init()
  }

  @available(*, unavailable)
  required init?(coder aDecoder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
  
  private static let neutralLUTImage: CIImage = {
    let image = UIImage(named: "neutral-lut", in: _pixelengine_bundle, compatibleWith: nil)!
    return CIImage(image: image)!
  }()
  
  override public var outputImage: CIImage? {
    guard let inputImage = inputImage else { return nil }
    let result = kernel.apply(extent: inputImage.extent, roiCallback: { (index, destRect) -> CGRect in
      if (index == 0) {
        return destRect
      } else {
        return Self.neutralLUTImage.extent
      }
    }, arguments: [inputImage, inputColorLookupTable ?? Self.neutralLUTImage, inputIntensity])
    return result
  }

  private static let once: Void = {}()

  public var inputIntensity: CGFloat = 1 {
    didSet {}
  }

  public var inputColorLookupTable: CIImage? {
    didSet {}
  }
}
