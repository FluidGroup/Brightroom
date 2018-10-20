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
  
  private let removeAllButton = UIButton.init(type: .system)

  public override func setup() {
    super.setup()

    backgroundColor = Style.default.control.backgroundColor

    addSubview(removeAllButton)
    addSubview(navigationView)

    removeAllButton.translatesAutoresizingMaskIntoConstraints = false
    navigationView.translatesAutoresizingMaskIntoConstraints = false

    NSLayoutConstraint.activate([
      
      removeAllButton.topAnchor.constraint(greaterThanOrEqualTo: navigationView.superview!.topAnchor),
      removeAllButton.rightAnchor.constraint(equalTo: navigationView.superview!.rightAnchor),
      removeAllButton.leftAnchor.constraint(equalTo: navigationView.superview!.leftAnchor),
      
      navigationView.topAnchor.constraint(greaterThanOrEqualTo: removeAllButton.bottomAnchor),
      navigationView.rightAnchor.constraint(equalTo: navigationView.superview!.rightAnchor),
      navigationView.leftAnchor.constraint(equalTo: navigationView.superview!.leftAnchor),
      navigationView.bottomAnchor.constraint(equalTo: navigationView.superview!.bottomAnchor),
      ])
    
    removeAllButton.addTarget(self, action: #selector(didTapRemoveAllButton), for: .touchUpInside)
    
    removeAllButton.setTitle("RemoveAll", for: .normal)
    removeAllButton.titleLabel?.font = UIFont.boldSystemFont(ofSize: 17)

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
  
  @objc
  private func didTapRemoveAllButton() {
    
    context.action(.removeAllMasking)
  }
}
