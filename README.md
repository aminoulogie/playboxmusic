# Playbox Music

iOS music app: iTunes catalog browsing, Soulseek search and downloads, a local library, and a DJ-style mixing player with lyrics.

## Build

The Xcode project is generated with [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```sh
brew install xcodegen
xcodegen generate --spec project.yml
open PlayboxMusic.xcodeproj
```

On GitHub, the **Build Playbox Music IPA** workflow builds an unsigned IPA on every push to `main` and publishes it as a release (`music-v<version>` plus a rolling `music-current`). An unsigned IPA must be signed with a valid Apple certificate before it installs on a device.
