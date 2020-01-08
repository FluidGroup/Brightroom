//
//  NotificationCenter+assetPicker.swift
//  AssetsPicker
//
//  Created by Antoine Marandon on 16/12/2019.
//  Copyright © 2019 eure. All rights reserved.
//

import Foundation

let PhotoPickerPickAssetsNotificationName = NSNotification.Name(rawValue: "jp.eure.assetspicke.PhotoPickerPickAssestNotification")
let PhotoPickerPickImagesNotificationName = NSNotification.Name(rawValue: "jp.eure.assetspicke.PhotoPickerPickImagesNotification")
let PhotoPickerCancelNotificationName = NSNotification.Name(rawValue: "jp.eure.assetspicke.PhotoPickerCancelNotification")
extension NotificationCenter {
    static let assetPicker = NotificationCenter()
}
