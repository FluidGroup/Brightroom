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

#if COCOAPODS
let bundle = Bundle.init(for: Dummy.self)
  .path(forResource: "BrightroomUI", ofType: "bundle")
  .map {
    Bundle.init(path: $0)
}!
#elseif SWIFT_PACKAGE_MANAGER
let bundle = Bundle.init(for: Dummy.self)
  .path(forResource: "Brightroom_BrightroomUI", ofType: "bundle")
  .map {
    Bundle.init(path: $0)
  }!
#else
let bundle = Bundle.init(for: Dummy.self)
#endif

public let BrightroomUIBundle = bundle

fileprivate final class Dummy {}

@inline(__always)
func _pixeleditor_ensureMainThread() {
  assert(Thread.isMainThread)
}
