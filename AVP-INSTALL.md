# Installing MacroCube on Apple Vision Pro

MacroCube is a fork of [ClassiCube](https://github.com/ClassiCube/ClassiCube), the Minecraft Classic compatible client, for visionOS. It adds a Metal renderer, XR rendering through Compositor Services, and the SwiftUI app lifecycle. The launcher opens in a window; a world opens in a mixed immersive space, where the blocks are drawn at a reduced scale around you, your head is the camera, and you place blocks with your hands.

## What you need

- A Mac with Xcode and the visionOS SDK
- An Apple ID added to Xcode, so you have a development team to sign with
- Apple Vision Pro, paired with Xcode
- An internet connection the first time the app runs (see below)

## Your game files

You don't supply any. ClassiCube is a clean-room client, and this repository contains no Minecraft game files.

The first time the launcher runs, it downloads the assets it needs from minecraft.net and classicube.net. Choose **OK** when it asks.

## Build from source

There's no prebuilt app. From a checkout of this repository:

1. Open `misc/visionOS/CCVisionOS.xcodeproj` in Xcode.
2. Select the **CCVisionOS** target, go to **Signing & Capabilities → Team**, and choose your development team.
3. Choose your Apple Vision Pro as the run destination, then run (**Product → Run**) to build and install it.

The project builds the ClassiCube sources in `src/` directly, so there's nothing else to fetch. Its bundle identifier is `com.testing.CCVisionOS`; if Xcode reports that it isn't available to your team, change it to one of your own in the same tab.

## Notes

- Known issues, from the README:
  - The wrist menu isn't functional yet.
  - In multiplayer, placing blocks can get you kicked from a server, because the client doesn't yet call SetReach when it joins.
  - The loading bar during the asset download needs fixing.
  - Camera smoothing is still on in XR mode.
  - The 2D Metal renderer mode isn't enabled yet.
- To join classicube.net servers you need a [ClassiCube account](https://www.classicube.net/). LAN and locally hosted servers don't need one.
- ClassiCube is not affiliated with (or supported by) Mojang AB, Minecraft, or Microsoft.
