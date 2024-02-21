//
//  DemoCropView.swift
//  SwiftUIDemo
//
//  Created by Muukii on 2021/03/05.
//  Copyright © 2021 muukii. All rights reserved.
//

import BrightroomEngine
import BrightroomUI
import PrecisionLevelSlider
import SwiftUI
import UIKit

public struct PhotosCropRotating: View {

  @StateObject var editingStack: EditingStack

  @State var rotation: EditingCrop.Rotation?
  @State var adjustmentAngle: EditingCrop.AdjustmentAngle?
  @State var croppingAspectRatio: PixelAspectRatio?

  @State var canReset: Bool = false
  @State var isFocusingAspectRatio: Bool = false

  public init(
    editingStack: @escaping () -> EditingStack
  ) {
    self._editingStack = .init(wrappedValue: editingStack())
  }

  public var body: some View {
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

          Group {
            if isFocusingAspectRatio {
              aspectRatioView
            } else {
              rotationAdjustmentView
            }
          }
          .zIndex(1)
        }
      }
    }
    .onAppear {
      editingStack.start()
    }

  }

  private var rotationAdjustmentView: some View {
    SwiftUIPrecisionLevelSlider(
      value: .init(
        get: { (adjustmentAngle?.degrees ?? 0) },
        set: { value in
          adjustmentAngle = .init(degrees: value)
        }
      ),
      haptics: .init(trigger: { value in
        if value.truncatingRemainder(dividingBy: 5) == 0 {
          return .impact(style: .light, intensity: 0.4)
        } else {
          return nil
        }
      }),
      range: .init(
        range: -45...45,
        transform: { source in
          source.rounded(.toNearestOrEven)
        }
      ),
      centerLevel: { value in
        HStack {
          Spacer()
          VStack {
            Spacer(minLength: 12)
            Rectangle()
              .frame(width: 1)
            Spacer(minLength: 12)
          }
          Spacer()
        }
        .foregroundStyle(.tint)
      },
      track: { value in
        VStack {
          HStack {
            Spacer()
            Circle()
              .frame(width: 6, height: 6)
              .opacity(value == 0 ? 0 : 1)
              .animation(.spring, value: value == 0)
            Spacer()
          }
          HStack(spacing: 0) {
            ForEach(0..<4) { i in
              ShortBar()
                .foregroundStyle(.primary)
              Group {
                Spacer(minLength: 0)
                ShortBar()
                Spacer(minLength: 0)
                ShortBar()
                Spacer(minLength: 0)
                ShortBar()
                Spacer(minLength: 0)
                ShortBar()
                Spacer(minLength: 0)
                ShortBar()
                Spacer(minLength: 0)
                ShortBar()
                Spacer(minLength: 0)
                ShortBar()
                Spacer(minLength: 0)
                ShortBar()
                Spacer(minLength: 0)
                ShortBar()
                Spacer(minLength: 0)
              }
              .foregroundStyle(.secondary)
            }
            ShortBar()
              .foregroundStyle(.primary)
          }
        }
        .foregroundStyle(.tint)
      }
    )
    .tint(.white)
    .frame(height: 50)
  }

  private var aspectRatioView: some View {
    VStack(spacing: 20) {
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
              isSelected: croppingAspectRatio?.asCGSize()
                == editingStack.state.loadedState?.imageSize
            ) {
              guard let imageSize = editingStack.state.loadedState?.imageSize else {
                return
              }
              croppingAspectRatio = .init(imageSize)
            }

            AspectRationButton(
              title: Text("FREEFORM"),
              isSelected: croppingAspectRatio == nil
            ) {
              croppingAspectRatio = nil
            }

            AspectRationButton(
              title: Text("SQUARE"),
              isSelected: croppingAspectRatio == .square
            ) {
              croppingAspectRatio = .square
            }

            ForEach(Self.horizontalRectangleApectRatios) { ratio in
              AspectRationButton(
                title: Text("\(Int(ratio.width)):\(Int(ratio.height))"),
                isSelected: croppingAspectRatio == ratio
              ) {
                croppingAspectRatio = ratio
              }
            }
          }
          .tint(.white)

        }
        .padding(.horizontal, 20)
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
struct ShortBar: View {
  var body: some View {
    RoundedRectangle(cornerRadius: 8)
      .frame(width: 1, height: 10)
  }
}
