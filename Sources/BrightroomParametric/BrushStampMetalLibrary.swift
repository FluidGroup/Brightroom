//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
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

import Foundation

/// Locates the build-compiled Metal library bundled with BrightroomParametric.
///
/// `ParametricKernels.metal` and `BrushMaskRenderShader.metal` are compiled by
/// the package/Xcode Metal build step into `default.metallib`. The parametric
/// renderer loads Core Image kernels from this library, and BrightroomUI loads
/// the live brush-mask vertex/fragment functions from the same library.
public enum BrushStampMetalLibrary {

  /// Returns the URL for the bundled `default.metallib`.
  public static func url() throws -> URL {
    guard let url = Bundle.module.url(forResource: "default", withExtension: "metallib") else {
      throw BrushStampMetalLibraryError.missingResource("default.metallib")
    }
    return url
  }

  /// Returns the bundled `default.metallib` contents.
  public static func data() throws -> Data {
    let url = try url()
    do {
      return try Data(contentsOf: url)
    } catch {
      throw BrushStampMetalLibraryError.unreadableResource(
        "default.metallib: \(String(describing: error))"
      )
    }
  }
}

/// Errors thrown while loading BrightroomParametric's compiled Metal library.
public enum BrushStampMetalLibraryError: Error, Equatable, Sendable {

  /// The package resource bundle does not contain `default.metallib`.
  case missingResource(String)

  /// The compiled Metal library exists but could not be read.
  case unreadableResource(String)
}
