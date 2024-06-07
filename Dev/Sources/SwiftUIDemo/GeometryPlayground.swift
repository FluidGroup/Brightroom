import SwiftUI

struct BookGeometryPlaygroud: View, PreviewProvider {
  var body: some View {
    ContentView()
  }

  static var previews: some View {
    Self()
  }

  private struct ContentView: View {

    var body: some View {
      ZStack {

        Color.black.opacity(0.2)
          .frame(width: 200, height: 300)

        Color.black.opacity(0.2)
          .frame(width: 200, height: 300)
          .rotationEffect(.degrees(10))

      }
    }
  }
}
