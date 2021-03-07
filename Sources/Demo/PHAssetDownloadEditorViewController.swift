//
//  PHAssetDownloadEditorViewController.swift
//  PixelEngine
//
//  Created by Antoine Marandon on 16/12/2019.
//  Copyright © 2019 muukii. All rights reserved.
//


import PixelEngine
import PixelEditor
import MosaiqueAssetsPicker
import Photos

final class PHAssetDownloadEditorViewController : UIViewController {

  @IBOutlet weak var imageView: UIImageView!
  private var selectedAsset: PHAsset?

  override func viewDidLoad() {
    super.viewDidLoad()
  }


  @IBAction func didTapPushButton(_ sender: Any) {

    let picker = MosaiqueAssetPickerViewController()
      .setSelectionMode(.single)
      .setNumberOfItemsPerRow(3)
    picker.pickerDelegate = self

    present(picker, animated: true, completion: nil)
  }

  @IBAction func didTapPushKeepingButton(_ sender: Any) {
    guard let selectedAsset = selectedAsset else { return }
    
    let controller = PixelEditViewController(
      viewModel: .init(
        editingStack: EditingStack(
          source: .init(asset: selectedAsset),
          previewSize: .init(width: view.frame.width, height: view.frame.width)
        )
      )
    )
    
    controller.delegate = self
    
    navigationController?.pushViewController(controller, animated: true)
    
  }
}

extension PHAssetDownloadEditorViewController: MosaiqueAssetPickerDelegate {
  
  func photoPicker(_ controller: UIViewController, didPickImages images: [UIImage]) {
    
  }
  
  func photoPicker(_ controller: UIViewController, didPickAssets assets: [AssetFuture]) {
    
  }
  
  func photoPickerDidCancel(_ controller: UIViewController) {
    
  }
  
  func photoPicker(_ pickerController: MosaiqueAssetPickerViewController, didPickAssets assets: [AssetFuture]) {
    self.selectedAsset = assets.first?.asset
    pickerController.dismiss(animated: true, completion: nil)
  }
}


extension PHAssetDownloadEditorViewController : PixelEditViewControllerDelegate {

  func pixelEditViewController(_ controller: PixelEditViewController, didEndEditing editingStack: EditingStack) {
    self.navigationController?.popToViewController(self, animated: true)
    let image = editingStack.makeRenderer().render(resolution: .full)
    self.imageView.image = image
  }

  func pixelEditViewControllerDidCancelEditing(in controller: PixelEditViewController) {
    self.navigationController?.popToViewController(self, animated: true)
  }
}
