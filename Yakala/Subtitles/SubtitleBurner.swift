import Foundation
import AVFoundation
import UIKit

/// Altyazıları videonun görüntüsüne kalıcı olarak işler
enum SubtitleBurner {
    struct Style {
        var fontScale: CGFloat = 1.0
        var boxed: Bool = true
    }

    static func burn(video: URL,
                     cues: [SubtitleCue],
                     style: Style,
                     output: URL,
                     progress: @escaping (Double) -> Void) async throws -> URL {
        let asset = AVURLAsset(url: video)
        let duration = try await asset.load(.duration)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw MediaExportError.failed("Bu dosyada görüntü bulunamadı.")
        }
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let naturalSize = try await videoTrack.load(.naturalSize)
        let preferredTransform = try await videoTrack.load(.preferredTransform)
        let nominalFrameRate = try await videoTrack.load(.nominalFrameRate)

        let composition = AVMutableComposition()
        let fullRange = CMTimeRange(start: .zero, duration: duration)

        guard let compositionVideo = composition.addMutableTrack(withMediaType: .video,
                                                                 preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw MediaExportError.failed("Video hazırlanamadı.")
        }
        try compositionVideo.insertTimeRange(fullRange, of: videoTrack, at: .zero)

        if let audioTrack = audioTracks.first,
           let compositionAudio = composition.addMutableTrack(withMediaType: .audio,
                                                              preferredTrackID: kCMPersistentTrackID_Invalid) {
            try compositionAudio.insertTimeRange(fullRange, of: audioTrack, at: .zero)
        }

        // Dikey çekilmiş videoların yönünü koru
        let transformedRect = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        let renderSize = CGSize(width: abs(transformedRect.width).rounded(),
                                height: abs(transformedRect.height).rounded())
        let fixedTransform = preferredTransform.concatenating(
            CGAffineTransform(translationX: -transformedRect.origin.x, y: -transformedRect.origin.y)
        )

        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compositionVideo)
        layerInstruction.setTransform(fixedTransform, at: .zero)

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = fullRange
        instruction.layerInstructions = [layerInstruction]

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        let fps = nominalFrameRate > 1 ? nominalFrameRate : 30
        videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, fps.rounded())))
        videoComposition.instructions = [instruction]

        let parentLayer = CALayer()
        parentLayer.frame = CGRect(origin: .zero, size: renderSize)
        let videoLayer = CALayer()
        videoLayer.frame = parentLayer.frame
        parentLayer.addSublayer(videoLayer)
        parentLayer.addSublayer(subtitleLayer(cues: cues, renderSize: renderSize, style: style))

        videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: videoLayer,
                                                                             in: parentLayer)

        return try await MediaExporter.export(asset: composition,
                                              preset: AVAssetExportPresetHighestQuality,
                                              to: output,
                                              fileType: .mp4,
                                              videoComposition: videoComposition,
                                              progress: progress)
    }

    /// Her altyazı için yalnızca kendi süresinde görünen bir katman oluşturur.
    /// Not: Bu katmanlarda başlangıç noktası sol alttır.
    static func subtitleLayer(cues: [SubtitleCue], renderSize: CGSize, style: Style) -> CALayer {
        let container = CALayer()
        container.frame = CGRect(origin: .zero, size: renderSize)

        let base = min(renderSize.width, renderSize.height)
        let fontSize = max(14, base * 0.05 * style.fontScale)
        let font = UIFont.systemFont(ofSize: fontSize, weight: .semibold)
        let maxTextWidth = renderSize.width * 0.86
        let bottomMargin = renderSize.height * 0.06
        let horizontalPadding = fontSize * 0.45
        let verticalPadding = fontSize * 0.2

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping

        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.white,
            .paragraphStyle: paragraph
        ]
        if !style.boxed {
            attributes[.strokeColor] = UIColor.black
            attributes[.strokeWidth] = -3.0
        }

        for cue in cues {
            let text = SubtitleFormatter.wrap(cue.text)
            let attributed = NSAttributedString(string: text, attributes: attributes)
            let bounds = attributed.boundingRect(with: CGSize(width: maxTextWidth, height: .greatestFiniteMagnitude),
                                                 options: [.usesLineFragmentOrigin, .usesFontLeading],
                                                 context: nil)
            let textSize = CGSize(width: ceil(bounds.width) + 2, height: ceil(bounds.height) + fontSize * 0.1)
            let boxSize = CGSize(width: textSize.width + horizontalPadding * 2,
                                 height: textSize.height + verticalPadding * 2)

            let box = CALayer()
            box.frame = CGRect(x: ((renderSize.width - boxSize.width) / 2).rounded(),
                               y: bottomMargin.rounded(),
                               width: boxSize.width.rounded(),
                               height: boxSize.height.rounded())
            box.backgroundColor = style.boxed ? UIColor.black.withAlphaComponent(0.55).cgColor : UIColor.clear.cgColor
            box.cornerRadius = fontSize * 0.25

            let textLayer = CATextLayer()
            textLayer.string = attributed
            textLayer.isWrapped = true
            textLayer.alignmentMode = .center
            textLayer.contentsScale = 2
            textLayer.frame = CGRect(x: horizontalPadding, y: verticalPadding,
                                     width: textSize.width, height: textSize.height)
            if !style.boxed {
                textLayer.shadowColor = UIColor.black.cgColor
                textLayer.shadowOpacity = 0.9
                textLayer.shadowRadius = fontSize * 0.12
                textLayer.shadowOffset = .zero
            }
            box.addSublayer(textLayer)

            // Varsayılan olarak gizli; yalnızca altyazının süresi boyunca görünür
            box.opacity = 0
            let visibility = CABasicAnimation(keyPath: "opacity")
            visibility.fromValue = 1
            visibility.toValue = 1
            visibility.beginTime = AVCoreAnimationBeginTimeAtZero + max(cue.start, 0)
            visibility.duration = max(cue.end - cue.start, 0.1)
            visibility.isRemovedOnCompletion = false
            visibility.fillMode = .removed
            box.add(visibility, forKey: "visible")

            container.addSublayer(box)
        }
        return container
    }
}
