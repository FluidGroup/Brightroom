
import AsyncDisplayKit
import GlossButtonNode
import TextureSwiftSupport
import UIKit

final class TopViewController: DisplayNodeViewController {
  private let stackScrollNode = StackScrollNode()

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .white

    stackScrollNode.append(nodes: [
      Self.makeCell(title: "Hello", onTap: {}),
    ])
    
    stackScrollNode.scrollView.delaysContentTouches = false
  }

  override func layoutSpecThatFits(_ constrainedSize: ASSizeRange) -> ASLayoutSpec {
    LayoutSpec {
      stackScrollNode
    }
  }

  private static func makeCell(title: String, onTap: @escaping () -> Void) -> ASCellNode {
    let button = GlossButtonNode()

    button.setDescriptor(
      .init(
        title: NSAttributedString(string: title, attributes: [
          .font : UIFont.preferredFont(forTextStyle: .body),
          .foregroundColor: UIColor.darkGray
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
          button
            .padding(8)
        }
      }
    }
  }
}
