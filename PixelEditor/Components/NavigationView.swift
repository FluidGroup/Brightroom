//
//  SaveControlView.swift
//  PixelEditor
//
//  Created by muukii on 10/10/18.
//  Copyright © 2018 muukii. All rights reserved.
//

import Foundation

final class NavigationView : UIStackView {

  var didTapSaveButton: () -> Void = {}
  var didTapCancelButton: () -> Void = {}

  private let saveButton = UIButton(type: .system)
  private let cancelButton = UIButton(type: .system)

  init() {

    super.init(frame: .zero)

    axis = .horizontal
    distribution = .fillEqually

    addArrangedSubview(cancelButton)
    addArrangedSubview(saveButton)

    cancelButton.setTitle(TODOL10n("Cancel"), for: .normal)
    saveButton.setTitle(TODOL10n("Save"), for: .normal)

    cancelButton.setTitleColor(.black, for: .normal)
    saveButton.setTitleColor(.black, for: .normal)

    cancelButton.titleLabel!.font = UIFont.systemFont(ofSize: 17)
    saveButton.titleLabel!.font = UIFont.boldSystemFont(ofSize: 17)

    cancelButton.addTarget(self, action: #selector(_didTapCancelButton), for: .touchUpInside)
    saveButton.addTarget(self, action: #selector(_didTapSaveButton), for: .touchUpInside)
  }

  required init(coder: NSCoder) {
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
