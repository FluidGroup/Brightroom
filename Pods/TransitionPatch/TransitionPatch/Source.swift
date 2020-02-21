
import Foundation

public protocol PatchType {
  associatedtype Value
}

public struct ProgressPatch: PatchType {
  
  public typealias Value = CGFloat
  
  public var fractionCompleted: Value
  
  public init(_ fractionCompleted: Value) {
    self.fractionCompleted = fractionCompleted
  }
  
  public func reverse() -> ProgressPatch {
    return ProgressPatch(1 - fractionCompleted)
  }
  
  public func transition(start: CGFloat, end: CGFloat) -> ValuePatch {
    return .init(((end - start) * fractionCompleted) + start)
  }
  
  public func clip(min: CGFloat, max: CGFloat) -> ProgressPatch {
    return ProgressPatch(Swift.max(Swift.min(fractionCompleted, max), min))
  }
  
  public func progress(start: CGFloat, end: CGFloat) -> ProgressPatch {
    return ValuePatch(fractionCompleted)
      .progress(start: start, end: end)
  }
}

public struct ValuePatch: PatchType {
  
  public typealias Value = CGFloat
  
  public var value: Value
  
  public init(_ value: Value) {
    self.value = value
  }
  
  public func clip(min: CGFloat, max: CGFloat) -> ValuePatch {
    return .init(Swift.max(Swift.min(value, max), min))
  }
  
  public func progress(start: CGFloat, end: CGFloat) -> ProgressPatch {
    return ProgressPatch.init((value - start) / (end - start))
  }
}

public struct PointPatch: PatchType {
  
  public typealias Value = CGPoint
  
  public var value: Value
  
  public init(_ value: Value) {
    self.value = value
  }
  
  public func vector() -> VectorPatch {
    return .init(CGVector(dx: value.x, dy: value.y))
  }
  
  public func distance(from: CGPoint) -> ValuePatch {
    return .init(sqrt(pow(value.x - from.x, 2) + pow(value.y - from.y, 2)))
  }
  
  public func distance(to: CGPoint) -> ValuePatch {
    return .init(sqrt(pow(to.x - value.x, 2) + pow(to.y - value.y, 2)))
  }
}

public struct VectorPatch: PatchType {
  public typealias Value = CGVector
  
  public var value: Value
  
  public init(_ value: Value) {
    self.value = value
  }
  
  public func magnitude() -> CGFloat {
    return sqrt(pow(value.dx, 2) + pow(value.dy, 2))
  }
}

