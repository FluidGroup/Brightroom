import BrightroomEngine
import BrightroomParametric
import BrightroomUI
import ImageIO
import SwiftUI

/// The built-in editor in a navigation stack, hosted as a Mac app would.
///
/// - The window's title is the photo's file name, and its subtitle when the
///   photo was taken and its pixel size.
/// - Every write to the document is registered with the window's
///   `UndoManager`, so Edit > Undo and Redo walk the editor's operations.
/// - The window is dark, the host's choice: the editor draws its image column
///   dark and leaves the window's appearance to the host.
/// - Done and Cancel leave the screen, and the edit with it.
struct EditorDemoView: View {

  private let onClose: @MainActor () -> Void

  @State private var document = ImageEditorDocument(source: Self.photo.source)
  /// The target the `UndoManager` registrations are grouped under.
  @State private var undoTarget = UndoTarget()

  @Environment(\.undoManager) private var undoManager

  init(onClose: @escaping @MainActor () -> Void) {
    self.onClose = onClose
  }

  var body: some View {
    NavigationStack {
      ImageEditor(
        document: undoableBinding,
        options: .editorDemo,
        onDone: onClose,
        onCancel: onClose
      )
      .navigationTitle(Self.photo.name)
      .navigationSubtitle(subtitle)
    }
    .preferredColorScheme(.dark)
    .onDisappear {
      // The edit leaves with the screen, so its undo steps go too.
      undoManager?.removeAllActions(withTarget: undoTarget)
    }
  }

  /// When the photo was taken (if known) and its pixel size, as in
  /// "2020-11-02 13:35 · 1638 × 2048".
  private var subtitle: String {
    let size = document.source.pixelSize
    let pixelSize = "\(Int(size.width)) × \(Int(size.height))"
    guard let dateTaken = Self.photo.dateTaken else {
      return pixelSize
    }
    return "\(dateTaken) · \(pixelSize)"
  }

  /// The document, with each write registered with the window's
  /// `UndoManager`.
  private var undoableBinding: Binding<ImageEditorDocument> {
    Binding {
      document
    } set: {
      Self.write($0, to: $document, undoManager: undoManager, target: undoTarget)
    }
  }

  /// Writes `new` to `document` and registers the write with `undoManager`.
  ///
  /// The reverse step is registered right here: inside an undo, the
  /// `UndoManager` records it as the redo. Registering from
  /// `onChange(of:)` would run after the undo returned and record a new
  /// undo step instead.
  private static func write(
    _ new: ImageEditorDocument,
    to document: Binding<ImageEditorDocument>,
    undoManager: UndoManager?,
    target: UndoTarget
  ) {
    let old = document.wrappedValue
    guard old != new else {
      return
    }
    document.wrappedValue = new
    undoManager?.registerUndo(withTarget: target) { _ in
      write(old, to: document, undoManager: undoManager, target: target)
    }
  }

  private final class UndoTarget {}
}

extension EditorDemoView {

  /// The photo the screen edits: gaku.jpeg from the app bundle, or the
  /// generated sample when that file is missing or unreadable.
  private struct Photo {

    /// The file name without its extension.
    var name: String
    /// When the photo was taken, as "2020-11-02 13:35", or nil when unknown.
    var dateTaken: String?
    var source: SourceImage
  }

  /// Read once, not each time the screen's view is created.
  private static let photo: Photo = {
    guard
      let url = Bundle.main.url(forResource: "gaku", withExtension: "jpeg"),
      let source = try? SourceImage(contentsOf: url)
    else {
      return Photo(name: "Sample", dateTaken: nil, source: CanvasDemoSample.makeSourceImage())
    }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return Photo(
      name: url.deletingPathExtension().lastPathComponent,
      dateTaken: dateTaken(fileURL: url).map(formatter.string(from:)),
      source: source
    )
  }()

  /// When the photo was taken: EXIF DateTimeOriginal, in the zone of
  /// OffsetTimeOriginal when the file records one; otherwise TIFF DateTime;
  /// otherwise the file's creation date.
  private static func dateTaken(fileURL: URL) -> Date? {
    let properties = CGImageSourceCreateWithURL(fileURL as CFURL, nil)
      .flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) } as? [CFString: Any]
    let exif = properties?[kCGImagePropertyExifDictionary] as? [CFString: Any]
    let tiff = properties?[kCGImagePropertyTIFFDictionary] as? [CFString: Any]

    if
      let text = exif?[kCGImagePropertyExifDateTimeOriginal] as? String,
      let date = exifDate(text, offset: exif?[kCGImagePropertyExifOffsetTimeOriginal] as? String)
    {
      return date
    }
    if
      let text = tiff?[kCGImagePropertyTIFFDateTime] as? String,
      let date = exifDate(text, offset: nil)
    {
      return date
    }
    return try? fileURL.resourceValues(forKeys: [.creationDateKey]).creationDate
  }

  /// Reads an EXIF or TIFF date such as "2020:11:02 13:35:24", in the zone
  /// of `offset` ("+09:00") or, without one, in the current zone.
  private static func exifDate(_ text: String, offset: String?) -> Date? {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = offset == nil ? "yyyy:MM:dd HH:mm:ss" : "yyyy:MM:dd HH:mm:ssxxx"
    return formatter.date(from: text + (offset ?? ""))
  }
}

private extension ImageEditor.Options {

  /// The demo presets in three groups: color looks, black and white, and
  /// the bundled LUTs.
  static var editorDemo: Self {
    let blackAndWhiteIDs: Set = ["brightroom.preset.mono", "brightroom.preset.noir"]
    let presets = DemoFilters.make()
    var options = Self()
    options.filterGroups = [
      FilterGroup(
        title: "C",
        name: "Color",
        color: .gray,
        filters: presets.filter { !blackAndWhiteIDs.contains($0.id) }
      ),
      FilterGroup(
        title: "BW",
        name: "Black & White",
        color: .white,
        filters: presets.filter { blackAndWhiteIDs.contains($0.id) }
      ),
      FilterGroup(title: "LUT", name: "Looks", color: .orange, filters: DemoLUTs.bundled),
    ]
    return options
  }
}
