
import AsyncDisplayKit
import GlossButtonNode
import TextureSwiftSupport
import UIKit

func makeMetadataString(image: UIImage) -> String {
  let formatter = ByteCountFormatter()
  formatter.countStyle = .file
  let jpegSize = formatter.string(fromByteCount: Int64(image.jpegData(compressionQuality: 1)!.count))

  let meta = """
  size: \(image.size.width * image.scale), \(image.size.height * image.scale)
  jpegSize: \(jpegSize),
  colorSpace: \(image.cgImage?.colorSpace as Any)
  """
  
  return meta
}

enum Components {
  final class ResultImageCell: ASCellNode {
    var image: UIImage? {
      didSet {
        if let image = image {
          imageNode.image = image

          let meta = makeMetadataString(image: image)
          metadataTextNode.attributedText = NSAttributedString(string: meta)
        } else {
          imageNode.image = nil
          metadataTextNode.attributedText = nil
        }
      }
    }

    private let tutorialTextNode = ASTextNode()
    private let metadataTextNode = ASTextNode()
    private let shape = ShapeLayerNode.roundedCorner(radius: 0)
    private let imageNode = ASImageNode()
    private let saveButton = GlossButtonNode()

    override init() {
      super.init()
      automaticallyManagesSubnodes = true
      imageNode.contentMode = .scaleAspectFit

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

      shape.shapeFillColor = .init(white: 0.9, alpha: 1)
    }

    override func layoutSpecThatFits(_ constrainedSize: ASSizeRange) -> ASLayoutSpec {
      LayoutSpec {
        VStackLayout(spacing: 8) {
          HStackLayout(justifyContent: .center) {
            imageNode
              .aspectRatio(1)
              .width(300)
              .background(ZStackLayout {
                shape
                CenterLayout {
                  tutorialTextNode
                }
              })
              .padding(8)
          }
          metadataTextNode
            .padding(8)
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
          .font: UIFont.preferredFont(forTextStyle: .headline),
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
          .padding(8)
        }
      }
      .onDidLoad { _ in
        shape.shapeFillColor = .init(white: 0.95, alpha: 1)
      }
    }
  }
}
