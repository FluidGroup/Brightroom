//
//  SaveControlView.swift
//  PixelEditor
//
//  Created by muukii on 10/10/18.
//  Copyright © 2018 muukii. All rights reserved.
//

import Foundation

open class NavigationView : UIStackView {

  public var didTapSaveButton: () -> Void = {}
  public var didTapCancelButton: () -> Void = {}

  private let saveButton = UIButton(type: .system)
  private let cancelButton = UIButton(type: .system)

  public init() {

    super.init(frame: .zero)

    axis = .horizontal
    distribution = .fillEqually

    heightAnchor.constraint(equalToConstant: 50).isActive = true

    addArrangedSubview(cancelButton)
    addArrangedSubview(saveButton)

    cancelButton.setTitle(L10n.cancel, for: .normal)
    saveButton.setTitle(L10n.save, for: .normal)

    cancelButton.setTitleColor(.black, for: .normal)
    saveButton.setTitleColor(.black, for: .normal)

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
    didTapSaveButton()
  }

  @objc
  private func _didTapCancelButton() {
    didTapCancelButton()
  }
}
