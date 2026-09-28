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

/// The document `ImageEditor` edits: a source image and its `ImageEditorFeature`,
/// with the edit's history.
public typealias ImageEditorDocument = EditingDocument<ImageEditorFeature>

extension EditingDocument where Content == ImageEditorFeature {

  /// Creates a document with no effects and a crop that covers the whole
  /// image.
  ///
  /// To start from a policy-decided crop such as a framed face, use
  /// `init(source:cropModifier:history:)`.
  public init(source: SourceImage, history: History = History()) {
    self.init(
      source: source,
      feature: ImageEditorFeature(imageSize: source.pixelSize),
      history: history
    )
  }
}

// MARK: - ImageEditor operations

/// The document operations of ImageEditor's controls.
///
/// They change `feature` only; the editor commits once per tool visit (see
/// `ImageEditorSession`).
extension EditingDocument where Content == ImageEditorFeature {

  /// Selects a filter preset, or clears it with nil.
  ///
  /// Selecting the preset that is already selected changes nothing, so the
  /// feature keeps the selected preset's value.
  mutating func selectFilterPreset(_ preset: FilterFeature?) {
    guard feature.effects.preset?.id != preset?.id else {
      return
    }
    feature.effects.preset = preset
  }

  /// Writes an adjustment slider value into the global effects.
  mutating func setAdjustmentValue(
    _ sliderValue: Double,
    parameter: ImageEditor.Adjustment
  ) {
    parameter.apply(sliderValue: sliderValue, to: &feature.effects)
  }

  /// Removes the local blur; the effects and the crop are unchanged.
  mutating func clearLocalBlur() {
    feature.localBlur = nil
  }

  /// Whether the final crop differs from ImageEditor's Reset target.
  ///
  /// Reset only restores the crop geometry, so this intentionally ignores
  /// effects and the local blur.
  func hasCropChanges(tolerance: CGFloat = 1) -> Bool {
    let crop = CropEditingState(cropFeature: feature.crop, imageSize: source.pixelSize)
    let initial = crop.makeInitial()
    return crop.rotation != initial.rotation
      || abs(crop.adjustmentAngle.radians - initial.adjustmentAngle.radians) > 0.0001
      || abs(crop.cropExtent.minX - initial.cropExtent.minX) > tolerance
      || abs(crop.cropExtent.minY - initial.cropExtent.minY) > tolerance
      || abs(crop.cropExtent.width - initial.cropExtent.width) > tolerance
      || abs(crop.cropExtent.height - initial.cropExtent.height) > tolerance
  }
}
