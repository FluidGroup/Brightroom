//
//  PixelEditor.swift
//  PixelEditor
//
//  Created by muukii on 10/10/18.
//  Copyright © 2018 muukii. All rights reserved.
//

import Foundation

#if !RELEASE

public typealias TODOL10n = String

extension TODOL10n {

  public init(raw: String, _ key: String) {
    self = raw
  }

  public init(raw: String) {
    self = raw
  }
}
#endif

public typealias NonL10n = String

let bundle = Bundle.init(for: Dummy.self)

final class Dummy {}
