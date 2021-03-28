
import AsyncDisplayKit

// v0.1.0

/// Backing Component is ASCollectionNode
open class StackScrollNode : ASDisplayNode, ASCollectionDelegate, ASCollectionDataSource {
  
  public final var onScrollViewDidScroll: (UIScrollView) -> Void = { _ in }
  
  open var shouldWaitUntilAllUpdatesAreCommitted: Bool = false
  
  open var isScrollEnabled: Bool {
    get {
      return collectionNode.view.isScrollEnabled
    }
    set {
      collectionNode.view.isScrollEnabled = newValue
    }
  }
  
  open var scrollView: UIScrollView {
    return collectionNode.view
  }
  
  open var collectionViewLayout: UICollectionViewLayout {
    return collectionNode.view.collectionViewLayout
  }
  
  open private(set) var nodes: [ASCellNode] = []
  
  /// It should not be accessed unless there is special.
  internal let collectionNode: ASCollectionNode
  
  public init(layout: UICollectionViewFlowLayout) {
    
    collectionNode = ASCollectionNode(collectionViewLayout: layout)
    collectionNode.backgroundColor = .clear
    
    super.init()
  }
  
  public override convenience init() {
    
    let layout = UICollectionViewFlowLayout()
    layout.minimumInteritemSpacing = 0
    layout.minimumLineSpacing = 0
    layout.sectionInset = .zero
    
    self.init(layout: layout)
  }
  
  open func append(nodes: [ASCellNode]) {
    
    self.nodes += nodes
    
    collectionNode.reloadData()
    if shouldWaitUntilAllUpdatesAreCommitted {
      collectionNode.waitUntilAllUpdatesAreProcessed()
    }
  }
  
  open func removeAll() {
    self.nodes = []
    
    collectionNode.reloadData()
    if shouldWaitUntilAllUpdatesAreCommitted {
      collectionNode.waitUntilAllUpdatesAreProcessed()
    }
  }
  
  open func replaceAll(nodes: [ASCellNode]) {
    
    self.nodes = nodes
    
    collectionNode.reloadData()
    if shouldWaitUntilAllUpdatesAreCommitted {
      collectionNode.waitUntilAllUpdatesAreProcessed()
    }
  }
  
  open override func didLoad() {
    
    super.didLoad()
    
    addSubnode(collectionNode)
    
    collectionNode.delegate = self
    collectionNode.dataSource = self
    collectionNode.view.alwaysBounceVertical = true
  }
  
  open override func layoutSpecThatFits(_ constrainedSize: ASSizeRange) -> ASLayoutSpec {
    
    return ASWrapperLayoutSpec(layoutElement: collectionNode)
  }
  
  // MARK: - ASCollectionDelegate
  
  public func collectionNode(_ collectionNode: ASCollectionNode, constrainedSizeForItemAt indexPath: IndexPath) -> ASSizeRange {
    
    return ASSizeRange(
      min: .init(width: collectionNode.bounds.width, height: 0),
      max: .init(width: collectionNode.bounds.width, height: .infinity)
    )
  }
  
  // MARK: - ASCollectionDataSource
  open var numberOfSections: Int {
    return 1
  }
  
  public func collectionNode(_ collectionNode: ASCollectionNode, numberOfItemsInSection section: Int) -> Int {
    
    return nodes.count
  }
  
  public func collectionNode(_ collectionNode: ASCollectionNode, nodeForItemAt indexPath: IndexPath) -> ASCellNode {
    return nodes[indexPath.item]
  }
  
  // MARK: - UIScrollViewDelegate
  public func scrollViewDidScroll(_ scrollView: UIScrollView) {
    onScrollViewDidScroll(scrollView)
  }
}
