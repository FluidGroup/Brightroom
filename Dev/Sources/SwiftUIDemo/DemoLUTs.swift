//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

import BrightroomParametric
import Foundation

/// The lookup tables bundled with the demo, as filters for
/// `ImageEditor.Options.filters`.
///
/// Brightroom has no bundle scanner: the file naming rule belongs to the app.
/// This demo names LUT images `LUT_<dimension>_<name>.{png,jpg,jpeg}`, 5.x's
/// `ColorCubeLoader` rule, and also picks up `.cube` files.
enum DemoLUTs {

  /// The filters for the LUTs in the app bundle, loaded once.
  static let bundled: [FilterFeature] = {
    do {
      return try filters(in: Bundle.main.bundleURL)
    } catch {
      assertionFailure("Could not load the bundled LUTs: \(error)")
      return []
    }
  }()

  /// Loads a filter for each LUT file directly inside `directory`, sorted by
  /// file name. Other files are skipped. The id is the file name.
  static func filters(in directory: URL) throws -> [FilterFeature] {
    try FileManager.default
      .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
      .compactMap { url -> FilterFeature? in
        let cube: ColorCubeFeature
        switch url.pathExtension.lowercased() {
        case "cube":
          cube = try ColorCubeFeature(contentsOfCubeFile: url)
        case "png", "jpg", "jpeg":
          let parts = url.deletingPathExtension().lastPathComponent
            .split(separator: "_", maxSplits: 2)
          guard parts.count == 3, parts[0] == "LUT" else { return nil }
          cube = try ColorCubeFeature(
            contentsOfCubeImage: url,
            name: String(parts[2]),
            dimension: Int(parts[1])
          )
        default:
          return nil
        }
        return FilterFeature(name: cube.name, id: cube.id, effects: [AnyImageEffect(cube)])
      }
  }
}
