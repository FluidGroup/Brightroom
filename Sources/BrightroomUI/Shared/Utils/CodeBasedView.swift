//
//  CodeBasedView.swift
//  PixelEditor
//
//  Created by Muukii on 2021/03/03.
//  Copyright © 2021 muukii. All rights reserved.
//

import UIKit

/**
 A view that can only be created from code, not from a nib.
 */
class CodeBasedView : UIView {
  
  override init(frame: CGRect) {
    super.init(frame: frame)
  }
  
  @available(*, unavailable)
  required init?(coder aDecoder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
}
