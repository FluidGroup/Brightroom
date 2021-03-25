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
import PixelEngine
#endif

public final class PixelEditViewModel: Equatable, StoreComponentType {
  
  public static func == (lhs: PixelEditViewModel, rhs: PixelEditViewModel) -> Bool {
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
    
  public let options: PixelEditOptions
  
  public let store: DefaultStore
  
  public let editingStack: EditingStack
  
  private var subscriptions: Set<VergeAnyCancellable> = .init()
  
  public let doneButtonTitle: String
  
  public init(
    editingStack: EditingStack,
    doneButtonTitle: String = L10n.done,
    options: PixelEditOptions = .default
  ) {
    
    self.doneButtonTitle = doneButtonTitle
    self.options = options
    self.editingStack = editingStack
    self.store = .init(initialState: .init(editingState: editingStack.state))
    
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
        $0.title = L10n.editAdjustment
      case .masking:
        $0.title = L10n.editMask
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
    
    guard save else {
      commit {
        guard let loadedState = $0.editingState.loadedState else {
          assertionFailure()
          return
        }
        $0.proposedCrop = loadedState.currentEdit.crop
      }
      return
    }
        
    guard let proposed = state.proposedCrop else {
      return
    }
    
    editingStack.crop(proposed)
    editingStack.takeSnapshot()
    
  }
  
  func setProposedCrop(_ proposedCrop: EditingCrop) {
    commit {
      $0.proposedCrop = proposedCrop
    }
  }
  
}
