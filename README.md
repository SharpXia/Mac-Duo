<div align="center">

# Mac Duo X

**Wish you could bring the iPhone Duo effect to your MacBook?**

https://github.com/user-attachments/assets/3ea3b098-c6d2-4398-8f3a-e9087bbb33f2

Close the lid and watch your screen content tilt, blur, and fade as it moves.  
Mac Duo X adds this effect to your MacBook, with controls in the menu bar.

**Available in:** English and Simplified Chinese (简体中文).

<img src="./assets/menu.png" width="400" alt="Mac Duo X menu">

</div>

<hr>

With the default settings, it's recommended to view the effect in front of your MacBook.

- **Metal rendering:** Uses GPU rendering to apply perspective, blur, and dimming as the lid closes.
- **Live screen content:** Uses ScreenCaptureKit to capture and render screen content in real time.
- **Adjustable perspective:** Tweak the perspective to suit your viewing position and make the effect look more natural.
- **Every display:** The effect plays on connected external displays too — the picture stays flat and grows uniformly blurrier with the lid. Turn it off in the settings to keep it on the built-in display only.
- **Release when shut:** Once the lid has stayed fully closed, the blur and the cover lift again, so a closed clamshell or anything waiting on this Mac sees a clear screen.

> [!NOTE]
> Mac Duo X is an independent continuation of [Mac Duo](https://github.com/sumimakito/Mac-Duo) by [Makito](https://github.com/sumimakito), shared under the Apache License 2.0. All credit for the original idea and implementation goes there. If you enjoy the original, consider [sponsoring Makito](https://github.com/sponsors/sumimakito).
>
> This repository is developed and maintained separately; it is not affiliated with or endorsed by the original author.

## Download

Grab the latest signed build from the [Releases](https://github.com/SharpXia/Mac-Duo-X/releases) page — the DMG or the ZIP, both universal (Apple Silicon + Intel).

Requires macOS 14 or later and a MacBook with a compatible lid angle sensor.
Grant Screen Recording permission when prompted to enable the effect.

> [!IMPORTANT]
> These builds are signed with an Apple Development certificate and are not notarized. On first launch, macOS may block the app. Right-click the app and choose **Open**, or run `xattr -cr "/Applications/Mac Duo X.app"` to clear the quarantine flag.

## Build

Requires Xcode with Swift 6.0 or later. Run from the project directory:

```sh
./build.sh
```

The script creates `build/Mac Duo X.app` with an ad-hoc signature. Open it from Finder, or build and launch with:

```sh
./build.sh --run
```

To sign with your own identity, set `SIGN_IDENTITY`:

```sh
SIGN_IDENTITY="Apple Development: your name (TEAMID)" ./build.sh
```

macOS may require Screen Recording permission again after rebuilding with a different signing identity.

## Known limitations

- Only MacBooks with a compatible lid angle sensor can use the effect. The app reports when no sensor is available.
- The sensor must be one macOS marks as built-in. An external display with a similar sensor is ignored.
- External displays only grow uniformly blurrier with the lid; the leaning picture, gradient blur, and dimming stay on the built-in display.
- The effect stops when macOS sleeps as the lid closes.
- Clicks pass through the effect to the apps underneath.

## Acknowledgements

This project is built with AI assistance.

This repository continues development independently from [sumimakito/Mac-Duo](https://github.com/sumimakito/Mac-Duo) by [Makito](https://github.com/sumimakito) — all credit for the original idea and implementation goes there. Thanks for sharing it under Apache 2.0.

## License

Licensed under the [Apache License 2.0](LICENSE). The original Mac Duo is Copyright 2026 Makito; modifications and further development of Mac Duo X are Copyright 2026 Xinding Xia.

See [NOTICE](NOTICE) for attribution.
