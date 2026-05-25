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

public struct PixelEditorLocalizedStrings: Sendable {

  @available(*, deprecated, renamed: "control_preset_normal_name")
  public var normal: String {
    get {
      control_preset_normal_name
    }
    set {
      control_preset_normal_name = newValue
    }
  }

  public var done = "Done"

  public var control_preset_normal_name = "Normal"

  public var cancel = "Cancel"
  public var filter = "Filter"
  public var edit = "Edit"

  public var editAdjustment = "Adjust"
  public var editMask = "Mask"
  public var editHighlights = "Highlights"
  public var editShadows = "Shadows"
  public var editSaturation = "Saturation"
  public var editContrast = "Contrast"
  public var editBlur = "Blur"
  public var editTemperature = "Temperature"
  public var editBrightness = "Brightness"
  public var editVignette = "Vignette"
  public var editFade = "Fade"
  public var editClarity = "Clarity"
  public var editSharpen = "Sharpen"
  public var clear = "Clear"

  public init() {}
}
