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

import Testing
import CoreGraphics

import BrightroomParametric

/// `AspectRatio` compares by ratio, so `4:3`, `8:6` and a `4032x3024`
/// image size are the same value. `Hashable` must agree with that, or `Set`
/// and `Dictionary` treat equal ratios as different keys.
struct AspectRatioTests {

  @Test func `Ratios with the same proportion are equal`() {
    #expect(AspectRatio(width: 4, height: 3) == AspectRatio(width: 8, height: 6))
    #expect(AspectRatio(width: 4, height: 3) == AspectRatio(width: 4032, height: 3024))
    #expect(AspectRatio(width: 4, height: 3) != AspectRatio(width: 3, height: 4))
    #expect(AspectRatio(width: 4, height: 3).swapped() == AspectRatio(width: 6, height: 8))
  }

  @Test func `Equal ratios have equal hash values`() {
    let base = AspectRatio(width: 4, height: 3)

    for scale in 1...100 {
      let scaled = AspectRatio(width: 4 * CGFloat(scale), height: 3 * CGFloat(scale))
      #expect(scaled == base)
      #expect(scaled.hashValue == base.hashValue, "scale \(scale)")
    }
  }

  @Test func `A set holds one element per ratio`() {
    let ratios = (1...100).map {
      AspectRatio(width: 16 * CGFloat($0), height: 9 * CGFloat($0))
    }

    #expect(Set(ratios).count == 1)
    #expect(Set(ratios + ratios.map { $0.swapped() }).count == 2)
  }

  /// Looks up many scaled ratios, not just one: with a hash that disagrees
  /// with `==`, a single lookup can still land on the equal key by chance
  /// under the per-process hash seed.
  @Test func `A dictionary finds a value through an equal ratio`() {
    let titles: [AspectRatio: String] = [
      .init(width: 4, height: 3): "4:3",
      .init(width: 16, height: 9): "16:9",
    ]

    #expect(titles[.init(width: 4032, height: 3024)] == "4:3")
    #expect(titles[.init(width: 1920, height: 1080)] == "16:9")
    #expect(titles[.init(width: 3, height: 4)] == nil)

    for scale in 1...100 {
      let k = CGFloat(scale)
      #expect(titles[.init(width: 4 * k, height: 3 * k)] == "4:3", "scale \(scale)")
      #expect(titles[.init(width: 16 * k, height: 9 * k)] == "16:9", "scale \(scale)")
    }
  }

  /// Equality is exact, with no tolerance: a tolerance would not be
  /// transitive, so no hash could agree with it. The proportion is
  /// `height / width`, which gives these edge cases.
  @Test func `Zero sides compare by their exact proportion`() {
    // 0 / 4 and 0 / -4 are +0 and -0, which are equal and hash equally.
    #expect(AspectRatio(width: 4, height: 0) == AspectRatio(width: -4, height: 0))
    #expect(AspectRatio(width: 4, height: 0).hashValue == AspectRatio(width: -4, height: 0).hashValue)

    // A zero width gives an infinite proportion, whatever the height.
    #expect(AspectRatio(width: 0, height: 3) == AspectRatio(width: 0, height: 7))
    #expect(AspectRatio(width: 0, height: 3).hashValue == AspectRatio(width: 0, height: 7).hashValue)
    #expect(AspectRatio(width: -0.0, height: 3) != AspectRatio(width: 0, height: 3))

    // Zero by zero is NaN, which is not equal to itself.
    #expect(AspectRatio(width: 0, height: 0) != AspectRatio(width: 0, height: 0))
  }

  /// `id` identifies the exact width and height pair, not the ratio, so a
  /// `ForEach` over presets such as `5:4` and `10:8` keeps one row for each.
  @Test func `Identity keeps the authored width and height apart`() {
    #expect(AspectRatio(width: 5, height: 4).id != AspectRatio(width: 10, height: 8).id)
    #expect(AspectRatio(width: 5, height: 4).id == AspectRatio(width: 5, height: 4).id)
  }
}
