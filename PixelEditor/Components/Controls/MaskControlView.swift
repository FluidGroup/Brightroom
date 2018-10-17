//
//  MaskControlView.swift
//  PixelEditor
//
//  Created by muukii on 10/12/18.
//  Copyright © 2018 muukii. All rights reserved.
//

import Foundation

open class MaskControlViewBase : ControlViewBase {

}

public final class MaskControlView : MaskControlViewBase {

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
      self?.context.action(.endMasking(save: false))
    }

    navigationView.didTapSaveButton = { [weak self] in

      self?.pop()
      self?.context.action(.endMasking(save: true))
    }

  }

  public override func didMoveToSuperview() {
    super.didMoveToSuperview()

    if superview != nil {
      context.action(.setMode(.masking))
    } else {
      context.action(.setMode(.preview))
    }

  }
}
