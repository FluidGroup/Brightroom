//
//  CodeBasedView.swift
//  PixelEditor
//
//  Created by Muukii on 2021/03/03.
//  Copyright © 2021 muukii. All rights reserved.
//

import UIKit

/**
 A view that can be initializde only from code. (No supports to init from Nib)
 */
open class PixelEditorCodeBasedView : UIView {
  
  public override init(frame: CGRect) {
    super.init(frame: frame)
  }
  
  @available(*, unavailable)
  public required init?(coder aDecoder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
}
