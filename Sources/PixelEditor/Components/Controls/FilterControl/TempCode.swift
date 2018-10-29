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

import Foundation

enum TempCode {
  
  static func layout(navigationView: NavigationView, slider: StepSlider, in view: UIView) {
    
    let containerGuide = UILayoutGuide()
    
    view.addLayoutGuide(containerGuide)
    view.addSubview(slider)
    view.addSubview(navigationView)
    
    slider.translatesAutoresizingMaskIntoConstraints = false
    
    navigationView.translatesAutoresizingMaskIntoConstraints = false
    
    NSLayoutConstraint.activate([
      
      containerGuide.topAnchor.constraint(equalTo: slider.superview!.topAnchor),
      containerGuide.rightAnchor.constraint(equalTo: slider.superview!.rightAnchor, constant: -44),
      containerGuide.leftAnchor.constraint(equalTo: slider.superview!.leftAnchor, constant: 44),
      
      slider.topAnchor.constraint(greaterThanOrEqualTo: containerGuide.topAnchor),
      slider.rightAnchor.constraint(equalTo: containerGuide.rightAnchor),
      slider.leftAnchor.constraint(equalTo: containerGuide.leftAnchor),
      slider.bottomAnchor.constraint(lessThanOrEqualTo: containerGuide.bottomAnchor),
      slider.centerYAnchor.constraint(equalTo: containerGuide.centerYAnchor),
      
      navigationView.topAnchor.constraint(equalTo: containerGuide.bottomAnchor),
      navigationView.rightAnchor.constraint(equalTo: navigationView.superview!.rightAnchor),
      navigationView.leftAnchor.constraint(equalTo: navigationView.superview!.leftAnchor),
      navigationView.bottomAnchor.constraint(equalTo: navigationView.superview!.bottomAnchor),
      ])

  }
}
