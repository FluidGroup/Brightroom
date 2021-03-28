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

import Photos
import UIKit
import Verge

#if !COCOAPODS
import BrightroomEngine
#endif

@available(*, deprecated, renamed: "ClassicImageEditViewController")
public typealias PixelEditViewController = ClassicImageEditViewController

public final class ClassicImageEditViewController: UIViewController {
  
  /**
   - TODO: property names are not comprehensibility.
   */
  public struct LocalizedStrings {
    
    // Deprecates
    
    @available(*, deprecated, renamed: "control_colorcube_normal_name")
    public var normal: String {
      get {
        control_colorcube_normal_name
      }
      set {
        control_colorcube_normal_name = newValue
      }
    }

    public var done = "Done"
          
    public var control_colorcube_normal_name = "Normal"
    
    public var cancel = "Cancel"
    public var filter = "Filter"
    public var edit = "Edit"

    public var editAdjustment = "Adjust"
    public var editMask = "Mask"
    public var editHighlights = "Highlights"
    public var editShadows = "Shadows"
    public var editSaturation = "Saturation"
    public var editContrast = "Contrast"
    public var editBlur = "Blur"
    public var editTemperature = "Temperature"
    public var editBrightness = "Brightness"
    public var editVignette = "Vignette"
    public var editFade = "Fade"
    public var editClarity = "Clarity"
    public var editSharpen = "Sharpen"
    public var brushSizeSmall = "◦"
    public var brushSizeLarge = "◯"
    public var clear = "Clear"

    public init() {}
  }

  public struct Handlers {
    public var didEndEditing: (ClassicImageEditViewController, EditingStack) -> Void = { _, _ in }
    public var didCancelEditing: (ClassicImageEditViewController) -> Void = { _ in }
  }

  public var handlers: Handlers = .init()

  // MARK: - Private Propaties

  private let maskingView: BlurryMaskingView

  private let previewView: ImagePreviewView

  private let cropView: CropView

  private let editContainerView = UIView()

  private let controlContainerView = UIView()

  private let cropButton = UIButton(type: .system)

  private let stackView = ClassicImageEditControlStackView()

  private lazy var doneButton = UIBarButtonItem(
    title: viewModel.localizedStrings.done,
    style: .done,
    target: self,
    action: #selector(didTapDoneButton)
  )

  private lazy var cancelButton = UIBarButtonItem(
    title: viewModel.localizedStrings.cancel,
    style: .plain,
    target: self,
    action: #selector(didTapCancelButton)
  )

  private var subscriptions: Set<VergeAnyCancellable> = .init()

  private lazy var loadingView = LoadingBlurryOverlayView(
    effect: UIBlurEffect(style: .dark),
    activityIndicatorStyle: .whiteLarge
  )
  private lazy var touchGuardOverlayView = UIView()

  private let viewModel: ClassicImageEditViewModel

  // MARK: - Initializers

  public convenience init(
    imageProvider: ImageProvider,
    options: ClassicImageEditOptions = .default,
    localizedStrings: LocalizedStrings = .init()
  ) {
    let editingStack = EditingStack(imageProvider: imageProvider)

    self.init(
      editingStack: editingStack,
      options: options,
      localizedStrings: localizedStrings
    )
  }

  public convenience init(
    editingStack: EditingStack,
    options: ClassicImageEditOptions = .default,
    localizedStrings: LocalizedStrings = .init()
  ) {
    self.init(
      viewModel: .init(
        editingStack: editingStack,
        options: options,
        localizedStrings: localizedStrings
      )
    )
  }

