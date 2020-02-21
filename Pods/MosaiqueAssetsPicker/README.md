# 📸 MosaiqueAssetsPicker

Your customizable asset picker.

## Overview

![Whimsical AssetPicker](./AssetPicker.png)

## 🔶 Requirements

iOS 10.0+
Xcode 10.1+
Swift 4.2+

## 📱 Features

- [x] Load camera rolls and others albums
- [x] Customize cells
- [x] Customize style and localization
- [x] Custom header
- [x] Photo on the cloud
- [x] Permissions handling
- [x] Other asset ( LivePhoto, Video, Gif, .. )
- [x] Background downloading
- [ ] Selection counter ( badge ? )

## 👨🏻‍💻 Usage

### Default value

```swift
let photoPicker = MosaiqueAssetPickerViewController()
photoPicker.pickerDelegate = self

present(photoPicker, animated: true, completion: nil)
```

### Customization

#### Use Custom Cell classes

```swift
let cellRegistrator = AssetPickerCellRegistrator()
cellRegistrator.register(cellClass: Demo2AssetCell.self, forCellType: .asset)
cellRegistrator.register(cellClass: Demo2AssetCollectionCell.self, forCellType: .assetCollection)

let photoPicker = MosaiqueAssetPickerViewController()
                    .setCellRegistrator(cellRegistrator)

photoPicker.pickerDelegate = self

present(photoPicker, animated: true, completion: nil)
```

#### Use Custom Nib classes

```swift
let assetNib = UINib(nibName: String(describing: Demo3AssetNib.self), bundle: nil)
let assetCollectionNib = UINib(nibName: String(describing: Demo3AssetCollectionNib.self), bundle: nil)

let cellRegistrator = AssetPickerCellRegistrator()
cellRegistrator.register(nib: assetNib, forCellType: .asset)
cellRegistrator.register(nib: assetCollectionNib, forCellType: .assetCollection)

let photoPicker = MosaiqueAssetPickerViewController()
                    .setCellRegistrator(cellRegistrator)

photoPicker.pickerDelegate = self

present(photoPicker, animated: true, completion: nil)
```

#### Add header view

```swift
let headerView = UIView()
headerView.backgroundColor = .orange
headerView.translatesAutoresizingMaskIntoConstraints = false
headerView.heightAnchor.constraint(equalToConstant: 120).isActive = true

let photoPicker = MosaiqueAssetPickerViewController()
                    .setHeaderView(headerView, isHeaderFloating: true)

photoPicker.pickerDelegate = self

present(photoPicker, animated: true, completion: nil)
```

#### Other customization

```swift
func setSelectionMode(_ selectionMode: SelectionMode)
func setSelectionMode(_ selectionColor: UIColor)
func setSelectionColor(_ tintColor: UIColor)
func setNumberOfItemsPerRow(_ numberOfItemsPerRow: Int)
func setHeaderView(_ headerView: UIView, isHeaderFloating: Bool)
func setCellRegistrator(_ cellRegistrator: AssetPickerCellRegistrator)
func setMediaTypes(_ supportOnlyMediaType: [PHAssetMediaType])
func disableOnLibraryScrollAnimation()
func localize(_ localize: LocalizedStrings)

public enum SelectionMode {
    case single
    case multiple(limit: Int)
}

public struct LocalizedStrings {
    public var done: String = "Done"
    public var next: String = "Next"
    public var dismiss: String = "Dismiss"
    public var collections: String = "Collections"
    public var changePermissions: String = "Change your Photo Library permissions"
}
```

### AssetFuture usage

`AssetFuture` can be used to dismiss the view controller once the asset is selected but before the asset is ready/downloaded. It can be optained through the (optional)  delegate: 

`    func photoPicker(_ pickerController: MosaiqueAssetPickerViewController, didPickAssets assets: [AssetFuture])`

You can retreive asynchronously a thumbnail with `onThumbnailCompletion: ((Result<UIImage, NSError>) -> Void)?`
And the final image  with `finalImageResult: Result<UIImage, NSError>?`

As long as the `AssetFuture` is retained by you or the `MosaiqueAssetPickerViewController`, the asset will be fetched, using the network if needed, even if the app enters background. The fetch request is cancelled on release.


## Installation

### CocoaPods

XXXX


### What's using MosaiqueAssetsPicker

- Pairs Engage

## Authors

- Muukii <muukii.app@gmail.com>
- Aymen Rebouh <aymenmse@gmail.com>
- Antoine Marandon <antoine@marandon.fr>

## License

AssetsPicker is released under the MIT license.
