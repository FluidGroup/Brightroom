//
//  PixelCropViewModel.swift
//  PixelEditor
//
//  Created by Muukii on 2021/02/24.
//  Copyright © 2021 muukii. All rights reserved.
//

import Foundation
import PixelEngine
import Verge

public final class PixelCropViewModel: StoreComponentType {
  
  public struct State: Equatable {
        
  }
  
  public let store: DefaultStore
  
  public let editingStack: EditingStack
    
  init(editingStack: EditingStack) {
    
    self.editingStack = editingStack
    self.store = .init(initialState: .init())
  }
}
