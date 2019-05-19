//
// Copyright (c) 2018 Muukii <muukii.app@gmail.com>
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

import UIKit

import PixelEngine
import PixelEditor

extension Collection where Index == Int {
  
  fileprivate func concurrentMap<U>(_ transform: (Element) -> U) -> [U] {
    var buffer = [U?].init(repeating: nil, count: count)
    let lock = NSLock()
    DispatchQueue.concurrentPerform(iterations: count) { i in
      let e = self[i]
      let r = transform(e)
      lock.lock()
      buffer[i] = r
      lock.unlock()
    }
    return buffer.compactMap { $0 }
  }
}



extension ColorCubeStorage {
  static func loadToDefault() {
    
    do {
      
      try autoreleasepool {
        let bundle = Bundle.main
        let rootPath = bundle.bundlePath as NSString
        let fileList = try FileManager.default.contentsOfDirectory(atPath: rootPath as String)
        
        let filters = fileList
          .filter { $0.hasSuffix(".png") || $0.hasSuffix(".PNG") }
          .sorted()
          .concurrentMap { path -> FilterColorCube in
            let url = URL(fileURLWithPath: rootPath.appendingPathComponent(path))
            let data = try! Data(contentsOf: url)
            let image = UIImage(data: data)!
            let name = path
              .replacingOccurrences(of: "LUT_", with: "")
              .replacingOccurrences(of: ".png", with: "")
              .replacingOccurrences(of: ".PNG", with: "")
            return FilterColorCube.init(
              name: name,
              identifier: path,
              lutImage: image,
              dimension: 64
            )
        }
        
        self.default.filters = filters
      }
      
    } catch {
      
      assertionFailure("\(error)")
    }
  }
}

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {

  var window: UIWindow?


  func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
    // Override point for customization after application launch.

    ColorCubeStorage.loadToDefault()
    return true
  }

  func applicationWillResignActive(_ application: UIApplication) {
    // Sent when the application is about to move from active to inactive state. This can occur for certain types of temporary interruptions (such as an incoming phone call or SMS message) or when the user quits the application and it begins the transition to the background state.
    // Use this method to pause ongoing tasks, disable timers, and invalidate graphics rendering callbacks. Games should use this method to pause the game.
  }

  func applicationDidEnterBackground(_ application: UIApplication) {
    // Use this method to release shared resources, save user data, invalidate timers, and store enough application state information to restore your application to its current state in case it is terminated later.
    // If your application supports background execution, this method is called instead of applicationWillTerminate: when the user quits.
  }

  func applicationWillEnterForeground(_ application: UIApplication) {
    // Called as part of the transition from the background to the active state; here you can undo many of the changes made on entering the background.
  }

  func applicationDidBecomeActive(_ application: UIApplication) {
    // Restart any tasks that were paused (or not yet started) while the application was inactive. If the application was previously in the background, optionally refresh the user interface.
  }

  func applicationWillTerminate(_ application: UIApplication) {
    // Called when the application is about to terminate. Save data if appropriate. See also applicationDidEnterBackground:.
  }


}

