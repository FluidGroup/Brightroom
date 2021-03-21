
import AsyncDisplayKit
import GlossButtonNode
import TextureSwiftSupport
import UIKit

enum Components {
  
  static func makeSelectionCell(title: String, onTap: @escaping () -> Void) -> ASCellNode {
    
    let shape = ShapeLayerNode.roundedCorner(radius: 8)
    
    let button = GlossButtonNode()
    button.onTap = onTap
    
    button.setDescriptor(
      .init(
        title: NSAttributedString(string: title, attributes: [
          .font : UIFont.preferredFont(forTextStyle: .headline),
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
          HStackLayout {
            button
              .padding(.horizontal, 8)
              .padding(.vertical, 12)
              .flexGrow(1)
          }
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
