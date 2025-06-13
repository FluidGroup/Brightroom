//
// Copyright (c) 2021 Muukii <muukii.app@gmail.com>
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

import SwiftUI
#if !COCOAPODS
import BrightroomEngine
#endif

struct ClassicImageEditStepSliderSwiftUIView: View {
  
  @Binding var value: Double
  let range: ParameterRange<Double, any AnyObject>
  let onChanged: (Double) -> Void
  
  @State private var internalValue: Double = 0
  @State private var isDragging = false
  
  var body: some View {
    VStack(spacing: 8) {
      if isDragging {
        Text(String(format: "%+.0f", internalValue * 100))
          .font(.system(size: 14, weight: .medium))
          .foregroundColor(Color(ClassicImageEditStyle.default.black))
          .transition(.opacity)
      }
      
      GeometryReader { geometry in
        ZStack(alignment: .center) {
          Rectangle()
            .fill(Color.gray.opacity(0.3))
            .frame(height: 2)
          
          Circle()
            .fill(Color(ClassicImageEditStyle.default.black))
            .frame(width: 20, height: 20)
            .offset(x: thumbOffset(in: geometry.size.width))
            .gesture(
              DragGesture()
                .onChanged { dragValue in
                  isDragging = true
                  let newValue = calculateValue(from: dragValue.location.x, totalWidth: geometry.size.width)
                  internalValue = newValue
                  value = mapToRange(newValue)
                  onChanged(value)
                  
                  if abs(newValue) < 0.05 {
                    let impactFeedback = UIImpactFeedbackGenerator(style: .light)
                    impactFeedback.impactOccurred()
                  }
                }
                .onEnded { _ in
                  withAnimation(.easeOut(duration: 0.2)) {
                    isDragging = false
                  }
                }
            )
          
          if abs(internalValue) < 0.001 {
            Rectangle()
              .fill(Color(ClassicImageEditStyle.default.black))
              .frame(width: 2, height: 12)
          }
        }
      }
      .frame(height: 20)
    }
    .onAppear {
      internalValue = mapFromRange(value)
    }
    .onChange(of: value) { newValue in
      if !isDragging {
        internalValue = mapFromRange(newValue)
      }
    }
  }
  
  private func thumbOffset(in totalWidth: CGFloat) -> CGFloat {
    let centerX = totalWidth / 2
    return (internalValue * centerX)
  }
  
  private func calculateValue(from x: CGFloat, totalWidth: CGFloat) -> Double {
    let centerX = totalWidth / 2
    let offset = x - centerX
    let normalizedValue = offset / centerX
    return max(-1, min(1, normalizedValue))
  }
  
  private func mapToRange(_ normalizedValue: Double) -> Double {
    let mid = (range.max + range.min) / 2
    if normalizedValue >= 0 {
      return mid + (normalizedValue * (range.max - mid))
    } else {
      return mid + (normalizedValue * (mid - range.min))
    }
  }
  
  private func mapFromRange(_ rangeValue: Double) -> Double {
    let mid = (range.max + range.min) / 2
    if rangeValue >= mid {
      return (rangeValue - mid) / (range.max - mid)
    } else {
      return (rangeValue - mid) / (mid - range.min)
    }
  }
}

#Preview {
  ClassicImageEditStepSliderSwiftUIView(
    value: .constant(0),
    range: FilterExposure.range,
    onChanged: { _ in }
  )
  .padding()
}