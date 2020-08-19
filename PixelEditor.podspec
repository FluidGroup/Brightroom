Pod::Spec.new do |s|
  s.name = "PixelEditor"
  s.version = '0.2.2'
  s.summary = "The image editor and engine using CoreImage"

  s.homepage = "https://github.com/muukii/Pixel"
  s.license = 'MIT'
  s.author = "muukii"
  s.source = { :git => "https://github.com/muukii/Pixel.git", :tag => s.version }

  s.source_files = ['Sources/PixelEditor/**/*.swift']

  s.module_name = s.name
  s.requires_arc = true
  s.ios.deployment_target = '10.0'
  s.ios.frameworks = ['UIKit', 'CoreImage']

  s.resources = "Sources/PixelEditor/Media.xcassets"
  s.dependency 'PixelEngine', '~> 0.2.2'

  s.dependency 'TransitionPatch', '~> 1.0.0'
end
