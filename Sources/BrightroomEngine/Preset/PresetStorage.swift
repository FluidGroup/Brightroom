import Foundation

import BrightroomParametric

/// A shared collection of filter presets expressed as parametric features.
///
/// UI layers (e.g. ImageEditor's Filters mode) read presets from here and write
/// the selected one into their document (ImageEditor: `effects.preset`).
///
/// Main-actor isolated: it is a UI-facing shared store, configured once
/// (`loadLUTs`) and read while building the editor UI. The isolation makes the
/// shared `default` instance and its mutable `presets` race-free under Swift 6.
@MainActor
open class PresetStorage {

  public static let `default` = PresetStorage(presets: [])

  public var presets: [FilterFeature] = []

  public init(
    presets: [FilterFeature]
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
        FilterFeature(
          name: cube.name,
          id: cube.id,
          effects: [AnyImageEffect(cube)]
        )
      }
  }

}
