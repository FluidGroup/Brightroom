
import AsyncDisplayKit
@testable import BrightroomEngine
import GlossButtonNode
import MobileCoreServices
import TextureSwiftSupport
import UIKit

func makeMetadataString(image: UIImage) -> String {
  let formatter = ByteCountFormatter()
  formatter.countStyle = .file
  let jpegSize = formatter.string(fromByteCount: Int64(image.jpegData(compressionQuality: 1)!.count))
  
  let cgImage = image.cgImage!

  let meta = """
  size: \(image.size.width * image.scale), \(image.size.height * image.scale)
  estimated-jpegSize: \(jpegSize)
  colorSpace: \(cgImage.colorSpace.map { String(describing: $0) } ?? "null")
  bit-depth: \(cgImage.bitsPerPixel / 4)
  bytesPerRow: \(cgImage.bytesPerRow)
  """

  return meta
}

enum Components {
  final class ImageInspectorNode: ASDisplayNode {
    
    var image: UIImage? {
      didSet {
        if let image = image {
          (imageNode.view as! UIImageView).image = image
          
          let meta = makeMetadataString(image: image)
          metadataTextNode.attributedText = NSAttributedString(string: meta)
        } else {
          (imageNode.view as! UIImageView).image = nil
          metadataTextNode.attributedText = nil
        }
      }
    }
    
    private let nameNode = ASTextNode()
    private let imageNode = ASDisplayNode.init(viewBlock: { UIImageView() })
    private let shape = ShapeLayerNode.roundedCorner(radius: 0)
    private let metadataTextNode = ASTextNode()
    
    init(name: String) {
      super.init()
      automaticallyManagesSubnodes = true
      
      nameNode.attributedText = NSAttributedString(string: name)
    }
    
    override func didLoad() {
      super.didLoad()
      imageNode.contentMode = .scaleAspectFit
      shape.shapeFillColor = .init(white: 0.9, alpha: 1)
    }

    override func layoutSpecThatFits(_ constrainedSize: ASSizeRange) -> ASLayoutSpec {
      LayoutSpec {
        VStackLayout(spacing: 8) {
          nameNode
          
          imageNode
            .aspectRatio(1)
            .background(ZStackLayout {
              shape
            })
          
          metadataTextNode
        }
        .padding(8)
        .flexGrow(1)
      }
    }
  }

  final class ResultImageCell: ASCellNode {
    var image: UIImage? {
      didSet {
        if let image = image {
          
          renderedImageNode.image = image
          optimizedForSharingImageNode.image = UIImage(data: ImageTool.makeImageForJPEGOptimizedSharing(image: image.cgImage!))
          
        } else {
          renderedImageNode.image = nil
          optimizedForSharingImageNode.image = nil
        }
      }
    }

    private let tutorialTextNode = ASTextNode()
    
    private let renderedImageNode = ImageInspectorNode(name: "Rendered")
    private let optimizedForSharingImageNode = ImageInspectorNode(name: "Optimized for sharing")
    
    private let saveButton = GlossButtonNode()

    override init() {
      super.init()
      automaticallyManagesSubnodes = true

      tutorialTextNode.attributedText = NSAttributedString(
        string: "Rendered image preview",
        attributes: [
          .font: UIFont.preferredFont(forTextStyle: .headline),
          .foregroundColor: UIColor.systemGray,
        ]
      )

      saveButton.setDescriptor(
        .init(
          title: NSAttributedString(string: "Save", attributes: [
            .font: UIFont.preferredFont(forTextStyle: .headline),
            .foregroundColor: UIColor.darkGray,
          ]),
          image: nil,
          bodyStyle: .init(layout: .vertical()),
          surfaceStyle: .bodyOnly
        ),
        for: .normal
      )

      saveButton.onTap = { [weak self] in

        guard let image = self?.image else { return }
        UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
      }
    }

    override func didLoad() {
      super.didLoad()

    
    }

    override func layoutSpecThatFits(_ constrainedSize: ASSizeRange) -> ASLayoutSpec {
      LayoutSpec {
        VStackLayout(spacing: 8) {
          HStackLayout(justifyContent: .spaceAround, alignItems: .start) {
            renderedImageNode
              .flexBasis(fraction: 0.5)

              .flexGrow(1)
            
            optimizedForSharingImageNode
              .flexBasis(fraction: 0.5)

              .flexGrow(1)
          }
          saveButton
        }
      }
    }
  }

  static func makeSelectionCell(
    title: String,
    description: String? = nil,
    onTap: @escaping () -> Void
  ) -> ASCellNode {
    let shape = ShapeLayerNode.roundedCorner(radius: 8)

    let button = GlossButtonNode()
    button.onTap = onTap

    let descriptionLabel = ASTextNode()
    descriptionLabel.attributedText = description.map { NSAttributedString(
      string: $0,
      attributes: [
        .font: UIFont.preferredFont(forTextStyle: .caption1),
        .foregroundColor: UIColor.lightGray,
      ]
    )
    }

    button.setDescriptor(
      .init(
        title: NSAttributedString(string: title, attributes: [
          .font: UIFont.preferredFont(forTextStyle: .subheadline),
          .foregroundColor: UIColor.darkGray,
        ]),
        image: nil,
        bodyStyle: .init(layout: .vertical()),
        surfaceStyle: .bodyOnly
      ),
      for: .normal
    )

    return WrapperCellNode {
      return AnyDisplayNode { _, _ in

        LayoutSpec {
          VStackLayout(spacing: 8) {
            HStackLayout {
              button
                .flexGrow(1)
            }
            if description != nil {
              descriptionLabel
            }
          }
          .padding(.horizontal, 8)
          .padding(.vertical, 12)
          .background(shape)
          .padding(4)
        }
      }
      .onDidLoad { _ in
        shape.shapeFillColor = .init(white: 0.95, alpha: 1)
      }
    }
  }
}
