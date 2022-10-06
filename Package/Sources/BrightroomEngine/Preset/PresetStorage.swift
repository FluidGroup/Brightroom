import Foundation

open class PresetStorage {

  public static let `default` = PresetStorage(presets: [])

  public var presets: [FilterPreset] = []

  public init(
    presets: [FilterPreset]
  ) {
    self.presets = presets
  }
}

extension PresetStorage {

  public func loadLUTs(fromBundle bundle: Bundle = .main) throws {

    let loader = ColorCubeLoader(bundle: bundle)
    let filters = try loader.load()

    self.presets = filters
      .map {
        FilterPreset(
          name: $0.name,
          identifier: $0.identifier,
          filters: [$0.asAny()],
          userInfo: [:]
        )
      }
  }

}
