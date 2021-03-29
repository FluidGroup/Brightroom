## 🎉 v2.0.0-alpha.1 now open!

> 💥 v2.0.0 development is still early development. We have a lot of known issues.

> ⚒ Issues are managed in [v2 project](https://github.com/muukii/Brightroom/projects/2)

> 📌 Pixel has been renamed as **Brightroom**

> 📖 [Detailed documentations are available on here](https://www.notion.so/muukii/Brightroom-d4c59b37610a49de8a14131d24cd6162)

> 🎈 Please help us, we have issues that we don't know how to solve. (help wanted in Issues)

> ⭐️ If you interested in v2, hit the **Star button** to motivate us! 🤠

---

# v2-alpha.1 Brightroom - Composable image editor


<img src=top.png width=100%/>

| Classic Image Editor | PhotosCrop | Face detection |
| --- | --- | --- | 
| <img width=200px src="https://user-images.githubusercontent.com/1888355/112865486-c9154880-90f3-11eb-89eb-bc55f924f517.gif" /> | <img width=200px src=https://user-images.githubusercontent.com/1888355/112720381-4ea4c700-8f41-11eb-8ec3-2446518ded1b.gif /> | <img width=200px src=https://user-images.githubusercontent.com/1888355/112720303-cde5cb00-8f40-11eb-941f-c134368b87c5.gif /> |

Brightroom v2 provides the following features:
- Components are built separately and run standalone using an `EditingStack`.
- **Create your own image editor UI** by composing components.
- `EditingStack` manages the history of editing and renders images. It's like a headless browser.
- Wide color editing support

> 🤵🏻‍♂️ Support Muukii.  
> Hi, I'm Muukii. I'm working on open-source software including this library.  
> Please help me continue my work. I appreciate it.  
> https://github.com/sponsors/muukii

## Requirements

* Swift 5.3 (Xcode12.4+)
* iOS 12+

## Usage

<b><a href="https://www.notion.so/muukii/Brightroom-d4c59b37610a49de8a14131d24cd6162">Documentations</a></b>

## Installation

> ⚠️ Brightroom has not been published in CocoaPods since it's still early development.
> If you try to use it, following pod commands install libraries to your application.

**CocoaPods**

```ruby
pod "Brightroom/Engine", "2.0.0-alpha.1"
pod "Brightroom/UI-Classic", "2.0.0-alpha.1"
pod "Brightroom/UI-Crop", "2.0.0-alpha.1"
```

**Swift Package Manager**

```swift
dependencies: [
    .package(url: "https://github.com/muukii/Brightroom.git", exact: "2.0.0-alpha.1")
]
```

## License

Brightroom is available under the MIT license. See the LICENSE file for more info.

[![FOSSA Status](https://app.fossa.io/api/projects/git%2Bgithub.com%2Fmuukii%2FPixel.svg?type=large)](https://app.fossa.io/projects/git%2Bgithub.com%2Fmuukii%2FPixel?ref=badge_large)
