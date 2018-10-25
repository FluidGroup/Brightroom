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

open class AdjustmentControlBase : ControlBase {

}

public final class AdjustmentControl : AdjustmentControlBase {

  private let navigationView = NavigationView()

  public override func setup() {
    super.setup()

    backgroundColor = Style.default.control.backgroundColor

    addSubview(navigationView)

    navigationView.translatesAutoresizingMaskIntoConstraints = false

    NSLayoutConstraint.activate([
      navigationView.rightAnchor.constraint(equalTo: navigationView.superview!.rightAnchor),
      navigationView.leftAnchor.constraint(equalTo: navigationView.superview!.leftAnchor),
      navigationView.bottomAnchor.constraint(equalTo: navigationView.superview!.bottomAnchor),
      navigationView.topAnchor.constraint(greaterThanOrEqualTo: navigationView.superview!.topAnchor),
      ])

    navigationView.didTapCancelButton = { [weak self] in

      self?.context.action(.endAdjustment(save: false))
        self?.pop(animated: true)
    }

    navigationView.didTapDoneButton = { [weak self] in

      self?.context.action(.endAdjustment(save: true))
        self?.pop(animated: true)
    }

  }

  public override func didMoveToSuperview() {
    super.didMoveToSuperview()

    if superview != nil {
      context.action(.setMode(.adjustment))
    } else {
      context.action(.setMode(.preview))
    }

  }

}

