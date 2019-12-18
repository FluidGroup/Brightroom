//
//  AssetDetailViewController.Cell.swift
//  AssetsPicker
//
//  Created by Aymen Rebouh on 2018/10/19.
//  Copyright © 2018 eure. All rights reserved.
//

import Foundation
import UIKit

final class AssetDetailCell: UICollectionViewCell, AssetDetailCellBindable {
    var configuration: AssetPickerConfiguration!
    // MARK: Properties
    private var spinner: UIActivityIndicatorView?
    
    override var isSelected: Bool {
        didSet {
            updateSelection(isItemSelected: isSelected)
        }
    }        
    
    public let imageView: UIImageView = {
        let imageView = UIImageView()
        imageView.clipsToBounds = true
        imageView.contentMode = .scaleAspectFill
        return imageView
    }()
    
    var cellViewModel: AssetDetailCellViewModel?
    
    // MARK: Lifecycle
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        
        layout: do {
            contentView.addSubview(imageView)
            
            imageView.translatesAutoresizingMaskIntoConstraints = false
            
            NSLayoutConstraint.activate([
                imageView.topAnchor.constraint(equalTo: contentView.topAnchor),
                imageView.leftAnchor.constraint(equalTo: contentView.leftAnchor),
                imageView.rightAnchor.constraint(equalTo: contentView.rightAnchor),
                imageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
            ])
        }
    }
    
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    public func updateSelection(isItemSelected: Bool) {
        if isItemSelected {
            imageView.layer.borderColor = configuration.selectionColor.cgColor
            imageView.layer.borderWidth = 4
        } else {
            imageView.layer.borderColor = nil
            imageView.layer.borderWidth = 0
        }
    }
    
    // MARK: Core
    
    func bind(cellViewModel: AssetDetailCellViewModel) {
        self.cellViewModel = cellViewModel
        
        self.cellViewModel?.delegate = self
        cellViewModel.fetchPreviewImage()
        setDownloading(cellViewModel.isDownloading)
    }

    func setDownloading(_ isDownloading: Bool) {
        if isDownloading, spinner == nil {
            let spinner = UIActivityIndicatorView(style: .whiteLarge)
            contentView.addSubview(spinner)
            spinner.center = contentView.center
            spinner.startAnimating()
            self.spinner = spinner
        } else {
            spinner?.removeFromSuperview()
            spinner = nil
        }
    }
    
    public override func prepareForReuse() {
        super.prepareForReuse()
        spinner?.removeFromSuperview()
        imageView.image = nil
    }
}

// MARK: AssetDetailCellViewModelDelegate

extension AssetDetailCell: AssetDetailCellViewModelDelegate {
    func cellViewModel(_ cellViewModel: AssetDetailCellViewModel, didFetchImage image: UIImage) {
        imageView.image = image
    }

    func cellViewModel(_ cellViewModel: AssetDetailCellViewModel, isDownloading: Bool) {
        setDownloading(isDownloading)
    }
}
