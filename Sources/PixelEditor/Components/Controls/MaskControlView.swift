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
import Foundation

open class MaskControlBase : ControlBase {

}

public final class MaskControl : MaskControlBase {

  private let navigationView = NavigationView()
  
  private let removeAllButton = UIButton.init(type: .system)

  public override func setup() {
    super.setup()

    backgroundColor = Style.default.control.backgroundColor

    addSubview(removeAllButton)
    addSubview(navigationView)

    removeAllButton.translatesAutoresizingMaskIntoConstraints = false
    navigationView.translatesAutoresizingMaskIntoConstraints = false

    NSLayoutConstraint.activate([
      
      removeAllButton.topAnchor.constraint(greaterThanOrEqualTo: navigationView.superview!.topAnchor),
      removeAllButton.rightAnchor.constraint(equalTo: navigationView.superview!.rightAnchor),
      removeAllButton.leftAnchor.constraint(equalTo: navigationView.superview!.leftAnchor),
      
      navigationView.topAnchor.constraint(greaterThanOrEqualTo: removeAllButton.bottomAnchor),
      navigationView.rightAnchor.constraint(equalTo: navigationView.superview!.rightAnchor),
      navigationView.leftAnchor.constraint(equalTo: navigationView.superview!.leftAnchor),
      navigationView.bottomAnchor.constraint(equalTo: navigationView.superview!.bottomAnchor),
      ])
    
    removeAllButton.addTarget(self, action: #selector(didTapRemoveAllButton), for: .touchUpInside)
    
    removeAllButton.setTitle("RemoveAll", for: .normal)
    removeAllButton.titleLabel?.font = UIFont.boldSystemFont(ofSize: 17)

    navigationView.didTapCancelButton = { [weak self] in

      self?.pop()
      self?.context.action(.endMasking(save: false))
    }

    navigationView.didTapSaveButton = { [weak self] in

      self?.pop()
      self?.context.action(.endMasking(save: true))
    }

  }

  public override func didMoveToSuperview() {
    super.didMoveToSuperview()

    if superview != nil {
      context.action(.setMode(.masking))
    } else {
      context.action(.setMode(.preview))
    }

  }
  
  @objc
  private func didTapRemoveAllButton() {
    
    context.action(.removeAllMasking)
  }
}
