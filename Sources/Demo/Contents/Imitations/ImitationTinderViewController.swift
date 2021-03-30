//
// Copyright (c) 2021 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
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

import BrightroomUI
import TinyConstraints
import UIKit

final class ImitationTinderViewController: UIViewController {

  private let wrapper = WrapperCropView()

  override func viewDidLoad() {
    super.viewDidLoad()
    navigationItem.largeTitleDisplayMode = .never

    view.backgroundColor = .init(white: 0.96, alpha: 1)

    view.addSubview(wrapper)

    wrapper.edgesToSuperview(excluding: .bottom, usingSafeArea: true)

    didSelectImage(Asset.profile.image)
  }

  private func didSelectImage(_ image: UIImage) {

    wrapper.setTargetImage(image)
  }

  private func cropImage() {

    let image = try! wrapper.currentCropView?.renderImage()?.uiImage

    print(image as Any)

  }
}

private final class WrapperCropView: UIView {

  private(set) var currentCropView: CropView?

  init() {

    super.init(frame: .zero)

    /* Using TinyConstraints */
    height(300)

    backgroundColor = .white
    clipsToBounds = true
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func setTargetImage(_ image: UIImage) {

    currentCropView?.removeFromSuperview()

    let cropView = CropView(image: image, contentInset: .init(top: 4, left: 4, bottom: 4, right: 4))

    let outsideOverlay = CropView.CropOutsideOverlayBase()
    outsideOverlay.backgroundColor = UIColor.init(white: 1, alpha: 0.7)

    cropView.setCropOutsideOverlay(outsideOverlay)

    cropView.setLoadingOverlay(factory: {
      LoadingBlurryOverlayView(
        effect: UIBlurEffect(style: .extraLight),
        activityIndicatorStyle: .gray
      )
    })

    cropView.isGuideInteractionEnabled = false

    cropView.setCropInsideOverlay(InsideOverlay())

    cropView.setCroppingAspectRatio(.init(width: 5, height: 7))

    addSubview(cropView)

    cropView.edgesToSuperview()

  }

}

private final class InsideOverlay: CropView.CropInsideOverlayBase {

  private let gridView = CropView.RuleOfThirdsView(lineColor: .white)
  private let borderView = UIView()
  private let shapeLayer = CAShapeLayer()

  override init() {
    super.init()

    addSubview(gridView)
    addSubview(borderView)
    layer.addSublayer(shapeLayer)

    gridView.edgesToSuperview(insets: .init(top: 4, left: 4, bottom: 4, right: 4))
    borderView.edgesToSuperview(insets: .init(top: 4, left: 4, bottom: 4, right: 4))

    gridView.layer.borderWidth = 1
    gridView.layer.borderColor = UIColor.white.cgColor
    gridView.layer.cornerRadius = 8
    if #available(iOS 13.0, *) {
      gridView.layer.cornerCurve = .continuous
    } else {
      // Fallback on earlier versions
    }

  }

  override func layoutSubviews() {
    super.layoutSubviews()

    CATransaction.begin()
    CATransaction.setDisableActions(true)

    shapeLayer.frame = bounds

    let path = UIBezierPath(rect: bounds)
    path.append(UIBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 4), cornerRadius: 8))

    shapeLayer.path = path.cgPath
    shapeLayer.fillRule = .evenOdd
    shapeLayer.fillColor = UIColor.init(white: 1, alpha: 0.7).cgColor

    CATransaction.commit()
  }

}
