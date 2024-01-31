import SwiftUI

struct BookRotateScrollView: View, PreviewProvider {
  var body: some View {
    ContentView()
  }

  static var previews: some View {
    Self()
  }

  private struct ContentView: View {

    var body: some View {
      Represent()
    }
  }

  class ContainerView: UIView {

    override init(frame: CGRect) {
      super.init(frame: frame)

      let scrollView = UIScrollView()
      scrollView.backgroundColor = .black
      scrollView.frame = frame.insetBy(dx: 30, dy: 30)

      addSubview(scrollView)

      scrollView.transform = .init(rotationAngle: Angle(degrees: 40).radians)

    }

    required init?(coder: NSCoder) {
      fatalError("init(coder:) has not been implemented")
    }

  }

  struct Represent: UIViewRepresentable {

    func makeUIView(context: Context) -> BookRotateScrollView.ContainerView {
      .init(frame: .init(origin: .zero, size: .init(width: 300, height: 300)))
    }
    
    func updateUIView(_ uiView: BookRotateScrollView.ContainerView, context: Context) {

    }
    
    typealias UIViewType = ContainerView



  }

}

