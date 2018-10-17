//
//  DoodleControlView.swift
//  PixelEditor
//
//  Created by muukii on 10/11/18.
//  Copyright © 2018 muukii. All rights reserved.
//

import Foundation

open class DoodleControlViewBase : ControlViewBase {

}

public final class DoodleControlView : DoodleControlViewBase {

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

      self?.pop()
    }

    navigationView.didTapSaveButton = { [weak self] in

      self?.pop()
    }
  }
}
