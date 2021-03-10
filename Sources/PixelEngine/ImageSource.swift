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

import CoreImage
import Verge

#if canImport(UIKit)
import UIKit
#endif

#if canImport(Photos)
import Photos
#endif

public struct EditingCrop: Equatable {
  public enum Rotation: Equatable, CaseIterable {
    /// 0 degree - default
    case angle_0

    /// 90 degree
    case angle_90

    /// 180 degree
    case angle_180

    /// 270 degree
    case angle_270

    public var transform: CGAffineTransform {
      switch self {
      case .angle_0:
        return .identity
      case .angle_90:
        return .init(rotationAngle: -CGFloat.pi / 2)
      case .angle_180:
        return .init(rotationAngle: -CGFloat.pi)
      case .angle_270:
        return .init(rotationAngle: CGFloat.pi / 2)
      }
    }

    public func next() -> Self {
      switch self {
      case .angle_0: return .angle_90
      case .angle_90: return .angle_180
      case .angle_180: return .angle_270
      case .angle_270: return .angle_0
      }
    }
  }

  /**
   Returns aspect ratio.
   Would not be affected by rotation.
   */
  public var preferredAspectRatio: PixelAspectRatio?

  /// The dimensions in pixel for the image.
  public var imageSize: CGSize

  /// The rectangle that specifies the extent of the cropping.
  public var cropExtent: CGRect

  /// The angle that specifies rotation for the image.
  public var rotation: Rotation = .angle_0
  
  public private(set) var originalWidth: CGFloat

  public init(from ciImage: CIImage) {
    self.init(
      imageSize: .init(image: ciImage),
      cropRect: .init(origin: .zero, size: ciImage.extent.size)
    )
  }

  public init(imageSize: CGSize, cropRect: CGRect, rotation: Rotation = .angle_0) {
    self.imageSize = imageSize
    cropExtent = cropRect
    self.rotation = rotation
    self.originalWidth = imageSize.width
  }

  public func makeInitial() -> Self {
    .init(imageSize: imageSize, cropRect: .init(origin: .zero, size: imageSize))
  }

  /**
   Set new aspect ratio with updating cropping extent.
   Currently, the cropping extent changes to maximum size in the size of image.

   - TODO: Resizing cropping extent with keeping area by new aspect ratio.
   */
  public mutating func updateCropExtent(by newAspectRatio: PixelAspectRatio) {
    let maxSize = newAspectRatio.sizeThatFits(in: imageSize)

    cropExtent = .init(
      origin: .init(
        x: (imageSize.width - maxSize.width) / 2,
        y: (imageSize.height - maxSize.height) / 2
      ),
      size: maxSize
    )
  }
  
  public func scaled(toWidth width: CGFloat) -> Self {
    
    let scale = CGFloat(width) / CGFloat(imageSize.width)
    
    return scaled(scale)
  }
  
  public func restoreFromScaled() -> Self {
    return scaled(toWidth: originalWidth)
  }
  
  private func scaled(_ scale: CGFloat) -> Self {
    
    var modified = self
    
    modified.cropExtent.origin.x *= scale
    modified.cropExtent.origin.y *= scale
    modified.cropExtent.size.width *= scale
    modified.cropExtent.size.height *= scale
    
    modified.imageSize.width *= scale
    modified.imageSize.height *= scale
    
    return modified
  }
  
}


public enum ImageProviderError: Error {
  case failedToDownloadPreviewImage(underlyingError: Error)
  case failedToDownloadEditableImage(underlyingError: Error)
  
  case urlIsNotFileURL(URL)
  
  case failedToCreateCGDataProvider
  case failedToCreateCGImageSource
  case failedToGetImageSize
}

/**
 A stateful object that provides multiple image for EditingStack.
 */
public final class ImageProvider: Equatable, StoreComponentType {
  public static func == (lhs: ImageProvider, rhs: ImageProvider) -> Bool {
    lhs === rhs
  }

