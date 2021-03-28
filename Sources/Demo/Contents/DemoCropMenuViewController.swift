
import AsyncDisplayKit
import GlossButtonNode
import MosaiqueAssetsPicker
import TextureSwiftSupport
import UIKit

import BrightroomUI
import BrightroomEngine

final class DemoCropMenuViewController: StackScrollNodeViewController {
  private lazy var stackForHorizontal: EditingStack = Mocks.makeEditingStack(image: Asset.horizontalRect.image)
  private lazy var stackForVertical: EditingStack = Mocks.makeEditingStack(image: Asset.verticalRect.image)
  private lazy var stackForSquare: EditingStack = Mocks.makeEditingStack(image: Asset.squareRect.image)
  private lazy var stackForSmall: EditingStack = Mocks.makeEditingStack(image: Asset.superSmall.image)
  private lazy var stackForNasa: EditingStack = Mocks.makeEditingStack(
    fileURL:
    Bundle.main.path(
      forResource: "nasa",
      ofType: "jpg"
    ).map {
      URL(fileURLWithPath: $0)
    }!
  )

  private let resultCell = Components.ResultImageCell()

  override init() {
    super.init()
    title = "Crop"
  }

  override func viewDidLoad() {
    super.viewDidLoad()

    stackScrollNode.append(nodes: [
      resultCell,
      
      Components.makeSelectionCell(title: "Face detection", onTap: { [unowned self] in
                
        let stack = EditingStack.init(
          imageProvider: .init(image: Asset.horizontalRect.image),
          cropModifier: .faceDetection(aspectRatio: .square)
        )
        
        _presentCropViewConroller(stack)
      }),
      
      Components.makeSelectionCell(title: "Face detection - picker", onTap: { [unowned self] in
        
        self.__pickPhoto { image in
          
          let stack = EditingStack.init(
            imageProvider: .init(image: image),
            cropModifier: .faceDetection(aspectRatio: .square)
          )
          _presentCropViewConroller(stack)
        }
        
      }),
      
      Components.makeSelectionCell(title: "Face detection - picker - square", onTap: { [unowned self] in
        
        self.__pickPhoto { image in
          
          let stack = EditingStack.init(
            imageProvider: .init(image: image),
            cropModifier: .faceDetection(aspectRatio: .square)
          )
          _presentCropViewConroller(stack, fixedAspectRatio: .square)
        }
        
      }),

      Components.makeSelectionCell(title: "Horizontal rect from UIImage", onTap: { [unowned self] in
        _presentCropViewConroller(stackForHorizontal)
      }),

      Components.makeSelectionCell(title: "Vertical rect from UIImage", onTap: { [unowned self] in
        _presentCropViewConroller(stackForVertical)
      }),

      Components.makeSelectionCell(title: "Square rect from UIImage", onTap: { [unowned self] in
        _presentCropViewConroller(stackForSquare)
      }),

      Components.makeSelectionCell(title: "Super small rect from UIImage", onTap: { [unowned self] in
        _presentCropViewConroller(stackForSmall)
      }),

      Components.makeSelectionCell(title: "Super large rect from file URL", onTap: { [unowned self] in
        _presentCropViewConroller(stackForNasa)
      }),
      
      Components.makeSelectionCell(title: "Remote image (no retains stack)", onTap: { [unowned self] in
        
        let stack = EditingStack(
          imageProvider: .init(
            editableRemoteURL: URL(string: "https://images.unsplash.com/photo-1604456930969-37f67bcd6e1e?ixid=MXwxMjA3fDB8MHxwaG90by1wYWdlfHx8fGVufDB8fHw%3D&ixlib=rb-1.2.1")!
          )
        )
        
        _presentCropViewConroller(stack)
      }),
      
      Components.makeSelectionCell(title: "Remote image with preview (no retains stack)", onTap: { [unowned self] in
        
        let stack = EditingStack(
          imageProvider: .init(
            editableRemoteURL: URL(string: "https://images.unsplash.com/photo-1597522781074-9a05ab90638e?ixlib=rb-1.2.1&ixid=MXwxMjA3fDB8MHxwaG90by1wYWdlfHx8fGVufDB8fHw%3D")!
          )
        )
        
        _presentCropViewConroller(stack)
      }),

      Components.makeSelectionCell(
        title: "Square only",
        description: """
        CropViewController supports to disable the selecting aspect-ratio.
        Instead specify which aspect ratio fixes the cropping guide.
        """,
        onTap: { [unowned self] in
          
          var options = PhotosCropViewController.Options()
          options.aspectRatioOptions = .fixed(.square)

          let controller = PhotosCropViewController(editingStack: stackForVertical, options: options)
          _presentCropViewConroller(controller)
        }
      ),

      Components.makeSelectionCell(
        title: "Specified extent",
        description: """
        EditingStack can specify the extent of cropping while creating.
        """,
        onTap: { [unowned self] in
          
          let editingStack = EditingStack(
            imageProvider: .init(
              image: Asset.l1002725.image),
            cropModifier: .init { image, crop, completion in
              
              var new = crop
              new.updateCropExtentNormalizing(CGRect(
                origin: .zero,
                size: .init(width: 100, height: 300)
              ),
              respectingAspectRatio: nil
              )
              
              completion(new)
            }
          )
          
          //          var options = CropViewController.Options()
          //          options.aspectRatioOptions = .fixed(.square)
          
          let controller = PhotosCropViewController(editingStack: editingStack)
          _presentCropViewConroller(controller)
        }
      ),

      Components.makeSelectionCell(title: "Pick from library", onTap: { [unowned self] in

        self.__pickPhoto { image in

          let stack = EditingStack(imageProvider: .init(image: image))
          _presentCropViewConroller(stack)
        }

      }),
    ])
  }

  private func _presentCropViewConroller(_ crop: PhotosCropViewController) {
    crop.modalPresentationStyle = .fullScreen
    crop.handlers.didCancel = { controller in
      controller.dismiss(animated: true, completion: nil)
    }
    crop.handlers.didFinish = { [weak self] controller in
      controller.dismiss(animated: true, completion: nil)
      self?.resultCell.image = nil

      try! controller.editingStack.makeRenderer()
        .render { (result) in
          switch result {
          case .success(let rendered):
            self?.resultCell.image = rendered.uiImageDisplayP3
          case .failure(let error):
            print(error)
          }
        }
    }
      
    present(crop, animated: true, completion: nil)
  }

  private func _presentCropViewConroller(_ editingStack: EditingStack, fixedAspectRatio: PixelAspectRatio? = nil) {
    var options = PhotosCropViewController.Options()
    if let fixedAspectRatio = fixedAspectRatio {
      options.aspectRatioOptions = .fixed(fixedAspectRatio)
    }
    let crop = PhotosCropViewController(editingStack: editingStack, options: options)
    
    _presentCropViewConroller(crop)
  }
}
