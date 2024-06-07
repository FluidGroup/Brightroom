<h1 align=center>Brightroom</h1>
<p align=center><i>A full-featured composable image editor with a customizable UI -- all backed by the power of Metal.</i></p>
<br/>

| Image Editor | PhotosCropRotating | Face Detection | Masking |
| --- | --- | --- | --- |
| <img width=200px src="https://user-images.githubusercontent.com/1888355/112865486-c9154880-90f3-11eb-89eb-bc55f924f517.gif" /> | <img width=200px src=https://github.com/FluidGroup/Brightroom/assets/1888355/df14adc2-97fc-465b-8919-7727c9bae8bd /> | <img width=200px src=https://user-images.githubusercontent.com/1888355/112720303-cde5cb00-8f40-11eb-941f-c134368b87c5.gif /> | <img width=200px src=https://user-images.githubusercontent.com/1888355/112927084-6487d700-914f-11eb-86a5-28f9373285e6.gif /> |

## Features

- **Create your own image editor UI** by composing components.
  - Components are built separately and run standalone using an `EditingStack`.
  - `EditingStacks` **manage editing history** and render images. *It's like a headless browser!*
- Edit and render using [**P3 Wide Color** Gamut](https://instagram-engineering.com/bringing-wide-color-to-instagram-5a5481802d7d)
- Support for [Super Large Photos™ (≤ 12000 pixels)](https://eoimages.gsfc.nasa.gov/images/imagerecords/78000/78314/VIIRS_3Feb2012_lrg.jpg).
- Previews and rendering backed with the power of **Metal**.
- Create custom-drawn **masks** on photos.
- Drop-in support for your own **custom filters using LUTs**.
- Load and download **remote images** for editing with a `URL`.
- Support for both UIKit and SwiftUI.

## Requirements

| iOS Target | Xcode Version | Swift Version |
|:---:|:---:|:---:|
| iOS 15.0+ | Xcode 15.2+ | Swift 5.9+ |

## Support the Project
Buy me a coffee or support me on [GitHub](https://github.com/sponsors/muukii?frequency=one-time&sponsor=muukii).

<a href="https://www.buymeacoffee.com/muukii">
<img width=25% alt="yellow-button" src="https://user-images.githubusercontent.com/1888355/146226808-eb2e9ee0-c6bd-44a2-a330-3bbc8a6244cf.png">
</a>

## 🎉 v2 Now Available!
There are a few important housekeeping notes for those coming from v1.

 - ⚒ Issues are managed in the [v2 Project](https://github.com/muukii/Brightroom/projects/2)
 - 📌 Pixel has been renamed **Brightroom**.
 - 📖 Detailed documentation is available [on Notion](https://www.notion.so/muukii/Brightroom-d4c59b37610a49de8a14131d24cd6162).
 - 🎈 **Help Wanted**: CoreImage and Metal professionals!
 - ⭐️ If you're interested in v2, **star the project** to motivate us! 🤠
 - 🪐 Brightroom's state management is now powered by [Verge](https://github.com/VergeGroup/Verge).

## Installation

**Swift Package Manager**

```swift
dependencies: [
    .package(url: "https://github.com/muukii/Brightroom.git", upToNextMajor: "2.2.0")
]
```

# Documentation

View the [full documentation](https://www.notion.so/muukii/Brightroom-d4c59b37610a49de8a14131d24cd6162) on Notion.

## Built-In UI

**BrightroomUIPhotosCrop.PhotosCropRotation**

<img width=200px src=https://github.com/FluidGroup/Brightroom/assets/1888355/df14adc2-97fc-465b-8919-7727c9bae8bd />

```swift
import SwiftUI
import BtightroomUIPhotosCrop

struct DemoCropView: View {

  @StateObject var editingStack: EditingStack
  @State var resultImage: ResultImage?

  init(
    editingStack: @escaping () -> EditingStack
  ) {
    self._editingStack = .init(wrappedValue: editingStack())
  }

  var body: some View {
    ZStack {

      VStack {
        PhotosCropRotating(editingStack: { editingStack })

        Button("Done") {
          let image = try! editingStack.makeRenderer().render().cgImage
          self.resultImage = .init(cgImage: image)
        }
      }
    }
    .onAppear {
      editingStack.start()
    }
  }

}
```

**ClassicEditor**

```
PixelEditViewController
```

# Demo & Full App
There is an entire open-source and production-ready app available on the App Store that uses Brightroom. It's called [Drip](https://github.com/muukii/Drip.app).

This repository also contains a demo app which demonstrates what Brightroom can perform and showcases some easy experiments. Clone this repo and build the project to try it out!

# License

Brightroom is available under the MIT license. See the LICENSE file for more info.

# Status

[![FOSSA Status](https://app.fossa.io/api/projects/git%2Bgithub.com%2Fmuukii%2FPixel.svg?type=large)](https://app.fossa.io/projects/git%2Bgithub.com%2Fmuukii%2FPixel?ref=badge_large)
