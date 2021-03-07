# Uncomment the next line to define a global platform for your project
platform :ios, "10.0"

target "PixelEngine" do
  use_frameworks!
  pod "Verge", git: "git@github.com:VergeGroup/Verge.git", branch: "main"
end

target "PixelEditor" do
  use_frameworks!
  pod "TransitionPatch"
  pod "Verge", git: "git@github.com:VergeGroup/Verge.git", branch: "main"
end

abstract_target 'Demo_Apps' do

  use_frameworks!
  pod "Reveal-SDK"
  pod "Verge", git: "git@github.com:VergeGroup/Verge.git", branch: "main"
  pod "TransitionPatch"
  pod "SwiftGen"

  target "Demo" do
    pod "MosaiqueAssetsPicker", :git => "git@github.com:eure/AssetsPicker.git"
  end

  target "SwiftUIDemo" do
    use_frameworks!
  end

end

