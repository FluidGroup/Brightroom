//
//  TopControlView.swift
//  PixelEditor
//
//  Created by muukii on 10/10/18.
//  Copyright © 2018 muukii. All rights reserved.
//

import Foundation

final class TopControlView : ControlViewBase, ControlChildViewType {

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

  private lazy var filtesView = FilterControlView(context: context)

  private lazy var editView = EditControlView(context: context)

  private let filtersButton = UIButton(type: .system)

  private let editButton = UIButton(type: .system)

  override init(context: PixelEditContext) {

    super.init(context: context)

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

  final class EditControlView : ControlViewBase, ControlChildViewType {

    private let contentView = UIView()
    private let itemsView = UIStackView()
    private let scrollView = UIScrollView()

    override func setup() {

      super.setup()

      backgroundColor = .white

      layout: do {

        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        if #available(iOS 11.0, *) {
          scrollView.contentInsetAdjustmentBehavior = .never
        }
        scrollView.contentInset.right = 36
        scrollView.contentInset.left = 36
        addSubview(scrollView)

        scrollView.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
          scrollView.topAnchor.constraint(equalTo: scrollView.superview!.topAnchor),
          scrollView.rightAnchor.constraint(equalTo: scrollView.superview!.rightAnchor),
          scrollView.leftAnchor.constraint(equalTo: scrollView.superview!.leftAnchor),
          scrollView.bottomAnchor.constraint(equalTo: scrollView.superview!.bottomAnchor),
          ])

        scrollView.addSubview(contentView)

        contentView.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
          contentView.widthAnchor.constraint(greaterThanOrEqualTo: contentView.superview!.widthAnchor, constant: -(scrollView.contentInset.right + scrollView.contentInset.left)),
          contentView.heightAnchor.constraint(equalTo: contentView.superview!.heightAnchor),
          contentView.topAnchor.constraint(equalTo: contentView.superview!.topAnchor),
          contentView.rightAnchor.constraint(equalTo: contentView.superview!.rightAnchor),
          contentView.leftAnchor.constraint(equalTo: contentView.superview!.leftAnchor),
          contentView.bottomAnchor.constraint(equalTo: contentView.superview!.bottomAnchor),
          ])

        contentView.addSubview(itemsView)

        itemsView.axis = .horizontal
        itemsView.alignment = .center
        itemsView.distribution = .equalCentering
        itemsView.spacing = 16

        itemsView.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
          itemsView.heightAnchor.constraint(equalTo: itemsView.superview!.heightAnchor),
          itemsView.topAnchor.constraint(equalTo: itemsView.superview!.topAnchor),
          itemsView.rightAnchor.constraint(lessThanOrEqualTo: itemsView.superview!.rightAnchor),
          itemsView.leftAnchor.constraint(greaterThanOrEqualTo: itemsView.superview!.leftAnchor),
          itemsView.bottomAnchor.constraint(equalTo: itemsView.superview!.bottomAnchor),
          itemsView.centerXAnchor.constraint(equalTo: itemsView.superview!.centerXAnchor),
          ])

      }

      item: do {

        adjustment: do {
          let button = UIButton(type: .system)
          button.addTarget(self, action: #selector(adjustment), for: .touchUpInside)
          button.setTitle(TODOL10n("Adjust"), for: .normal)
          itemsView.addArrangedSubview(button)
        }

        doodle: do {
          let button = UIButton(type: .system)
          button.addTarget(self, action: #selector(doodle), for: .touchUpInside)
          button.setTitle(TODOL10n("Doodle"), for: .normal)
          itemsView.addArrangedSubview(button)
        }

      }
    }

    @objc
    private func adjustment() {

      push(AdjustmentControlView(context: context))
    }

    @objc
    private func doodle() {

      push(DoodleControlView(context: context))
    }
    
  }

  final class FilterControlView : ControlViewBase, ControlChildViewType {

    override func setup() {
      super.setup()
      backgroundColor = .white
    }
  }

}
