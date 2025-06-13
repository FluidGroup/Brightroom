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

struct ClassicImageEditRootControlSwiftUIView: View {
  
  enum DisplayType {
    case filter
    case edit
  }
  
  @ObservedObject var viewModel: ClassicImageEditSwiftUIViewModel
  @Binding var navigationPath: NavigationPath
  @State private var displayType: DisplayType = .filter
  
  var body: some View {
    VStack(spacing: 0) {
      contentView
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      
      HStack(spacing: 0) {
        Button(action: {
          displayType = .filter
        }) {
          Text(viewModel.localizedStrings.filter)
            .font(.system(size: 17, weight: .bold))
            .foregroundColor(displayType == .filter ? .black : .black.opacity(0.5))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        
        Button(action: {
          displayType = .edit
        }) {
          Text(viewModel.localizedStrings.edit)
            .font(.system(size: 17, weight: .bold))
            .foregroundColor(displayType == .edit ? .black : .black.opacity(0.5))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }
      .frame(height: 50)
    }
    .background(Color(viewModel.style.control.backgroundColor))
  }
  
  @ViewBuilder
  private var contentView: some View {
    switch displayType {
    case .filter:
      ClassicImageEditPresetListControlSwiftUIView(
        viewModel: viewModel,
        navigationPath: $navigationPath
      )
      
    case .edit:
      ClassicImageEditEditMenuControlSwiftUIView(
        viewModel: viewModel,
        navigationPath: $navigationPath
      )
    }
  }
}

#Preview {
  ClassicImageEditRootControlSwiftUIView(
    viewModel: ClassicImageEditSwiftUIViewModel(
      editingStack: EditingStack(imageProvider: .init(image: UIImage(systemName: "photo")!)),
      options: .default,
      localizedStrings: .init()
    ),
    navigationPath: .constant(NavigationPath())
  )
}