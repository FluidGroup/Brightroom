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

import PixelEngine

open class SkinToneRootControlBase: ControlBase {

    public required override init(context: PixelEditContext) {
        super.init(context: context)
    }

}

open class SkinToneRootControl: SkinToneRootControlBase {


    public required init(
            context: PixelEditContext
    ) {

        super.init(context: context)
    }


    open override func layoutSubviews() {
        super.layoutSubviews()
    }


    public let slider = StepSlider(frame: .zero)

    open override func setup() {
        super.setup()

        backgroundColor = Style.default.control.backgroundColor

//        TempCode.layout(navigationView: navigationView, slider: slider, in: self)

        slider.addTarget(self, action: #selector(valueChanged), for: .valueChanged)

        addSubview(slider)

        slider.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            slider.topAnchor.constraint(greaterThanOrEqualTo: self.topAnchor),
            slider.rightAnchor.constraint(equalTo: self.rightAnchor),
            slider.leftAnchor.constraint(equalTo: self.leftAnchor),
//            slider.bottomAnchor.constraint(equalTo: self.bottomAnchor),
            slider.centerYAnchor.constraint(equalTo: self.centerYAnchor),
            slider.centerXAnchor.constraint(equalTo: self.centerXAnchor),
//            slider.heightAnchor.constraint(equalTo: self.heightAnchor, constant: -60),
//            slider.heightAnchor.constraint(equalToConstant: 100),
        ])

    }

    open override func didReceiveCurrentEdit(_ edit: EditingStack.Edit) {

        slider.set(value: edit.filters.skinTone?.value ?? 0, in: FilterSkinTone.range)

    }

    @objc
    private func valueChanged() {

        let value = slider.transition(in: FilterSkinTone.range)

        guard value != 0 else {
            context.action(.setFilter({ $0.skinTone = nil }))
            return
        }

        var f = FilterSkinTone()
        f.value = value
        context.action(.setFilter({ $0.skinTone = f }))
    }

}
