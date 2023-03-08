
import Foundation

func _url(forResource: String, ofType: String) -> URL {
  Bundle.main.path(
    forResource: forResource,
    ofType: ofType
  ).map {
    URL(fileURLWithPath: $0)
  }!
}
