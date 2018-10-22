//
//  Options.swift
//  PixelEditor
//
//  Created by Hiroshi Kimura on 2018/10/21.
//  Copyright © 2018 muukii. All rights reserved.
//

import Foundation

public var L10n: L10nStorage = .init()

public struct L10nStorage {
  
  public var done = "Done"
  public var save = "Save"
  public var normal = "Normal"
  public var cancel = "Cancel"
  public var filter = "Filter"
  public var edit = "Edit"
  
  public var editAdjustment = "Adjust"
  public var editMask = "Mask"
  public var editHighlights = "Highlights"
  public var editShadows = "Shadows"
  public var editSaturation = "Saturation"
  public var editContrast = "Contrast"
  public var editBlur = "Blur"
  public var editTemperature = "Temperature"
  public var editBrightness = "Brightness"
  public var editVignette = "Vignette"
  public var editFade = "Fade"
  public var editClarity = "Clarity"
  public var editSharpen = "Sharpen"
  
  public init() {
    
  }
}

public struct Options {
  
  public static let `default`: Options = .init()
  
  public var classes: Classes = .init()
}

extension Options {
  public struct Classes {
    
    public struct Control {
      
      public var colorCubeControl: ColorCubeControlViewBase.Type = ColorCubeControlView.self
      public var editMenuControl: EditMenuControlViewBase.Type = EditMenuControlView.self
      public var rootControl: RootControlViewBase.Type = RootControlView.self
      public var brightnessControl: BrightnessControlViewBase.Type = BrightnessControlView.self
      public var gaussianBlurControl: GaussianBlurControlViewBase.Type = GaussianBlurControlView.self
      public var saturationControl: SaturationControlViewBase.Type = SaturationControlView.self
      public var contrastControl: ContrastControlViewBase.Type = ContrastControlView.self
      public var temperatureControl: TemperatureControlViewBase.Type = TemperatureControlView.self
      public var vignetteControl: VignetteControlViewBase.Type = VignetteControlView.self
      public var highlightsControl: HighlightsControlViewBase.Type = HighlightsControlView.self
      public var shadowsControl: ShadowsControlViewBase.Type = ShadowsControlView.self
      public var fadeControl: FadeControlViewBase.Type = FadeControlView.self
      public var clarityControl: ClarityControlViewBase.Type = ClarityControlView.self
      public var sharpenControl: SharpenControlViewBase.Type = SharpenControlView.self
      
      public init() {
        
      }
    }
    
    public var control: Control = .init()
    
    public init() {
      
    }
  }
}
