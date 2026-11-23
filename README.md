# Jukebox for iOS

Jukebox is a native iPhone and iPad music player for stock Jellyfin servers in the 12.1 and 12.2 release families. Browse albums, artists, songs and playlists, search your music library, and control playback from the app or the Lock Screen.

## Build and run

1. On a Mac with Xcode and the iOS 27 SDK, run `python3 -B -m tools.prepare` from the repository root to generate the bundled demo media. Regenerating any missing encoded test audio requires FFmpeg.
2. Open `Jukebox.xcodeproj` and select the **Jukebox** scheme. For a physical device, select your development team and a bundle identifier you can sign.
3. Run the app. Enter your server’s HTTPS address, including when using Tailscale, and select a Music library, or choose **Try invented music** to explore the demo.

To see your saved server address and username, open **Accounts → Connection details**. On the Connect screen, tap the information button beside a saved account. Viewing these details works offline.

Keep personal server addresses, signing settings and library data local. Use invented accounts and media in contributions and tests.

## Playlists

Jukebox uses your signed-in account’s playlist permissions. It can create private playlists, edit songs and their order, change covers, and manage sharing on playlists you own. A shared editor can make the changes Jellyfin permits. A playlist imported from an M3U file may have no Jellyfin owner. In Jellyfin Web, open the playlist’s menu, choose **Add to playlist**, then **New**, to create a playlist owned by your account. The copy has a new ID.

## Checks

Run `swift test --jobs 1` for the Core tests and `python3 -B -m tools.add_source --check` for Xcode source membership. The JukeboxUITests target exercises the native interface with invented music.
