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

/// The parametric document edited by PhotosCrop and `SwiftUICropView`.
///
/// Evaluation order is the order of `body`: global effects, then the brush
/// painted blur, then the final crop. Absent features are `nil` and contribute
/// nothing. The document is authored in the oriented, pre-crop source domain
/// whose size is `EditingStack.Loaded.imageSize`, at full resolution: evaluate
/// it over a source of that size (the export source, or the editing source
/// scaled up to it), never over the downsampled editing source directly.
///
/// Until leaf features lose their `id`, change an existing member in place
/// (for example `document.effects.exposure?.value = 0.5`) or rebuild members
/// through the initializers, which give them the document's fixed identities.
/// A member assigned directly carries its own identity, so an equal edit can
/// compare unequal (and, in a history, add a checkpoint). A member whose
/// `isEnabled` is false contributes nothing.
public struct PhotosCropDocument: Feature, Equatable {

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
    ///
    /// Members get the document's fixed identities, and disabled members are
    /// dropped. The preset keeps its identity.
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
      self = normalized()
    }

    public var body: some ImageEffect {
      // A member assigned after construction may be disabled; like the
      // identified model, a disabled member contributes nothing.
      let effects = normalized()
      effects.preset
      effects.exposure
      effects.brightness
      effects.temperature
      effects.highlights
      effects.shadows
      effects.saturation
      effects.contrast
      effects.sharpen
      effects.unsharpMask
      effects.gaussianBlur
      effects.fade
      effects.vignette
    }
  }

  /// Global effects, evaluated first.
  public var effects: Effects

  /// The brush-painted blur, evaluated after the global effects and before
  /// the final crop.
  ///
  /// Its stamps are in BrightroomParametric's working space (bottom-left
  /// origin, y-up) of the oriented, pre-crop source at full resolution.
  public var blurMask: LocalAdjustment<GaussianBlurFeature>?

  /// The final crop: the framing and clipping Feature of this document.
  public var crop: CropFeature

  /// A document with no effects and a crop that covers the whole image.
  ///
  /// - Parameter orientedImageSize: The oriented source pixel size,
  ///   `EditingStack.Loaded.imageSize`.
  public init(orientedImageSize: CGSize) {
    self.effects = .init()
    self.blurMask = nil
    self.crop = CropFeature(
      displayCropRect: CGRect(origin: .zero, size: orientedImageSize),
      imageSize: orientedImageSize
    )
    self.crop.id = MemberID.crop
  }

  /// Rebuilds a document, for example one restored by the host.
  ///
  /// The members' identities are normalized to the document's own, and an
  /// effect or a blur mask whose `isEnabled` is false is dropped, so a
  /// restored document compares and renders the same as one built in the
  /// editor. `crop` must be enabled; to restore an edit without a crop, pass a
  /// crop that covers the whole image.
  public init(
    effects: Effects = .init(),
    blurMask: LocalAdjustment<GaussianBlurFeature>? = nil,
    crop: CropFeature
  ) {
    self.effects = effects
    self.blurMask = blurMask
    self.crop = crop
    self = normalized()
  }

  public var body: some Feature {
    effects
    // A disabled blur contributes nothing, as `normalized()` drops it.
    blurMask?.content.isEnabled == true ? blurMask : nil
    crop
  }
}

extension PhotosCropDocument {

  /// Replaces the crop geometry with a crop-editing state.
  ///
  /// The rect is pixel-snapped through the engine snapper
  /// (`CropFeature(displayCropRect:…)`), the same one `CropView` commits
  /// through.
  public mutating func setCrop(_ crop: CropEditingState) {
    crop.write(to: &self.crop)
  }
}

// MARK: - Member identities

extension PhotosCropDocument {

