import AVFoundation
import AVKit
import BrightroomEngine
import BrightroomParametric
import CoreGraphics
import CoreImage
import SwiftUI

struct ParametricVideoRenderPlaygroundView: View {

  @State private var player: AVPlayer?
  @State private var asset: AVURLAsset?
  @State private var isPreparingVideo = false
  @State private var isPlaying = true
  @State private var errorMessage: String?

  @State private var renderSizeMode: ParametricVideoPlaygroundRenderSizeMode = .source
  @State private var isCropEnabled = true
  @State private var cropInset: Double = 28
  @State private var brightness: Double = 0.04
  @State private var saturation: Double = 0.12
  @State private var blurRadius: Double = 0

  var body: some View {
    VStack(spacing: 0) {
      Form {
        Section("Playback") {
          Picker("Render Size", selection: $renderSizeMode) {
            ForEach(ParametricVideoPlaygroundRenderSizeMode.allCases) { mode in
              Text(mode.title).tag(mode)
            }
          }
          .pickerStyle(.segmented)

          Button(isPlaying ? "Pause" : "Play") {
            togglePlayback()
          }
        }

        Section("Crop") {
          Toggle("Enabled", isOn: $isCropEnabled)
          Slider(value: $cropInset, in: 0...88, step: 1) {
            Text("Inset")
          }
        }

        Section("Effects") {
          Slider(value: $brightness, in: -0.25...0.25, step: 0.01) {
            Text("Brightness")
          }
          Slider(value: $saturation, in: -0.75...0.75, step: 0.01) {
            Text("Saturation")
          }
          Slider(value: $blurRadius, in: 0...18, step: 1) {
            Text("Blur")
          }
        }

        if let errorMessage {
          Section("Error") {
            Text(errorMessage)
              .font(.caption.monospaced())
          }
        }
      }
      .frame(maxHeight: 430)

      playerSurface
    }
    .navigationTitle("Parametric Video")
    .task {
      await prepareVideoIfNeeded()
    }
    .onChange(of: settings) { _, _ in
      applyVideoComposition()
    }
    .onDisappear {
      player?.pause()
    }
    .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { notification in
      guard let item = player?.currentItem,
            notification.object as? AVPlayerItem === item
      else {
        return
      }

      item.seek(to: .zero) { _ in
        if isPlaying {
          player?.play()
        }
      }
    }
  }

