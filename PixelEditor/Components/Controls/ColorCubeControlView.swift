//
//  ColorCubeControlView.swift
//  PixelEditor
//
//  Created by muukii on 10/17/18.
//  Copyright © 2018 muukii. All rights reserved.
//

import Foundation

import PixelEngine

open class ColorCubeControlView : ControlViewBase, UICollectionViewDelegateFlowLayout, UICollectionViewDataSource {

  // MARK: - Properties

  public lazy var collectionView: UICollectionView = self.makeCollectionView()

  private var filters: [FilterColorCube] = [] {
    didSet {
      collectionView.reloadData()
    }
  }

  // MARK: - Functions

  open override func setup() {
    super.setup()

    backgroundColor = Style.default.control.backgroundColor

    addSubview(collectionView)
    collectionView.frame = bounds
    collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]

    collectionView.dataSource = self
    collectionView.delegate = self

    self.filters = ColorCubeStorage.filters

  }

  open func makeCollectionView() -> UICollectionView {

    let collectionView = UICollectionView(frame: .zero, collectionViewLayout: makeCollectionViewLayout())

    collectionView.backgroundColor = .clear

    collectionView.register(Cell.self, forCellWithReuseIdentifier: Cell.identifier)

    return collectionView
  }

  open func makeCollectionViewLayout() -> UICollectionViewLayout {

    let layout = UICollectionViewFlowLayout()

    layout.scrollDirection = .horizontal
    layout.minimumLineSpacing = 20
    layout.minimumInteritemSpacing = 0

    return layout
  }

  open override func layoutSubviews() {
    super.layoutSubviews()
    collectionView.collectionViewLayout.invalidateLayout()
  }

  // MARK: - UICollectionViewDeleagte / DataSource

  open func numberOfSections(in collectionView: UICollectionView) -> Int {
    return 1
  }

  open func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
    return filters.count
  }

  open func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {

    let cell = collectionView.dequeueReusableCell(withReuseIdentifier: Cell.identifier, for: indexPath) as! Cell

    return cell
  }

  open func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {

    return CGSize(width: 60, height: collectionView.bounds.height)
  }

  open func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {

    let filter = filters[indexPath.item]
    context.action(.setFilterColorCube(filter))
    context.action(.commit)
  }

  // MARK: - Nested Types

  open class Cell : UICollectionViewCell {

    static let identifier = "me.muukii.PixelEditor.FilterCell"

    public let imageView = UIImageView()

    public override init(frame: CGRect) {
      super.init(frame: frame)

      imageView.contentMode = .scaleAspectFill
      contentView.backgroundColor = UIColor.init(white: 0.95, alpha: 1)

      contentView.addSubview(imageView)
      imageView.frame = contentView.bounds
      imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    }

    open override func prepareForReuse() {
      super.prepareForReuse()
      imageView.image = nil
    }

    public required init?(coder aDecoder: NSCoder) {
      fatalError("init(coder:) has not been implemented")
    }

  }
}
