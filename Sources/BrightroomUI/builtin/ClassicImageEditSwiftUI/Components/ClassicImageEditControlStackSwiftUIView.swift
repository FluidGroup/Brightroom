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

struct ClassicImageEditControlStackSwiftUIView: View {
  
  @ObservedObject var viewModel: ClassicImageEditSwiftUIViewModel
  @State private var navigationPath = NavigationPath()
  
  var body: some View {
    NavigationStack(path: $navigationPath) {
      ClassicImageEditRootControlSwiftUIView(
        viewModel: viewModel,
        navigationPath: $navigationPath
      )
      .navigationDestination(for: ControlDestination.self) { destination in
        destinationView(for: destination)
      }
    }
  }
  
  @ViewBuilder
  private func destinationView(for destination: ControlDestination) -> some View {
    switch destination {
    case .editMenu:
      ClassicImageEditEditMenuControlSwiftUIView(
        viewModel: viewModel,
        navigationPath: $navigationPath
      )
      
    case .presetList:
      ClassicImageEditPresetListControlSwiftUIView(
        viewModel: viewModel,
        navigationPath: $navigationPath
      )
      
    case .exposure:
      ClassicImageEditExposureControlSwiftUIView(
        viewModel: viewModel,
        navigationPath: $navigationPath
      )
      
    case .contrast:
      ClassicImageEditContrastControlSwiftUIView(
        viewModel: viewModel,
        navigationPath: $navigationPath
      )
      
    case .clarity:
      ClassicImageEditClarityControlSwiftUIView(
        viewModel: viewModel,
        navigationPath: $navigationPath
      )
      
    case .temperature:
      ClassicImageEditTemperatureControlSwiftUIView(
        viewModel: viewModel,
        navigationPath: $navigationPath
      )
      
    case .saturation:
      ClassicImageEditSaturationControlSwiftUIView(
        viewModel: viewModel,
        navigationPath: $navigationPath
      )
      
    case .fade:
      ClassicImageEditFadeControlSwiftUIView(
        viewModel: viewModel,
        navigationPath: $navigationPath
      )
      
    case .highlights:
      ClassicImageEditHighlightsControlSwiftUIView(
        viewModel: viewModel,
        navigationPath: $navigationPath
      )
      
    case .shadows:
      ClassicImageEditShadowsControlSwiftUIView(
        viewModel: viewModel,
        navigationPath: $navigationPath
      )
      
    case .vignette:
      ClassicImageEditVignetteControlSwiftUIView(
        viewModel: viewModel,
        navigationPath: $navigationPath
      )
      
    case .sharpen:
      ClassicImageEditSharpenControlSwiftUIView(
        viewModel: viewModel,
        navigationPath: $navigationPath
      )
      
    case .gaussianBlur:
      ClassicImageEditGaussianBlurControlSwiftUIView(
        viewModel: viewModel,
        navigationPath: $navigationPath
      )
      
    case .crop:
      ClassicImageEditCropControlSwiftUIView(
        viewModel: viewModel,
        navigationPath: $navigationPath
      )
      
    case .mask:
      ClassicImageEditMaskControlSwiftUIView(
        viewModel: viewModel,
        navigationPath: $navigationPath
      )
      
    case .doodle:
      ClassicImageEditDoodleControlSwiftUIView(
        viewModel: viewModel,
        navigationPath: $navigationPath
      )
    }
  }
}

enum ControlDestination: Hashable {
  case editMenu
  case presetList
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
  case crop
  case mask
  case doodle
}