  /// Fixed identities for the members the editor creates.
  ///
  /// Leaf features still carry an `id`, and synthesized equality compares it.
  /// Building every member with its fixed id and changing existing members in
  /// place keeps two documents built through the same operations equal, so
  /// re-applying a value adds no undo checkpoint and keeps canvas caches.
  /// Removed together with `FeatureID`.
  enum MemberID {
    static let exposure = FeatureID(rawValue: "brightroom.photos-crop.exposure")
    static let brightness = FeatureID(rawValue: "brightroom.photos-crop.brightness")
    static let temperature = FeatureID(rawValue: "brightroom.photos-crop.temperature")
    static let highlights = FeatureID(rawValue: "brightroom.photos-crop.highlights")
    static let shadows = FeatureID(rawValue: "brightroom.photos-crop.shadows")
    static let saturation = FeatureID(rawValue: "brightroom.photos-crop.saturation")
    static let contrast = FeatureID(rawValue: "brightroom.photos-crop.contrast")
    static let sharpen = FeatureID(rawValue: "brightroom.photos-crop.sharpen")
    static let unsharpMask = FeatureID(rawValue: "brightroom.photos-crop.unsharp-mask")
    static let gaussianBlur = FeatureID(rawValue: "brightroom.photos-crop.gaussian-blur")
    static let fade = FeatureID(rawValue: "brightroom.photos-crop.fade")
    static let vignette = FeatureID(rawValue: "brightroom.photos-crop.vignette")
    static let crop = FeatureID(rawValue: "brightroom.photos-crop.crop")
    /// Kept from the previous masking seed so the blur's identity does not
    /// change.
    static let blurMaskEffect = FeatureID(rawValue: "brightroom.crop-view.masking-blur")
    static let blurMaskBrush = FeatureID(rawValue: "brightroom.photos-crop.blur-mask.brush")
  }

  /// The document with every present member stamped with its fixed identity,
  /// and disabled effects and a disabled blur mask removed.
  ///
  /// Values that enter from outside the editor (a restored document) go
  /// through this once. The preset keeps the host's identity, since selection
  /// compares preset identifiers.
  func normalized() -> Self {
    var copy = self
    copy.effects = effects.normalized()

    if var blurMask, blurMask.content.isEnabled {
      blurMask.content.id = MemberID.blurMaskEffect
      if case var .brush(brush) = blurMask.maskTree.root {
        brush.id = MemberID.blurMaskBrush
        blurMask.maskTree.root = .brush(brush)
      }
      copy.blurMask = blurMask
    } else {
      copy.blurMask = nil
    }

    assert(crop.isEnabled, "PhotosCropDocument requires an enabled crop.")
    copy.crop.id = MemberID.crop
    return copy
  }
}

extension PhotosCropDocument.Effects {

  typealias MemberID = PhotosCropDocument.MemberID

  /// The effects with every present member stamped with its fixed identity,
  /// and disabled members removed. The preset keeps its identity.
  func normalized() -> Self {
    var copy = self
    copy.preset = Self.normalize(preset, isEnabled: \.isEnabled) { _ in }
    copy.exposure = Self.normalize(exposure, isEnabled: \.isEnabled) { $0.id = MemberID.exposure }
    copy.brightness = Self.normalize(brightness, isEnabled: \.isEnabled) { $0.id = MemberID.brightness }
    copy.temperature = Self.normalize(temperature, isEnabled: \.isEnabled) { $0.id = MemberID.temperature }
    copy.highlights = Self.normalize(highlights, isEnabled: \.isEnabled) { $0.id = MemberID.highlights }
    copy.shadows = Self.normalize(shadows, isEnabled: \.isEnabled) { $0.id = MemberID.shadows }
    copy.saturation = Self.normalize(saturation, isEnabled: \.isEnabled) { $0.id = MemberID.saturation }
    copy.contrast = Self.normalize(contrast, isEnabled: \.isEnabled) { $0.id = MemberID.contrast }
    copy.sharpen = Self.normalize(sharpen, isEnabled: \.isEnabled) { $0.id = MemberID.sharpen }
    copy.unsharpMask = Self.normalize(unsharpMask, isEnabled: \.isEnabled) { $0.id = MemberID.unsharpMask }
    copy.gaussianBlur = Self.normalize(gaussianBlur, isEnabled: \.isEnabled) { $0.id = MemberID.gaussianBlur }
    copy.fade = Self.normalize(fade, isEnabled: \.isEnabled) { $0.id = MemberID.fade }
    copy.vignette = Self.normalize(vignette, isEnabled: \.isEnabled) { $0.id = MemberID.vignette }
    return copy
  }

  private static func normalize<Member>(
    _ member: Member?,
    isEnabled: (Member) -> Bool,
    stamp: (inout Member) -> Void
  ) -> Member? {
    guard var member, isEnabled(member) else {
      return nil
    }
    stamp(&member)
    return member
  }
}
