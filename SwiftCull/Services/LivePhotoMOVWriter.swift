import AVFoundation

private final class MediaBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

enum LivePhotoMOVWriter {
    static func write(asset: AVURLAsset, clip: LivePhotoClip,
                      identifier: String, to outputURL: URL) async throws {
        let composition = try await makeComposition(asset: asset, clip: clip)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)

        let identifierItem = AVMutableMetadataItem()
        identifierItem.keySpace = .quickTimeMetadata
        identifierItem.key = "com.apple.quicktime.content.identifier" as NSString
        identifierItem.value = identifier as NSString
        identifierItem.dataType = kCMMetadataBaseDataType_UTF8 as String
        writer.metadata = [identifierItem]

        guard let videoTrack = try await composition.loadTracks(withMediaType: .video).first else {
            throw LivePhotoError.invalidVideo
        }
        let size = try await videoTrack.load(.naturalSize)
        let width = Int(size.width.rounded(.up)) + Int(size.width.rounded(.up)) % 2
        let height = Int(size.height.rounded(.up)) + Int(size.height.rounded(.up)) % 2
        guard width > 0, height > 0 else { throw LivePhotoError.invalidVideo }
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: min(max(width * height * 5, 2_000_000), 20_000_000),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]
        guard writer.canApply(outputSettings: videoSettings, forMediaType: .video) else {
            throw LivePhotoError.videoExport("H.264 编码不可用")
        }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.transform = try await videoTrack.load(.preferredTransform)
        guard writer.canAdd(videoInput) else { throw LivePhotoError.videoExport("无法写入视频轨道") }
        writer.add(videoInput)

        let audioTrack = try await composition.loadTracks(withMediaType: .audio).first
        var audioInput: AVAssetWriterInput?
        var audioOutput: AVAssetReaderTrackOutput?

        let reader = try AVAssetReader(asset: composition)
        let videoOutput = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else { throw LivePhotoError.videoExport("无法读取视频轨道") }
        reader.add(videoOutput)

        if let audioTrack {
            let settings = try await audioSettings(for: audioTrack)
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings.writer)
            let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: settings.reader)
            output.alwaysCopiesSampleData = false
            guard writer.canAdd(input), reader.canAdd(output) else {
                throw LivePhotoError.videoExport("无法处理音频轨道")
            }
            writer.add(input)
            reader.add(output)
            audioInput = input
            audioOutput = output
        }

        let metadataInput = try makeStillImageMetadataInput()
        guard writer.canAdd(metadataInput) else {
            throw LivePhotoError.videoExport("无法写入封面时间轨道")
        }
        writer.add(metadataInput)
        let metadataAdaptor = AVAssetWriterInputMetadataAdaptor(assetWriterInput: metadataInput)

        guard writer.startWriting() else {
            throw LivePhotoError.videoExport(writer.error?.localizedDescription ?? "写入器启动失败")
        }
        writer.startSession(atSourceTime: .zero)
        guard appendStillImageTime(clip.coverOffset, to: metadataAdaptor) else {
            writer.cancelWriting()
            throw LivePhotoError.videoExport("封面时间写入失败")
        }
        metadataInput.markAsFinished()

        guard reader.startReading() else {
            writer.cancelWriting()
            throw LivePhotoError.videoExport(reader.error?.localizedDescription ?? "读取器启动失败")
        }
        let cancellableReader = MediaBox(reader)
        do {
            try await withTaskCancellationHandler {
                async let video: Void = appendSamples(from: videoOutput, to: videoInput,
                                                       reader: reader, writer: writer,
                                                       queueName: "swiftcull.livephoto.video")
                if let audioInput, let audioOutput {
                    async let audio: Void = appendSamples(from: audioOutput, to: audioInput,
                                                           reader: reader, writer: writer,
                                                           queueName: "swiftcull.livephoto.audio")
                    _ = try await (video, audio)
                } else {
                    try await video
                }
            } onCancel: {
                cancellableReader.value.cancelReading()
            }
        } catch {
            reader.cancelReading()
            writer.cancelWriting()
            throw error
        }
        try Task.checkCancellation()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw LivePhotoError.videoExport(writer.error?.localizedDescription ?? "写入未完成")
        }
    }

    private static func makeComposition(asset: AVURLAsset,
                                        clip: LivePhotoClip) async throws -> AVMutableComposition {
        guard let sourceVideo = try await asset.loadTracks(withMediaType: .video).first else {
            throw LivePhotoError.invalidVideo
        }
        let requested = CMTimeRange(
            start: CMTime(seconds: clip.start, preferredTimescale: 600),
            duration: CMTime(seconds: clip.duration, preferredTimescale: 600))
        let available = try await sourceVideo.load(.timeRange)
        let videoRange = CMTimeRangeGetIntersection(requested, otherRange: available)
        guard videoRange.isValid, !videoRange.isEmpty else { throw LivePhotoError.invalidRange }

        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw LivePhotoError.videoExport("无法创建视频轨道")
        }
        try videoTrack.insertTimeRange(videoRange, of: sourceVideo, at: .zero)
        videoTrack.preferredTransform = try await sourceVideo.load(.preferredTransform)

        if let sourceAudio = try await asset.loadTracks(withMediaType: .audio).first {
            let availableAudio = try await sourceAudio.load(.timeRange)
            let audioRange = CMTimeRangeGetIntersection(videoRange, otherRange: availableAudio)
            if audioRange.isValid, !audioRange.isEmpty {
                guard let audioTrack = composition.addMutableTrack(
                    withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                    throw LivePhotoError.videoExport("无法创建音频轨道")
                }
                try audioTrack.insertTimeRange(audioRange, of: sourceAudio,
                                               at: CMTimeSubtract(audioRange.start, videoRange.start))
            }
        }
        return composition
    }

    private static func audioSettings(for track: AVAssetTrack) async throws ->
        (reader: [String: Any], writer: [String: Any]) {
        let descriptions = try await track.load(.formatDescriptions)
        guard let description = descriptions.first,
              let format = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee else {
            throw LivePhotoError.videoExport("无法读取音频格式")
        }
        let sampleRate = min(max(format.mSampleRate, 8_000), 96_000)
        let channels = min(max(Int(format.mChannelsPerFrame), 1), 2)
        return (
            reader: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channels,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ],
            writer: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channels,
                AVEncoderBitRateKey: channels == 1 ? 96_000 : 160_000
            ]
        )
    }

    private static func makeStillImageMetadataInput() throws -> AVAssetWriterInput {
        let specification: [String: Any] = [
            kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as String:
                "mdta/com.apple.quicktime.still-image-time",
            kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as String:
                kCMMetadataBaseDataType_SInt8
        ]
        var description: CMFormatDescription?
        let status = CMMetadataFormatDescriptionCreateWithMetadataSpecifications(
            allocator: kCFAllocatorDefault,
            metadataType: kCMMetadataFormatType_Boxed,
            metadataSpecifications: [specification] as CFArray,
            formatDescriptionOut: &description)
        guard status == noErr, let description else {
            throw LivePhotoError.videoExport("无法创建封面时间格式")
        }
        return AVAssetWriterInput(mediaType: .metadata, outputSettings: nil,
                                  sourceFormatHint: description)
    }

    private static func appendStillImageTime(_ offset: Double,
                                             to adaptor: AVAssetWriterInputMetadataAdaptor) -> Bool {
        let item = AVMutableMetadataItem()
        item.key = "com.apple.quicktime.still-image-time" as NSString
        item.keySpace = .quickTimeMetadata
        item.value = 0 as NSNumber
        item.dataType = kCMMetadataBaseDataType_SInt8 as String
        let group = AVTimedMetadataGroup(
            items: [item],
            timeRange: CMTimeRange(start: CMTime(seconds: offset, preferredTimescale: 600),
                                   duration: CMTime(value: 1, timescale: 30)))
        return adaptor.append(group)
    }

    private static func appendSamples(from output: AVAssetReaderOutput,
                                      to input: AVAssetWriterInput,
                                      reader: AVAssetReader,
                                      writer: AVAssetWriter,
                                      queueName: String) async throws {
        let output = MediaBox(output)
        let input = MediaBox(input)
        let reader = MediaBox(reader)
        let writer = MediaBox(writer)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            input.value.requestMediaDataWhenReady(on: DispatchQueue(label: queueName)) {
                while input.value.isReadyForMoreMediaData {
                    if let sample = output.value.copyNextSampleBuffer() {
                        guard input.value.append(sample) else {
                            input.value.markAsFinished()
                            continuation.resume(throwing: LivePhotoError.videoExport(
                                writer.value.error?.localizedDescription ?? "媒体数据写入失败"))
                            return
                        }
                    } else {
                        input.value.markAsFinished()
                        if reader.value.status == .failed {
                            continuation.resume(throwing: LivePhotoError.videoExport(
                                reader.value.error?.localizedDescription ?? "媒体数据读取失败"))
                        } else if reader.value.status == .cancelled {
                            continuation.resume(throwing: CancellationError())
                        } else {
                            continuation.resume()
                        }
                        return
                    }
                }
            }
        }
    }
}