  public init(viewModel: ClassicImageEditViewModel) {
    self.viewModel = viewModel
    cropView = .init(editingStack: viewModel.editingStack, contentInset: .zero)
    previewView = .init(editingStack: viewModel.editingStack)
    maskingView = .init(editingStack: viewModel.editingStack)
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  public required init?(coder aDecoder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  // MARK: - Functions

  override public func viewDidLoad() {
    // FIXME: Check loading

    super.viewDidLoad()

    cropView.setCropOutsideOverlay(.init()&>.do {
      $0.backgroundColor = .white
    })
    cropView.setCropInsideOverlay(nil)
    cropView.isGuideInteractionEnabled = false
    cropView.isAutoApplyEditingStackEnabled = false

    cropView.setCroppingAspectRatio(viewModel.options.croppingAspectRatio)

    maskingView.isBackdropImageViewHidden = true

    layout: do {
      root: do {
        view.backgroundColor = .white

        let guide = UILayoutGuide()

        view.addLayoutGuide(guide)

        view.addSubview(editContainerView)
        view.addSubview(controlContainerView)

        editContainerView.accessibilityIdentifier = "app.muukii.pixel.editContainerView"
        controlContainerView.accessibilityIdentifier = "app.muukii.pixel.controlContainerView"

        editContainerView.translatesAutoresizingMaskIntoConstraints = false
        controlContainerView.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
          guide.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
          guide.rightAnchor.constraint(equalTo: view.rightAnchor),
          guide.leftAnchor.constraint(equalTo: view.leftAnchor),
          guide.widthAnchor.constraint(equalTo: guide.heightAnchor, multiplier: 1),

          {
            let c = editContainerView.topAnchor.constraint(equalTo: guide.topAnchor)
            c.priority = .defaultHigh
            return c
          }(),
          {
            let c = editContainerView.rightAnchor.constraint(equalTo: guide.rightAnchor)
            c.priority = .defaultHigh
            return c
          }(),
          {
            let c = editContainerView.leftAnchor.constraint(equalTo: guide.leftAnchor)
            c.priority = .defaultHigh
            return c
          }(),
          {
            let c = editContainerView.bottomAnchor.constraint(equalTo: guide.bottomAnchor)
            c.priority = .defaultHigh
            return c
          }(),

          editContainerView.centerXAnchor.constraint(equalTo: guide.centerXAnchor),
          editContainerView.centerYAnchor.constraint(equalTo: guide.centerYAnchor),

          controlContainerView.topAnchor.constraint(equalTo: guide.bottomAnchor),
          controlContainerView.rightAnchor.constraint(equalTo: view.rightAnchor),
          controlContainerView.leftAnchor.constraint(equalTo: view.leftAnchor),
          {
            if #available(iOS 11.0, *) {
              return controlContainerView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
            } else {
              return controlContainerView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
            }
          }(),
        ])
      }

      root: do {
        view.backgroundColor = ClassicImageEditStyle.default.control.backgroundColor
      }

      edit: do {
        [
          cropView,
          previewView,
          maskingView,
        ].forEach { view in
          view.translatesAutoresizingMaskIntoConstraints = false
          editContainerView.addSubview(view)
          NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: view.superview!.topAnchor),
            view.rightAnchor.constraint(equalTo: view.superview!.rightAnchor),
            view.bottomAnchor.constraint(equalTo: view.superview!.bottomAnchor),
            view.leftAnchor.constraint(equalTo: view.superview!.leftAnchor),
          ])
        }
      }

      control: do {
        controlContainerView.addSubview(stackView)

        stackView.frame = stackView.bounds
        stackView.autoresizingMask = [.flexibleHeight, .flexibleWidth]
      }
    }

    stackView.push(
      viewModel.options.classes.control.rootControl.init(
        viewModel: viewModel,
        colorCubeControl: viewModel.options.classes.control.colorCubeControl.init(
          viewModel: viewModel
        )
      ),
      animated: false
    )

    viewModel.sinkState(queue: .mainIsolated()) { [weak self] state in

      guard let self = self else { return }

      self.updateUI(state: state)
    }
    .store(in: &subscriptions)

    cropView.store.sinkState { [viewModel] state in

      state.ifChanged(\.proposedCrop) { value in
        guard let value = value else { return }
        viewModel.setProposedCrop(value)
      }
    }
    .store(in: &subscriptions)

    viewModel.editingStack.start()
  }

  override public func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    view.layoutIfNeeded()
  }

  // MARK: - Private Functions

  @objc
  private func didTapDoneButton() {
    handlers.didEndEditing(self, viewModel.editingStack)
  }

  @objc
  private func didTapCancelButton() {
    handlers.didCancelEditing(self)
  }

  private func updateUI(state: Changes<ClassicImageEditViewModel.State>) {
    state.ifChanged(\.title) { title in
      navigationItem.title = title
    }

    state.ifChanged(\.maskingBrushSize) {
      maskingView.setBrushSize($0)
    }

    state.ifChanged(\.proposedCrop) { value in
      guard let value = value else { return }
      cropView.setCrop(value)
    }

    state.ifChanged(\.mode) { mode in
      switch mode {
      case .crop:

        navigationItem.rightBarButtonItem = nil
        navigationItem.leftBarButtonItem = nil

        cropView.isHidden = false
        previewView.isHidden = true
        
        maskingView.isHidden = true
        maskingView.isblurryImageViewHidden = true
        
        maskingView.isUserInteractionEnabled = false

      case .masking:

        navigationItem.rightBarButtonItem = nil
        navigationItem.leftBarButtonItem = nil

        cropView.isHidden = true
        previewView.isHidden = false
        maskingView.isHidden = false
        maskingView.isblurryImageViewHidden = false

        maskingView.isUserInteractionEnabled = true

      case .editing:

        navigationItem.rightBarButtonItem = nil
        navigationItem.leftBarButtonItem = nil

        cropView.isHidden = true
        previewView.isHidden = false
        maskingView.isHidden = true
        maskingView.isblurryImageViewHidden = true

        maskingView.isUserInteractionEnabled = false

      case .preview:

        navigationItem.setHidesBackButton(true, animated: false)
        navigationItem.rightBarButtonItem = doneButton
        navigationItem.leftBarButtonItem = cancelButton

        previewView.isHidden = false
        cropView.isHidden = true
        maskingView.isHidden = false
        maskingView.isblurryImageViewHidden = false

        maskingView.isUserInteractionEnabled = false
      }
    }

    let editingState = state.map(\.editingState)

    editingState.ifChanged(\.isLoading) { isLoading in

      switch isLoading {
      case true:

        let loadingView = self.loadingView
        let touchGuardOverlayView = self.touchGuardOverlayView

        touchGuardOverlayView.backgroundColor = .init(white: 1, alpha: 0.5)

        view.addSubview(loadingView)
        view.addSubview(touchGuardOverlayView)

        touchGuardOverlayView.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
          loadingView.leadingAnchor.constraint(equalTo: previewView.leadingAnchor),
          loadingView.trailingAnchor.constraint(equalTo: previewView.trailingAnchor),
          loadingView.topAnchor.constraint(equalTo: previewView.topAnchor),
          loadingView.bottomAnchor.constraint(equalTo: previewView.bottomAnchor),
          touchGuardOverlayView.leadingAnchor.constraint(equalTo: controlContainerView.leadingAnchor),
          touchGuardOverlayView.trailingAnchor.constraint(equalTo: controlContainerView.trailingAnchor),
          touchGuardOverlayView.topAnchor.constraint(equalTo: controlContainerView.topAnchor),
          touchGuardOverlayView.bottomAnchor.constraint(equalTo: controlContainerView.bottomAnchor),
        ])
        self.doneButton.isEnabled = false

      case false:
        self.loadingView.removeFromSuperview()
        self.touchGuardOverlayView.removeFromSuperview()
        self.doneButton.isEnabled = true
      }
    }
  }
}
