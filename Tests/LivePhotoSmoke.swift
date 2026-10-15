import AVFoundation
import Foundation

@main
enum LivePhotoSmoke {
    static func main() async throws {
        guard CommandLine.arguments.count == 3 else {
            fatalError("Expected source MOV and output directory")
        }
        let source = URL(fileURLWithPath: CommandLine.arguments[1])
        let directory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let duration = try await LivePhotoService.videoDuration(at: source)
        FileHandle.standardError.write(Data("Source duration: \(duration)\n".utf8))
        guard duration >= 5.9 else { fatalError("Source duration is incorrect") }

        let clip = LivePhotoClip(start: 1.0, end: 3.5, cover: 2.0)
        FileHandle.standardError.write(Data("Generating first pair\n".utf8))
        guard let first = try await LivePhotoService.generate(
            from: source, clip: clip, destination: .folder(directory)) else {
            fatalError("Missing exported pair")
        }
        guard FileManager.default.fileExists(atPath: first.imageURL.path),
              FileManager.default.fileExists(atPath: first.videoURL.path) else {
            fatalError("Exported pair is missing")
        }
        let video = AVURLAsset(url: first.videoURL)
        FileHandle.standardError.write(Data("Checking output audio\n".utf8))
        let audioTracks = try await video.loadTracks(withMediaType: .audio)
        guard !audioTracks.isEmpty else { fatalError("Audio was lost") }

        FileHandle.standardError.write(Data("Generating second pair\n".utf8))
        guard let second = try await LivePhotoService.generate(
            from: source, clip: clip, destination: .folder(directory)) else {
            fatalError("Missing second pair")
        }
        guard first != second else { fatalError("Repeated export overwrote the first pair") }
        let edgeClip = LivePhotoClip.centered(on: duration, videoDuration: duration)
        guard edgeClip.cover < edgeClip.end,
              let edge = try await LivePhotoService.generate(
                from: source, clip: edgeClip, destination: .folder(directory)),
              FileManager.default.fileExists(atPath: edge.videoURL.path) else {
            fatalError("End-of-video cover failed")
        }
        print("Live Photo smoke passed: \(first.imageURL.lastPathComponent), \(second.imageURL.lastPathComponent)")
    }
}
