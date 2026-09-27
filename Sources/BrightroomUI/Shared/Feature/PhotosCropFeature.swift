//
// Copyright (c) 2026 Muukii <muukii.app@gmail.com>
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

import CoreGraphics

import BrightroomEngine
import BrightroomParametric

/// The feature edited by PhotosCrop and `SwiftUICropView`.
///
/// Evaluation order is the order of `body`: global effects, then the brush
/// painted blur, then the final crop. Absent features are `nil` and contribute
/// nothing. The feature is authored in the oriented pixel coordinates of its
/// document's image (`SourceImage.pixelSize`), at full resolution: evaluate it
/// over a source of that size (the export source, or the editing source
/// scaled up to it), never over the downsampled editing source directly.
///
/// Features compare by value: two features built from the same values are
/// equal, whichever way they were built. Edit one inside a
/// `EditingDocument<PhotosCropFeature>`, which keeps it with its image.
public struct PhotosCropFeature: Feature, Equatable {

  /// Global, extent-preserving effects, evaluated in declaration order.
  public struct Effects: ImageEffect, Equatable {

    public var preset: PresetFeature?
    public var exposure: ExposureFeature?
    public var brightness: BrightnessFeature?
    public var temperature: TemperatureFeature?
    public var highlights: HighlightsFeature?
    public var shadows: ShadowsFeature?
    public var saturation: SaturationFeature?
    public var contrast: ContrastFeature?
    public var sharpen: SharpenFeature?
    public var unsharpMask: UnsharpMaskFeature?
    public var gaussianBlur: GaussianBlurFeature?
    public var fade: FadeFeature?
    public var vignette: VignetteFeature?

    /// Creates global effects. Omitted effects are absent.
    public init(
      preset: PresetFeature? = nil,
      exposure: ExposureFeature? = nil,
      brightness: BrightnessFeature? = nil,
      temperature: TemperatureFeature? = nil,
      highlights: HighlightsFeature? = nil,
      shadows: ShadowsFeature? = nil,
      saturation: SaturationFeature? = nil,
      contrast: ContrastFeature? = nil,
      sharpen: SharpenFeature? = nil,
      unsharpMask: UnsharpMaskFeature? = nil,
      gaussianBlur: GaussianBlurFeature? = nil,
      fade: FadeFeature? = nil,
      vignette: VignetteFeature? = nil
    ) {
      self.preset = preset
      self.exposure = exposure
      self.brightness = brightness
      self.temperature = temperature
      self.highlights = highlights
      self.shadows = shadows
      self.saturation = saturation
      self.contrast = contrast
      self.sharpen = sharpen
      self.unsharpMask = unsharpMask
      self.gaussianBlur = gaussianBlur
      self.fade = fade
      self.vignette = vignette
    }

    public var body: some ImageEffect {
      preset
      exposure
      brightness
      temperature
      highlights
      shadows
      saturation
      contrast
      sharpen
      unsharpMask
      gaussianBlur
      fade
      vignette
    }
  }

  /// Global effects, evaluated first.
  public var effects: Effects

  /// The brush-painted blur, evaluated after the global effects and before
  /// the final crop.
  ///
  /// Its stamps are in BrightroomParametric's working space (bottom-left
  /// origin, y-up) of the oriented, pre-crop source at full resolution.
  ///
  /// The editor authors a mask tree rooted at a brush, and the editing canvas
  /// previews only that shape. A mask tree with another root (for example an
  /// inverted or feathered brush) renders at export, but the canvas shows the
  /// image without it.
  public var blurMask: LocalAdjustment<GaussianBlurFeature>?

  /// The final crop: the framing and clipping Feature of this feature.
  public var crop: CropFeature

  /// A feature with no effects and a crop that covers the whole image.
  ///
  /// - Parameter imageSize: The oriented pixel size of the image,
  ///   `SourceImage.pixelSize`.
  public init(imageSize: CGSize) {
    self.effects = .init()
    self.blurMask = nil
    self.crop = CropFeature(
      displayCropRect: CGRect(origin: .zero, size: imageSize),
      imageSize: imageSize
    )
  }

  /// Rebuilds a feature, for example one restored by the host.
  ///
  /// A feature rebuilt from the same values compares and renders the same as
  /// the one built in the editor. To restore an edit without a crop, pass a
  /// crop that covers the whole image.
  public init(
    effects: Effects = .init(),
    blurMask: LocalAdjustment<GaussianBlurFeature>? = nil,
    crop: CropFeature
  ) {
    self.effects = effects
    self.blurMask = blurMask
    self.crop = crop
  }

  public var body: some Feature {
    effects
    blurMask
    crop
  }
}

extension PhotosCropFeature {

  /// Replaces the crop geometry with a crop-editing state.
  ///
  /// The rect is pixel-snapped through the engine snapper
  /// (`CropFeature(displayCropRect:…)`), the same one `CropView` commits
  /// through.
  public mutating func setCrop(_ crop: CropEditingState) {
    self.crop = crop.makeCropFeature()
  }
}
