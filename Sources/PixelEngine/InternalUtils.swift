//
//  InternalUtils.swift
//  PixelEngine
//
//  Created by Hiroshi Kimura on 2018/10/21.
//  Copyright © 2018 muukii. All rights reserved.
//

import Foundation

public enum RequireError: Swift.Error {
  case missingRequiredValue(failureDescription: String?, file: StaticString, function: StaticString, line: UInt)
}

extension Optional {
  
  @inline(__always)
  func require(_ failureDescription: String? = nil, file: StaticString = #file, function: StaticString = #function, line: UInt = #line) throws -> Wrapped {
    switch self {
    case .none:
      throw RequireError.missingRequiredValue(failureDescription: failureDescription, file: file, function: function, line: line)
    case .some(let value):
      return value
    }
  }
  
  @inline(__always)
  func unsafeRequire(_ failureDescription: String? = nil, file: StaticString = #file, function: StaticString = #function, line: UInt = #line) -> Wrapped {
    switch self {
    case .none:
      fatalError("\(RequireError.missingRequiredValue(failureDescription: failureDescription, file: file, function: function, line: line))")
    case .some(let value):
      return value
    }
  }
}
