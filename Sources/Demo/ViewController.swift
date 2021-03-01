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

import UIKit

import PixelEngine

class ViewController: UIViewController {

  @IBOutlet weak var imageView: UIImageView!

  override func viewDidLoad() {
    super.viewDidLoad()
  
  }

  @IBAction func didTapButton(_ sender: Any) {

    let image = UIImage(named: "small")!

    let engine = ImageRenderer(source: CIImage(image: image)!)

    let path = DrawnPath(
      brush: .init(color: .red, width: 30),
      path: .init(rect: CGRect.init(x: 0, y: 0, width: 50, height: 50))
    )

    engine.edit.croppingRect = .init(imageSize: .init(image: image), cropRect: .init(origin: .zero, size: .init(width: 400, height: 400)))
    engine.edit.drawer = [
      path,
      BlurredMask(paths: []),
    ]

    let result = engine.render()

    imageView.image = result
  }
}
