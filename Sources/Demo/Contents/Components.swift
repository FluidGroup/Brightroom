
import AsyncDisplayKit
import GlossButtonNode
import TextureSwiftSupport
import UIKit

enum Components {
  final class ResultImageCell: ASCellNode {
    var image: UIImage? {
      didSet {
        if let image = image {
          imageNode.image = image
          metadataTextNode.attributedText = NSAttributedString(string: "\(image.size.width * image.scale), \(image.size.height * image.scale)")
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

    override init() {
      super.init()
      automaticallyManagesSubnodes = true
      imageNode.contentMode = .scaleAspectFit
      
      tutorialTextNode.attributedText = NSAttributedString(
        string: "Rendered image preview",
        attributes: [
          .font : UIFont.preferredFont(forTextStyle: .headline),
          .foregroundColor : UIColor.systemGray
        ]
      )
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
