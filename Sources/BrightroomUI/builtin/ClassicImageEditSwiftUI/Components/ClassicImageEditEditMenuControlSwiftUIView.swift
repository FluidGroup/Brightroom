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

struct ClassicImageEditEditMenuControlSwiftUIView: View {
  
  @ObservedObject var viewModel: ClassicImageEditSwiftUIViewModel
  @Binding var navigationPath: NavigationPath
  @State private var currentEdit: EditingStack.Edit?
  
  var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 16) {
        ForEach(displayedMenus, id: \.self) { menu in
          EditMenuButton(
            menu: menu,
            localizedStrings: viewModel.localizedStrings,
            hasChanges: hasChanges(for: menu),
            action: {
              handleMenuTap(menu)
            }
          )
        }
      }
      .padding(.horizontal, 36)
    }
    .background(Color(viewModel.style.control.backgroundColor))
    .onReceive(viewModel.editingStack.$state) { state in
      currentEdit = state.loadedState?.currentEdit
    }
  }
  
  private var displayedMenus: [ClassicImageEditEditMenu] {
    let ignoredEditMenus: Set<ClassicImageEditEditMenu> = viewModel.options.classes.control.ignoredEditMenus
    return viewModel.options.classes.control.editMenus.filter { !ignoredEditMenus.contains($0) }
  }
  
  private func hasChanges(for menu: ClassicImageEditEditMenu) -> Bool {
    guard let edit = currentEdit else { return false }
    
    switch menu {
    case .adjustment:
      return false
    case .mask:
      return !edit.drawings.blurredMaskPaths.isEmpty
    case .exposure:
      return edit.filters.exposure != nil
    case .contrast:
      return edit.filters.contrast != nil
    case .clarity:
      return edit.filters.unsharpMask != nil
    case .temperature:
      return edit.filters.temperature != nil
    case .saturation:
      return edit.filters.saturation != nil
    case .fade:
      return edit.filters.fade != nil
    case .highlights:
      return edit.filters.highlights != nil
    case .shadows:
      return edit.filters.shadows != nil
    case .vignette:
      return edit.filters.vignette != nil
    case .sharpen:
      return edit.filters.sharpen != nil
    case .gaussianBlur:
      return edit.filters.gaussianBlur != nil
    }
  }
  
  private func handleMenuTap(_ menu: ClassicImageEditEditMenu) {
    switch menu {
    case .adjustment:
      navigationPath.append(ControlDestination.crop)
    case .mask:
      navigationPath.append(ControlDestination.mask)
    case .exposure:
      navigationPath.append(ControlDestination.exposure)
    case .contrast:
      navigationPath.append(ControlDestination.contrast)
    case .clarity:
      navigationPath.append(ControlDestination.clarity)
    case .temperature:
      navigationPath.append(ControlDestination.temperature)
    case .saturation:
      navigationPath.append(ControlDestination.saturation)
    case .fade:
      navigationPath.append(ControlDestination.fade)
    case .highlights:
      navigationPath.append(ControlDestination.highlights)
    case .shadows:
      navigationPath.append(ControlDestination.shadows)
    case .vignette:
      navigationPath.append(ControlDestination.vignette)
    case .sharpen:
      navigationPath.append(ControlDestination.sharpen)
    case .gaussianBlur:
      navigationPath.append(ControlDestination.gaussianBlur)
    }
  }
}

struct EditMenuButton: View {
  let menu: ClassicImageEditEditMenu
  let localizedStrings: ClassicImageEditViewController.LocalizedStrings
  let hasChanges: Bool
  let action: () -> Void
  
  @State private var isPressed = false
  
  var body: some View {
    Button(action: {
      let impactFeedback = UIImpactFeedbackGenerator(style: .light)
      impactFeedback.impactOccurred()
      action()
    }) {
      VStack(spacing: 0) {
        Circle()
          .fill(Color.black)
          .frame(width: 4, height: 4)
          .opacity(hasChanges ? 1 : 0)
          .padding(.bottom, 8)
        
        Image(imageName(for: menu), bundle: Bundle.module)
          .resizable()
          .aspectRatio(contentMode: .fit)
          .frame(width: 50, height: 50)
          .foregroundColor(Color(ClassicImageEditStyle.default.black))
        
        Text(localizedText(for: menu))
          .font(.system(size: 12, weight: .medium))
          .foregroundColor(Color(ClassicImageEditStyle.default.black))
          .padding(.top, 12)
      }
    }
    .scaleEffect(isPressed ? 0.6 : 1.0)
    .opacity(isPressed ? 0.6 : 1.0)
    .animation(.easeInOut(duration: 0.16), value: isPressed)
    .onLongPressGesture(minimumDuration: 0, maximumDistance: .infinity, pressing: { pressing in
      isPressed = pressing
    }, perform: {})
  }
  
  private func imageName(for menu: ClassicImageEditEditMenu) -> String {
    switch menu {
    case .adjustment: return "adjustment"
    case .mask: return "mask"
    case .exposure: return "brightness"
    case .contrast: return "contrast"
    case .clarity: return "structure"
    case .temperature: return "temperature"
    case .saturation: return "saturation"
    case .fade: return "fade"
    case .highlights: return "highlights"
    case .shadows: return "shadows"
    case .vignette: return "vignette"
    case .sharpen: return "sharpen"
    case .gaussianBlur: return "blur"
    }
  }
  
  private func localizedText(for menu: ClassicImageEditEditMenu) -> String {
    switch menu {
    case .adjustment: return localizedStrings.editAdjustment
    case .mask: return localizedStrings.editMask
    case .exposure: return localizedStrings.editBrightness
    case .contrast: return localizedStrings.editContrast
    case .clarity: return localizedStrings.editClarity
    case .temperature: return localizedStrings.editTemperature
    case .saturation: return localizedStrings.editSaturation
    case .fade: return localizedStrings.editFade
    case .highlights: return localizedStrings.editHighlights
    case .shadows: return localizedStrings.editShadows
    case .vignette: return localizedStrings.editVignette
    case .sharpen: return localizedStrings.editSharpen
    case .gaussianBlur: return localizedStrings.editBlur
    }
  }
}

#Preview {
  ClassicImageEditEditMenuControlSwiftUIView(
    viewModel: ClassicImageEditSwiftUIViewModel(
      editingStack: EditingStack(imageProvider: .init(image: UIImage(systemName: "photo")!)),
      options: .default,
      localizedStrings: .init()
    ),
    navigationPath: .constant(NavigationPath())
  )
}