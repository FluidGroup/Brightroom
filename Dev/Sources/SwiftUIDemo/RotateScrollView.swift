import SwiftUI
import SwiftUIHosting
import SwiftUISupport

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
        ViewHost(instantiated: uiView)
        HStack {
          Button("Action") {
            // (5952.0, 3421.0)
            uiView.scrollView.customZoom(
              to: .init(
                origin: .zero,
                size: .init(width: 5952, height: 3421)
              ),
              animated: true
            )
          }
        }
      }
      .navigationBarTitleDisplayMode(.inline)
    }
  }

  class ContainerView: UIView, UIScrollViewDelegate {

    let scrollView = UIScrollView()
    let imageView = UIImageView(image: UIImage(named: "horizontal-rect")!)

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

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
      imageView
    }

  }

}

extension UIScrollView {

  fileprivate func customZoom(to rect: CGRect, animated: Bool) {

    var rect = rect

    rect.origin.x += contentInset.left
    rect.origin.y += contentInset.top
    rect.size.width += contentInset.left + contentInset.right + 1000

    print(rect)

    self.zoom(to: rect, animated: animated)

  }

  fileprivate func myZoom(to rect: CGRect, animated: Bool) {

    // contentInsetを考慮したズームスケールの計算
    let insetAdjustedBoundsSize = CGSize(width: self.bounds.size.width - self.contentInset.left - self.contentInset.right, height: self.bounds.size.height - self.contentInset.top - self.contentInset.bottom)
    let scaleWidth = insetAdjustedBoundsSize.width / rect.size.width
    let scaleHeight = insetAdjustedBoundsSize.height / rect.size.height
    let minScale = min(scaleWidth, scaleHeight)

    // 新しいズームスケールを設定
    let zoomScale = self.zoomScale * minScale

    // ズームスケールを適用
    self.setZoomScale(zoomScale, animated: animated)

    // ズーム後の領域を中央に表示するためのオフセット計算
    var offset = CGPoint()
    offset.x = (rect.origin.x * zoomScale) - ((insetAdjustedBoundsSize.width - rect.size.width * zoomScale) / 2) - self.contentInset.left
    offset.y = (rect.origin.y * zoomScale) - ((insetAdjustedBoundsSize.height - rect.size.height * zoomScale) / 2) - self.contentInset.top

    // オフセットを適用
    self.setContentOffset(offset, animated: animated)
  }
}


