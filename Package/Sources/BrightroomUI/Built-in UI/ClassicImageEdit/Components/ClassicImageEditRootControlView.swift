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

open class ClassicImageEditRootControlBase: ClassicImageEditControlBase {

  public required init(
    viewModel: ClassicImageEditViewModel,
    editMenuControl: ClassicImageEditEditMenuControlBase,
    presetListControl: ClassicImageEditPresetListControlBase
  ) {
    super.init(viewModel: viewModel)
  }
}

open class ClassicImageEditRootControl: ClassicImageEditRootControlBase {

  public enum DisplayType {
    case filter
    case edit
  }

  public var displayType: DisplayType = .filter {
    didSet {
      guard oldValue != displayType else { return }
      set(displayType: displayType)
    }
  }

  public let filtersButton = UIButton(type: .system)

  public let editButton = UIButton(type: .system)

  private let containerView = UIView()

  public let presetListControl: ClassicImageEditPresetListControlBase

  public let editMenuControl: ClassicImageEditEditMenuControlBase

  // MARK: - Initializers

  public required init(
    viewModel: ClassicImageEditViewModel,
    editMenuControl: ClassicImageEditEditMenuControlBase,
    presetListControl: ClassicImageEditPresetListControlBase
  ) {

    self.presetListControl = presetListControl
    self.editMenuControl = editMenuControl

    super.init(
      viewModel: viewModel,
      editMenuControl: editMenuControl,
      presetListControl: presetListControl
    )

    backgroundColor = ClassicImageEditStyle.default.control.backgroundColor

    layout: do {

      let stackView = UIStackView(arrangedSubviews: [filtersButton, editButton])
      stackView.axis = .horizontal
      stackView.distribution = .fillEqually

      addSubview(containerView)
      addSubview(stackView)

      containerView.translatesAutoresizingMaskIntoConstraints = false
      stackView.translatesAutoresizingMaskIntoConstraints = false

      NSLayoutConstraint.activate([

        containerView.topAnchor.constraint(equalTo: containerView.superview!.topAnchor),
        containerView.leftAnchor.constraint(equalTo: containerView.superview!.leftAnchor),
        containerView.rightAnchor.constraint(equalTo: containerView.superview!.rightAnchor),

        stackView.topAnchor.constraint(equalTo: containerView.bottomAnchor),
        stackView.leftAnchor.constraint(equalTo: stackView.superview!.leftAnchor),
        stackView.rightAnchor.constraint(equalTo: stackView.superview!.rightAnchor),
        stackView.bottomAnchor.constraint(equalTo: stackView.superview!.bottomAnchor),
        stackView.heightAnchor.constraint(equalToConstant: 50),
      ])

    }

    body: do {

      filtersButton.setTitle(viewModel.localizedStrings.filter, for: .normal)
      editButton.setTitle(viewModel.localizedStrings.edit, for: .normal)

      filtersButton.tintColor = .clear
      editButton.tintColor = .clear

      filtersButton.setTitleColor(UIColor.black.withAlphaComponent(0.5), for: .normal)
      editButton.setTitleColor(UIColor.black.withAlphaComponent(0.5), for: .normal)

      filtersButton.setTitleColor(.black, for: .selected)
      editButton.setTitleColor(.black, for: .selected)

      filtersButton.titleLabel!.font = UIFont.boldSystemFont(ofSize: 17)
      editButton.titleLabel!.font = UIFont.boldSystemFont(ofSize: 17)

      filtersButton.addTarget(self, action: #selector(didTapFilterButton), for: .touchUpInside)
      editButton.addTarget(self, action: #selector(didTapEditButton), for: .touchUpInside)
    }

  }

  // MARK: - Functions

  open override func didMoveToSuperview() {
    super.didMoveToSuperview()

    if superview != nil {
      set(displayType: displayType)
    }
  }

  @objc
  private func didTapFilterButton() {

    displayType = .filter
  }

  @objc
  private func didTapEditButton() {

    displayType = .edit
  }

  private func set(displayType: DisplayType) {

    containerView.subviews.forEach { $0.removeFromSuperview() }

    filtersButton.isSelected = false
    editButton.isSelected = false

    switch displayType {
    case .filter:

      presetListControl.frame = containerView.bounds
      presetListControl.autoresizingMask = [.flexibleWidth, .flexibleHeight]
      containerView.addSubview(presetListControl)

      filtersButton.isSelected = true

    case .edit:

      editMenuControl.frame = containerView.bounds
      editMenuControl.autoresizingMask = [.flexibleWidth, .flexibleHeight]

      containerView.addSubview(editMenuControl)

      editButton.isSelected = true
    }
  }

}

/// A view that disabled preset and edit selection button.
/// It displays the edit panel directly.
open class ClassicImageEditNoPresetRootControl: ClassicImageEditRootControlBase {

  private let containerView = UIView()

  public let editMenuControl: ClassicImageEditEditMenuControlBase

  // MARK: - Initializers

  public required init(
    viewModel: ClassicImageEditViewModel,
    editMenuControl: ClassicImageEditEditMenuControlBase,
    presetListControl: ClassicImageEditPresetListControlBase
  ) {

    self.editMenuControl = editMenuControl

    super.init(
      viewModel: viewModel,
      editMenuControl: editMenuControl,
      presetListControl: presetListControl
    )

    backgroundColor = ClassicImageEditStyle.default.control.backgroundColor

    layout: do {

      addSubview(containerView)

      containerView.translatesAutoresizingMaskIntoConstraints = false

      NSLayoutConstraint.activate([
        containerView.topAnchor.constraint(equalTo: containerView.superview!.topAnchor),
        containerView.leftAnchor.constraint(equalTo: containerView.superview!.leftAnchor),
        containerView.rightAnchor.constraint(equalTo: containerView.superview!.rightAnchor),
        containerView.bottomAnchor.constraint(equalTo: containerView.superview!.bottomAnchor),
      ])

      editMenuControl.frame = containerView.bounds
      editMenuControl.autoresizingMask = [.flexibleWidth, .flexibleHeight]
      containerView.addSubview(editMenuControl)
    }

  }

}
