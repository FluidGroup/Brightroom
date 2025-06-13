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
#if !COCOAPODS
import BrightroomEngine
#endif

struct ClassicImageEditMaskControlSwiftUIView: View {
  
  @ObservedObject var viewModel: ClassicImageEditSwiftUIViewModel
  @Binding var navigationPath: NavigationPath
  
  @State private var brushSize: Double = 0
  
  var body: some View {
    VStack(spacing: 0) {
      VStack(spacing: 16) {
        Button(action: {
          viewModel.editingStack.removeAllMasking()
        }) {
          Text(viewModel.localizedStrings.clear)
            .font(.system(size: 17, weight: .bold))
            .foregroundColor(Color(ClassicImageEditStyle.default.black))
        }
        .padding(.top, 16)
        
        VStack(spacing: 8) {
          Circle()
            .fill(Color.black.opacity(0.5))
            .frame(width: brushSizeInPixels, height: brushSizeInPixels)
            .animation(.easeOut(duration: 0.1), value: brushSize)
          
          HStack(spacing: 16) {
            Text(viewModel.localizedStrings.brushSizeSmall)
              .foregroundColor(.black)
            
            ClassicImageEditStepSliderSwiftUIView(
              value: $brushSize,
              range: .init(min: -0.5, max: 0.5),
              onChanged: { value in
                let size = 30 + (value * 60)
                viewModel.setBrushSize(CGFloat(size))
              }
            )
            
            Text(viewModel.localizedStrings.brushSizeLarge)
              .foregroundColor(.black)
          }
          .padding(.horizontal, 20)
        }
        
        Spacer()
      }
      
      ClassicImageEditNavigationSwiftUIView(
        saveText: viewModel.localizedStrings.done,
        cancelText: viewModel.localizedStrings.cancel,
        onSave: {
          viewModel.endMasking(save: true)
          viewModel.setMode(.preview)
          navigationPath.removeLast()
        },
        onCancel: {
          viewModel.endMasking(save: false)
          viewModel.setMode(.preview)
          navigationPath.removeLast()
        }
      )
    }
    .background(Color(viewModel.style.control.backgroundColor))
    .onAppear {
      viewModel.setMode(.masking)
    }
  }
  
  private var brushSizeInPixels: CGFloat {
    CGFloat(30 + (brushSize * 60))
  }
}

#Preview {
  ClassicImageEditMaskControlSwiftUIView(
    viewModel: ClassicImageEditSwiftUIViewModel(
      editingStack: EditingStack(imageProvider: .init(image: UIImage(systemName: "photo")!)),
      options: .default,
      localizedStrings: .init()
    ),
    navigationPath: .constant(NavigationPath())
  )
}