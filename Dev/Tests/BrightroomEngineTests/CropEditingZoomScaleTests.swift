import Testing
import Foundation
import CoreGraphics

@testable import BrightroomParametric
@testable import BrightroomUI

/// Guards the crop authoring zoom policy shared with blur-mask editing.
///
/// The final crop output becomes the masking tool's canvas. These tests keep
/// crop zoom from producing a canvas so small that viewport-sized brushes become
/// sub-pixel image-space strokes.
struct CropEditingZoomScaleTests {

  @Test func `Maximum zoom keeps crop output at the minimum maskable side`() {
    let imageSize = CGSize(width: 4000, height: 3000)
    let crop = CropEditingState(
      cropFeature: CropFeature.test(imageSize: imageSize),
      imageSize: imageSize
    )
    let guideSize = CGSize(width: 400, height: 300)

    let scales = crop.calculateZoomScale(visibleSize: guideSize)
    let cropOutputSizeAtMaximumZoom = CGSize(
      width: guideSize.width / scales.max / crop.imageToPlatterScale(),
      height: guideSize.height / scales.max / crop.imageToPlatterScale()
    )

    #expect(scales.max.isFinite)
    #expect(abs(scales.max - 9.375) < 0.0001)
    #expect(
      abs(min(cropOutputSizeAtMaximumZoom.width, cropOutputSizeAtMaximumZoom.height)
        - CropEditingState.minimumAuthoredCropOutputSideLength) < 0.0001
    )
  }

  @Test func `Maximum zoom does not require a crop output larger than the image`() {
    let imageSize = CGSize(width: 80, height: 60)
    let crop = CropEditingState(
      cropFeature: CropFeature.test(imageSize: imageSize),
      imageSize: imageSize
    )
    let guideSize = CGSize(width: 400, height: 300)

    let scales = crop.calculateZoomScale(visibleSize: guideSize)
    let cropOutputSizeAtMaximumZoom = CGSize(
      width: guideSize.width / scales.max / crop.imageToPlatterScale(),
      height: guideSize.height / scales.max / crop.imageToPlatterScale()
    )

    #expect(scales.max.isFinite)
    #expect(abs(scales.max - scales.min) < 0.0001)
    #expect(abs(cropOutputSizeAtMaximumZoom.width - imageSize.width) < 0.0001)
    #expect(abs(cropOutputSizeAtMaximumZoom.height - imageSize.height) < 0.0001)
  }
}
