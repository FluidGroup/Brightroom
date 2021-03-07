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

import Foundation

public struct Options {
  
  public static let `default`: Options = .init()
  
  public static var current: Options = .init()
  
  public var classes: Classes = .init()
}

extension Options {
  public struct Classes {
    
    public struct Control {
      
      public var colorCubeControl: ColorCubeControlBase.Type = ColorCubeControl.self
      public var editMenuControl: EditMenuControlBase.Type = EditMenu.EditMenuControl.self
      public var rootControl: RootControlBase.Type = RootControl.self
      public var exposureControl: ExposureControlBase.Type = ExposureControl.self
      public var gaussianBlurControl: GaussianBlurControlBase.Type = GaussianBlurControl.self
      public var saturationControl: SaturationControlBase.Type = SaturationControl.self
      public var contrastControl: ContrastControlBase.Type = ContrastControl.self
      public var temperatureControl: TemperatureControlBase.Type = TemperatureControl.self
      public var vignetteControl: VignetteControlBase.Type = VignetteControl.self
      public var highlightsControl: HighlightsControlBase.Type = HighlightsControl.self
      public var shadowsControl: ShadowsControlBase.Type = ShadowsControl.self
      public var fadeControl: FadeControlBase.Type = FadeControl.self
      public var clarityControl: ClarityControlBase.Type = ClarityControl.self
      public var sharpenControl: SharpenControlBase.Type = SharpenControl.self
      
      public var ignoredEditMenu: [EditMenu] = []
      
      public init() {
        
      }
    }
    
    public var control: Control = .init()
    
    public init() {
      
    }
  }
}
