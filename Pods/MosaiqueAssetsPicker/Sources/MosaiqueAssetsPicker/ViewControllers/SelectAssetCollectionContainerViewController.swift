//
//  PhotosPickerSelectAssetsViewController.swift
//  AssetsPicker
//
//  Created by Aymen Rebouh on 2018/10/16.
//  Copyright © 2018 eure. All rights reserved.
//

import Foundation
import UIKit
import Photos

final class SelectAssetCollectionContainerViewController: UIViewController {
 
    let configuration: MosaiqueAssetPickerConfiguration
    
    private lazy var changePermissionsButton: UIButton = {
        let button = UIButton(type: UIButton.ButtonType.custom)
        button.titleLabel?.font = UIFont.boldSystemFont(ofSize: 17)
        button.setTitleColor(configuration.tintColor, for: .normal)
        
        return button
    }()
 
    // MARK: Lifecycle

    init(configuration: MosaiqueAssetPickerConfiguration) {
        self.configuration = configuration
        super.init(nibName: nil, bundle: nil)
    }
    
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    public override func viewDidLoad() {
        super.viewDidLoad()
        
        view.backgroundColor = .white
        
        handleAuthorizations()
    }
    
    // MARK: User Interaction
    
    @objc func openSettings(sender: UIButton) {
        UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
    }
    
    private func handleAuthorizations() {
        switch PHPhotoLibrary.authorizationStatus() {
        case .authorized:
            setup()
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization { newStatus in
                DispatchQueue.main.async {
                    if newStatus == .authorized {
                        self.setup()
                    } else {
                        self.showPermissionsLabel()
                    }
                }
            }
        case .denied, .restricted:
            showPermissionsLabel()
        @unknown default:
            break
        }
    }
    
    private func setup() {
        let assetsCollectionsViewController = AssetsCollectionViewController(configuration: configuration)
        addChild(assetsCollectionsViewController)
        view.addSubview(assetsCollectionsViewController.view)
        
        assetsCollectionsViewController.view.translatesAutoresizingMaskIntoConstraints = false
        
        NSLayoutConstraint.activate([
            assetsCollectionsViewController.view.topAnchor.constraint(equalTo: self.view.topAnchor),
            assetsCollectionsViewController.view.leadingAnchor.constraint(equalTo: self.view.leadingAnchor),
            assetsCollectionsViewController.view.trailingAnchor.constraint(equalTo: self.view.trailingAnchor),
            assetsCollectionsViewController.view.bottomAnchor.constraint(equalTo: self.view.bottomAnchor)
            ])
    }

    private func showPermissionsLabel() {
        view.addSubview(changePermissionsButton)
        
        changePermissionsButton.translatesAutoresizingMaskIntoConstraints = false
        changePermissionsButton.setTitle(configuration.localize.changePermissions, for: .normal)
        changePermissionsButton.addTarget(self, action: #selector(openSettings(sender:)), for: .touchUpInside)
       
        NSLayoutConstraint.activate([
            changePermissionsButton.topAnchor.constraint(equalTo: view.topAnchor),
            changePermissionsButton.leftAnchor.constraint(equalTo: view.leftAnchor),
            changePermissionsButton.rightAnchor.constraint(equalTo: view.rightAnchor),
            changePermissionsButton.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ]
        )
    }

}

