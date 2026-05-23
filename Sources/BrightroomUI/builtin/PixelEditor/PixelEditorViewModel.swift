//
// Copyright (c) 2021 Muukii <muukii.app@gmail.com>
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
import Observation

import BrightroomEngine

@MainActor
@Observable
public final class PixelEditorViewModel {

  public enum Mode {
    case crop
    case masking
    case editing
    case preview
  }

  public let options: PixelEditorOptions

  public let editingStack: EditingStack

  public let localizedStrings: PixelEditorLocalizedStrings

  public var title: String = ""
  public var mode: Mode = .preview
  public var maskingBrushSize: MaskingBrushSize = .point(30)
  var drawnPaths: [DrawnPath] = []
  public var proposedCrop: EditingCrop? = nil

  public init(
    editingStack: EditingStack,
    options: PixelEditorOptions,
    localizedStrings: PixelEditorLocalizedStrings
  ) {
    self.localizedStrings = localizedStrings
    self.options = options
    self.editingStack = editingStack

    if options.isFaceDetectionEnabled {
      editingStack.cropModifier = .faceDetection(aspectRatio: options.croppingAspectRatio)
    } else if let aspectRatio = options.croppingAspectRatio {
      editingStack.cropModifier = .init { image, crop, completion in
        var new = crop
        new.updateCropExtentIfNeeded(toFitAspectRatio: aspectRatio)
        completion(new)
      }
    }
  }

  func setTitle(_ title: String) {
    self.title = title
  }

  func setMode(_ mode: Mode) {
    self.mode = mode

    switch mode {
    case .crop:
      title = localizedStrings.editAdjustment
    case .masking:
      title = localizedStrings.editMask
    case .editing:
      break
    case .preview:
      title = ""
    }
  }

  func endMasking(save: Bool) {
    if save {
      editingStack.takeSnapshot()
    } else {
      editingStack.revertEdit()
    }
  }

  func setBrushSize(_ brushSize: CGFloat) {
    maskingBrushSize = .point(brushSize)
  }

  func setDrawinPaths(_ drawnPaths: [DrawnPath]) {
    self.drawnPaths = drawnPaths
  }

  func endCrop(save: Bool) {
    if save {
      if let proposed = proposedCrop {
        editingStack.crop(proposed)
        editingStack.takeSnapshot()
      }

    } else {
      guard let loadedState = editingStack.loadedState else {
        assertionFailure()
        return
      }
      proposedCrop = loadedState.currentEdit.crop
    }
  }

  func setProposedCrop(_ proposedCrop: EditingCrop) {
    self.proposedCrop = proposedCrop
  }
}
