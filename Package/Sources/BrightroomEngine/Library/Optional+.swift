//
// Copyright (c) 2021 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
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

extension Optional {
  internal func unwrap(
    orThrow debugDescription: String? = nil,
    file: StaticString = #file,
    function: StaticString = #function,
    line: UInt = #line
  ) throws -> Wrapped {
    if let value = self {
      return value
    }
    throw Optional.BrightroomUnwrappedNilError(
      debugDescription,
      file: file,
      function: function,
      line: line
    )
  }

  public struct BrightroomUnwrappedNilError: Swift.Error, CustomDebugStringConvertible {
    let file: StaticString
    let function: StaticString
    let line: UInt

    // MARK: Public

    public init(
      _ debugDescription: String? = nil,
      file: StaticString = #file,
      function: StaticString = #function,
      line: UInt = #line
    ) {
      self.debugDescription = debugDescription ?? "Failed to unwrap on \(file):\(function):\(line)"
      self.file = file
      self.function = function
      self.line = line
    }

    // MARK: CustomDebugStringConvertible

    public let debugDescription: String
  }
}