  public struct State {
    public enum Image: Equatable {
      case preview(CGImageSource)
      case editable(CGImageSource)
    }

    public var loadedImage: Image? {
      if let editable = editableImage {
        return .editable(editable)
      }

      if let preview = previewImage {
        return .preview(preview)
      }

      return nil
    }

    fileprivate var previewImage: CGImageSource?
    fileprivate var editableImage: CGImageSource?
    
    public fileprivate(set) var loadingNonFatalErrors: [ImageProviderError] = []
    public fileprivate(set) var loadingFatalErrors: [ImageProviderError] = []
    public let imageSize: CGSize
  }

  public let store: DefaultStore

  private var pendingAction: (ImageProvider) -> Void

  #if os(iOS)
  
  /// Creates an instance from data
  public init(data: Data, imageSize: CGSize) throws {
        
    guard let provider = CGDataProvider(data: data as CFData) else {
      throw ImageProviderError.failedToCreateCGDataProvider
    }
    
    guard let imageSource = CGImageSourceCreateWithDataProvider(provider, nil) else {
      throw ImageProviderError.failedToCreateCGImageSource
    }
    
    store = .init(
      initialState: .init(
        previewImage: nil,
        editableImage: imageSource,
        imageSize: imageSize
      )
    )
    pendingAction = { _ in }
  }

  /// Creates an instance from UIImage
  ///
  /// - Attention: To reduce memory footprint, as possible creating an instance from url instead.
  public convenience init(image uiImage: UIImage) {
    try! self.init(data: uiImage.pngData()!, imageSize: .init(image: uiImage))
  }

  #endif

//  public init(image: CIImage) {
//    precondition(image.extent.origin == .zero)
//    store = .init(
//      initialState: .init(
//        previewImage: nil,
//        editableImage: image,
//        imageSize: .init(width: Int(image.extent.size.width), height: Int(image.extent.size.height))
//      )
//    )
//    pendingAction = { _ in }
//  }
  
  public init(
    fileURL: URL
  ) throws {
    guard fileURL.isFileURL else {
      throw ImageProviderError.urlIsNotFileURL(fileURL)
    }
    
    guard let provider = CGDataProvider(url: fileURL as CFURL) else {
      throw ImageProviderError.failedToCreateCGDataProvider
    }
    
    guard let imageSource = CGImageSourceCreateWithDataProvider(provider, nil) else {
      throw ImageProviderError.failedToCreateCGImageSource
    }
    
    guard let size = ImageTool.readImageSize(from: imageSource) else {
      throw ImageProviderError.failedToGetImageSize
    }
    
    store = .init(
      initialState: .init(
        previewImage: nil,
        editableImage: imageSource,
        imageSize: size
      )
    )
    pendingAction = { _ in }
  }

  /**
   Creates an instance by most efficient way.
   */
  public convenience init(
    previewURL: URL? = nil,
    editableURL: URL,
    imageSize: CGSize
  ) {
    self.init(
      previewURLRequest: previewURL.map { URLRequest(url: $0) },
      editableURLRequest: URLRequest(url: editableURL),
      imageSize: imageSize
    )
  }

