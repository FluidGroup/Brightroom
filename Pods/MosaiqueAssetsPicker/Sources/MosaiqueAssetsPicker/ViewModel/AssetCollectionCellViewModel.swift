//
//  PhotoPicker.PhotosPickerAssetsCollectionDelegate.Cell.ViewModel.swift
//  AssetsPicker
//
//  Created by Aymen Rebouh on 2018/10/18.
//  Copyright © 2018 eure. All rights reserved.
//

import Foundation
import UIKit
import Photos

public protocol AssetsCollectionCellViewModelDelegate: class {
    func cellViewModel(_ cellViewModel: AssetCollectionCellViewModel, didFetchImage image: UIImage)
    func cellViewModel(_ cellViewModel: AssetCollectionCellViewModel, didFetchNumberOfAssets numberOfAssets: String)
}


public final class AssetCollectionCellViewModel: ItemIdentifier {
    
    // MARK: Properties
    
    public weak var delegate: AssetsCollectionCellViewModelDelegate?
    public var assetCollection: PHAssetCollection
    private var imageRequestId: PHImageRequestID?
    
    // MARK: Lifecycle
    
    init(assetCollection: PHAssetCollection) {
        self.assetCollection = assetCollection
    }
    
    init(withAssetCollection assetCollection: PHAssetCollection) {
        self.assetCollection = assetCollection
    }
    
    // MARK: ItemIdentifier
    
    public var identifier: String {
        return assetCollection.localIdentifier
    }
    
    // MARK: Core
    
    public func cancelLatestImageIfNeeded() {
        guard let imageRequestId = imageRequestId else { return }
        PHCachingImageManager.default().cancelImageRequest(imageRequestId)
        self.imageRequestId = nil
    }
    
    public func fetchLatestImage() {
        imageRequestId = nil
        
        let firstAssetFetchOptions: PHFetchOptions = {
            let fetchOptions = PHFetchOptions()
            fetchOptions.sortDescriptors = [
                NSSortDescriptor(key: "creationDate", ascending: false),
            ]
            fetchOptions.predicate = NSPredicate(format: "mediaType = %d", PHAssetMediaType.image.rawValue)
            
            return fetchOptions
        }()
        
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            guard let self = self else { return }
            
            let result = PHAsset.fetchAssets(
                in: self.assetCollection,
                options: firstAssetFetchOptions
            )
            
            DispatchQueue.main.async {
                self.delegate?.cellViewModel(self, didFetchNumberOfAssets: result.count.description)
            }
            
            guard let firstAsset = result.firstObject else {
                return
            }
            
            let options = PHImageRequestOptions()
            options.deliveryMode = .opportunistic
            options.isNetworkAccessAllowed = true
            options.version = .current
            options.resizeMode = .fast
            
            let imageManager = PHCachingImageManager.default()
            
            self.imageRequestId = imageManager.requestImage(
                for: firstAsset,
                targetSize: CGSize(width: 250, height: 250),
                contentMode: .aspectFill,
                options: options) { [weak self] (image, userInfo) in
                    guard let `self` = self else { return }
                    if let image = image {
                        DispatchQueue.main.async {
                            self.delegate?.cellViewModel(self, didFetchImage: image)
                        }
                    }
            }
        }
    }
}
