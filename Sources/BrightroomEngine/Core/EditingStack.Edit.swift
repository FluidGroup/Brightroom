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
import Foundation
import UIKit

extension EditingStack {
  // TODO: Consider more effective shape
  public struct Edit: Equatable {
    func makeFilters() -> [AnyFilter] {
      return filters.makeFilters()
    }
    
    public var imageSize: CGSize {
      crop.imageSize
    }
    
    /// In orientation.up
    public var crop: EditingCrop
    public var filters: Filters = .init()
    public var localAdjustments: [LocalAdjustmentLayer] = []
    public var drawings: Drawings = .init()
    
    init(crop: EditingCrop) {
      self.crop = crop
    }

    func isRenderingEquivalent(to other: Self) -> Bool {
      filters == other.filters
        && localAdjustments == other.localAdjustments
        && drawings == other.drawings
        && crop.isRenderingEquivalent(to: other.crop)
    }

    public struct LocalAdjustmentLayer: Equatable {
      public var id: UUID
      public var isEnabled: Bool
      public var effect: LocalAdjustmentEffect
      public var mask: LocalAdjustmentMask

      public init(
        id: UUID = UUID(),
        isEnabled: Bool = true,
        effect: LocalAdjustmentEffect,
        mask: LocalAdjustmentMask = .init()
      ) {
        self.id = id
        self.isEnabled = isEnabled
        self.effect = effect
        self.mask = mask
      }
    }

    public enum LocalAdjustmentEffect: Equatable {
      case gaussianBlur(radius: CGFloat)
      case exposure(value: Double)
    }

    public struct LocalAdjustmentMask: Equatable {
      public var strokes: [LocalAdjustmentStroke]

      public init(strokes: [LocalAdjustmentStroke] = []) {
        self.strokes = strokes
      }

      public var isEmpty: Bool {
        strokes.allSatisfy(\.stamps.isEmpty)
      }
    }

    public struct LocalAdjustmentStroke: Equatable {
      public var stamps: [CGPoint]
      public var brush: LocalAdjustmentBrush

      public init(
        stamps: [CGPoint],
        brush: LocalAdjustmentBrush
      ) {
        self.stamps = stamps
        self.brush = brush
      }
    }

    public struct LocalAdjustmentBrush: Equatable {
      public var size: CGFloat
      public var hardness: CGFloat
      public var opacity: CGFloat

      public init(
        size: CGFloat,
        hardness: CGFloat,
        opacity: CGFloat
      ) {
        self.size = size
        self.hardness = hardness
        self.opacity = opacity
      }
    }
    
    public struct Drawings: Equatable {
      // TODO: Remove Rect from DrawnPath
      public var blurredMaskPaths: [DrawnPath] = []
    }

    public struct Filters: Equatable {

      public var preset: FilterPreset?
      
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

      public var additionalFilters: [AnyFilter] = []

      func makeFilters() -> [AnyFilter] {
        return (
          ([

            /**
             Must be first filter since color-cube does not support wide range color.
             */
            preset?.asAny(),

            // Before
            exposure?.asAny(),
            brightness?.asAny(),
            temperature?.asAny(),
            highlights?.asAny(),
            shadows?.asAny(),
            saturation?.asAny(),
            contrast?.asAny(),

            // After
            sharpen?.asAny(),
            unsharpMask?.asAny(),
            gaussianBlur?.asAny(),
            fade?.asAny(),
            vignette?.asAny(),

          ] as [AnyFilter?])
          + additionalFilters
        )
        .compactMap { $0 }
      }
      
      public func apply(to ciImage: CIImage) -> CIImage {
        makeFilters().reduce(ciImage) { (image, filter) -> CIImage in
          filter.apply(to: image, sourceImage: image)
        }
      }
    }
  }
}
