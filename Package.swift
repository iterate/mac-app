// swift-tools-version: 5.9
import PackageDescription

var products: [Product] = [
    .library(name: "VoiceMeetCore", targets: ["VoiceMeetCore"]),
]
var dependencies: [Package.Dependency] = []
var targets: [Target] = [
    .target(name: "VoiceMeetCore"),
    .testTarget(name: "VoiceMeetCoreTests", dependencies: ["VoiceMeetCore"]),
]

// The app needs AppKit, ScreenCaptureKit and AVFoundation, so only a Mac gets its target. On Linux
// the package is VoiceMeetCore and its tests.
#if os(macOS)
products.append(.executable(name: "VoiceMeetMac", targets: ["VoiceMeetMac"]))
targets.append(.executableTarget(name: "VoiceMeetMac", dependencies: ["VoiceMeetCore", "Record", "Live", "SpeechText"]))
// Speech: the microphone as text, on this Mac (README.md, "Dictation"). Everything that touches the
// speech model is here. The model is NVIDIA's Parakeet as Core ML, through FluidAudio, the library
// that the Swift app Hex used.
dependencies.append(.package(url: "https://github.com/FluidInference/FluidAudio", exact: "0.18.4"))
targets.append(.target(name: "SpeechText", dependencies: ["VoiceMeetCore", .product(name: "FluidAudio", package: "FluidAudio")]))
targets.append(.testTarget(name: "SpeechTextTests", dependencies: ["SpeechText", "VoiceMeetCore"]))
// `speech-bench` runs one model's recognizer on sound files, for `harness/speech-bench` (local only).
targets.append(.executableTarget(name: "speech-bench", dependencies: ["SpeechText", "VoiceMeetCore"]))
// The recorder: screens, cameras, microphones and speakers into 30-second files in a spool
// (README.md, "The record"). `record-run` drives it from a terminal, for tests.
targets.append(.target(name: "Record"))
targets.append(.executableTarget(name: "record-run", dependencies: ["Record"]))
targets.append(.testTarget(name: "RecordTests", dependencies: ["Record"]))
// Live: the Mac as a WebRTC peer, fed by the recorder's own capture (README.md, "Live"). Everything
// that touches WebRTC is here; the recorder does not import it. The library is LiveKit's build of
// WebRTC, its macOS slice, a release asset of this repository. `live-run` drives it from a
// terminal, for tests.
targets.append(.binaryTarget(
    name: "LiveKitWebRTC",
    url: "https://github.com/iterate/mac-app/releases/download/libwebrtc-150.7871.06/LiveKitWebRTC-macos-150.7871.06.xcframework.zip",
    checksum: "8d0c0c33a1f5db7600ef2c74033a7ce815056d444976e2519f4596a2a813252c"
))
targets.append(.target(name: "Live", dependencies: ["Record", "VoiceMeetCore", "LiveKitWebRTC"]))
targets.append(.executableTarget(name: "live-run", dependencies: ["Live", "Record", "VoiceMeetCore"]))
#endif

let package = Package(
    name: "voice-meet-mac",
    // macOS 14.0 is the first with SCContentSharingPicker and with the control of ducking.
    platforms: [.macOS(.v14)],
    products: products,
    dependencies: dependencies,
    targets: targets
)
