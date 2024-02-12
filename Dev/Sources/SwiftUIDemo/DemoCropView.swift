//
//  DemoCropView.swift
//  SwiftUIDemo
//
//  Created by Muukii on 2021/03/05.
//  Copyright © 2021 muukii. All rights reserved.
//

import BrightroomEngine
import BrightroomUI
import SwiftUI
import UIKit

struct DemoCropView: View {

  @StateObject var editingStack: EditingStack

  @State var rotation: EditingCrop.Rotation?
  @State var adjustmentAngle: EditingCrop.AdjustmentAngle?
  @State var croppingAspectRatio: PixelAspectRatio?

  @State var resultImage: ResultImage?

  @State var canReset: Bool = false
  @State var isFocusingAspectRatio: Bool = false

  init(
    editingStack: @escaping () -> EditingStack
  ) {
    self._editingStack = .init(wrappedValue: editingStack())
  }

  var body: some View {
    VStack {
      ZStack {
        Color.black
          .ignoresSafeArea()

        VStack {

          HStack {
            Button(
              action: {

                if self.rotation == nil {
                  self.rotation = .angle_0
                  self.rotation = self.rotation!.next()
                } else {
                  self.rotation = self.rotation!.next()
                }

              },
              label: {
                Image(systemName: "rotate.left")
                  .resizable()
                  .aspectRatio(contentMode: .fit)
                  .frame(width: 22)
                  .foregroundStyle(.secondary)
              }
            )

            Spacer()

            if editingStack.state.loadedState?.hasUncommitedChanges ?? false {
              Button {
                rotation = nil
                adjustmentAngle = nil
                croppingAspectRatio = nil

                //                switch croppingAspectRatio {
                //                case .fixed(let ratio):
                //                  cropView.setCroppingAspectRatio(ratio)
                //                case .selectable:
                //                  cropView.setCroppingAspectRatio(nil)
                //                }
                //                cropView.resetCrop()

              } label: {
                Text("RESET")
                  .font(.subheadline)
              }
              .tint(.yellow)
            }

            Spacer()

            Button(
              action: {
                isFocusingAspectRatio.toggle()
              },
              label: {
                Image(systemName: isFocusingAspectRatio ? "aspectratio.fill" : "aspectratio")
                  .resizable()
                  .aspectRatio(contentMode: .fit)
                  .frame(width: 22)
                  .foregroundStyle(isFocusingAspectRatio ? .primary : .secondary)
              }
            )
          }
          .tint(.white)
          .padding()
          .zIndex(1)

          SwiftUICropView(
            editingStack: editingStack
          )
          .rotation(rotation)
          .adjustmentAngle(adjustmentAngle)
          .croppingAspectRatio(croppingAspectRatio)
          .zIndex(0)

          if isFocusingAspectRatio {
            aspectRatioView
          }

          VStack {

            HStack {
              Button("16:9") {
                self.croppingAspectRatio = .init(width: 16, height: 9)
              }

              Button("Freeform") {
                self.croppingAspectRatio = nil
              }
            }
            HStack {
              Button("0") {
                self.rotation = .angle_0
              }
              Button("90") {
                self.rotation = .angle_90
              }
              Button("180") {
                self.rotation = .angle_180
              }
              Button("270") {
                self.rotation = .angle_270
              }
              Button("- 10") {
                if self.adjustmentAngle == nil {
                  self.adjustmentAngle = .zero
                }
                self.adjustmentAngle! -= .degrees(10)
              }
              Button("+ 10") {
                if self.adjustmentAngle == nil {
                  self.adjustmentAngle = .zero
                }
                self.adjustmentAngle! += .degrees(10)
              }
            }
          }
          .zIndex(1)
        }
      }
      Button("Done") {
        let image = try! editingStack.makeRenderer().render().cgImage
        self.resultImage = .init(cgImage: image)
      }
    }
    .onAppear {
      editingStack.start()
    }
    .sheet(item: $resultImage) {
      RenderedResultView(result: $0)
    }
  }

