# Menu bar icon wiring

The menu bar template lives at:

    Desktop/Sources/Resources/MenuBarIcon.imageset/

It is generated from `dmg-assets/logo/menubar-template.svg` by
`scripts/generate-icons.sh` and is registered as a **template image** so macOS
tints it automatically for light/dark mode and selected/highlighted states.

## Asset Catalog (already written by the script)

`MenuBarIcon.imageset/Contents.json`:

```json
{
  "images" : [
    { "idiom" : "mac", "scale" : "1x", "filename" : "MenuBarIcon.png"     },
    { "idiom" : "mac", "scale" : "2x", "filename" : "MenuBarIcon@2x.png"  },
    { "idiom" : "mac", "scale" : "3x", "filename" : "MenuBarIcon@3x.png"  }
  ],
  "info" : { "author" : "xcode", "version" : 1 },
  "properties" : { "template-rendering-intent" : "template" }
}
```

The imageset directory must be inside an `.xcassets` bundle that is part of the
target. If `Resources/` is not yet wrapped in an `.xcassets`, move the
imageset into `Desktop/Sources/Resources/Assets.xcassets/MenuBarIcon.imageset/`
(or whichever asset catalog the target already references in
`Package.swift` / Xcode build settings).

## Swift wiring (do NOT edit OmiApp.swift here — concurrent agent owns it)

In `OmiApp.swift`'s `setupMenuBar()` (around line 797, just after
`statusBarItem = NSStatusBar.system.statusItem(...)`), replace any existing
text-only / emoji button setup with:

```swift
if let img = NSImage(named: "MenuBarIcon") {
    img.isTemplate = true   // critical — lets macOS tint for light/dark
    statusBarItem.button?.image = img
    statusBarItem.button?.imagePosition = .imageLeading
}
```

`isTemplate = true` is the load-bearing line. Without it the icon will show
as solid black on dark menu bars and look broken.
