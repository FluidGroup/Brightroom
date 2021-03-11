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
  
  /**
   Creates an instance from fileURL.
   This is most efficient way to edit image without large memory footprint.
   */
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
   Creates an instance
   */
  public convenience init(
    previewRemoteURL: URL? = nil,
    editableRemoteURL: URL,
    imageSize: CGSize
  ) {
    self.init(
      previewRemoteURLRequest: previewRemoteURL.map { URLRequest(url: $0) },
      editableRemoteURLRequest: URLRequest(url: editableRemoteURL),
      imageSize: imageSize
    )
  }

  public init(
    previewRemoteURLRequest: URLRequest? = nil,
    editableRemoteURLRequest: URLRequest,
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

      if let previewURLRequest = previewRemoteURLRequest {
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

      let editableTask = URLSession.shared.downloadTask(with: editableRemoteURLRequest) { url, response, error in

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
