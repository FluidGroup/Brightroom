//
// Copyright (c) 2021 Muukii <muukii.app@gmail.com>
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

import UIKit

public final class LoadingBlurryOverlayView: PixelEditorCodeBasedView {
  
  public init(
    effect: UIVisualEffect,
    activityIndicatorStyle: UIActivityIndicatorView.Style
  ) {
    super.init(frame: .zero)

    let effectView = UIVisualEffectView(effect: effect)
    let activityIndicatorView = UIActivityIndicatorView(style: activityIndicatorStyle)

    backgroundColor = .clear

    addSubview(effectView)
    addSubview(activityIndicatorView)

    activityIndicatorView.startAnimating()
    activityIndicatorView.hidesWhenStopped = false
    activityIndicatorView.isHidden = false

    [effectView, activityIndicatorView].forEach {
      $0.translatesAutoresizingMaskIntoConstraints = false
    }

    NSLayoutConstraint.activate([
      effectView.leadingAnchor.constraint(equalTo: leadingAnchor),
      effectView.trailingAnchor.constraint(equalTo: trailingAnchor),
      effectView.topAnchor.constraint(equalTo: topAnchor),
      effectView.bottomAnchor.constraint(equalTo: bottomAnchor),
      activityIndicatorView.centerYAnchor.constraint(equalTo: centerYAnchor),
      activityIndicatorView.centerXAnchor.constraint(equalTo: centerXAnchor),
    ])
  }
}
