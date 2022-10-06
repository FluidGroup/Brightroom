import UIKit
import Foundation

private final class Proxy {
  static var key: Void?
  private weak var base: UIControl?

  init(_ base: UIControl) {
    self.base = base
  }

  var onTouchUpInside: (() -> Void)? {
    didSet {
      base?.addTarget(self, action: #selector(touchUpInside), for: .touchUpInside)
    }
  }

  @objc private func touchUpInside(sender: AnyObject) {
    onTouchUpInside?()
  }
}

extension UIControl {
  func onTap(_ closure: @escaping () -> Swift.Void) {
    tapable.onTouchUpInside = closure
  }

  private var tapable: Proxy {
    get {
      if let handler = objc_getAssociatedObject(self, &Proxy.key) as? Proxy {
        return handler
      } else {
        self.tapable = Proxy(self)
        return self.tapable
      }
    }
    set {
      objc_setAssociatedObject(self, &Proxy.key, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
  }
}
