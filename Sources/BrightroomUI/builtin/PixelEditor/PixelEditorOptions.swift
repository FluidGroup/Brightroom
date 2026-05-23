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

import BrightroomEngine

public struct PixelEditorOptions: Sendable {

  public static let `default`: PixelEditorOptions = .init()

  public var croppingAspectRatio: PixelAspectRatio?
  public var isFaceDetectionEnabled: Bool
  public var ignoredEditMenus: Set<PixelEditorEditMenu>
  public var editMenus: [PixelEditorEditMenu]

  public init(
    croppingAspectRatio: PixelAspectRatio? = .square,
    isFaceDetectionEnabled: Bool = false,
    ignoredEditMenus: Set<PixelEditorEditMenu> = [],
    editMenus: [PixelEditorEditMenu] = PixelEditorEditMenu.allCases
  ) {
    self.croppingAspectRatio = croppingAspectRatio
    self.isFaceDetectionEnabled = isFaceDetectionEnabled
    self.ignoredEditMenus = ignoredEditMenus
    self.editMenus = editMenus
  }
}

public enum PixelEditorEditMenu: CaseIterable, Hashable, Sendable {
  case adjustment
  case mask
  case exposure
  case contrast
  case clarity
  case temperature
  case saturation
  case fade
  case highlights
  case shadows
  case vignette
  case sharpen
  case gaussianBlur
}