  public init(
    previewURLRequest: URLRequest? = nil,
    editableURLRequest: URLRequest,
    imageSize: CGSize
  ) {
    store = .init(
      initialState: .init(
        previewImage: nil,
        editableImage: nil,
        imageSize: imageSize
      )
    )

    pendingAction = { `self` in

      var previewTask: URLSessionDownloadTask?

      if let previewURLRequest = previewURLRequest {
        previewTask = URLSession.shared.downloadTask(with: previewURLRequest) { url, response, error in

          if let error = error {
            self.store.commit {
              $0.loadingNonFatalErrors.append(.failedToDownloadPreviewImage(underlyingError: error))
            }
          }
          
          self.commit { state in
            if let url = url {
              
              guard let provider = CGDataProvider(url: url as CFURL) else {
                state.loadingNonFatalErrors.append(ImageProviderError.failedToCreateCGDataProvider)
                return
              }
              
              guard let imageSource = CGImageSourceCreateWithDataProvider(provider, nil) else {
                state.loadingNonFatalErrors.append(ImageProviderError.failedToCreateCGImageSource)
                return
              }
              
              state.previewImage = imageSource
            }
          }
         
        }
      }

      let editableTask = URLSession.shared.downloadTask(with: editableURLRequest) { url, response, error in

        previewTask?.cancel()

        if let error = error {
          self.store.commit {
            $0.loadingFatalErrors.append(.failedToDownloadEditableImage(underlyingError: error))
          }
        }
       
        self.commit { state in
          if let url = url {
            
            guard let provider = CGDataProvider(url: url as CFURL) else {
              state.loadingFatalErrors.append(ImageProviderError.failedToCreateCGDataProvider)
              return
            }
            
            guard let imageSource = CGImageSourceCreateWithDataProvider(provider, nil) else {
              state.loadingFatalErrors.append(ImageProviderError.failedToCreateCGImageSource)
              return
            }
            
            state.editableImage = imageSource
          }
        }
      }

      previewTask?.resume()
      editableTask.resume()
    }
  }

  #if canImport(Photos)

  public init(asset: PHAsset) {
    // TODO: cancellation, Error handeling

    store = .init(
      initialState: .init(
        previewImage: nil,
        editableImage: nil,
        imageSize: .init(
          width: asset.pixelWidth,
          height: asset.pixelHeight
        )
      )
    )

    pendingAction = { `self` in

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

      PHImageManager.default().requestImage(
        for: asset,
        targetSize: CGSize(width: 360, height: 360),
        contentMode: .aspectFit,
        options: previewRequestOptions
      ) { [weak self] image, info in
        
        // FIXME: Avoid loading image, get a url instead.
        
        guard let self = self else { return }
               
        self.commit { state in
          
          if let error = info?[PHImageErrorKey] as? Error {
            state.loadingNonFatalErrors.append(.failedToDownloadPreviewImage(underlyingError: error))
            return
          }
          
          guard let image = image else { return }
          guard let url = ImageTool.writeImageToTmpDirectory(image: image) else {
            assertionFailure()
            return
          }
          
          guard let provider = CGDataProvider(url: url as CFURL) else {
            state.loadingNonFatalErrors.append(ImageProviderError.failedToCreateCGDataProvider)
            return
          }
          
          guard let imageSource = CGImageSourceCreateWithDataProvider(provider, nil) else {
            state.loadingNonFatalErrors.append(ImageProviderError.failedToCreateCGImageSource)
            return
          }
          
          state.previewImage = imageSource
          
        }
        
      }

      PHImageManager.default().requestImage(
        for: asset,
        targetSize: PHImageManagerMaximumSize,
        contentMode: .aspectFit,
        options: finalImageRequestOptions
      ) { [weak self] image, info in
        
        // FIXME: Avoid loading image, get a url instead.

        guard let self = self else { return }
             
        self.commit { state in
                    
          if let error = info?[PHImageErrorKey] as? Error {
            state.loadingFatalErrors.append(.failedToDownloadEditableImage(underlyingError: error))
            return
          }
          
          guard let image = image else { return }
          guard let url = ImageTool.writeImageToTmpDirectory(image: image) else {
            assertionFailure()
            return
          }
          
          guard let provider = CGDataProvider(url: url as CFURL) else {
            state.loadingFatalErrors.append(ImageProviderError.failedToCreateCGDataProvider)
            return
          }
          
          guard let imageSource = CGImageSourceCreateWithDataProvider(provider, nil) else {
            state.loadingFatalErrors.append(ImageProviderError.failedToCreateCGImageSource)
            return
          }
          
          state.editableImage = imageSource
          
        }
      }
    }
  }

  #endif

  func start() {
    pendingAction(self)
  }
}

private func imageOrientationToTiffOrientation(_ value: UIImage.Orientation) -> Int32 {
  switch value {
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
