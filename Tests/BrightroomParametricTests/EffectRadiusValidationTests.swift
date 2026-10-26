//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

import Foundation
import Testing

import BrightroomParametric

/// Public API only. A host restores a stored Gaussian blur, sharpen, or
/// unsharp-mask radius through `EffectRadius`'s validating initializers,
/// which accept a finite, non-negative number and reject everything else.
@Suite("EffectRadius validating initializers")
struct EffectRadiusValidationTests {

  @Test(arguments: [0, 0.5, 3, 250, 12_000])
  func `a finite non-negative radius is restored unchanged`(value: Double) {
    #expect(EffectRadius(validatingAbsolute: value) == .absolute(value))
    #expect(EffectRadius(validatingProportional: value) == .proportional(value))
  }

  @Test(arguments: [-1, -Double.ulpOfOne, .nan, .infinity, -.infinity])
  func `a negative or non-finite radius is rejected`(value: Double) {
    #expect(EffectRadius(validatingAbsolute: value) == nil)
    #expect(EffectRadius(validatingProportional: value) == nil)
  }
}
