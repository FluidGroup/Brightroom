//
//  FullscreenIdentifiableView.swift
//  SwiftUIDemo
//
//  Created by Muukii on 2021/03/16.
//  Copyright © 2021 muukii. All rights reserved.
//

import SwiftUI

struct FullscreenIdentifiableView: View, Identifiable {
  
  @Environment(\.dismiss) var dismiss

  let id = UUID()
  private let content: AnyView
  private let showsDismissButton: Bool
  
  init<Content: View>(
    showsDismissButton: Bool = true,
    content: () -> Content
  ) {
    self.showsDismissButton = showsDismissButton
    self.content = .init(content())
  }
  
  var body: some View {
    VStack {
      content
      if showsDismissButton {
        Button("Dismiss") {
          dismiss()
        }
        .padding(16)
      }
    }
  }
}

