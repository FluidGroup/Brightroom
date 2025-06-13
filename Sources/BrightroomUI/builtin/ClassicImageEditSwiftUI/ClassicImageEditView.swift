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

public struct ClassicImageEditView: View {
  
  @StateObject private var viewModel: ClassicImageEditSwiftUIViewModel
  
  public var onEndEditing: (EditingStack) -> Void = { _ in }
  public var onCancelEditing: () -> Void = { }
  
  public init(
    imageProvider: ImageProvider,
    options: ClassicImageEditOptions = .default,
    localizedStrings: ClassicImageEditViewController.LocalizedStrings = .init()
  ) {
    let editingStack = EditingStack(imageProvider: imageProvider)
    self._viewModel = StateObject(wrappedValue: ClassicImageEditSwiftUIViewModel(
      editingStack: editingStack,
      options: options,
      localizedStrings: localizedStrings
    ))
  }
  
  public init(
    editingStack: EditingStack,
    options: ClassicImageEditOptions = .default,
    localizedStrings: ClassicImageEditViewController.LocalizedStrings = .init()
  ) {
    self._viewModel = StateObject(wrappedValue: ClassicImageEditSwiftUIViewModel(
      editingStack: editingStack,
      options: options,
      localizedStrings: localizedStrings
    ))
  }
  
  public var body: some View {
    NavigationView {
      VStack(spacing: 0) {
        editArea
          .background(Color.white)
        
        controlArea
          .background(Color(viewModel.style.control.backgroundColor))
      }
      .ignoresSafeArea(.container, edges: .bottom)
      .navigationBarTitleDisplayMode(.inline)
      .navigationTitle(viewModel.title)
      .toolbar {
        toolbarContent
      }
    }
    .onAppear {
      viewModel.editingStack.start()
    }
  }
  
  @ViewBuilder
  private var editArea: some View {
    GeometryReader { geometry in
      let squareSize = min(geometry.size.width, geometry.size.height)
      
      ZStack {
        switch viewModel.mode {
        case .crop:
          CropViewWrapper(
            editingStack: viewModel.editingStack,
            croppingAspectRatio: viewModel.options.croppingAspectRatio
          )
          
        case .masking:
          ImagePreviewViewWrapper(editingStack: viewModel.editingStack)
          BlurryMaskingViewWrapper(
            editingStack: viewModel.editingStack,
            brushSize: viewModel.maskingBrushSize,
            isBlurryImageViewHidden: false
          )
          
        case .editing:
          ImagePreviewViewWrapper(editingStack: viewModel.editingStack)
          
        case .preview:
          ImagePreviewViewWrapper(editingStack: viewModel.editingStack)
          BlurryMaskingViewWrapper(
            editingStack: viewModel.editingStack,
            brushSize: viewModel.maskingBrushSize,
            isBlurryImageViewHidden: false
          )
          .allowsHitTesting(false)
        }
        
        if viewModel.isLoading {
          ZStack {
            Color.white.opacity(0.5)
            ProgressView()
              .progressViewStyle(CircularProgressViewStyle(tint: .gray))
              .scaleEffect(1.5)
          }
        }
      }
      .frame(width: squareSize, height: squareSize)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }
  
  @ViewBuilder
  private var controlArea: some View {
    ClassicImageEditControlStackSwiftUIView(viewModel: viewModel)
  }
  
  @ToolbarContentBuilder
  private var toolbarContent: some ToolbarContent {
    switch viewModel.mode {
    case .preview:
      ToolbarItem(placement: .navigationBarLeading) {
        Button(viewModel.localizedStrings.cancel) {
          onCancelEditing()
        }
      }
      
      ToolbarItem(placement: .navigationBarTrailing) {
        Button(viewModel.localizedStrings.done) {
          onEndEditing(viewModel.editingStack)
        }
        .fontWeight(.semibold)
        .disabled(viewModel.isLoading)
      }
      
    default:
      ToolbarItem(placement: .navigationBarLeading) {
        EmptyView()
      }
    }
  }
}

struct CropViewWrapper: UIViewRepresentable {
  let editingStack: EditingStack
  let croppingAspectRatio: PixelAspectRatio?
  
  func makeUIView(context: Context) -> CropView {
    let cropView = CropView(editingStack: editingStack, contentInset: .zero)
    cropView.setCropOutsideOverlay(
      .init()&>.do {
        $0.backgroundColor = .white
      }
    )
    cropView.setCropInsideOverlay(nil)
    cropView.isGuideInteractionEnabled = false
    cropView.isAutoApplyEditingStackEnabled = false
    cropView.setCroppingAspectRatio(croppingAspectRatio)
    return cropView
  }
  
  func updateUIView(_ uiView: CropView, context: Context) {
  }
}

struct ImagePreviewViewWrapper: UIViewRepresentable {
  let editingStack: EditingStack
  
  func makeUIView(context: Context) -> ImagePreviewView {
    return ImagePreviewView(editingStack: editingStack)
  }
  
  func updateUIView(_ uiView: ImagePreviewView, context: Context) {
  }
}

struct BlurryMaskingViewWrapper: UIViewRepresentable {
  let editingStack: EditingStack
  let brushSize: CanvasView.BrushSize
  let isBlurryImageViewHidden: Bool
  
  func makeUIView(context: Context) -> BlurryMaskingView {
    let view = BlurryMaskingView(editingStack: editingStack)
    view.isBackdropImageViewHidden = true
    return view
  }
  
  func updateUIView(_ uiView: BlurryMaskingView, context: Context) {
    uiView.setBrushSize(brushSize)
    uiView.isBlurryImageViewHidden = isBlurryImageViewHidden
  }
}

#Preview {
  ClassicImageEditView(
    imageProvider: .init(image: UIImage(systemName: "photo")!)
  )
}