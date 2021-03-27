//
// Copyright (c) 2021 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
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

import CoreImage

extension EditingStack {
  // TODO: Consider more effective shape
  public struct Edit: Equatable {
    func makeFilters() -> [Filtering] {
      return filters.makeFilters()
    }
    
    public var imageSize: CGSize {
      crop.imageSize
    }
    
    public var crop: EditingCrop
    public var filters: Filters = .init()
    public var drawings: Drawings = .init()
    
    init(crop: EditingCrop) {
      self.crop = crop
    }
    
    public struct Drawings: Equatable {
      // TODO: Remove Rect from DrawnPath
      public var blurredMaskPaths: [DrawnPath] = []
    }
    
    //
    //    public struct Light {
    //
    //    }
    //
    //    public struct Color {
    //
    //    }
    //
    //    public struct Effects {
    //
    //    }
    //
    //    public struct Detail {
    //
    //    }
    
    public struct Filters: Equatable {
      public var colorCube: FilterColorCube?
      
      public var brightness: FilterBrightness?
      public var contrast: FilterContrast?
      public var saturation: FilterSaturation?
      public var exposure: FilterExposure?
      
      public var highlights: FilterHighlights?
      public var shadows: FilterShadows?
      
      public var temperature: FilterTemperature?
      
      public var sharpen: FilterSharpen?
      public var gaussianBlur: FilterGaussianBlur?
      public var unsharpMask: FilterUnsharpMask?
      
      public var vignette: FilterVignette?
      public var fade: FilterFade?
      
      func makeFilters() -> [Filtering] {
        return ([
          // Before
          exposure,
          brightness,
          temperature,
          highlights,
          shadows,
          saturation,
          contrast,
          colorCube,
          
          // After
          sharpen,
          unsharpMask,
          gaussianBlur,
          fade,
          vignette,
        ] as [Filtering?])
        .compactMap { $0 }
      }
      
      func apply(to ciImage: CIImage) -> CIImage {
        makeFilters().reduce(ciImage) { (image, filter) -> CIImage in
          filter.apply(to: image, sourceImage: image)
        }
      }
    }
  }
}
