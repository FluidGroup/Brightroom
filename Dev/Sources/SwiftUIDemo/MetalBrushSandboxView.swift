import CoreImage
import BrightroomEngine
import IOSurface
import MetalKit
import os
import simd
import SwiftUI
import UIKit

enum MetalBrushSandboxInteractionMode: String, CaseIterable, Identifiable {
  case draw
  case view

  var id: Self { self }

  var title: String {
    switch self {
    case .draw:
      return "Draw"
    case .view:
      return "View"
    }
  }
}

extension MetalBrushSandboxInteractionMode {
  var isDrawingEnabled: Bool {
    switch self {
    case .draw:
      return true
    case .view:
      return false
    }
  }

  var panMinimumNumberOfTouches: Int {
    switch self {
    case .draw:
      return 2
    case .view:
      return 1
    }
  }
}

enum MetalBrushSandboxRenderMode: String, CaseIterable, Identifiable {
  case full
  case filteredOnly
  case viewportFilteredOnly
  case viewportFull
  case viewportCachedSource

  var id: Self { self }

  var title: String {
    switch self {
    case .full:
      return "Full"
    case .filteredOnly:
      return "Filtered"
    case .viewportFilteredOnly:
      return "Viewport"
    case .viewportFull:
      return "VP Full"
    case .viewportCachedSource:
      return "VP Cached"
    }
  }
}

extension MetalBrushSandboxRenderMode {
  var usesCommittedTiles: Bool {
    switch self {
    case .full, .filteredOnly:
      return true
    case .viewportFilteredOnly, .viewportFull, .viewportCachedSource:
      return false
    }
  }

  var usesViewportRenderer: Bool {
    switch self {
    case .full, .filteredOnly:
      return false
    case .viewportFilteredOnly, .viewportFull, .viewportCachedSource:
      return true
    }
  }

  var allowsDrawing: Bool {
    switch self {
    case .full, .filteredOnly:
      return true
    case .viewportFilteredOnly, .viewportFull, .viewportCachedSource:
      return false
    }
  }

  var usesLocalEffectRenderImages: Bool {
    switch self {
    case .full, .viewportFull, .viewportCachedSource:
      return true
    case .filteredOnly, .viewportFilteredOnly:
      return false
    }
  }

  var usesViewportCachedSource: Bool {
    switch self {
    case .viewportCachedSource:
      return true
    case .full, .filteredOnly, .viewportFilteredOnly, .viewportFull:
      return false
    }
  }
}

struct MetalBrushSandboxView: View {

  @Environment(\.dismiss) private var dismiss

  private let image: UIImage

  init(image: UIImage = Asset.l1000316.image) {
    self.image = image
  }

  var body: some View {
    MetalBrushSandboxRepresentable(image: image)
      .accessibilityIdentifier("metal-brush-sandbox-canvas")
    .navigationTitle("Metal Brush Sandbox")
    .navigationBarTitleDisplayMode(.inline)
    .navigationBarBackButtonHidden(true)
    .toolbar {
      ToolbarItem(placement: .navigationBarLeading) {
        Button {
          dismiss()
        } label: {
          Label("Back", systemImage: "chevron.left")
        }
        .accessibilityIdentifier("metal-brush-back")
      }
    }
  }
}

struct MetalBrushSandboxMetrics: Equatable {
  var zoomScale: Double = 1
  var stampCount: Int = 0
  var strokeCount: Int = 0
}

private struct MetalBrushSandboxRepresentable: UIViewRepresentable {

  let image: UIImage

  func makeUIView(context: Context) -> MetalBrushSandboxRootView {
    MetalBrushSandboxRootView(image: image)
  }

  func updateUIView(_ uiView: MetalBrushSandboxRootView, context: Context) {}
}
