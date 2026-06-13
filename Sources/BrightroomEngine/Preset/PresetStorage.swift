import Foundation

import BrightroomParametric

/// A shared collection of filter presets expressed as parametric features.
///
/// UI layers (e.g. PhotosCrop's Filters mode) read presets from here and write
/// the selected one into the document's global-effects node.
open class PresetStorage {

  public static let `default` = PresetStorage(presets: [])

  public var presets: [PresetFeature] = []

  public init(
    presets: [PresetFeature]
  ) {
    self.presets = presets
  }
}

extension PresetStorage {

  /// Loads LUT files from the bundle into single-effect color-cube presets.
  public func loadLUTs(fromBundle bundle: Bundle = .main) throws {

    let loader = ColorCubeLoader(bundle: bundle)
    let cubes = try loader.load()

    self.presets = cubes
      .map { cube in
        PresetFeature(
          id: .init(rawValue: cube.identifier),
          name: cube.name,
          identifier: cube.identifier,
          effects: [cube]
        )
      }
  }

}
