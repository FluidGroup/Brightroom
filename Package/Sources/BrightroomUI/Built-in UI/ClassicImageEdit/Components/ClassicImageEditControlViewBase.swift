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

#if !COCOAPODS
import BrightroomEngine
#endif
import Verge

open class ClassicImageEditControlBase : UIView, ClassicImageEditControlChildViewType {
  
  open func didReceiveCurrentEdit(state: Changes<ClassicImageEditViewModel.State>) {
    
  }

  public let viewModel: ClassicImageEditViewModel
  
  private var subscriptions: Set<VergeAnyCancellable> = .init()

  public init(viewModel: ClassicImageEditViewModel) {
    self.viewModel = viewModel
    super.init(frame: .zero)
    setup()
    
    viewModel.sinkState { [weak self] (state) in
      self?.didReceiveCurrentEdit(state: state)
    }
    .store(in: &subscriptions)
  }

  @available(*, unavailable)
  public required init?(coder aDecoder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  open func setup() {

  }
}
