import AppKit

// Package the approved Landing Signal artwork without re-drawing or re-sampling
// it at build time. PNGs were rendered directly from the editable SVG at each size.
// Normal builds need only the macOS SDK and iconutil, not an SVG renderer.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let assets = root.appendingPathComponent("Assets/AppIcon/png")
let destination = CommandLine.arguments.dropFirst().first.map { URL(fileURLWithPath: $0, isDirectory: true) }
    ?? root.appendingPathComponent("build")
let output = destination.appendingPathComponent("Icon.iconset")
let manager = FileManager.default
try manager.createDirectory(at: destination, withIntermediateDirectories: true)
if manager.fileExists(atPath: output.path) { try manager.removeItem(at: output) }
try manager.createDirectory(at: output, withIntermediateDirectories: true)

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let source = assets.appendingPathComponent("\(pixels).png")
        let data = try Data(contentsOf: source)
        guard let bitmap = NSBitmapImageRep(data: data), bitmap.pixelsWide == pixels,
              bitmap.pixelsHigh == pixels, bitmap.hasAlpha else {
            fatalError("Invalid icon artwork: \(source.path); expected \(pixels)×\(pixels) with alpha")
        }
        let suffix = scale == 2 ? "@2x" : ""
        try data.write(to: output.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
    }
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", output.path, "-o", destination.appendingPathComponent("Icon.icns").path]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else { fatalError("iconutil failed") }
