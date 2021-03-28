Pod::Spec.new do |s|
  s.name = "Brightroom"
  s.version = "2.0.0-alpha.1"
  s.summary = "A component-oriented image editor on top of CoreImage."

  s.homepage = "https://github.com/muukii/Brightroom"
  s.license = "MIT"
  s.author = "muukii"
  s.source = { :git => "https://github.com/muukii/Brightroom.git", :tag => s.version }

  s.swift_version = "5.3"
  s.module_name = s.name
  s.requires_arc = true
  s.ios.deployment_target = "12.0"
  s.ios.frameworks = ["UIKit", "CoreImage"]
  s.ios.dependency "Verge", "~> 8.9.1"

  s.subspec "Engine" do |ss|
    ss.source_files = "Sources/BrightroomEngine/**/*.swift"
  end

  s.subspec "UI-Classic" do |ss|
    ss.source_files = "Sources/BrightroomUI/Shared/**/*.swift", "Sources/BrightroomUI/Built-in UI/ClassicImageEdit/**/*.swift"
    ss.dependency "Brightroom/Engine"
    ss.dependency "TransitionPatch"
  end

  s.subspec "UI-Crop" do |ss|
    ss.source_files = "Sources/BrightroomUI/Shared/**/*.swift", "Sources/BrightroomUI/Built-in UI/PhotosCrop/**/*.swift"
    ss.dependency "Brightroom/Engine"
  end
end
