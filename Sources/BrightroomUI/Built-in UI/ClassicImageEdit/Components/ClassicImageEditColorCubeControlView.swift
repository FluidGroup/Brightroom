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
import UIKit

#if !COCOAPODS
import BrightroomEngine
#endif

import Verge

open class ClassicImageEditColorCubeControlBase : ClassicImageEditControlBase {
  
  public required override init(
    viewModel: ClassicImageEditViewModel
  ) {    
    super.init(viewModel: viewModel)
  }
}

open class ColorCubeControl: ClassicImageEditColorCubeControlBase, UICollectionViewDelegateFlowLayout, UICollectionViewDataSource {
  
  private enum Section : Int, CaseIterable {
    
    case original
    case selections
  }
  
  private struct State: Equatable {
    
    struct Content: Equatable {
      var previews: [PreviewFilterColorCube]
      var originalImage: CIImage
    }
   
    var content: Content?
  }

  // MARK: - Properties
  
  public var current: FilterColorCube?

  public lazy var collectionView: UICollectionView = self.makeCollectionView()
  
  private let feedbackGenerator = UISelectionFeedbackGenerator()
  
  private let store: Store<State, Never>
  
  private var subscriptions: Set<VergeAnyCancellable> = .init()
  
  // MARK: - Functions

  public required init(
    viewModel: ClassicImageEditViewModel
    ) {
    
    self.store = .init(initialState: .init())
        
    super.init(viewModel: viewModel)
    
    viewModel.sinkState { [weak self] state in
      
      guard let self = self else { return }
        
      self.store.commit { viewState in
        
        if let state = state._beta_map(\.editingState.loadedState) {
        
          state.ifChanged(\.thumbnailImage, \.previewColorCubeFilters) { image, filters in
                      
            viewState.content = .init(previews: filters, originalImage: image)
          }
          
        }
        
      }
          
    }
    .store(in: &subscriptions)
    
    store.sinkState { [weak self] (state) in
      
      guard let self = self else { return }
      
      if state.hasChanges(\.content) {
        self.collectionView.reloadData()
      }
      
    }
    .store(in: &subscriptions)
    
  }

  open override func setup() {
    super.setup()

    backgroundColor = ClassicImageEditStyle.default.control.backgroundColor

    addSubview(collectionView)
    
    let itemSize = (collectionView.collectionViewLayout as? UICollectionViewFlowLayout)?.itemSize
    collectionView.translatesAutoresizingMaskIntoConstraints = false

    NSLayoutConstraint.activate([
      collectionView.topAnchor.constraint(greaterThanOrEqualTo: collectionView.superview!.topAnchor),
      collectionView.rightAnchor.constraint(equalTo: collectionView.superview!.rightAnchor),
      collectionView.leftAnchor.constraint(equalTo: collectionView.superview!.leftAnchor),
      collectionView.bottomAnchor.constraint(lessThanOrEqualTo: collectionView.superview!.bottomAnchor),
      collectionView.centerYAnchor.constraint(equalTo: collectionView.superview!.centerYAnchor),
      collectionView.heightAnchor.constraint(equalToConstant: itemSize?.height ?? 100),
      ])

    collectionView.dataSource = self
    collectionView.delegate = self

  }

  open func makeCollectionView() -> UICollectionView {

    let collectionView = UICollectionView(frame: .zero, collectionViewLayout: makeCollectionViewLayout())

    if #available(iOS 11.0, *) {
      collectionView.contentInsetAdjustmentBehavior = .never
    } else {
      // Fallback on earlier versions
    }
    collectionView.backgroundColor = .clear
    collectionView.showsVerticalScrollIndicator = false
    collectionView.showsHorizontalScrollIndicator = false
    collectionView.contentInset.right = 44
    collectionView.contentInset.left = 44
    collectionView.delaysContentTouches = false

    collectionView.register(NormalCell.self, forCellWithReuseIdentifier: NormalCell.identifier)
    collectionView.register(SelectionCell.self, forCellWithReuseIdentifier: SelectionCell.identifier)

