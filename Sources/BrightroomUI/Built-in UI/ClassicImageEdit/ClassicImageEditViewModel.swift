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

import UIKit
import Verge
#if !COCOAPODS
import BrightroomEngine
#endif

public final class ClassicImageEditViewModel: Equatable, StoreComponentType {
  public static func == (lhs: ClassicImageEditViewModel, rhs: ClassicImageEditViewModel) -> Bool {
    lhs === rhs
  }

  public enum Mode {
    case crop
    case masking
    case editing
    case preview
  }

  public struct State: Equatable {
    public var editingState: Changes<EditingStack.State>

    public fileprivate(set) var title: String = ""
    public fileprivate(set) var mode: Mode = .preview

    public fileprivate(set) var maskingBrushSize: CanvasView.BrushSize = .point(30)

    // TODO: Rename
    fileprivate var drawnPaths: [DrawnPath] = []
    fileprivate(set) var proposedCrop: EditingCrop?
  }

  public let options: ClassicImageEditOptions

  public let store: DefaultStore

  public let editingStack: EditingStack

  private var subscriptions: Set<VergeAnyCancellable> = .init()

  public let localizedStrings: ClassicImageEditViewController.LocalizedStrings

  public init(
    editingStack: EditingStack,
    options: ClassicImageEditOptions,
    localizedStrings: ClassicImageEditViewController.LocalizedStrings
  ) {
    self.localizedStrings = localizedStrings
    self.options = options
    self.editingStack = editingStack
    store = .init(initialState: .init(editingState: editingStack.state))

    if options.isFaceDetectionEnabled {
      editingStack.cropModifier = .faceDetection(aspectRatio: options.croppingAspectRatio)
    } else if let aspectRatio = options.croppingAspectRatio {
      editingStack.cropModifier = .init { image, crop, completion in
        var new = crop
        new.updateCropExtentIfNeeded(by: aspectRatio)
        completion(new)
      }
    }

    editingStack.assign(to: assignee(\.editingState)).store(in: &subscriptions)
  }

  func setTitle(_ title: String) {
    commit {
      $0.title = title
    }
  }

  func setMode(_ mode: Mode) {
    commit {
      $0.mode = mode

      switch mode {
      case .crop:
        $0.title = localizedStrings.editAdjustment
      case .masking:
        $0.title = localizedStrings.editMask
      case .editing:
        break
      case .preview:
        $0.title = ""
      }
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
    commit {
      $0.maskingBrushSize = .point(brushSize)
    }
  }

  func setDrawinPaths(_ drawnPaths: [DrawnPath]) {
    commit {
      $0.drawnPaths = drawnPaths
    }
  }

  func endCrop(save: Bool) {
    if save {
      if let proposed = state.proposedCrop {
        editingStack.crop(proposed)
        editingStack.takeSnapshot()
      }

    } else {
      commit {
        guard let loadedState = $0.editingState.loadedState else {
          assertionFailure()
          return
        }
        $0.proposedCrop = loadedState.currentEdit.crop
      }
    }
  }

  func setProposedCrop(_ proposedCrop: EditingCrop) {
    commit {
      $0.proposedCrop = proposedCrop
    }
  }
}
