#!/bin/bash
set -e

# Generate a simple OpenTypeNo icon using SF Symbols
# Create a temporary Swift script to generate the icon

cat > /tmp/generate_opentypeno_icon.swift << 'EOF'
import AppKit
import CoreGraphics

let size: CGFloat = 1024
// macOS icon grid: ~80% of canvas for the icon body, with ~10% padding on each side
let padding: CGFloat = size * 0.1
let iconSize: CGFloat = size - padding * 2
// macOS superellipse corner radius ≈ 22.37% of icon body size
let cornerRadius: CGFloat = iconSize * 0.2237

let image = NSImage(size: NSSize(width: size, height: size))

image.lockFocus()

// Rounded rect path (macOS icon shape)
let iconRect = NSRect(x: padding, y: padding, width: iconSize, height: iconSize)
let path = NSBezierPath(roundedRect: iconRect, xRadius: cornerRadius, yRadius: cornerRadius)
path.addClip()

// Background gradient (same brand colors)
let gradient = NSGradient(colors: [
    NSColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1.0),
    NSColor(red: 0.1, green: 0.3, blue: 0.7, alpha: 1.0)
])
gradient?.draw(in: iconRect, angle: 135)

// Draw "⌃" text centered in the icon body
let text = "⌃"
let font = NSFont.systemFont(ofSize: iconSize * 0.5, weight: .light)
let attrs: [NSAttributedString.Key: Any] = [
    .font: font,
    .foregroundColor: NSColor.white
]
let textSize = text.size(withAttributes: attrs)
let textRect = NSRect(
    x: padding + (iconSize - textSize.width) / 2,
    y: padding + (iconSize - textSize.height) / 2,
    width: textSize.width,
    height: textSize.height
)
text.draw(in: textRect, withAttributes: attrs)

image.unlockFocus()

// Save as PNG
if let tiffData = image.tiffRepresentation,
   let bitmap = NSBitmapImageRep(data: tiffData),
   let pngData = bitmap.representation(using: .png, properties: [:]) {
    try? pngData.write(to: URL(fileURLWithPath: "/tmp/opentypeno_icon_1024.png"))
}
EOF

swift /tmp/generate_opentypeno_icon.swift

# Generate iconset
cd App/OpenTypeNo.iconset

sips -z 16 16 /tmp/opentypeno_icon_1024.png --out icon_16x16.png
sips -z 32 32 /tmp/opentypeno_icon_1024.png --out icon_16x16@2x.png
sips -z 32 32 /tmp/opentypeno_icon_1024.png --out icon_32x32.png
sips -z 64 64 /tmp/opentypeno_icon_1024.png --out icon_32x32@2x.png
sips -z 128 128 /tmp/opentypeno_icon_1024.png --out icon_128x128.png
sips -z 256 256 /tmp/opentypeno_icon_1024.png --out icon_128x128@2x.png
sips -z 256 256 /tmp/opentypeno_icon_1024.png --out icon_256x256.png
sips -z 512 512 /tmp/opentypeno_icon_1024.png --out icon_256x256@2x.png
sips -z 512 512 /tmp/opentypeno_icon_1024.png --out icon_512x512.png
sips -z 1024 1024 /tmp/opentypeno_icon_1024.png --out icon_512x512@2x.png

cd ../..
iconutil -c icns App/OpenTypeNo.iconset -o App/OpenTypeNo.icns

echo "Icon generated at App/OpenTypeNo.icns"
