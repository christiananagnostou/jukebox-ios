# Jukebox for iOS

Jukebox is a native iPhone and iPad music player for stock Jellyfin servers in the 12.1, 12.2 and 12.4 release families. Browse albums, artists, songs and playlists, search your music library, and control playback from the app or the Lock Screen.

## Build and run

1. On a Mac with Xcode and the iOS 27 SDK, run `python3 -B -m tools.prepare` from the repository root to generate the bundled demo media. Regenerating any missing encoded test audio requires FFmpeg.
2. Open `Jukebox.xcodeproj` and select the **Jukebox** scheme. For a physical device, select your development team and a bundle identifier you can sign.
3. Run the app. Enter your Jellyfin server’s HTTPS address, including any base path, and tap the arrow beside it or press **Continue** on the keyboard. You can also choose **Try invented music** to explore the demo.

Open **Accounts → Connection details** for the current username, server address, Jellyfin version when available, and selected Music library. Each saved account shows its server address. Tap a saved account to inspect it, then choose **Switch to this account** or **Remove from this iPhone** (or iPad). Removal clears that connection’s saved sign-in, queue and preferences on this device. The Jellyfin user and server library stay intact. On the Connect screen, the information button opens these details offline.

For your first device, choose **Use username and password** and enter your Jellyfin credentials. Jukebox takes you directly to the password screen when the server has sign-in codes turned off.

If you’re already signed in elsewhere, choose **Show a sign-in code** on the new device. On a signed-in Jellyfin browser, open **Settings → Quick Connect**. In a signed-in Jukebox app, open **Accounts → Quick Connect**. Enter the code there and tap the approval button. The new device signs in to the account shown.

Keep personal server addresses, signing settings and library data local. Use invented accounts and media in contributions and tests.

## Playlists

Jukebox uses your signed-in account’s playlist permissions. It can create private playlists, edit songs and their order, change covers, and manage sharing on playlists you own. A shared editor can make the changes Jellyfin permits.

To copy a playlist, open **Playlist actions (…) → Make an editable copy**, choose a name, and tap **Create copy**. Jukebox can copy read-only playlists when Jellyfin lists their songs in the selected Music library. It creates a separate private playlist, checks its editing access, and compares every song position and repeat with the original. If Jellyfin can’t confirm the result, check the new playlist before making another copy.

On Jellyfin 12.4.0, check that an imported M3U shows the expected tracks in Jellyfin before copying it. In compatibility testing, Jellyfin returned zero tracks for an M3U containing three entries. The server also returned HTTP 500 when adding an individual playlist collaborator. [12.4 test results](https://github.com/christiananagnostou/jukebox-ios/pull/3)

## Checks

GitHub Actions runs the Core suite on macOS for pull requests and pushes to `main`. Run `swift test --jobs 1` locally and `python3 -B -m tools.add_source --check` to check Xcode source membership. The JukeboxUITests target exercises the native interface with invented music.

To repeat the Jellyfin 12.4 compatibility check on a Mac, unpack the stock server and Jellyfin FFmpeg and pass their executable paths to the test. [Jellyfin 12.4 release](https://github.com/jellyfin/jellyfin/releases/tag/v12.4)

```sh
swift build --build-system native --build-tests --jobs 1 -Xswiftc -DSTOCK_JELLYFIN_TEST --scratch-path .build/stock
python3 -B -m tools.stock_test --scratch-path .build/stock \
  --jellyfin /path/to/jellyfin --ffmpeg /path/to/ffmpeg
```

The check starts a temporary loopback server, signs in with a password and Quick Connect, plays the same FLAC in Original and High through AVPlayer, and verifies a private playlist copy with a repeated song. It removes the fixture server and accounts when it finishes.
