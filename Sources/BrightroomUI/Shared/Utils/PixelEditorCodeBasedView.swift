//
//  CodeBasedView.swift
//  PixelEditor
//
//  Created by Muukii on 2021/03/03.
//  Copyright © 2021 muukii. All rights reserved.
//

import BrightroomEngine
import UIKit

/**
 A view that can be initializde only from code. (No supports to init from Nib)
 */
class _PixelEditorCodeBasedView : UIView {
  
  override init(frame: CGRect) {
    super.init(frame: frame)
  }
  
  @available(*, unavailable)
  required init?(coder aDecoder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
}

extension EditingStack {

  func requireLoadedStateForLoadedUIView(
    file: StaticString = #fileID,
    line: UInt = #line
  ) -> Loaded {
    assert(
      loadedState != nil,
      "SwiftUI loaded branch created or updated a UIKit view while EditingStack.loadedState was nil.",
      file: file,
      line: line
    )
    return loadedState!
  }
}
