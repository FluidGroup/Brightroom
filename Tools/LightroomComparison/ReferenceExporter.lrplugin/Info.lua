-- A local, explicitly invoked acquisition tool for the comparison experiment.
return {
  LrSdkVersion = 13.0,
  LrSdkMinimumVersion = 6.0,
  LrToolkitIdentifier = "org.brightroom.research.reference-exporter",
  LrPluginName = "Brightroom Reference Exporter",
  LrLibraryMenuItems = {
    { title = "Export prepared Brightroom references", file = "Run.lua" },
  },
  VERSION = { major = 1, minor = 0, revision = 0 },
}
