//
//  File.swift
//  PixelEditor
//
//  Created by muukii on 10/15/18.
//  Copyright © 2018 muukii. All rights reserved.
//

import Foundation

import os.log

enum EngineLog {

  private static let osLog = OSLog.init(subsystem: "PixelEngine", category: "Engine")
   private static let queue = DispatchQueue.init(label: "me.muukii.PixelEngine.Log")

  static func debug(_ object: Any...) {

    queue.async {
      if #available(iOS 12.0, *) {
        os_log(.debug, log: osLog, "%@", object.map { "\($0)" }.joined(separator: " "))
      } else {
        os_log("%@", log: osLog, type: .debug, object.map { "\($0)" }.joined(separator: " "))
      }
    }
  }
}
