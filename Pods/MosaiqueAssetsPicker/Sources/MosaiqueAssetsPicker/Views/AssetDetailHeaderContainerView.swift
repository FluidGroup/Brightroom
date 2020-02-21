//
//  AssetDetailHeaderContainerView.swift
//  AssetsPicker
//
//  Created by Aymen Rebouh on 2018/10/29.
//  Copyright © 2018 eure. All rights reserved.
//

import Foundation
import UIKit

final class AssetDetailHeaderContainerView : UICollectionReusableView {
    
    func set(view: UIView) {
        
        subviews.forEach { $0.removeFromSuperview() }
        
        addSubview(view)
        
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: topAnchor),
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
    
}