  private var aspectRatioView: some View {
    VStack {
      HStack(spacing: 18) {

        // vertical
        Button {

        } label: {
          ZStack {
            RoundedRectangle(cornerRadius: 2)
              .stroke(style: .init(lineWidth: 5))
              .fill(Color(white: 0.5, opacity: 1))

            RoundedRectangle(cornerRadius: 2)
              .fill(Color(white: 0.3, opacity: 1))

            Image(systemName: "checkmark")
              .resizable()
              .aspectRatio(contentMode: .fit)
              .frame(width: 12)
              .foregroundStyle(Color.black)
          }
          .tint(.white)
          .frame(width: 18, height: 28)
        }

        // horizontal
        Button {

        } label: {
          ZStack {
            RoundedRectangle(cornerRadius: 2)
              .stroke(style: .init(lineWidth: 5))
              .fill(Color(white: 0.5, opacity: 1))

            RoundedRectangle(cornerRadius: 2)
              .fill(Color(white: 0.3, opacity: 1))

            Image(systemName: "checkmark")
              .resizable()
              .aspectRatio(contentMode: .fit)
              .frame(width: 12)
              .foregroundStyle(Color.black)
          }
          .tint(.white)
          .frame(width: 28, height: 18)
        }
      }

      ScrollView(.horizontal, showsIndicators: false) {
        HStack {

          Group {

            AspectRationButton(
              title: Text("ORIGINAL"),
              isSelected: true
            ) {

            }

            AspectRationButton(
              title: Text("FREEFORM"),
              isSelected: true
            ) {

            }

            AspectRationButton(
              title: Text("SQUARE"),
              isSelected: true
            ) {

            }

            ForEach(Self.horizontalRectangleApectRatios) { ratio in
              AspectRationButton(
                title: Text("\(Int(ratio.width)):\(Int(ratio.height))"),
                isSelected: false
              ) {

              }
            }
          }
          .tint(.white)

        }

      }
    }
  }

  private static let horizontalRectangleApectRatios: [PixelAspectRatio] = [
    .init(width: 16, height: 9),
    .init(width: 10, height: 8),
    .init(width: 7, height: 5),
    .init(width: 4, height: 3),
    .init(width: 5, height: 3),
    .init(width: 3, height: 2),
  ]
}

struct AspectRationButton: View {

  let title: Text
  let isSelected: Bool
  let onTap: @MainActor () -> Void

  var body: some View {
    Button(
      action: {
        onTap()
      },
      label: {
        title
          .font(.caption)
          .foregroundStyle(.primary)
          .padding(.horizontal, 10)
          .padding(.vertical, 6)
          .background(
            Capsule()
              .foregroundStyle(.tertiary)
              .opacity(isSelected ? 1 : 0)
          )
          .foregroundStyle(.tint)
      }
    )
  }
}

struct AspectRationButtonStyle: PrimitiveButtonStyle {

  let isSeleted: Bool

  func makeBody(configuration: Configuration) -> some View {
    configuration
      .label
      .foregroundStyle(.primary)
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .background(
        Capsule()
          .foregroundStyle(.tertiary)
          .opacity(isSeleted ? 1 : 0)
      )
      .foregroundStyle(.tint)

  }

}

struct Slider: View {

  enum SliderPreferenceKey: PreferenceKey {

    static var defaultValue: CGRect = .zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
      //      nextValue()
    }

    typealias Value = CGRect

  }

  @State var value: Int = 0

  var body: some View {

    VStack {
      Circle()
        .frame(width: 2, height: 2)
      GeometryReader(content: { geometry in
        ScrollViewReader { proxy in
          ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
              ForEach(0..<25) { index in
                RoundedRectangle(cornerRadius: 2)
                  .fill(Color(white: 0.5, opacity: 1))
                  .frame(width: 2, height: 20)
              }
              RoundedRectangle(cornerRadius: 2)
                .frame(width: 2, height: 20)
                .id(0)
              ForEach(0..<25) { index in
                RoundedRectangle(cornerRadius: 2)
                  .fill(Color(white: 0.5, opacity: 1))
                  .frame(width: 2, height: 20)
              }
            }
            .background(
              GeometryReader { geometry in
                Color.clear.preference(
                  key: SliderPreferenceKey.self,
                  value: geometry.frame(in: .named("ScrollView"))
                )
              }
            )
            .padding(.horizontal, geometry.size.width / 2)
            .onPreferenceChange(
              SliderPreferenceKey.self,
              perform: { value in
                print(value)
              }
            )

          }
          .coordinateSpace(name: "ScrollView")
          .onAppear(perform: {
            proxy.scrollTo(0, anchor: .center)
          })

        }
        //      .background(Color.red)
      })
    }

  }

}

#Preview("Slider") {
  Slider()
}

#Preview {
  DemoCropView(
    editingStack: { Mocks.makeEditingStack(image: Mocks.imageHorizontal()) }
  )
}

#Preview {
  Text("")
    .onAppear {

      let uiView = UIView(frame: .init(origin: .zero, size: .init(width: 100, height: 200)))
      print(uiView.frame)

      uiView.transform = .init(rotationAngle: Angle(degrees: 10).radians)
      print(uiView.transform)

      print(uiView.frame, uiView.bounds)
    }
}
