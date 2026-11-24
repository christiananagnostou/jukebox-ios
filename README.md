# Jukebox for iOS

Jukebox is a native iPhone and iPad music player for stock Jellyfin servers in the 12.1 and 12.2 release families. Browse albums, artists, songs and playlists, search your music library, and control playback from the app or the Lock Screen.

## Build and run

1. On a Mac with Xcode and the iOS 27 SDK, run `python3 -B -m tools.prepare` from the repository root to generate the bundled demo media. Regenerating any missing encoded test audio requires FFmpeg.
2. Open `Jukebox.xcodeproj` and select the **Jukebox** scheme. For a physical device, select your development team and a bundle identifier you can sign.
3. Run the app. Enter your Jellyfin server’s HTTPS address, including any base path, and tap the arrow beside it or press **Continue** on the keyboard. You can also choose **Try invented music** to explore the demo.

To see your saved server address and username, open **Accounts → Connection details**. On the Connect screen, tap the information button beside a saved account. Viewing these details works offline.

For your first device, choose **Use username and password** and enter your Jellyfin credentials. Jukebox takes you directly to the password screen when the server has sign-in codes turned off.

If you’re already signed in elsewhere, choose **Show a sign-in code** on the new device. On a signed-in Jellyfin browser, open **Settings → Quick Connect**. In a signed-in Jukebox app, open **Accounts → Approve another device**. Enter the code there and tap the approval button. The new device signs in to the account shown.

Keep personal server addresses, signing settings and library data local. Use invented accounts and media in contributions and tests.

## Playlists

Jukebox uses your signed-in account’s playlist permissions. It can create private playlists, edit songs and their order, change covers, and manage sharing on playlists you own. A shared editor can make the changes Jellyfin permits.

To copy a playlist, open **Playlist actions (…) → Make an editable copy**, choose a name, and tap **Create copy**. This also works for read-only imports when all songs belong to the selected Music library. Jukebox creates a separate private playlist, checks its editing access, and compares every song position and repeat with the original. If Jellyfin can’t confirm the result, check the new playlist before making another copy.

## Checks

Run `swift test --jobs 1` for the Core tests and `python3 -B -m tools.add_source --check` for Xcode source membership. The JukeboxUITests target exercises the native interface with invented music.
