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

import SwiftUI
import Combine
#if !COCOAPODS
import BrightroomEngine
#endif

@MainActor
public final class ClassicImageEditSwiftUIViewModel: ObservableObject {
  
  public enum Mode {
    case crop
    case masking
    case editing
    case preview
  }
  
  @Published public private(set) var title: String = ""
  @Published public private(set) var mode: Mode = .preview
  @Published public private(set) var maskingBrushSize: CanvasView.BrushSize = .point(30)
  @Published public private(set) var isLoading: Bool = false
  
  public let options: ClassicImageEditOptions
  public let editingStack: EditingStack
  public let localizedStrings: ClassicImageEditViewController.LocalizedStrings
  public let style: ClassicImageEditStyle
  
  private var subscriptions: Set<AnyCancellable> = []
  private var proposedCrop: EditingCrop?
  
  public init(
    editingStack: EditingStack,
    options: ClassicImageEditOptions,
    localizedStrings: ClassicImageEditViewController.LocalizedStrings,
    style: ClassicImageEditStyle = .default
  ) {
    self.editingStack = editingStack
    self.options = options
    self.localizedStrings = localizedStrings
    self.style = style
    
    if options.isFaceDetectionEnabled {
      editingStack.cropModifier = .faceDetection(aspectRatio: options.croppingAspectRatio)
    } else if let aspectRatio = options.croppingAspectRatio {
      editingStack.cropModifier = .init { image, crop, completion in
        var new = crop
        new.updateCropExtentIfNeeded(toFitAspectRatio: aspectRatio)
        completion(new)
      }
    }
    
    editingStack.sinkState { [weak self] state in
      guard let self = self else { return }
      Task { @MainActor in
        self.isLoading = state.loadedState?.isLoading ?? false
      }
    }
    .store(in: &subscriptions)
  }
  
  public func setTitle(_ title: String) {
    self.title = title
  }
  
  public func setMode(_ mode: Mode) {
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
  
  public func endMasking(save: Bool) {
    if save {
      editingStack.takeSnapshot()
    } else {
      editingStack.revertEdit()
    }
  }
  
  public func setBrushSize(_ brushSize: CGFloat) {
    maskingBrushSize = .point(brushSize)
  }
  
  public func endCrop(save: Bool) {
    if save {
      if let proposed = proposedCrop {
        editingStack.crop(proposed)
        editingStack.takeSnapshot()
      }
    } else {
      if let loadedState = editingStack.state.loadedState {
        proposedCrop = loadedState.currentEdit.crop
      }
    }
  }
  
  public func setProposedCrop(_ proposedCrop: EditingCrop) {
    self.proposedCrop = proposedCrop
  }
}