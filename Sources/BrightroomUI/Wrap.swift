
/// https://github.com/VergeGroup/Wrap/edit/main/Sources/Chain/Chain.swift

postfix operator &>

postfix func &> <T>(argument: T) -> Wrap<T> {
  .init(argument)
}

struct Wrap<Value> {
  
  let value: Value
  
  init(_ value: Value) {
    self.value = value
  }
  
}

extension Wrap {
  
  func map<U>(_ transform: (Value) throws -> U) rethrows -> U {
    try transform(value)
  }
  
  @discardableResult
  func `do`(_ applier: (Value) throws -> Void) rethrows -> Value where Value : AnyObject {
    try applier(value)
    return value
  }
  
  func modify(_ modifier: (inout Value) throws -> Void) rethrows -> Value {
    var v = value
    try modifier(&v)
    return v
  }
  
  func filter(_ filter: (Value) -> Bool) -> Value? {
    guard filter(value) else {
      return nil
    }
    return value
  }
  
}

