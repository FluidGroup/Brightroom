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

/// The feature edited by ImageEditor and `ImageEditorCanvas`.
///
/// Evaluation order is the order of `body`: global effects, then the brush
/// painted blur, then the final crop, then the vignette, which is centred on
/// the cropped picture. Absent features are `nil` and contribute nothing. The feature is authored in the oriented pixel coordinates of its
/// document's source image (`EditingDocument.source.pixelSize`), at full
/// resolution: evaluate it over a source of that size (the export source, or
/// the editing source scaled up to it), never over the downsampled editing
/// source directly.
///
/// Features compare by value: two features built from the same values are
/// equal, whichever way they were built. Edit one inside a
/// `ImageEditorDocument`, which keeps it with its source image.
public struct ImageEditorFeature: Feature, Equatable {

  /// Global, extent-preserving effects, evaluated in declaration order
  /// before the local blur and the final crop.
  ///
  /// Their radii resolve against the chain entry (the whole source), so a
  /// crop does not change them. The vignette, which the output frame decides,
  /// is `ImageEditorFeature.vignette`, evaluated after the crop.
  public struct Effects: ImageEffect, Equatable {

    public var preset: FilterFeature?
    public var exposure: ExposureFeature?
    public var brightness: BrightnessFeature?
    public var whiteBalance: WhiteBalanceFeature?
    public var highlights: HighlightsFeature?
    public var shadows: ShadowsFeature?
    public var saturation: SaturationFeature?
    public var contrast: ContrastFeature?
    public var sharpen: SharpenFeature?
    public var unsharpMask: UnsharpMaskFeature?
    public var gaussianBlur: GaussianBlurFeature?
    public var fade: FadeFeature?

    /// Creates global effects. Omitted effects are absent.
    public init(
      preset: FilterFeature? = nil,
      exposure: ExposureFeature? = nil,
      brightness: BrightnessFeature? = nil,
      whiteBalance: WhiteBalanceFeature? = nil,
      highlights: HighlightsFeature? = nil,
      shadows: ShadowsFeature? = nil,
      saturation: SaturationFeature? = nil,
      contrast: ContrastFeature? = nil,
      sharpen: SharpenFeature? = nil,
      unsharpMask: UnsharpMaskFeature? = nil,
      gaussianBlur: GaussianBlurFeature? = nil,
      fade: FadeFeature? = nil
    ) {
      self.preset = preset
      self.exposure = exposure
      self.brightness = brightness
      self.whiteBalance = whiteBalance
      self.highlights = highlights
      self.shadows = shadows
      self.saturation = saturation
      self.contrast = contrast
      self.sharpen = sharpen
      self.unsharpMask = unsharpMask
      self.gaussianBlur = gaussianBlur
      self.fade = fade
    }

    public var body: some ImageEffect {
      preset
      exposure
      brightness
      whiteBalance
      highlights
      shadows
      saturation
      contrast
      sharpen
      unsharpMask
      gaussianBlur
      fade
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
  /// The editor authors a brush mask, and the editing canvas previews and
  /// paints only that shape. Any other mask (for example an inverted or
  /// feathered brush) renders at export, but the canvas shows the image
  /// without it, and the editor cannot paint it: see `isLocalBlurPaintable`.
  public var localBlur: LocalAdjustmentFeature<GaussianBlurFeature>?

  /// The final crop: the framing and clipping Feature of this feature.
  ///
  /// It is authored in the oriented, pre-crop source at full resolution
  /// (`SourceImage.pixelSize`), in y-up coordinates. The editor and the
  /// canvas write pixel-aligned crops. A crop you assign is rendered as
  /// given, so align it first: create it with `CropFeature.fitted(to:imageSize:)`
  /// or `CropFeature(topLeftRect:imageSize:quarterTurn:straightenRadians:)`,
  /// or call `pixelAligned(imageSize:)`.
  public var crop: CropFeature

  /// The vignette, evaluated after the final crop.
  ///
  /// It is centred on the crop output and its radius is half the output's
  /// longer side, so it follows the crop: a crop never leaves the darkening
  /// off-centre. A vignette inside `effects.preset` is part of that look and
  /// stays before the crop.
  public var vignette: VignetteFeature?

  /// A feature with no effects and a crop that covers the whole image.
  ///
  /// - Parameter imageSize: The oriented pixel size of the image,
  ///   `SourceImage.pixelSize`.
  init(imageSize: CGSize) {
    self.effects = .init()
    self.localBlur = nil
    self.crop = CropFeature(
      topLeftRect: CGRect(origin: .zero, size: imageSize),
      imageSize: imageSize
    )
    self.vignette = nil
  }

  /// Rebuilds a feature, for example one restored by the host.
  ///
  /// A feature rebuilt from the same values compares and renders the same as
  /// the one built in the editor. To restore an edit without a crop, pass a
  /// crop that covers the whole image.
  public init(
    effects: Effects = .init(),
    localBlur: LocalAdjustmentFeature<GaussianBlurFeature>? = nil,
    crop: CropFeature,
    vignette: VignetteFeature? = nil
  ) {
    self.effects = effects
    self.localBlur = localBlur
    self.crop = crop
    self.vignette = vignette
  }

  public var body: some Feature {
    effects
    localBlur
    crop
    vignette
  }
}
