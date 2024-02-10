import SwiftUI
import SwiftUIHosting
import SwiftUISupport
import MondrianLayout

struct BookRotateScrollView: View, PreviewProvider {
  var body: some View {
    ContentView()
  }

  static var previews: some View {
    Self()
  }

  private struct ContentView: View {

    @State var uiView: ContainerView = .init(frame: .zero)

    var body: some View {
      VStack {
        Representable()
      }
      .navigationBarTitleDisplayMode(.inline)
    }
  }

  struct Representable: UIViewRepresentable {

    func makeUIView(context: Context) -> ContainerView {
      ContainerView()
    }

    func updateUIView(_ uiView: ContainerView, context: Context) {

    }
  }

  class ContainerView: UIView, UIScrollViewDelegate {

    let scrollView = UIScrollView()
    let imageView = UIImageView(image: UIImage(named: "horizontal-rect")!)
    private let manualLayoutView = UIView()

    override init(frame: CGRect) {
      super.init(frame: frame)

      scrollView.backgroundColor = .black
      scrollView.contentInsetAdjustmentBehavior = .never
      scrollView.frame = frame.insetBy(dx: 30, dy: 30)

      addSubview(scrollView)

      scrollView.addSubview(imageView)
      scrollView.contentSize = imageView.bounds.size
      scrollView.delegate = self

//      scrollView.transform = .init(rotationAngle: Angle(degrees: 40).radians)

//      print(imageView.bounds.size)

      backgroundColor = .red

      manualLayoutView.backgroundColor = .systemGray

      Mondrian.buildSubviews(on: self) {
        VStackBlock {
          manualLayoutView
          SwiftUIHostingView {
            HStack {
              Button("Action") {

              }
            }
          }
        }
      }

    }

    override func layoutSubviews() {
      super.layoutSubviews()

      scrollView.frame = bounds
      scrollView.minimumZoomScale = 0.01
      scrollView.maximumZoomScale = 100
      scrollView.contentInset = .init(top: 100, left: 100, bottom: 100, right: 100  )

    }

    required init?(coder: NSCoder) {
      fatalError("init(coder:) has not been implemented")
    }

  }

}
