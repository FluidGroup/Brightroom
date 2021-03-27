Pod::Spec.new do |s|
  s.name = "Brightroom"
  s.version = "2.0.0-beta.1"
  s.summary = "The image editor and engine using CoreImage"

  s.homepage = "https://github.com/muukii/Pixel"
  s.license = "MIT"
  s.author = "muukii"
  s.source = { :git => "https://github.com/muukii/Pixel.git", :tag => s.version }

  s.swift_version = "5.3"
  s.module_name = s.name
  s.requires_arc = true
  s.ios.deployment_target = "12.0"
  s.ios.frameworks = ["UIKit", "CoreImage"]
  s.ios.dependency "Verge", "~> 8.9.1"

  s.subspec "Engine" do |ss|
    ss.source_files = "Sources/PixelEngine/**/*.swift"
  end

  s.subspec "Editor" do |ss|
    ss.source_files = "Sources/PixelEditor/**/*.swift"
    ss.dependency "Brightroom/Engine"
    ss.dependency "TransitionPatch"
  end
end