  @ViewBuilder
  private var playerSurface: some View {
    ZStack {
      Color.black

      if let player {
        VideoPlayer(player: player)
      } else if isPreparingVideo {
        ProgressView()
          .tint(.white)
      } else if let errorMessage {
        Text(errorMessage)
          .font(.caption.monospaced())
          .foregroundStyle(.white)
          .padding()
      }
    }
    .aspectRatio(Self.videoSize.width / Self.videoSize.height, contentMode: .fit)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.black)
  }

  private var settings: ParametricVideoPlaygroundSettings {
    ParametricVideoPlaygroundSettings(
      renderSizeMode: renderSizeMode,
      isCropEnabled: isCropEnabled,
      cropInset: cropInset,
      brightness: brightness,
      saturation: saturation,
      blurRadius: blurRadius
    )
  }

  @MainActor
  private func prepareVideoIfNeeded() async {
    guard asset == nil else {
      return
    }

    isPreparingVideo = true
    defer {
      isPreparingVideo = false
    }

    do {
      let url = try await Task.detached(priority: .userInitiated) {
        try Self.makeDemoVideoURL()
      }
      .value
      let asset = AVURLAsset(url: url)
      let item = AVPlayerItem(asset: asset)
      let player = AVPlayer(playerItem: item)

      self.asset = asset
      self.player = player
      applyVideoComposition()
      player.play()
    } catch {
      errorMessage = String(describing: error)
    }
  }

  @MainActor
  private func applyVideoComposition() {
    guard let asset,
          let item = player?.currentItem
    else {
      return
    }

    do {
      item.videoComposition = try ParametricVideoRenderer().makeVideoComposition(
        for: asset,
        document: makeFeatureDocument(),
        renderSizeMode: renderSizeMode.rendererMode
      )
      errorMessage = nil
    } catch {
      errorMessage = String(describing: error)
    }
  }

  private func togglePlayback() {
    guard let player else {
      return
    }

    isPlaying.toggle()

    if isPlaying {
      player.play()
    } else {
      player.pause()
    }
  }

  private func makeFeatureDocument() throws -> EditingDocument {
    var features: [MainFeature] = []

    if isCropEnabled {
      features.append(
        .domain(
          CropFeature(
            id: Self.cropID,
            cropRect: cropRect
          )
        )
      )
    }

    if abs(brightness) > 0.001 {
      features.append(
        .effect(
          BrightnessFeature(
            id: Self.brightnessID,
            value: brightness
          )
        )
      )
    }

    if abs(saturation) > 0.001 {
      features.append(
        .effect(
          SaturationFeature(
            id: Self.saturationID,
            value: saturation
          )
        )
      )
    }

    if blurRadius > 0.1 {
      features.append(
        .effect(
          GaussianBlurFeature(
            id: Self.blurID,
            radius: blurRadius
          )
        )
      )
    }

    return EditingDocument(
      mainTree: MainTree(features: features)
    )
  }

  private var cropRect: CGRect {
    let inset = CGFloat(cropInset)
    return CGRect(
      x: inset,
      y: inset * 0.5,
      width: max(Self.videoSize.width - inset * 2, 1),
      height: max(Self.videoSize.height - inset, 1)
    )
  }

  nonisolated private static func makeDemoVideoURL() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("brightroom-parametric-video-\(UUID().uuidString)")
      .appendingPathExtension("mov")
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(
      mediaType: .video,
      outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: Int(videoSize.width),
        AVVideoHeightKey: Int(videoSize.height),
      ]
    )
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
      assetWriterInput: input,
      sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: Int(videoSize.width),
        kCVPixelBufferHeightKey as String: Int(videoSize.height),
        kCVPixelBufferIOSurfacePropertiesKey as String: [:],
      ]
    )
    let context = CIContext()
    let colorSpace = CGColorSpaceCreateDeviceRGB()

    guard writer.canAdd(input) else {
      throw ParametricVideoPlaygroundError.cannotAddInput
    }

    writer.add(input)

    guard writer.startWriting() else {
      throw writer.error ?? ParametricVideoPlaygroundError.cannotStartWriting
    }

    writer.startSession(atSourceTime: .zero)

    for frameIndex in 0..<90 {
      while !input.isReadyForMoreMediaData {
        Thread.sleep(forTimeInterval: 0.005)
      }

      let pixelBuffer = try makePixelBuffer()
      let frameImage = makeFrameImage(frameIndex: frameIndex)
      context.render(
        frameImage,
        to: pixelBuffer,
        bounds: CGRect(origin: .zero, size: videoSize),
        colorSpace: colorSpace
      )

      guard adaptor.append(
        pixelBuffer,
        withPresentationTime: CMTime(value: CMTimeValue(frameIndex), timescale: 30)
      ) else {
        throw writer.error ?? ParametricVideoPlaygroundError.cannotAppendFrame
      }
    }

    input.markAsFinished()

    let semaphore = DispatchSemaphore(value: 0)
    writer.finishWriting {
      semaphore.signal()
    }
    semaphore.wait()

    guard writer.status == .completed else {
      throw writer.error ?? ParametricVideoPlaygroundError.cannotFinishWriting(writer.status)
    }

    return url
  }

  nonisolated private static func makePixelBuffer() throws -> CVPixelBuffer {
    var pixelBuffer: CVPixelBuffer?
    let result = CVPixelBufferCreate(
      kCFAllocatorDefault,
      Int(videoSize.width),
      Int(videoSize.height),
      kCVPixelFormatType_32BGRA,
      [
        kCVPixelBufferIOSurfacePropertiesKey as String: [:],
      ] as CFDictionary,
      &pixelBuffer
    )

    guard result == kCVReturnSuccess, let pixelBuffer else {
      throw ParametricVideoPlaygroundError.cannotCreatePixelBuffer(result)
    }

    return pixelBuffer
  }

  nonisolated private static func makeFrameImage(frameIndex: Int) -> CIImage {
    let extent = CGRect(origin: .zero, size: videoSize)
    let progress = CGFloat(frameIndex) / 90
    let checker = CIFilter(
      name: "CICheckerboardGenerator",
      parameters: [
        "inputCenter": CIVector(x: 0, y: 0),
        "inputColor0": CIColor(red: 0.08, green: 0.12, blue: 0.17, alpha: 1),
        "inputColor1": CIColor(red: 0.32, green: 0.38, blue: 0.31, alpha: 1),
        "inputWidth": 36,
        "inputSharpness": 0.78,
      ]
    )!
    .outputImage!
    .cropped(to: extent)
    let bandX = progress * (videoSize.width + 96) - 48
    let warmBand = CIImage(color: CIColor(red: 0.95, green: 0.36, blue: 0.16, alpha: 0.82))
      .cropped(to: CGRect(x: bandX, y: 0, width: 48, height: videoSize.height))
      .composited(over: checker)
    let coolBand = CIImage(color: CIColor(red: 0.05, green: 0.46, blue: 0.9, alpha: 0.78))
      .cropped(to: CGRect(x: videoSize.width - bandX - 52, y: 0, width: 52, height: videoSize.height))
      .composited(over: warmBand)
    let glow = CIFilter(
      name: "CIRadialGradient",
      parameters: [
        "inputCenter": CIVector(
          x: 72 + cos(progress * .pi * 2) * 42,
          y: 96 + sin(progress * .pi * 2) * 34
        ),
        "inputRadius0": 8,
        "inputRadius1": 74,
        "inputColor0": CIColor(red: 1, green: 0.94, blue: 0.68, alpha: 0.95),
        "inputColor1": CIColor(red: 1, green: 0.94, blue: 0.68, alpha: 0),
      ]
    )!
    .outputImage!
    .cropped(to: extent)

    return glow
      .composited(over: coolBand)
      .cropped(to: extent)
  }

  nonisolated private static let videoSize = CGSize(width: 320, height: 200)
  nonisolated private static let cropID = FeatureID(rawValue: "video-playground-crop")
  nonisolated private static let brightnessID = FeatureID(rawValue: "video-playground-brightness")
  nonisolated private static let saturationID = FeatureID(rawValue: "video-playground-saturation")
  nonisolated private static let blurID = FeatureID(rawValue: "video-playground-blur")
}

private struct ParametricVideoPlaygroundSettings: Equatable {
  var renderSizeMode: ParametricVideoPlaygroundRenderSizeMode
  var isCropEnabled: Bool
  var cropInset: Double
  var brightness: Double
  var saturation: Double
  var blurRadius: Double
}

private enum ParametricVideoPlaygroundRenderSizeMode: String, CaseIterable, Identifiable {
  case source
  case featureOutput

  var id: Self { self }

  var title: String {
    switch self {
    case .source:
      "Source"
    case .featureOutput:
      "Feature"
    }
  }

  var rendererMode: ParametricVideoRenderer.RenderSizeMode {
    switch self {
    case .source:
      .source
    case .featureOutput:
      .featureOutput
    }
  }
}

private enum ParametricVideoPlaygroundError: Error {
  case cannotAddInput
  case cannotStartWriting
  case cannotAppendFrame
  case cannotFinishWriting(AVAssetWriter.Status)
  case cannotCreatePixelBuffer(CVReturn)
}
