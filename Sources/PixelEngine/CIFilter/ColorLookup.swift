
import CoreImage

public final class ColorLookup: CIFilter {
  private let kernel: CIColorKernel

  public var inputImage: CIImage?

  override public init() {
    let url = _pixelengine_bundle.url(forResource: "default", withExtension: "metallib")!
    let data = try! Data(contentsOf: url)
    kernel = try! CIColorKernel(functionName: "colorLookup", fromMetalLibraryData: data)
    super.init()
  }

  @available(*, unavailable)
  required init?(coder aDecoder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override public var outputImage: CIImage? {
    guard let inputImage = inputImage else { return nil }
    return kernel.apply(extent: inputImage.extent, arguments: [inputImage])
  }

  private static let once: Void = {}()

  public var inputIntensity: CGFloat = 1 {
    didSet {}
  }

  public var inputColorLookupTable: CIImage? {
    didSet {}
  }
}
