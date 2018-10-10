//
//  TopControlView.swift
//  PixelEditor
//
//  Created by muukii on 10/10/18.
//  Copyright © 2018 muukii. All rights reserved.
//

import Foundation

final class TopControlView : UIView, ControlChildViewType {

  enum DisplayType {
    case filter
    case edit
  }

  var displayType: DisplayType = .filter {
    didSet {
      guard oldValue != displayType else { return }
      set(displayType: displayType)
    }
  }

  private let containerView = UIView()

  private lazy var filtesView = FilterControlView()

  private lazy var editView = EditControlView()

  private let filtersButton = UIButton(type: .system)

  private let editButton = UIButton(type: .system)

  init() {

    super.init(frame: .zero)

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

      filtersButton.addTarget(self, action: #selector(didTapFilterButton), for: .touchUpInside)
      editButton.addTarget(self, action: #selector(didTapEditButton), for: .touchUpInside)
    }

    set(displayType: displayType)

  }

  required init?(coder aDecoder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
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

    switch displayType {
    case .filter:
      containerView.addSubview(filtesView)
      editView.frame = containerView.bounds
      editView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    case .edit:
      containerView.addSubview(editView)
      editView.frame = containerView.bounds
      editView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    }
  }

}

extension TopControlView {

  final class EditControlView : UIView, ControlChildViewType {

    private let itemsView = UIStackView()

    init() {
      super.init(frame: .zero)

      stack: do {

        itemsView.axis = .horizontal
        itemsView.alignment = .center
        itemsView.distribution = .equalSpacing
        itemsView.spacing = 8

        itemsView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(itemsView)

        NSLayoutConstraint.activate([
          itemsView.topAnchor.constraint(greaterThanOrEqualTo: itemsView.superview!.topAnchor),
          itemsView.rightAnchor.constraint(equalTo: itemsView.superview!.rightAnchor),
          itemsView.leftAnchor.constraint(equalTo: itemsView.superview!.leftAnchor),
          itemsView.bottomAnchor.constraint(greaterThanOrEqualTo: itemsView.superview!.bottomAnchor),
          itemsView.centerYAnchor.constraint(equalTo: itemsView.superview!.centerYAnchor),
          ])

      }

      item: do {

        let button = UIButton(type: .system)

        button.addTarget(self, action: #selector(adjustment), for: .touchUpInside)
        button.setTitle(TODOL10n("Adjust"), for: .normal)
        itemsView.addArrangedSubview(button)
      }
    }

    required init?(coder aDecoder: NSCoder) {
      fatalError("init(coder:) has not been implemented")
    }

    @objc
    private func adjustment() {

      push(AdjustmentControlView()) 
    }
  }

  final class FilterControlView : UIView, ControlChildViewType {

    init() {
      super.init(frame: .zero)
    }

    required init?(coder aDecoder: NSCoder) {
      fatalError("init(coder:) has not been implemented")
    }
  }

}
