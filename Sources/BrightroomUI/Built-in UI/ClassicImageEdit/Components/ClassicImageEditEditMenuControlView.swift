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

#if !COCOAPODS
import BrightroomEngine
#endif
import Verge

open class ClassicImageEditEditMenuControlBase: ClassicImageEditControlBase {
  override public required init(viewModel: ClassicImageEditViewModel) {
    super.init(viewModel: viewModel)
  }
}

public enum ClassicImageEditEditMenu: CaseIterable {
  case adjustment
  case mask
  case exposure
  case contrast
  case clarity
  case temperature
  case saturation
  case fade
  case highlights
  case shadows
  case vignette
  case sharpen
  case gaussianBlur
  
  open class EditMenuControl: ClassicImageEditEditMenuControlBase {
    public let contentView = UIView()
    public let itemsView = UIStackView()
    public let scrollView = UIScrollView()
    
    public lazy var adjustmentButton: ButtonView = {
      let button = ButtonView(
        name: viewModel.localizedStrings.editAdjustment,
        image: UIImage(named: "adjustment", in: bundle, compatibleWith: nil)!
      )
      button.addTarget(self, action: #selector(adjustment), for: .touchUpInside)
      return button
    }()
    
    public lazy var maskButton: ButtonView = {
      let button = ButtonView(
        name: viewModel.localizedStrings.editMask,
        image: UIImage(named: "mask", in: bundle, compatibleWith: nil)!
      )
      button.addTarget(self, action: #selector(masking), for: .touchUpInside)
      return button
    }()
    
    public lazy var exposureButton: ButtonView = {
      let button = ButtonView(
        name: viewModel.localizedStrings.editBrightness,
        image: UIImage(named: "brightness", in: bundle, compatibleWith: nil)!
      )
      button.addTarget(self, action: #selector(brightness), for: .touchUpInside)
      return button
    }()
    
    public lazy var gaussianBlurButton: ButtonView = {
      let button = ButtonView(
        name: viewModel.localizedStrings.editBlur,
        image: UIImage(named: "blur", in: bundle, compatibleWith: nil)!
      )
      button.addTarget(self, action: #selector(blur), for: .touchUpInside)
      return button
    }()
    
    public lazy var contrastButton: ButtonView = {
      let button = ButtonView(
        name: viewModel.localizedStrings.editContrast,
        image: UIImage(named: "contrast", in: bundle, compatibleWith: nil)!
      )
      button.addTarget(self, action: #selector(contrast), for: .touchUpInside)
      return button
    }()
    
    public lazy var temperatureButton: ButtonView = {
      let button = ButtonView(
        name: viewModel.localizedStrings.editTemperature,
        image: UIImage(named: "temperature", in: bundle, compatibleWith: nil)!
      )
      button.addTarget(self, action: #selector(warmth), for: .touchUpInside)
      return button
    }()
    
    public lazy var saturationButton: ButtonView = {
      let button = ButtonView(
        name: viewModel.localizedStrings.editSaturation,
        image: UIImage(named: "saturation", in: bundle, compatibleWith: nil)!
      )
      button.addTarget(self, action: #selector(saturation), for: .touchUpInside)
      return button
    }()
    
    public lazy var highlightsButton: ButtonView = {
      let button = ButtonView(
        name: viewModel.localizedStrings.editHighlights,
        image: UIImage(named: "highlights", in: bundle, compatibleWith: nil)!
      )
      button.addTarget(self, action: #selector(highlights), for: .touchUpInside)
      return button
    }()
    
    public lazy var shadowsButton: ButtonView = {
      let button = ButtonView(
        name: viewModel.localizedStrings.editShadows,
        image: UIImage(named: "shadows", in: bundle, compatibleWith: nil)!
      )
      button.addTarget(self, action: #selector(shadows), for: .touchUpInside)
      return button
    }()
    
    public lazy var vignetteButton: ButtonView = {
      let button = ButtonView(
        name: viewModel.localizedStrings.editVignette,
        image: UIImage(named: "vignette", in: bundle, compatibleWith: nil)!
      )
      button.addTarget(self, action: #selector(vignette), for: .touchUpInside)
      return button
    }()
    
    public lazy var fadeButton: ButtonView = {
      let button = ButtonView(
        name: viewModel.localizedStrings.editFade,
        image: UIImage(named: "fade", in: bundle, compatibleWith: nil)!
      )
      button.addTarget(self, action: #selector(fade), for: .touchUpInside)
      return button
    }()
    
    public lazy var sharpenButton: ButtonView = {
      let button = ButtonView(
        name: viewModel.localizedStrings.editSharpen,
        image: UIImage(named: "sharpen", in: bundle, compatibleWith: nil)!
      )
      button.addTarget(self, action: #selector(sharpen), for: .touchUpInside)
      return button
    }()
    
    public lazy var clarityButton: ButtonView = {
      let button = ButtonView(
        name: viewModel.localizedStrings.editClarity,
        image: UIImage(named: "structure", in: bundle, compatibleWith: nil)!
      )
      button.addTarget(self, action: #selector(clarity), for: .touchUpInside)
      return button
    }()
    
    override open func setup() {
      super.setup()
      
      backgroundColor = ClassicImageEditStyle.default.control.backgroundColor
      
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
          contentView.widthAnchor.constraint(
            greaterThanOrEqualTo: contentView.superview!.widthAnchor,
            constant: -(scrollView.contentInset.right + scrollView.contentInset.left)
          ),
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
        let ignoredEditMenu: [ClassicImageEditEditMenu] = viewModel.options.classes.control.ignoredEditMenu
        let displayedMenu = ClassicImageEditEditMenu.allCases.filter { ignoredEditMenu.contains($0) == false }
        
        var buttons: [ButtonView] = []
        
        for editMenu in displayedMenu {
          switch editMenu {
          case .adjustment:
            buttons.append(adjustmentButton)
          case .mask:
            buttons.append(maskButton)
          case .exposure:
            buttons.append(exposureButton)
          case .gaussianBlur:
            buttons.append(gaussianBlurButton)
          case .contrast:
            buttons.append(contrastButton)
          case .temperature:
            buttons.append(temperatureButton)
          case .saturation:
            buttons.append(saturationButton)
          case .highlights:
            buttons.append(highlightsButton)
          case .shadows:
            buttons.append(shadowsButton)
          case .vignette:
            buttons.append(vignetteButton)
          case .fade:
            buttons.append(fadeButton)
          case .sharpen:
            buttons.append(sharpenButton)
          case .clarity:
            buttons.append(clarityButton)
          }
        }
        
        for button in buttons {
          itemsView.addArrangedSubview(button)
        }
        
        /*
         
         color: do {
         let button = ButtonView(name: TODOL10n("Color"), image: .init())
         button.addTarget(self, action: #selector(color), for: .touchUpInside)
         itemsView.addArrangedSubview(button)
         }
         
         */
        hls: do {
          // http://flexmonkey.blogspot.com/2016/03/creating-selective-hsl-adjustment.html
        }
      }
    }
    
    override open func didReceiveCurrentEdit(state: Changes<ClassicImageEditViewModel.State>) {
      if let edit = state.editingState.loadedState?.currentEdit {
        maskButton.hasChanges = !edit.drawings.blurredMaskPaths.isEmpty
        
        contrastButton.hasChanges = edit.filters.contrast != nil
        exposureButton.hasChanges = edit.filters.exposure != nil
        temperatureButton.hasChanges = edit.filters.temperature != nil
        saturationButton.hasChanges = edit.filters.saturation != nil
        highlightsButton.hasChanges = edit.filters.highlights != nil
        shadowsButton.hasChanges = edit.filters.shadows != nil
        vignetteButton.hasChanges = edit.filters.vignette != nil
        gaussianBlurButton.hasChanges = edit.filters.gaussianBlur != nil
        fadeButton.hasChanges = edit.filters.fade != nil
        sharpenButton.hasChanges = edit.filters.sharpen != nil
        clarityButton.hasChanges = edit.filters.unsharpMask != nil
      }
    }
    
    @objc
    private func adjustment() {
      push(ClassicImageEditCropControl(viewModel: viewModel), animated: true)
    }
    
    @objc
    private func masking() {
      push(ClassicImageEditMaskControl(viewModel: viewModel), animated: true)
    }
    
    @objc
    private func doodle() {
      push(ClassicImageEditDoodleControl(viewModel: viewModel), animated: true)
    }
    
    @objc
    private func brightness() {
      push(
        viewModel.options.classes.control.exposureControl.init(viewModel: viewModel),
        animated: true
      )
    }
    
    @objc
    private func blur() {
      push(
        viewModel.options.classes.control.gaussianBlurControl.init(viewModel: viewModel),
        animated: true
      )
    }
    
    @objc
    private func contrast() {
      push(
        viewModel.options.classes.control.contrastControl.init(viewModel: viewModel),
        animated: true
      )
    }
    
    @objc
    private func clarity() {
      push(
        viewModel.options.classes.control.clarityControl.init(viewModel: viewModel),
        animated: true
      )
    }
    
    @objc
    private func warmth() {
      push(
        viewModel.options.classes.control.temperatureControl.init(viewModel: viewModel),
        animated: true
      )
    }
    
    @objc
    private func saturation() {
      push(
        viewModel.options.classes.control.saturationControl.init(viewModel: viewModel),
        animated: true
      )
    }
    
    @objc
    private func color() {}
    
    @objc
    private func fade() {
      push(viewModel.options.classes.control.fadeControl.init(viewModel: viewModel), animated: true)
    }
    
    @objc
    private func highlights() {
      push(
        viewModel.options.classes.control.highlightsControl.init(viewModel: viewModel),
        animated: true
      )
    }
    
    @objc
    private func shadows() {
      push(
        viewModel.options.classes.control.shadowsControl.init(viewModel: viewModel),
        animated: true
      )
    }
    
    @objc
    private func vignette() {
      push(
        viewModel.options.classes.control.vignetteControl.init(viewModel: viewModel),
        animated: true
      )
    }
    
    @objc
    private func sharpen() {
      push(
        viewModel.options.classes.control.sharpenControl.init(viewModel: viewModel),
        animated: true
      )
    }
    
    open class ButtonView: UIControl {
      public let nameLabel = UILabel()
      
      public let imageView = UIImageView()
      
      public let changesMarkView = UIView()
      
      private let feedbackGenerator = UISelectionFeedbackGenerator()
      
      public var hasChanges: Bool = false {
        didSet {
          guard oldValue != hasChanges else { return }
          changesMarkView.isHidden = !hasChanges
        }
      }
      
      public init(name: String, image: UIImage) {
        super.init(frame: .zero)
        
        layout: do {
          addSubview(nameLabel)
          addSubview(imageView)
          addSubview(changesMarkView)
          
          nameLabel.translatesAutoresizingMaskIntoConstraints = false
          imageView.translatesAutoresizingMaskIntoConstraints = false
          changesMarkView.translatesAutoresizingMaskIntoConstraints = false
          
          NSLayoutConstraint.activate([
            changesMarkView.topAnchor.constraint(equalTo: topAnchor, constant: 0),
            changesMarkView.centerXAnchor.constraint(equalTo: centerXAnchor),
            changesMarkView.widthAnchor.constraint(equalToConstant: 4),
            changesMarkView.heightAnchor.constraint(equalToConstant: 4),
            
            imageView.topAnchor.constraint(equalTo: changesMarkView.bottomAnchor, constant: 8),
            imageView.rightAnchor.constraint(lessThanOrEqualTo: rightAnchor, constant: -4),
            imageView.leftAnchor.constraint(greaterThanOrEqualTo: leftAnchor, constant: 4),
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 50),
            imageView.widthAnchor.constraint(equalTo: imageView.heightAnchor),
            
            nameLabel.topAnchor.constraint(equalTo: imageView.bottomAnchor, constant: 12),
            nameLabel.rightAnchor.constraint(equalTo: rightAnchor, constant: 0),
            nameLabel.leftAnchor.constraint(equalTo: leftAnchor, constant: 0),
            nameLabel.bottomAnchor.constraint(equalTo: bottomAnchor),
            
          ])
        }
        
        style: do {
          imageView.contentMode = .scaleAspectFill
          imageView.tintColor = ClassicImageEditStyle.default.black
          nameLabel.font = UIFont.systemFont(ofSize: 12, weight: .medium)
          nameLabel.textColor = ClassicImageEditStyle.default.black
          nameLabel.textAlignment = .center
          
          changesMarkView.layer.cornerRadius = 2
          changesMarkView.backgroundColor = ClassicImageEditStyle.default.black
          changesMarkView.isHidden = true
        }
        
        body: do {
          imageView.image = image
          nameLabel.text = name
        }
        
        addTarget(self, action: #selector(didTapSelf), for: .touchUpInside)
      }
      
      public required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
      }
      
      override open var isHighlighted: Bool {
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
      
      @objc private func didTapSelf() {
        feedbackGenerator.selectionChanged()
      }
    }
  }
}