    return collectionView
  }

  open func makeCollectionViewLayout() -> UICollectionViewLayout {

    let layout = UICollectionViewFlowLayout()

    layout.scrollDirection = .horizontal
    layout.minimumLineSpacing = 16
    layout.minimumInteritemSpacing = 0
    layout.itemSize = CGSize(width: 64, height: 100)

    return layout
  }
  
  open override func didReceiveCurrentEdit(state: Changes<ClassicImageEditViewModel.State>) {
    
    state.ifChanged(\.editingState.loadedState?.currentEdit.filters.colorCube) { value in
      current = value
      collectionView.visibleCells.forEach {
        updateSelected(cell: $0)
      }
      scrollToSelectedItem(animated: true)
    }
    
  }
  
  open override func layoutSubviews() {
    super.layoutSubviews()
    collectionView.collectionViewLayout.invalidateLayout()
    scrollToSelectedItem(animated: false)
  }

  // MARK: - UICollectionViewDeleagte / DataSource

  open func numberOfSections(in collectionView: UICollectionView) -> Int {
    guard store.state.content != nil else {
      return 0
    }
    return Section.allCases.count
  }

  open func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
    
    guard let content = store.state.content else {
      return 0
    }
    
    switch Section.allCases[section] {
    case .original:
      return 1
    case .selections:
      return content.previews.count
    }
  }
  
  private func updateSelected(cell: UICollectionViewCell) {
    switch cell {
    case let cell as NormalCell:
      cell._isSelected = current == nil
    case let cell as SelectionCell:
      cell._isSelected = current == cell.preview?.filter
    default:
      break
    }
  }

  open func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
    
    guard let content = store.state.content else {
      preconditionFailure()
    }
        
    switch Section.allCases[indexPath.section] {
    case .original:
      let cell = collectionView.dequeueReusableCell(withReuseIdentifier: NormalCell.identifier, for: indexPath) as! NormalCell
      cell.set(originalImage: content.originalImage, name: viewModel.localizedStrings.control_colorcube_normal_name)
      updateSelected(cell: cell)
      return cell
    case .selections:
      let cell = collectionView.dequeueReusableCell(withReuseIdentifier: SelectionCell.identifier, for: indexPath) as! SelectionCell
      let filter = content.previews[indexPath.item]
      cell.set(preview: filter)
      updateSelected(cell: cell)
      return cell
    }

  }

  open func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
    
    guard let content = store.state.content else {
      preconditionFailure()
    }
    
    switch Section.allCases[indexPath.section] {
    case .original:
      
      viewModel.editingStack.set(filters: {
        $0.colorCube = nil
      })
      
      viewModel.editingStack.takeSnapshot()
      
    case .selections:
            
      viewModel.editingStack.set(filters: {
        let filter = content.previews[indexPath.item]
        $0.colorCube = filter.filter
      })
      
      viewModel.editingStack.takeSnapshot()
    }
    
    feedbackGenerator.selectionChanged()

  }
  
  public func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, insetForSectionAt section: Int) -> UIEdgeInsets {
    
    switch Section.allCases[section] {
    case .original:
      return .zero
    case .selections:
      return UIEdgeInsets(top: 0, left: 24, bottom: 0, right: 0)
    }
  }
  
  private func scrollToSelectedItem(animated: Bool) {
    
    guard let content = store.state.content else {
      
      return
    }

    if let current = current, let index = content.previews.firstIndex(where: { $0.filter == current }) {
      collectionView.scrollToItem(
        at: IndexPath.init(item: index, section: Section.selections.rawValue),
        at: .centeredHorizontally,
        animated: animated
      )
    } else {
      collectionView.scrollToItem(
        at: IndexPath.init(item: 0, section: Section.original.rawValue),
        at: .centeredHorizontally,
        animated: animated
      )
    }
  }

  // MARK: - Nested Types
  
  open class CellBase : UICollectionViewCell {
    
    let nameLabel: UILabel = .init()
    let imageView: MetalImageView = .init()
    
    public override init(frame: CGRect) {
      super.init(frame: frame)
      
      layout: do {
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        
        contentView.addSubview(nameLabel)
        contentView.addSubview(imageView)
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        imageView.translatesAutoresizingMaskIntoConstraints = false
        
        NSLayoutConstraint.activate([
          
          imageView.topAnchor.constraint(equalTo: contentView.topAnchor),
          imageView.rightAnchor.constraint(equalTo: contentView.rightAnchor),
          imageView.leftAnchor.constraint(equalTo: contentView.leftAnchor),
          imageView.widthAnchor.constraint(equalTo: imageView.heightAnchor),
          
          nameLabel.topAnchor.constraint(equalTo: imageView.bottomAnchor, constant: 12),
          nameLabel.rightAnchor.constraint(lessThanOrEqualTo: contentView.rightAnchor, constant: -2),
          nameLabel.leftAnchor.constraint(greaterThanOrEqualTo: contentView.leftAnchor, constant: 2),
          nameLabel.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
          
          ])
      }
      
      style: do {
        
        nameLabel.textAlignment = .center
        nameLabel.font = UIFont.systemFont(ofSize: 12, weight: .medium)
        nameLabel.textColor = ClassicImageEditStyle.default.black
        
      }
      
      initialStyle: do {
        
        nameLabel.alpha = 0.3
      }
    }
    
    public required init?(coder aDecoder: NSCoder) {
      fatalError("init(coder:) has not been implemented")
    }
    
    open override func prepareForReuse() {
      super.prepareForReuse()
      nameLabel.text = nil
      _isSelected = false
    }
    
    open var _isSelected: Bool = false {
      didSet {
        nameLabel.alpha = _isSelected ? 1 : 0.3
      }
    }
    
    open override var isHighlighted: Bool {
      get {
        
        return super.isHighlighted
      }
      set {
        
        super.isHighlighted = newValue
        
      }
    }
  }
  
  open class NormalCell : CellBase {
    
    static let identifier = "me.muukii.PixelEditor.FilterCellNormal"

    open func set(originalImage: CIImage, name: String) {
      
      nameLabel.text = name
      imageView.display(image: originalImage)
    }
    
  }

  open class SelectionCell : CellBase {

    static let identifier = "me.muukii.PixelEditor.FilterCell"
    
    open var preview: PreviewFilterColorCube?

    open func set(preview: PreviewFilterColorCube) {
      
      self.preview = preview

      nameLabel.text = preview.filter.name
      imageView.display(image: preview.image)
    }

  }
}
