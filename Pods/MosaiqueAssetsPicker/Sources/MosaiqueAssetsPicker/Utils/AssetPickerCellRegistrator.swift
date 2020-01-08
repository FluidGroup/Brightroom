//
//  CellRegistrator.swift
//  AssetsPicker
//
//  Created by Aymen Rebouh on 2018/10/30.
//  Copyright © 2018 eure. All rights reserved.
//

import Foundation
import UIKit

public enum CellType: String {
    case assetCollection, asset
}

public protocol CustomizableCell {}

public protocol AssetDetailCellBindable: CustomizableCell, AssetDetailCellViewModelDelegate {
    var cellViewModel: AssetDetailCellViewModel? { get set }
    func bind(cellViewModel: AssetDetailCellViewModel)
}

public protocol AssetCollectionCellBindable: CustomizableCell, AssetsCollectionCellViewModelDelegate {
    var cellViewModel: AssetCollectionCellViewModel? { get set }
    func bind(cellViewModel: AssetCollectionCellViewModel)
}

public class AssetPickerCellRegistrator {
    
    // MARK: Properties
    
    var customAssetItemClasses: [CellType: (UICollectionViewCell.Type, String)] = [:]
    var customAssetItemNibs: [CellType: (UINib, String)] = [:]

    var defaultAssetItemClasses: [CellType: (UICollectionViewCell.Type, String)] = [
        .asset: (AssetDetailCell.self, String(describing: AssetDetailCell.self)),
        .assetCollection: (AssetCollectionCell.self, String(describing: AssetCollectionCell.self))
    ]
    
    func cellType(forCellType cellType: CellType) -> UICollectionViewCell.Type {
        return customAssetItemClasses[cellType]?.0 ?? defaultAssetItemClasses[cellType]?.0 ?? UICollectionViewCell.self
    }
    
    func cellIdentifier(forCellType cellType: CellType) -> String {
        return customAssetItemNibs[cellType]?.1 ?? customAssetItemClasses[cellType]?.1 ?? defaultAssetItemClasses[cellType]?.1 ?? "Cell"
    }

    // MARK: Lifecycle
    
    public init() {}
     
    // MARK: Core
    
    public func register(nib: UINib, forCellType cellType: CellType) {
        let nibIdentifier = String(describing: nib.self)
        customAssetItemNibs[cellType] = (nib, nibIdentifier)
    }
    
    public func register<T: UICollectionViewCell>(cellClass: T.Type, forCellType cellType: CellType) where T: CustomizableCell {
        let cellIdentifier = String(describing: T.self)
        customAssetItemClasses[cellType] = (cellClass, cellIdentifier)
    }
}
