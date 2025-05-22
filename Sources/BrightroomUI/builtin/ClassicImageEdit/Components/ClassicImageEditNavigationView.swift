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

open class ClassicImageEditNavigationView : UIStackView {

  public var didTapDoneButton: () -> Void = {}
  public var didTapCancelButton: () -> Void = {}

  private let saveButton = UIButton(type: .system)
  private let cancelButton = UIButton(type: .system)
  
  private let feedbacker = UIImpactFeedbackGenerator(style: .light)

  public init(saveText: String, cancelText: String) {

    super.init(frame: .zero)

    axis = .horizontal
    distribution = .fillEqually

    heightAnchor.constraint(equalToConstant: 50).isActive = true

    addArrangedSubview(cancelButton)
    addArrangedSubview(saveButton)

    cancelButton.setTitle(cancelText, for: .normal)
    saveButton.setTitle(saveText, for: .normal)

    cancelButton.setTitleColor(ClassicImageEditStyle.default.black, for: .normal)
    saveButton.setTitleColor(ClassicImageEditStyle.default.black, for: .normal)

    cancelButton.titleLabel!.font = UIFont.systemFont(ofSize: 17)
    saveButton.titleLabel!.font = UIFont.boldSystemFont(ofSize: 17)

    cancelButton.addTarget(self, action: #selector(_didTapCancelButton), for: .touchUpInside)
    saveButton.addTarget(self, action: #selector(_didTapSaveButton), for: .touchUpInside)
  }

  public required init(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  @objc
  private func _didTapSaveButton() {
    didTapDoneButton()
    feedbacker.impactOccurred()
  }

  @objc
  private func _didTapCancelButton() {
    didTapCancelButton()
    feedbacker.impactOccurred()
  }
}
