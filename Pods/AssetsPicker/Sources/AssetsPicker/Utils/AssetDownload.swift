//
//  AssetDownload.swift
//  AssetsPicker
//
//  Created by Antoine Marandon on 09/12/2019.
//  Copyright © 2019 eure. All rights reserved.
//

import Foundation
import Photos

public class AssetDownload {
    public let asset: PHAsset
    public var onComplete: ((Result<UIImage, NSError>) -> Void)? {
        didSet {
            guard onComplete != nil else { return }
            lock.exec {
                if let finalImageResult = self.finalImageResult {
                    onComplete?(finalImageResult)
                    onComplete = nil
                }
            }
            cancelBackgroundTaskIfNeed()
        }
    }
    public var onThumbnailCompletion: ((Result<UIImage, NSError>) -> Void)? {
        didSet {
            guard onThumbnailCompletion != nil else { return }
            lock.exec {
                if let thumbnailResult = self.thumbnailResult {
                    onThumbnailCompletion?(thumbnailResult)
                    onThumbnailCompletion = nil
                }
            }
        }
    }
    public internal(set) var thumbnailResult: Result<UIImage, NSError>? {
        didSet {
            guard let thumbnailResult = thumbnailResult else { preconditionFailure("thumbnailResult must not be set to nil") }
            lock.exec {
                onThumbnailCompletion?(thumbnailResult)
                thumbnailRequestID = nil
            }
        }
    }
    public internal(set) var finalImageResult: Result<UIImage, NSError>? {
        didSet {
            lock.exec {
                guard let finalImageResult = finalImageResult else { preconditionFailure("finalImageResult must not be set to nil") }
                onComplete?(finalImageResult)
                imageRequestID = nil
            }
            cancelBackgroundTaskIfNeed()
        }
    }
    private let lock = NSLock()
    private var taskID = UIBackgroundTaskIdentifier.invalid
    internal var thumbnailRequestID: PHImageRequestID?
    internal var imageRequestID: PHImageRequestID?

    init(asset: PHAsset) {
        self.asset = asset
        self.taskID = UIApplication.shared.beginBackgroundTask(withName: "AssetPicker.download", expirationHandler: { [weak self] in
            self?.cancelBackgroundTaskIfNeed()
        })
    }

    deinit {
        if let imageRequestID = self.imageRequestID {
            PHCachingImageManager.default().cancelImageRequest(imageRequestID)
        }
        if let thumbnailRequestID = self.thumbnailRequestID {
            PHCachingImageManager.default().cancelImageRequest(thumbnailRequestID)
        }
        cancelBackgroundTaskIfNeed()
    }

    internal func cancelBackgroundTaskIfNeed() {
        guard self.taskID != .invalid else { return }
        self.lock.exec {
            guard self.taskID != .invalid else { return }
            UIApplication.shared.endBackgroundTask(self.taskID)
            self.taskID = .invalid
        }
    }
}
