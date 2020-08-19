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

import CoreImage

#if canImport(UIKit)
import UIKit
#endif

public enum ImageSource {
  case previewOnly(CIImage)
  case editable(CIImage)

  var image: CIImage {
    switch self {
    case .editable(let image):
      return image
    case .previewOnly(let image)  :
      return image
    }
  }
}

public protocol ImageSourceType {
  func setImageUpdateListener(_ listner: @escaping (ImageSourceType) -> Void)
  var imageSource: ImageSource? { get }
}

#if canImport(Photos)
import Photos

public final class PHAssetImageSource: ImageSourceType {
  private var listner: ((ImageSourceType) -> Void) = { _ in }
  public var imageSource: ImageSource? {
    didSet {
      listner(self)
    }
  }

  public init(_ asset: PHAsset) {
    let previewRequestOptions = PHImageRequestOptions()
    previewRequestOptions.deliveryMode = .highQualityFormat
    previewRequestOptions.isNetworkAccessAllowed = true
    previewRequestOptions.version = .current
    previewRequestOptions.resizeMode = .fast
    let finalImageRequestOptions = PHImageRequestOptions()
    finalImageRequestOptions.deliveryMode = .highQualityFormat
    finalImageRequestOptions.isNetworkAccessAllowed = true
    finalImageRequestOptions.version = .current
    finalImageRequestOptions.resizeMode = .none
    //TODO cancellation, Error handeling

    PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 360, height: 360), contentMode: .aspectFit, options: previewRequestOptions) { [weak self] (image, _) in
      guard let image = image, let self = self else { return }
      let ciImage = image.ciImage ?? CIImage(cgImage: image.cgImage!)
      self.imageSource = .previewOnly(ciImage)
    }
    PHImageManager.default().requestImage(for: asset, targetSize: PHImageManagerMaximumSize, contentMode: .aspectFit, options: finalImageRequestOptions) { [weak self] (image, _) in
      guard let image = image, let self = self else { return }
      let ciImage = image.ciImage ?? CIImage(cgImage: image.cgImage!)
      self.imageSource = .editable(ciImage)
    }
  }

  public func setImageUpdateListener(_ listner: @escaping (ImageSourceType) -> Void) {
    if imageSource != nil {
      listner(self)
    }
    self.listner = listner
  }
}

#endif

public struct StaticImageSource: ImageSourceType {
  private let image: CIImage
  public var imageSource: ImageSource? {
    return .editable(image)
  }

  public func setImageUpdateListener(_ listner: @escaping (ImageSourceType) -> Void) {
    listner(self)
  }


  #if os(iOS)

  public init(source: UIImage) {

    let image = CIImage(image: source)!
    let fixedOriantationImage = image.oriented(forExifOrientation: imageOrientationToTiffOrientation(source.imageOrientation))

    self.init(source: fixedOriantationImage)
  }

  #endif

  public init(source: CIImage) {

    precondition(source.extent.origin == .zero)
    self.image = source
  }

}

fileprivate func imageOrientationToTiffOrientation(_ value: UIImage.Orientation) -> Int32 {
  switch value{
  case .up:
    return 1
  case .down:
    return 3
  case .left:
    return 8
  case .right:
    return 6
  case .upMirrored:
    return 2
  case .downMirrored:
    return 4
  case .leftMirrored:
    return 5
  case .rightMirrored:
    return 7
  @unknown default:
    fatalError()
  }
}
