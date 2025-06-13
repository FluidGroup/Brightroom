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

struct ClassicImageEditSharpenControlSwiftUIView: View, ClassicImageEditFilterControlSwiftUI {
  
  @ObservedObject var viewModel: ClassicImageEditSwiftUIViewModel
  @Binding var navigationPath: NavigationPath
  
  @State private var sliderValue: Double = 0
  
  var title: String {
    viewModel.localizedStrings.editSharpen
  }
  
  var body: some View {
    VStack(spacing: 0) {
      ClassicImageEditNavigationSwiftUIView(
        saveText: viewModel.localizedStrings.done,
        cancelText: viewModel.localizedStrings.cancel,
        onSave: {
          viewModel.editingStack.takeSnapshot()
          navigationPath.removeLast()
        },
        onCancel: {
          viewModel.editingStack.revertEdit()
          navigationPath.removeLast()
        }
      )
      
      Spacer()
      
      ClassicImageEditStepSliderSwiftUIView(
        value: $sliderValue,
        range: FilterSharpen.Params.sharpness,
        onChanged: { value in
          if value == 0 {
            viewModel.editingStack.set(filters: {
              $0.sharpen = nil
            })
          } else {
            viewModel.editingStack.set(filters: {
              var f = FilterSharpen()
              f.sharpness = value
              f.radius = 4
              $0.sharpen = f
            })
          }
        }
      )
      .padding(.horizontal, 20)
      .padding(.bottom, 20)
    }
    .background(Color(viewModel.style.control.backgroundColor))
    .onAppear {
      onAppearBase()
      loadCurrentValue()
    }
    .onDisappear {
      onDisappearBase()
    }
  }
  
  private func loadCurrentValue() {
    if let currentSharpen = viewModel.editingStack.state.loadedState?.currentEdit.filters.sharpen {
      sliderValue = currentSharpen.sharpness
    }
  }
}