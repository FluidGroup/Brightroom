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
import Verge

public struct PhotosCropRotating: View {

  private enum Direction {
    /**
     +----+
     |    |
     |    |
     |    |
     |    |
     |    |
     |    |
     +----+
     */
    case vertical
    /**
     +---------------+
     |               |
     |               |
     +---------------+
     */
    case horizontal

    mutating func swap() {
      switch self {
      case .horizontal: self = .vertical
      case .vertical: self = .horizontal
      }
    }
  }

  private enum AspectRatio: Equatable {
    case original(PixelAspectRatio)
    case freeform
    case specific(PixelAspectRatio)
  }

  @StateObject var editingStack: EditingStack

  @State private var rotation: EditingCrop.Rotation?
  @State private var adjustmentAngle: EditingCrop.AdjustmentAngle?
  @State private var croppingAspectRatio: AspectRatio = .freeform

  // TODO: use init value from original aspect ratio.
  @State private var croppingAspectRationDirection: Direction = .horizontal

  @State private var canReset: Bool = false
  @State private var isFocusingAspectRatio: Bool = false

  @State private var cropViewState: Changes<CropView.State>?

  public init(
    editingStack: @escaping () -> EditingStack
  ) {
    self._editingStack = .init(wrappedValue: editingStack())
  }

  private var isLoading: Bool {
    editingStack.state.isLoading
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
            .disabled(isLoading)

            Spacer()

            if editingStack.state.loadedState?.hasUncommitedChanges ?? false {
              Button {
                rotation = nil
                adjustmentAngle = nil
                croppingAspectRatio = .freeform

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
              .disabled(isLoading)
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
            .disabled(isLoading)
          }
          .tint(.white)
          .padding()
          .zIndex(1)

          SwiftUICropView(
            editingStack: editingStack,
            stateHandler: { state in
              cropViewState = state
            }
          )
          .rotation(rotation)
          .adjustmentAngle(adjustmentAngle)
          .croppingAspectRatio({
            switch croppingAspectRatio {
            case .freeform:
              return nil
            case .original(let ratio):
              return ratio
            case .specific(let ratio):
              return ratio
            }
          }())
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
    .disabled(isLoading)
  }

  private var aspectRatioView: some View {

    let isDirectionButtonDisabled: Bool = {
      switch croppingAspectRatio {
      case .original(_):
        return true
      case .freeform:
        return true
      case .specific(let ratio):
        guard ratio != .square else {
          return true
        }
        return false
      }
    }()

    return VStack(spacing: 20) {
      HStack(spacing: 18) {

        // vertical
        Button {
          if croppingAspectRationDirection != .vertical {
            switch croppingAspectRatio {
            case .freeform:
              assertionFailure()
            case .original:
              assertionFailure()
            case .specific(let ratio):
              croppingAspectRatio = .specific(ratio.swapped())
              croppingAspectRationDirection = .vertical
            }
          }
        } label: {
          ZStack {
            RoundedRectangle(cornerRadius: 2)
              .stroke(style: .init(lineWidth: 5))
              .fill(Color(white: 0.7, opacity: 1))

            RoundedRectangle(cornerRadius: 2)
              .fill(Color(white: 0.4, opacity: 1))

            if isDirectionButtonDisabled == false, croppingAspectRationDirection == .vertical {
              Image(systemName: "checkmark")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 12)
                .foregroundStyle(Color.black)
            }
          }
          .tint(.white)
          .frame(width: 18, height: 28)
          .compositingGroup()
          .opacity(isDirectionButtonDisabled ? 0.5 : 1)

        }
        .disabled(isDirectionButtonDisabled)

        // horizontal
        Button {
          if croppingAspectRationDirection != .horizontal {
            switch croppingAspectRatio {
            case .freeform:
              assertionFailure()
            case .original:
              assertionFailure()
            case .specific(let ratio):
              croppingAspectRatio = .specific(ratio.swapped())
              croppingAspectRationDirection = .horizontal
            }
          }
        } label: {
          ZStack {
            RoundedRectangle(cornerRadius: 2)
              .stroke(style: .init(lineWidth: 5))
              .fill(Color(white: 0.7, opacity: 1))

            RoundedRectangle(cornerRadius: 2)
              .fill(Color(white: 0.4, opacity: 1))

            if isDirectionButtonDisabled == false, croppingAspectRationDirection == .horizontal {
              Image(systemName: "checkmark")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 12)
                .foregroundStyle(Color.black)
            }
          }
          .tint(.white)
          .frame(width: 28, height: 18)
          .compositingGroup()
          .opacity(isDirectionButtonDisabled ? 0.5 : 1)

        }
        .disabled(isDirectionButtonDisabled)

      }

      ScrollView(.horizontal, showsIndicators: false) {
        HStack {

          Group {

            AspectRationButton(
              title: Text("ORIGINAL"),
              isSelected: {
                switch croppingAspectRatio {
                case .original(let pixelAspectRatio):
                  return pixelAspectRatio.asCGSize() ==  editingStack.state.loadedState?.imageSize
                case .freeform:
                  return false
                case .specific:
                  return false
                }
              }()
            ) {
              guard let imageSize = editingStack.state.loadedState?.imageSize else {
                return
              }
              croppingAspectRatio = .original(.init(imageSize))
            }

            AspectRationButton(
              title: Text("FREEFORM"),
              isSelected: croppingAspectRatio == .freeform
            ) {
              croppingAspectRatio = .freeform
            }

            AspectRationButton(
              title: Text("SQUARE"),
              isSelected: croppingAspectRatio == .specific(.square)
            ) {
              croppingAspectRatio = .specific(.square)
            }

            ForEach(Self.horizontalRectangleApectRatios) { ratio in
              switch croppingAspectRationDirection {
              case .vertical:
                AspectRationButton(
                  title: Text("\(Int(ratio.height)):\(Int(ratio.width))"),
                  isSelected: croppingAspectRatio == .specific(ratio.swapped())
                ) {
                  croppingAspectRatio = .specific(ratio.swapped())
                }
              case .horizontal:
                AspectRationButton(
                  title: Text("\(Int(ratio.width)):\(Int(ratio.height))"),
                  isSelected: croppingAspectRatio == .specific(ratio)
                ) {
                  croppingAspectRatio = .specific(ratio)
                }
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
