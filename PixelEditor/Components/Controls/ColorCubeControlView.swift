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

  private let filters: [PreviewFilterColorCube]

  // MARK: - Functions

  public init(context: PixelEditContext, filters: [PreviewFilterColorCube]) {
    self.filters = filters
    super.init(context: context)
  }

  open override func setup() {
    super.setup()

    backgroundColor = Style.default.control.backgroundColor

    addSubview(collectionView)
    collectionView.translatesAutoresizingMaskIntoConstraints = false

    NSLayoutConstraint.activate([
      collectionView.topAnchor.constraint(greaterThanOrEqualTo: collectionView.superview!.topAnchor),
      collectionView.rightAnchor.constraint(equalTo: collectionView.superview!.rightAnchor),
      collectionView.leftAnchor.constraint(equalTo: collectionView.superview!.leftAnchor),
      collectionView.bottomAnchor.constraint(lessThanOrEqualTo: collectionView.superview!.bottomAnchor),
      collectionView.centerYAnchor.constraint(equalTo: collectionView.superview!.centerYAnchor),
      collectionView.heightAnchor.constraint(equalToConstant: 80),
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
    let filter = filters[indexPath.item]
    cell.set(preview: filter)
    return cell
  }

  open func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {

    return CGSize(width: 80, height: collectionView.bounds.height)
  }

  open func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {

    let filter = filters[indexPath.item]
    context.action(.setFilter( { $0.colorCube = filter.filter }))
    context.action(.commit)
  }

  // MARK: - Nested Types

  open class Cell : UICollectionViewCell {

    static let identifier = "me.muukii.PixelEditor.FilterCell"

    public let nameLabel: UILabel = .init()
    public let imageView: UIImageView = .init()

    public override init(frame: CGRect) {
      super.init(frame: frame)

      layout: do {
        imageView.contentMode = .scaleAspectFill
        contentView.backgroundColor = UIColor.init(white: 0.95, alpha: 1)
        imageView.clipsToBounds = true

        contentView.addSubview(nameLabel)
        contentView.addSubview(imageView)
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        imageView.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([

          nameLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
          nameLabel.rightAnchor.constraint(lessThanOrEqualTo: contentView.rightAnchor),
          nameLabel.leftAnchor.constraint(greaterThanOrEqualTo: contentView.leftAnchor),

          imageView.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 8),
          imageView.rightAnchor.constraint(equalTo: contentView.rightAnchor, constant: -8),
          imageView.leftAnchor.constraint(equalTo: contentView.leftAnchor, constant: 8),
          imageView.widthAnchor.constraint(equalTo: imageView.heightAnchor, multiplier: 1),
          //        imageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: 8),
          ])
      }

      style: do {

        nameLabel.textAlignment = .center
        nameLabel.font = UIFont.systemFont(ofSize: 13)
        nameLabel.textColor = UIColor(white: 0.05, alpha: 1)

      }
    }

    open override func prepareForReuse() {
      super.prepareForReuse()
      imageView.image = nil
    }

    public required init?(coder aDecoder: NSCoder) {
      fatalError("init(coder:) has not been implemented")
    }

    open func set(preview: PreviewFilterColorCube) {

      nameLabel.text = "ABC"
      imageView.image = UIImage(ciImage: preview.image, scale: contentScaleFactor, orientation: .up)
    }

  }
}
