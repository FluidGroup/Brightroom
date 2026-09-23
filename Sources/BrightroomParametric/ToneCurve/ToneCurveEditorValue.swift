//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

/// A channel in a YRGB tone-curve value.
///
/// The `y` case identifies the shared luminance-facing channel without
/// prescribing its color-space formula or its ordering relative to RGB. A
/// renderer owns those semantics.
public enum ToneCurveChannel: CaseIterable, Equatable, Hashable, Identifiable, Sendable {
  /// The renderer-defined luminance-facing curve.
  case y

  /// The red component curve.
  case red

  /// The green component curve.
  case green

  /// The blue component curve.
  case blue

  /// Stable identity used by channel pickers and other data-driven clients.
  public var id: Self { self }
}

/// Four independently authored normalized tone curves.
///
/// This value can be shared by editors and render clients. It deliberately
/// contains no renderer-specific color-space or evaluation-order information.
public struct ToneCurveEditorValue: Equatable, Sendable {

  /// Four independent neutral channels used by a new editing session.
  public static let neutral = ToneCurveEditorValue()

  /// The renderer-defined Y channel.
  public var y: ToneCurve

  /// The red channel.
  public var red: ToneCurve

  /// The green channel.
  public var green: ToneCurve

  /// The blue channel.
  public var blue: ToneCurve

  /// Whether every channel is neutral.
  public var isNeutral: Bool {
    y.isNeutral && red.isNeutral && green.isNeutral && blue.isNeutral
  }

  /// Creates a value from four independently authored curves.
  public init(
    y: ToneCurve = .neutral,
    red: ToneCurve = .neutral,
    green: ToneCurve = .neutral,
    blue: ToneCurve = .neutral
  ) {
    self.y = y
    self.red = red
    self.green = green
    self.blue = blue
  }

  /// Accesses one curve by channel.
  public subscript(channel: ToneCurveChannel) -> ToneCurve {
    get {
      switch channel {
      case .y:
        y
      case .red:
        red
      case .green:
        green
      case .blue:
        blue
      }
    }
    set {
      switch channel {
      case .y:
        y = newValue
      case .red:
        red = newValue
      case .green:
        green = newValue
      case .blue:
        blue = newValue
      }
    }
  }

  /// Restores one channel without changing the other three.
  public mutating func reset(channel: ToneCurveChannel) {
    self[channel] = .neutral
  }

  /// Restores all four channels.
  public mutating func resetAll() {
    self = .neutral
  }
}
