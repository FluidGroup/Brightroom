//
//  TopControlView.swift
//  PixelEditor
//
//  Created by muukii on 10/10/18.
//  Copyright © 2018 muukii. All rights reserved.
//

import Foundation

open class RootControlViewBase : ControlViewBase {

}

final class RootControlView : RootControlViewBase {

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

  public let colorCubeControlView: ColorCubeControlView

  public lazy var editView = EditMenuControlView(context: context)

  // MARK: - Initializers

  init(context: PixelEditContext, colorCubeControlView: ColorCubeControlView) {

    self.colorCubeControlView = colorCubeControlView

    super.init(context: context)

    backgroundColor = Style.default.control.backgroundColor

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

      filtersButton.setTitle(TODOL10n(raw: "Filter"), for: .normal)
      editButton.setTitle(TODOL10n(raw: "Edit"), for: .normal)

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

  override func didMoveToSuperview() {
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
      containerView.addSubview(colorCubeControlView)
      subscribeChangedEdit(to: colorCubeControlView)

      colorCubeControlView.frame = containerView.bounds
      colorCubeControlView.autoresizingMask = [.flexibleWidth, .flexibleHeight]

      filtersButton.isSelected = true

    case .edit:
      containerView.addSubview(editView)
      subscribeChangedEdit(to: editView)

      editView.frame = containerView.bounds
      editView.autoresizingMask = [.flexibleWidth, .flexibleHeight]

      editButton.isSelected = true
    }
  }

}
