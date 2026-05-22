//
// Copyright (c) 2021 Muukii <muukii.app@gmail.com>
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

import SwiftUI
import UIKit

import BrightroomEngine

/**
 Apple's Photos app like crop view controller.

 You might use `CropView` to create a fully customized user interface.
 */
public final class PhotosCropViewController: UIViewController {

  public typealias LocalizedStrings = SwiftUIPhotosCropView.LocalizedStrings
  public typealias Options = SwiftUIPhotosCropView.Options

  public struct Handlers {
    public var didFinish: (PhotosCropViewController) -> Void = { _ in }
    public var didCancel: (PhotosCropViewController) -> Void = { _ in }
  }

  private let options: Options
  private var hostingController: UIViewController?

  public let editingStack: EditingStack
  public var handlers = Handlers()
  public var localizedStrings: LocalizedStrings

  public init(
    editingStack: EditingStack,
    options: Options = .init(),
    localizedStrings: LocalizedStrings = .init()
  ) {
    self.localizedStrings = localizedStrings
    self.options = options
    self.editingStack = editingStack
    super.init(nibName: nil, bundle: nil)
  }

  /**
   Creates an instance for using as standalone.

   This initializer offers us to get cropping function without detailed setup.
   To get a result image, call `renderImage()`.
   */
  public convenience init(
    imageProvider: ImageProvider,
    options: Options = .init(),
    localizedStrings: LocalizedStrings = .init()
  ) {
    self.init(
      editingStack: .init(
        imageProvider: imageProvider
      ),
      options: options,
      localizedStrings: localizedStrings
    )
  }

  @available(*, unavailable)
  public required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  /**
   Renders an image according to the editing.

   - Attension: This operation can be run background-thread.
   */
  public func renderImage(
    options: BrightRoomImageRenderer.Options,
    completion: @escaping (Result<BrightRoomImageRenderer.Rendered, Error>) -> Void
  ) {
    do {
      try editingStack.makeRenderer().render(options: options, completion: completion)
    } catch {
      completion(.failure(error))
    }
  }

  override public func viewDidLoad() {
    super.viewDidLoad()

    view.backgroundColor = .black
    view.clipsToBounds = true

    let contentView = SwiftUIPhotosCropView(
      editingStack: editingStack,
      options: options,
      localizedStrings: localizedStrings,
      onDone: { [weak self] in
        guard let self else { return }
        self.handlers.didFinish(self)
      },
      onCancel: { [weak self] in
        guard let self else { return }
        self.handlers.didCancel(self)
      }
    )

    let hostingController = UIHostingController(rootView: contentView)
    hostingController.view.backgroundColor = .clear

    addChild(hostingController)
    view.addSubview(hostingController.view)
    hostingController.didMove(toParent: self)

    hostingController.view.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      hostingController.view.topAnchor.constraint(equalTo: view.topAnchor),
      hostingController.view.leftAnchor.constraint(equalTo: view.leftAnchor),
      hostingController.view.rightAnchor.constraint(equalTo: view.rightAnchor),
      hostingController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])

    self.hostingController = hostingController
  }
}
