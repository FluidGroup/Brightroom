//
//  FilterChannels.swift
//  Fil
//
//  Created by Hiroshi Kimura on 12/29/15.
//  Copyright © 2015 muukii. All rights reserved.
//

import LightRoom
import JAYSON

public func == (lhs: FilterChannels, rhs: FilterChannels) -> Bool {
  if lhs.redChannel == rhs.redChannel &&
    lhs.greenChannel == rhs.greenChannel &&
    lhs.blueChannel == rhs.blueChannel {
    return true
  }
  return false
}

public func == (lhs: FilterChannels.Channel, rhs: FilterChannels.Channel) -> Bool {
  if lhs.redAmount == rhs.redAmount &&
    lhs.greenAmount == rhs.greenAmount &&
    lhs.blueAmount == rhs.blueAmount &&
    lhs.constant == rhs.constant {
    return true
  }
  return false
}

public struct FilterChannels: Filtering, MultipleParameters, PresetComponent, Equatable {

  /**
   Amount: -200% ~ 200%, actually values is -2...2
   */
  public struct Channel: Equatable {
    public var redAmount: Double // -1...1
    public var greenAmount: Double  // -1...1
    public var blueAmount: Double // -1...1
    public var constant: Double // -1...1

    public init(_ redAmount: Double, _ greenAmount: Double, _ blueAmount: Double, _ constant: Double) {
      self.redAmount = redAmount
      self.greenAmount = greenAmount
      self.blueAmount = blueAmount
      self.constant = constant
    }

    var vector: Vector4 {
      return [
        CGFloat(4 * self.redAmount),
        CGFloat(4 * self.greenAmount),
        CGFloat(4 * self.blueAmount),
        CGFloat(4 * self.constant),
      ]
    }

    var stringRepresentation: String {

      return "[\(4 * self.redAmount), \(4 * self.greenAmount), \(4 * self.blueAmount), \(4 * self.constant)]"
    }
  }

  public var redChannel: Channel
  public var greenChannel: Channel
  public var blueChannel: Channel

  public let filterChain: FilterChain = {

    return LightRoom.ColorFilter.ColorMatrix(
      rVector: self.redChannel.vector,
      gVector: self.greenChannel.vector,
      bVector: self.blueChannel.vector,
      aVector: [0,0,0,1],
      biasVector: [0,0,0,0])
  }

  public init(
    redChannel: Channel = Channel(0.25, 0, 0, 0),
    greenChannel: Channel = Channel(0, 0.25, 0, 0),
    blueChannel: Channel = Channel(0, 0, 0.25, 0)) {

    self.redChannel = redChannel
    self.greenChannel = greenChannel
    self.blueChannel = blueChannel
  }

  public init?(json: JSON) {

    guard
      let redChannelRedAmount = json[Keys.RedChannelRedAmount].number,
      let redChannelGreenAmount = json[Keys.RedChannelGreenAmount].number,
      let redChannelBlueAmount = json[Keys.RedChannelBlueAmount].number,
      let redChannelConstant = json[Keys.RedChannelConstant].number,
      let greenChannelRedAmount = json[Keys.GreenChannelRedAmount].number,
      let greenChannelGreenAmount = json[Keys.GreenChannelGreenAmount].number,
      let greenChannelBlueAmount = json[Keys.GreenChannelBlueAmount].number,
      let greenChannelConstant = json[Keys.GreenChannelConstant].number,
      let blueChannelRedAmount = json[Keys.BlueChannelRedAmount].number,
      let blueChannelGreenAmount = json[Keys.BlueChannelGreenAmount].number,
      let blueChannelBlueAmount = json[Keys.BlueChannelBlueAmount].number,
      let blueChannelConstant = json[Keys.BlueChannelConstant].number
      else {
        return nil
    }

    self.redChannel = Channel(redChannelRedAmount.doubleValue, redChannelGreenAmount.doubleValue, redChannelBlueAmount.doubleValue, redChannelConstant.doubleValue)
    self.greenChannel = Channel(greenChannelRedAmount.doubleValue, greenChannelGreenAmount.doubleValue, greenChannelBlueAmount.doubleValue, greenChannelConstant.doubleValue)
    self.blueChannel = Channel(blueChannelRedAmount.doubleValue, blueChannelGreenAmount.doubleValue, blueChannelBlueAmount.doubleValue, blueChannelConstant.doubleValue)
  }

  public func toJSON() -> JSON {

    var dictionary: [String: AnyObject] = [:]

    dictionary[Keys.RedChannelRedAmount] = NSNumber(double: self.redChannel.redAmount)
    dictionary[Keys.RedChannelGreenAmount] = NSNumber(double: self.redChannel.greenAmount)
    dictionary[Keys.RedChannelBlueAmount] = NSNumber(double: self.redChannel.blueAmount)
    dictionary[Keys.RedChannelConstant] = NSNumber(double: self.redChannel.constant)

    dictionary[Keys.GreenChannelRedAmount] = NSNumber(double: self.greenChannel.redAmount)
    dictionary[Keys.GreenChannelGreenAmount] = NSNumber(double: self.greenChannel.greenAmount)
    dictionary[Keys.GreenChannelBlueAmount] = NSNumber(double: self.greenChannel.blueAmount)
    dictionary[Keys.GreenChannelConstant] = NSNumber(double: self.greenChannel.constant)

    dictionary[Keys.BlueChannelRedAmount] = NSNumber(double: self.blueChannel.redAmount)
    dictionary[Keys.BlueChannelGreenAmount] = NSNumber(double: self.blueChannel.greenAmount)
    dictionary[Keys.BlueChannelBlueAmount] = NSNumber(double: self.blueChannel.blueAmount)
    dictionary[Keys.BlueChannelConstant] = NSNumber(double: self.blueChannel.constant)

    return JSON(dictionary)
  }

  private enum Keys {
    static let RedChannelRedAmount = "redChannelRedAmount"
    static let RedChannelGreenAmount = "redChannelGreenAmount"
    static let RedChannelBlueAmount = "redChannelBlueAmount"
    static let RedChannelConstant = "redChannelConstant"

    static let GreenChannelRedAmount = "greenChannelRedAmount"
    static let GreenChannelGreenAmount = "greenChannelGreenAmount"
    static let GreenChannelBlueAmount = "greenChannelBlueAmount"
    static let GreenChannelConstant = "greenChannelConstant"

    static let BlueChannelRedAmount = "blueChannelRedAmount"
    static let BlueChannelGreenAmount = "blueChannelGreenAmount"
    static let BlueChannelBlueAmount = "blueChannelBlueAmount"
    static let BlueChannelConstant = "blueChannelConstant"
  }
}

