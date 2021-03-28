//
// Copyright (c) 2018 Muukii <muukii.app@gmail.com>
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

#if !COCOAPODS
import BrightroomEngine
#endif

public struct ClassicImageEditOptions {
  
  public static let `default`: ClassicImageEditOptions = .init()
  
  public static var current: ClassicImageEditOptions = .init()
  
  public var croppingAspectRatio: PixelAspectRatio? = .square
  public var isFaceDetectionEnabled: Bool = false
  
  public var classes: Classes = .init()
  
  public init() {}
}

extension ClassicImageEditOptions {
  public struct Classes {
    
    public struct Control {
      
      public var colorCubeControl: ClassicImageEditColorCubeControlBase.Type = ColorCubeControl.self
      public var editMenuControl: ClassicImageEditEditMenuControlBase.Type = ClassicImageEditEditMenu.EditMenuControl.self
      public var rootControl: ClassicImageEditRootControlBase.Type = ClassicImageEditRootControl.self
      public var exposureControl: ClassicImageEditExposureControlBase.Type = ClassicImageEditExposureControl.self
      public var gaussianBlurControl: ClassicImageEditGaussianBlurControlBase.Type = ClassicImageEditGaussianBlurControl.self
      public var saturationControl: ClassicImageEditSaturationControlBase.Type = ClassicImageEditSaturationControl.self
      public var contrastControl: ClassicImageEditContrastControlBase.Type = ClassicImageEditContrastControl.self
      public var temperatureControl: ClassicImageEditTemperatureControlBase.Type = ClassicImageEditTemperatureControl.self
      public var vignetteControl: ClassicImageEditVignetteControlBase.Type = ClassicImageEditVignetteControl.self
      public var highlightsControl: ClassicImageEditHighlightsControlBase.Type = ClassicImageEditHighlightsControl.self
      public var shadowsControl: ClassicImageEditShadowsControlBase.Type = ClassicImageEditShadowsControl.self
      public var fadeControl: ClassicImageEditFadeControlBase.Type = ClassicImageEditFadeControl.self
      public var clarityControl: ClassicImageEditClarityControlBase.Type = ClassicImageEditClarityControl.self
      public var sharpenControl: ClassicImageEditSharpenControlBase.Type = ClassicImageEditSharpenControl.self
      
      public var ignoredEditMenu: [ClassicImageEditEditMenu] = []
      
      public init() {
        
      }
    }
    
    public var control: Control = .init()
    
    public init() {
      
    }
  }
}
