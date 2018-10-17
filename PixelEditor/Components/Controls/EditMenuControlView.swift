//
//  EditControlView.swift
//  PixelEditor
//
//  Created by muukii on 10/17/18.
//  Copyright © 2018 muukii. All rights reserved.
//

import Foundation

open class EditMenuControlView : ControlViewBase {

  public let contentView = UIView()
  public let itemsView = UIStackView()
  public let scrollView = UIScrollView()

  open override func setup() {

    super.setup()

    backgroundColor = Style.default.control.backgroundColor

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
      itemsView.distribution = .fillEqually
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

        let button = ButtonView(name: TODOL10n("Adjust"), image: .init())
        button.addTarget(self, action: #selector(adjustment), for: .touchUpInside)
        itemsView.addArrangedSubview(button)
      }

      mask: do {
        let button = ButtonView(name: TODOL10n("Mask"), image: .init())
        button.addTarget(self, action: #selector(masking), for: .touchUpInside)
        itemsView.addArrangedSubview(button)
      }

      //        doodle: do {
      //          let button = ButtonView(name: TODOL10n("Doodle"), image: .init())
      //          button.addTarget(self, action: #selector(doodle), for: .touchUpInside)
      //          itemsView.addArrangedSubview(button)
      //        }

      brightness: do {
        let button = ButtonView(name: TODOL10n("Brightness"), image: .init())
        button.addTarget(self, action: #selector(brightness), for: .touchUpInside)
        itemsView.addArrangedSubview(button)
      }

      gaussianBlur: do {
        let button = ButtonView(name: TODOL10n("Blur"), image: .init())
        button.addTarget(self, action: #selector(blur), for: .touchUpInside)
        itemsView.addArrangedSubview(button)
      }

      /*

       contrast: do {
       let button = ButtonView(name: TODOL10n("Contrast"), image: .init())
       button.addTarget(self, action: #selector(contrast), for: .touchUpInside)
       itemsView.addArrangedSubview(button)
       }

       structure: do {
       let button = ButtonView(name: TODOL10n("Structure"), image: .init())
       button.addTarget(self, action: #selector(structure), for: .touchUpInside)
       itemsView.addArrangedSubview(button)
       }

       warmth: do {
       let button = ButtonView(name: TODOL10n("Warmth"), image: .init())
       button.addTarget(self, action: #selector(warmth), for: .touchUpInside)
       itemsView.addArrangedSubview(button)
       }

       saturation: do {
       let button = ButtonView(name: TODOL10n("Saturation"), image: .init())
       button.addTarget(self, action: #selector(saturation), for: .touchUpInside)
       itemsView.addArrangedSubview(button)
       }

       color: do {
       let button = ButtonView(name: TODOL10n("Color"), image: .init())
       button.addTarget(self, action: #selector(color), for: .touchUpInside)
       itemsView.addArrangedSubview(button)
       }

       fade: do {
       let button = ButtonView(name: TODOL10n("Fade"), image: .init())
       button.addTarget(self, action: #selector(fade), for: .touchUpInside)
       itemsView.addArrangedSubview(button)
       }

       highlights: do {
       let button = ButtonView(name: TODOL10n("Highlights"), image: .init())
       button.addTarget(self, action: #selector(highlights), for: .touchUpInside)
       itemsView.addArrangedSubview(button)
       }

       shadows: do {
       let button = ButtonView(name: TODOL10n("Shadows"), image: .init())
       button.addTarget(self, action: #selector(shadows), for: .touchUpInside)
       itemsView.addArrangedSubview(button)
       }

       vignette: do {
       let button = ButtonView(name: TODOL10n("Vignette"), image: .init())
       button.addTarget(self, action: #selector(vignette), for: .touchUpInside)
       itemsView.addArrangedSubview(button)
       }

       sharpen: do {
       let button = ButtonView(name: TODOL10n("Sharpen"), image: .init())
       button.addTarget(self, action: #selector(sharpen), for: .touchUpInside)
       itemsView.addArrangedSubview(button)
       }
       */
      hls: do {
        // http://flexmonkey.blogspot.com/2016/03/creating-selective-hsl-adjustment.html
      }

    }
  }

  @objc
  private func adjustment() {

    push(AdjustmentControlView(context: context))
  }

  @objc
  private func masking() {

    push(MaskControlView(context: context))
  }

  @objc
  private func doodle() {

    push(DoodleControlView(context: context))
  }

  @objc
  private func brightness() {

    push(BrightnessControlView(context: context))
  }

  @objc
  private func blur() {
    push(GaussianBlurControlView(context: context))
  }

  @objc
  private func contrast() {

  }

  @objc
  private func structure() {

  }

  @objc
  private func warmth() {

  }

  @objc
  private func saturation() {

  }

  @objc
  private func color() {

  }

  @objc
  private func fade() {

  }

  @objc
  private func highlights() {

  }

  @objc
  private func shadows() {

  }

  @objc
  private func vignette() {

  }

  @objc
  private func sharpen() {

  }

  open class ButtonView : UIControl {

    public let nameLabel = UILabel()

    public let imageView = UIImageView()

    public init(name: String, image: UIImage) {
      super.init(frame: .zero)

      layout: do {
        addSubview(nameLabel)
        addSubview(imageView)

        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        imageView.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
          imageView.topAnchor.constraint(equalTo: topAnchor, constant: 8),
          imageView.rightAnchor.constraint(equalTo: rightAnchor, constant: -8),
          imageView.leftAnchor.constraint(equalTo: leftAnchor, constant: 8),
          imageView.widthAnchor.constraint(equalTo: imageView.heightAnchor),

          nameLabel.topAnchor.constraint(equalTo: imageView.bottomAnchor, constant: 8),
          nameLabel.rightAnchor.constraint(equalTo: rightAnchor, constant: -8),
          nameLabel.leftAnchor.constraint(equalTo: leftAnchor, constant: 8),
          nameLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
          ])
      }

      attributes: do {

        imageView.contentMode = .center
        nameLabel.font = UIFont.boldSystemFont(ofSize: 15)
        nameLabel.textColor = .black
        nameLabel.textAlignment = .center

      }

      body: do {

        imageView.image = image
        nameLabel.text = name
      }

    }

    public required init?(coder aDecoder: NSCoder) {
      fatalError("init(coder:) has not been implemented")
    }

    open override var isHighlighted: Bool  {
      didSet {
        UIView.animate(
          withDuration: 0.16,
          delay: 0,
          options: [.beginFromCurrentState],
          animations: {
            if self.isHighlighted {
              self.alpha = 0.6
            } else {
              self.alpha = 1
            }
        },
          completion: nil
        )
      }
    }

  }

}
