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

struct ClassicImageEditPresetListControlSwiftUIView: View {
  
  @ObservedObject var viewModel: ClassicImageEditSwiftUIViewModel
  @Binding var navigationPath: NavigationPath
  @State private var previewFilterPresets: [PreviewFilterPreset] = []
  @State private var selectedPreset: FilterPreset?
  @State private var originalImage: CIImage?
  
  var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 16) {
        PresetCell(
          title: viewModel.localizedStrings.control_preset_normal_name,
          image: originalImage,
          isSelected: selectedPreset == nil,
          action: {
            selectedPreset = nil
            viewModel.editingStack.set(filters: .init())
          }
        )
        
        ForEach(previewFilterPresets, id: \.filter.id) { preset in
          PresetCell(
            title: preset.name,
            image: preset.image,
            isSelected: selectedPreset?.id == preset.filter.id,
            action: {
              selectedPreset = preset.filter
              viewModel.editingStack.set(filters: preset.filter)
            }
          )
        }
      }
      .padding(.horizontal, 20)
    }
    .background(Color(viewModel.style.control.backgroundColor))
    .onReceive(viewModel.editingStack.$state) { state in
      if let loadedState = state.loadedState {
        originalImage = loadedState.thumbnailImage
        previewFilterPresets = loadedState.previewFilterPresets
      }
    }
  }
}

struct PresetCell: View {
  let title: String
  let image: CIImage?
  let isSelected: Bool
  let action: () -> Void
  
  @State private var uiImage: UIImage?
  
  var body: some View {
    Button(action: {
      let impactFeedback = UIImpactFeedbackGenerator(style: .light)
      impactFeedback.impactOccurred()
      action()
    }) {
      VStack(spacing: 8) {
        Group {
          if let uiImage = uiImage {
            Image(uiImage: uiImage)
              .resizable()
              .aspectRatio(contentMode: .fill)
          } else {
            Rectangle()
              .fill(Color.gray.opacity(0.3))
          }
        }
        .frame(width: 80, height: 80)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
          RoundedRectangle(cornerRadius: 8)
            .stroke(isSelected ? Color.black : Color.clear, lineWidth: 2)
        )
        
        Text(title)
          .font(.system(size: 12, weight: .medium))
          .foregroundColor(Color(ClassicImageEditStyle.default.black))
      }
    }
    .onAppear {
      loadImage()
    }
  }
  
  private func loadImage() {
    guard let ciImage = image else { return }
    
    DispatchQueue.global(qos: .userInitiated).async {
      let context = CIContext()
      if let cgImage = context.createCGImage(ciImage, from: ciImage.extent) {
        let uiImage = UIImage(cgImage: cgImage)
        DispatchQueue.main.async {
          self.uiImage = uiImage
        }
      }
    }
  }
}

#Preview {
  ClassicImageEditPresetListControlSwiftUIView(
    viewModel: ClassicImageEditSwiftUIViewModel(
      editingStack: EditingStack(imageProvider: .init(image: UIImage(systemName: "photo")!)),
      options: .default,
      localizedStrings: .init()
    ),
    navigationPath: .constant(NavigationPath())
  )
}