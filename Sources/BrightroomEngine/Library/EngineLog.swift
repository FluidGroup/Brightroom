//
// Copyright (c) 2018 Muukii <muukii.app@gmail.com>
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

import UIKit

import os.log

enum EngineLog {
  
  private static let osLog = OSLog.init(subsystem: "PixelEngine", category: "Engine")
  
  static func debug(_ object: Any...) {
    #if DEBUG
    if #available(iOS 12.0, *) {
      os_log(.debug, log: osLog, "%@", object.map { "\($0)" }.joined(separator: " "))
    } else {
      os_log("%@", log: osLog, type: .debug, object.map { "\($0)" }.joined(separator: " "))
    }
    #endif
  }
    
  static func debug(_ log: OSLog, _ object: Any...) {
    os_log(.debug, log: log, "%@", object.map { "\($0)" }.joined(separator: " "))
  }
  
  static func error(_ log: OSLog, _ object: Any...) {
    os_log(.error, log: log, "%@", object.map { "\($0)" }.joined(separator: " "))
  }
  
}

extension OSLog {
  
  static let renderer = OSLog.init(subsystem: "BrightroomEngine", category: "🎨 Renderer")
  static let stack = OSLog.init(subsystem: "BrightroomEngine", category: "🥞 Stack")

}
