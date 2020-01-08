//
//  AssetDetailViewControllerViewModel.swift
//  AssetsPicker
//
//  Created by Antoine Marandon on 19/11/2019.
//  Copyright © 2019 eure. All rights reserved.
//

import Photos
import UIKit.UIImage

public protocol AssetDetailViewModelDelegate: class {
    func displayItemsChange(_ changes: PHFetchResultChangeDetails<PHAsset>)
}

public final class AssetDetailViewModel: NSObject {

    // MARK: Properties

    public weak var delegate: AssetDetailViewModelDelegate?
    private let imageManager = PHCachingImageManager()
    private(set) var assetCollection: PHAssetCollection
    private(set) var selectionContainer: SelectionContainer<AssetDetailCellViewModel>
    private(set) var displayItems: PHFetchResult<PHAsset>
    let configuration: MosaiqueAssetPickerConfiguration
    var selectedIndexs: [Int] {
        let selectedAssets = selectionContainer.selectedItems.map { $0.asset }
        return selectedAssets.compactMap { displayItems.contains($0) ? displayItems.index(of: $0) : nil }
    }

    // MARK: Lifecycle

    init(assetCollection: PHAssetCollection, selectionContainer: SelectionContainer<AssetDetailCellViewModel>, configuration: MosaiqueAssetPickerConfiguration) {
        self.assetCollection = assetCollection
        self.selectionContainer = selectionContainer
        self.displayItems = PHFetchResult<PHAsset>()
        self.configuration = configuration
        super.init()
    }

    func fetchPhotos(onNext: @escaping (() -> ())) {
        DispatchQueue.global(qos: .userInteractive).async {

            let fetchOptions = PHFetchOptions()

            if !self.configuration.supportOnlyMediaType.isEmpty {
                let predicates = self.configuration.supportOnlyMediaType.map { NSPredicate(format: "mediaType = %d", $0.rawValue) }
                fetchOptions.predicate = NSCompoundPredicate(type: .or, subpredicates: predicates)
            }

            fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]

            let result = PHAsset.fetchAssets(
                in: self.assetCollection,
                options: fetchOptions
            )
            PHPhotoLibrary.shared().register(self)

            self.displayItems = result
            onNext()
        }
    }

    func downloadSelectedCells(onNext: @escaping (([UIImage]) -> Void)) -> [AssetFuture] {
        let dispatchGroup = DispatchGroup()
        var images: [UIImage] = []

        let assetsDownloads = selectionContainer.selectedItems.map { (cellViewModel) -> AssetFuture in
            dispatchGroup.enter()
            return cellViewModel.download(onNext: { image in
                DispatchQueue.main.async {
                    if let image = image {
                        images.append(image)
                    }
                    dispatchGroup.leave()
                }
            })
        }
        dispatchGroup.notify(queue: DispatchQueue.main) {
            onNext(images)
        }
        return assetsDownloads
    }

    func reset(withAssetCollection assetCollection: PHAssetCollection) {
        self.assetCollection = assetCollection
        self.selectionContainer.purge()
    }

    func cellModel(at index: Int) -> AssetDetailCellViewModel {

        let asset = displayItems.object(at: index)

        if let cellModel = selectionContainer.item(for: asset.localIdentifier) {
            return cellModel
        }

        let cellModel = makeCellModel(from: asset)

        return cellModel
    }

    private func makeCellModel(from asset: PHAsset) -> AssetDetailCellViewModel {

        let cellModel = AssetDetailCellViewModel(
            asset: asset,
            imageManager: imageManager,
            selectionContainer: selectionContainer
        )

        return cellModel
    }

    func toggle(item: AssetDetailCellViewModel) {
        if case .notSelected = item.selectionStatus() {
            select(item: item)
        } else {
            unselect(item: item)
        }
    }

    private func select(item: AssetDetailCellViewModel) {
        selectionContainer.append(item: item, removeFirstIfAlreadyFilled: selectionContainer.size == 1)
    }

    private func unselect(item: AssetDetailCellViewModel) {
        selectionContainer.remove(item: item)
    }
}


extension AssetDetailViewModel: PHPhotoLibraryChangeObserver {
    public func photoLibraryDidChange(_ changeInstance: PHChange) {
        guard let changeDetails = changeInstance.changeDetails(for: displayItems) else { return }
        assert(!Thread.isMainThread)
        DispatchQueue.main.sync {
            self.displayItems = changeDetails.fetchResultAfterChanges
            self.selectionContainer.purge()
            self.delegate?.displayItemsChange(changeDetails)
        }
    }
}
