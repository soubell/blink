# Building
We provide you with two ways to compile and install Blink Shell. This instructions will refer to assembling
a full Blink Shell, compiling libraries and resources yourself. Due to the many dependencies that compose
Blink Shell, this is the recommended but not shortest method.

You can also clone Blink and obtain a "ready to go"
tar.gz with all the dependencies as described in the ["Build" section of the README.md file](README.md#build).

## Requirements
Please note that to compile and install Blink in your personal
devices, you need to comply with Apple Developer Terms and Conditions,
including obtaining a Developer License for that purpose. You will also
need all the XCode command line developer tools and SDKs provided under
a separate license by Apple Inc.
- XCode > 11.0 and XCode command line tools
- Autotools for OSX

## Cloning
Clone Blink into your local repository and make sure to obtain any submodules:
git submodule init
git submodule update

## Dependencies & Requirements
Blink makes use of multiple dependencies that you have to compile
separately before building Blink itself. There are simple scripts available
to perform this operation.
- [Libssh2 for iOS](https://github.com/holzschu/libssh2-for-iOS); Includes OpenSSL.
- [Mosh for iOS](https://github.com/blinksh/build-mosh); Includes Protobuf.

Please note that Blink currently only supports armv64, so compilation for other architectures is not necessary.

### Installation
#### Libraries
The Blink Shell XCode project will look for Library dependencies under the Framework folder. Libssh2 and Mosh for iOS will
also build OpenSSL and Protobuf respectively, both required to work.

To install Libssh2 and OpenSSL in your Blink repository, please copy
the .framework files generated on [Libssh2 for iOS](https://github.com/carloscabanero/libssh2-for-iOS) to the Framework folders.

[Mosh for iOS](https://github.com/blinksh/build-mosh) will compile both protobuf and Mosh for iOS.
After compiling, copy libmoshios.framework AND libprotobuf.a from the build-protobuf/protobuf-version/lib folder.

Blink also makes use of two other projects, which should be automatically downloaded using git submodule
within the same project:
- UICKeyChainStore
- MBProgressHUD

#### Resources
Blink Shell makes use of a web terminal running from JavaScript code and linked at runtime. All the required
resources to bundle the app, like terminal, fonts and themes, must be included under the Resources folder.

Font Style uploads requires [webfonts.js](https://github.com/typekit/webfontloader), but it isn't
needed for Blink to work. Download the file and drop it into Resources folder.

Blink's Terminal is running from JavaScript code linked at runtime.
Most of the available open source terminals can be made to work with Blink,
just by providing a "write" and "signal" functions. An example of this
is provided in the Resources/term.html file. If you use another
terminal.js, edit term.html to match. We have been also successful plugging in other
terminals like [Terminal.js](http://terminal.js.org).

## Compiling
Blink uses a standard .xcodeproj file. Any missing files will be marked in
red, what can be used to test your installation.

To configure the project:
1. Under Targets > Blink > General > Identities set a unique Bundle Identifier.
2. Under Targets > Blink > General > Identities set your Team.
3. You might be requested to accept your profile or setup your developer account
with XCode, follow the proper Apple Developer documentation in that case.
4. If you would like to use HockeyApp, change the scheme to Blink Hockey, and add HockeyID with your AppID string to info.plist.

Make sure "Blink" is the selected Scheme for compilation. As a standard XCode project, just run it with Cmd-R.

## GitHub Actions: unsigned IPA

[`.github/workflows/build.yml`](.github/workflows/build.yml) builds Blink on
GitHub Actions and produces an unsigned IPA. No Apple developer account,
certificate, provisioning profile or secret is required, so it also works on
forks and on pull requests from forks.

It runs on:

- `push` to `raw` or `arena/**`
- `pull_request`
- manually from the Actions tab (**Run workflow**), where you can pick the
  build configuration (`Release` by default), the Xcode version and whether the
  unit tests should run. The IPA artifact is uploaded for every trigger.

The workflow follows the [Build section of the README](README.md#build):

1. checks out the repository together with its submodules,
2. fetches the prebuilt binary frameworks (`get_frameworks.sh`) and the vim
   runtime (`get_resources.sh`), with caching and retries,
3. removes `Blink.xcodeproj/project.xcworkspace/xcshareddata/` and creates
   `developer_setup.xcconfig` from `template_setup.xcconfig`,
4. resolves the Swift packages and builds the `Blink` scheme for
   `generic/platform=iOS` (arm64) with `CODE_SIGNING_ALLOWED=NO`,
5. packs `Payload/Blink.app` into `Blink-<version>-<build>-unsigned.ipa` and
   uploads it as the `Blink-unsigned-ipa` artifact.

The IPA is **not signed** and cannot be installed on a device as-is. Re-sign it
with your own certificate and provisioning profile first, for example with
Sideloadly, AltStore, Xcode, or your own `codesign` pipeline.

### Capabilities (README step 3a)

The App Store build declares capabilities that a personal or free team cannot
sign: Push Notifications, iCloud, Keychain sharing, Associated Domains and the
`group.sh.blink` App Group. Re-signing with such a team silently drops those
entitlements.

To match that situation, the workflow builds with
[`Blink/Blink-sideload.entitlements`](Blink/Blink-sideload.entitlements) (the
`entitlements` input defaults to `sideload`). Compared to
`Blink/Blink.entitlements` it drops:

| Entitlement | Capability |
|---|---|
| `aps-environment` | Push Notifications |
| `com.apple.developer.icloud-container-identifiers` | iCloud / CloudKit |
| `com.apple.developer.icloud-services` | iCloud / CloudKit |
| `com.apple.developer.ubiquity-container-identifiers` | iCloud Documents |
| `com.apple.developer.ubiquity-kvstore-identifier` | iCloud key-value store |
| `com.apple.developer.associated-domains` | Passkeys (`webcredentials:blink.sh`) |
| `com.apple.security.application-groups` | App Group (`group.sh.blink`), see above |
| `keychain-access-groups` | Keychain sharing |

The remaining ten entitlements (data protection, user fonts, web browser,
sandbox, Bluetooth, camera, user-selected files, network client/server,
location) do not require special approval.

The file is uploaded next to the IPA so it can be used for re-signing:

```bash
codesign -f -s "Apple Development: you@example.com" \
    --entitlements Blink-sideload.entitlements \
    Payload/Blink.app
```

Choose `entitlements: default` in the workflow to build with the App Store
entitlements (`Blink/Blink.entitlements`) instead, for example when you own the
capabilities and sign with the proper team.

### Sideloading a self-built IPA

A re-signed build (Sideloadly, AltStore, a personal team, ...) usually does not
carry the `com.apple.security.application-groups` entitlement, because
`group.sh.blink` belongs to Blink's developer team and cannot be registered by
another team. In that case iOS does not provide the shared App Group container.

Blink falls back to the app's own container (`Library/Application Support/Blink`)
when the App Group is unavailable, so the app still starts and keeps its data
locally. A message is logged at launch:

```
[BlinkPaths] App Group group.sh.blink is not available. Falling back to the app container.
```

Features that rely on sharing files between the app and its extensions (File
Provider, for example) will not work in that mode. To get them back, build with
your own `GROUP_ID` in `developer_setup.xcconfig`, register that App Group for
your team in the Apple Developer portal, and sign with a profile that includes
it.
