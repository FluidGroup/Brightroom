import AsyncDisplayKit
import GlossButtonNode
import TextureSwiftSupport
import UIKit

import BrightroomEngine
import BrightroomUI

final class DemoBuiltInEditorViewController: StackScrollNodeViewController {
  override init() {
    super.init()
    title = "Editor"
  }

  private let resultCell = Components.ResultImageCell()
  private let stack = EditingStack.init(
    imageProvider: .init(image: Asset.leica.image),
    cropModifier: .init { _, crop, completion in
      var new = crop
      new.updateCropExtent(by: .square)
      completion(new)
    }
  )

  override func viewDidLoad() {
    super.viewDidLoad()

    stackScrollNode.append(nodes: [
      resultCell,

      Components.makeSelectionCell(title: "Pick", onTap: { [unowned self] in

        __pickPhoto { image in
          self._presentNonSquare(.init(image: image))
        }

      }),

      Components.makeSelectionCell(title: "Pick - Square", onTap: { [unowned self] in

        __pickPhoto { image in
          self._presentSquare(.init(image: image))
        }

      }),
            
      Components.makeSelectionCell(title: "Pick - Face detection", onTap: { [unowned self] in
        
        __pickPhoto { image in
          let stack = EditingStack(imageProvider: .init(image: image))
          self._present(stack, square: false, faceDetection: true)
        }
        
      }),

      Components.makeSelectionCell(title: "Pick - Face detection - square", onTap: { [unowned self] in

        __pickPhoto { image in
          let stack = EditingStack(imageProvider: .init(image: image))
          self._present(stack, square: true, faceDetection: true)
        }

      }),
    

      Components.makeSelectionCell(title: "Example - Square", onTap: { [unowned self] in
        _presentSquare(.init(image: Asset.leica.image))
      }),

      Components.makeSelectionCell(title: "DisplayP3 - Square", onTap: { [unowned self] in
        _presentSquare(.init(image: Asset.instaLogo.image))
      }),

      Components.makeSelectionCell(title: "Example with keeping - Square", onTap: { [unowned self] in
        _present(stack, square: true)
      }),

      Components.makeSelectionCell(title: "Oriented image - Square", onTap: { [unowned self] in
        _presentSquare(try! .init(fileURL: _url(forResource: "IMG_5528", ofType: "HEIC")))
      }),

      Components.makeSelectionCell(title: "Remote image - Square", onTap: { [unowned self] in

        let stack = EditingStack(
          imageProvider: .init(
            editableRemoteURL: URL(string: "https://images.unsplash.com/photo-1597522781074-9a05ab90638e?ixlib=rb-1.2.1&ixid=MXwxMjA3fDB8MHxwaG90by1wYWdlfHx8fGVufDB8fHw%3D")!
          )
        )

        _present(stack, square: true)
      }),

    ])
  }

  private func _present(_ editingStack: EditingStack, square: Bool, faceDetection: Bool = false) {
    var options = ClassicImageEditOptions()

    options.isFaceDetectionEnabled = faceDetection
    if square {
      options.croppingAspectRatio = .square
    } else {
      options.croppingAspectRatio = nil
    }

    let controller = ClassicImageEditViewController(editingStack: editingStack, options: options)
    controller.handlers.didEndEditing = { [weak self] controller, stack in
      guard let self = self else { return }
      controller.dismiss(animated: true, completion: nil)

      self.resultCell.image = nil

      try! stack.makeRenderer().render { result in
        switch result {
        case let .success(rendered):
          self.resultCell.image = rendered.uiImageDisplayP3
        case let .failure(error):
          print(error)
        }
      }
    }

    controller.handlers.didCancelEditing = { controller in
      controller.dismiss(animated: true, completion: nil)
    }

    let navigationController = UINavigationController(rootViewController: controller)
    navigationController.modalPresentationStyle = .fullScreen

    present(navigationController, animated: true, completion: nil)
  }

  private func _presentSquare(_ imageProvider: ImageProvider) {
    let stack = EditingStack.init(
      imageProvider: imageProvider
    )

    _present(stack, square: true)
  }

  private func _presentNonSquare(_ imageProvider: ImageProvider) {
    let stack = EditingStack.init(
      imageProvider: imageProvider
    )

    _present(stack, square: false)
  }
}
