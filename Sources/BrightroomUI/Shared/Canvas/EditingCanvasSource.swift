import BrightroomEngine
import CoreGraphics
import CoreImage

/// The prepared image an `EditingCanvasView` edits over.
struct EditingCanvasSource {

  /// The oriented, downsampled, GPU-resident editing source (zero origin).
  let editingSourceImage: CIImage

  /// The oriented source size at full resolution: the domain the feature is
  /// authored in.
  let imageSize: CGSize

  init(_ previewSource: PreviewSource) {
    self.editingSourceImage = previewSource.image
    self.imageSize = previewSource.source.pixelSize
  }

  init(editingSourceImage: CIImage, imageSize: CGSize) {
    self.editingSourceImage = editingSourceImage
    self.imageSize = imageSize
  }
}
