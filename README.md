# PhotoRelay-Windows

PhotoRelay-Windows watches selected folders and uploads supported photos and videos to Google Photos using the bundled [`gotohp`](https://github.com/xob0t/gotohp) client. Windows is the primary setup; a separate shell runner is included for macOS and Linux.

> [!IMPORTANT]
> Windows keeps local files by default. If you select **Delete after upload** in the BAT menu, the watcher schedules local files for deletion 30 seconds after a confirmed upload, checking the size and SHA-256 hash before deletion. Keep another backup of important media.

## Features

- Watches only the folders configured for the current platform.
- Scans watched folders at startup, listens for new and renamed files, and periodically rescans to catch missed file-system events.
- Waits for a file to finish downloading or being written before uploading it.
- Tracks uploads and pending retries in a local SQLite database; compares content hashes to avoid duplicate uploads.
- Retries failed uploads and records recent activity for status and troubleshooting.
- On Windows, starts at sign-in through per-user Startup shortcuts and shows upload state in a tray icon, without a persistent console window.

## Requirements

### Windows

- Windows 10 or 11.
- The bundled `gotohp-cli-x64.exe`, `gotohp-x64.exe`, and `Modules/PSSQLite` files.
- A normal per-user account. Administrator rights are not required.

### macOS and Linux

- Bash, `curl`, and `sqlite3`.
- macOS: `fswatch` for real-time monitoring.
- Linux: `inotify-tools` for real-time monitoring.
- The shell runner's `setup` command can install or download its required components where supported. The pinned gotohp release provides Linux x86_64 and macOS universal binaries; other Linux architectures need a compatible `gotohp-cli` on `PATH`.

## Windows quick start

1. Clone the repository or extract its ZIP to a permanent folder writable by your Windows account. Do not run it from inside the ZIP. Keep the scripts, `Modules` folder, and bundled `gotohp` programs together.

   ```powershell
   git clone https://github.com/Muntakim23/PhotoRelay-Windows.git
   Set-Location PhotoRelay-Windows
   ```

2. Double-click `OneTime-Setup.bat`. It creates a watched-folder list for the signed-in Windows user's `%USERPROFILE%\Pictures` folder if one does not already exist. Existing folder selections are preserved.

3. If no Google account is connected, setup opens `gotohp-x64.exe`. Sign in there, wait for the account connection to finish, then close the window. Setup continues and starts the watcher and tray icon.

4. Check the tray icon. Windows may place it under the hidden-icons arrow. Use `FolderManager.bat` to add or remove watched folders; removing a folder from the list does not delete files in it.

5. To check status or logs, open PowerShell in the project folder and run:

   ```powershell
   .\PhotoRelay-Windows.bat status
   .\PhotoRelay-Windows.bat logs
   ```

The Windows setup is per user. Run it from the same Windows account that will sign in and use the watcher. If you move the project folder, run `OneTime-Setup.bat` again to refresh its Startup shortcuts.

In `PhotoRelay-Windows.bat`, choose **Local files after upload** to keep files (the default) or delete them after a successful upload. The selection is saved locally in `local-file-policy.txt`. A missing, unreadable or invalid setting keeps files. A running watcher from an older version must be restarted for this setting to take effect; deletion jobs already started by that older version do not read the new setting.

## Authentication and account setup

PhotoRelay-Windows uses [`gotohp`](https://github.com/xob0t/gotohp)'s Google Embedded Setup flow. It authenticates as an Android Google Photos client so gotohp can use the mobile upload endpoint for Pixel-style uploads.

### Why does the setup page keep loading?

After opening [`https://accounts.google.com/embedded/setup/v2/android`](https://accounts.google.com/embedded/setup/v2/android), sign in and click **I agree**. The page can keep spinning because it expects an Android device to acknowledge the connection. This is expected; the `oauth_token` cookie should already be available after the agreement step.

### Find the `oauth_token` cookie

1. Open Developer Tools with **F12**, or right-click the page and choose **Inspect**.
2. Open the cookie storage view:
   - **Chrome, Edge, Brave, Opera:** **Application** → **Storage** → **Cookies** → `https://accounts.google.com`.
   - **Firefox:** **Storage** → **Cookies** → `https://accounts.google.com`.
   - **Safari:** **Storage** → **Cookies** → `accounts.google.com`.
3. Find the cookie named `oauth_token` and copy its full value.

In the Windows `gotohp-x64.exe` window, choose **Add Google account**, complete the embedded sign-in, paste the cookie value into gotohp, and click **Connect account**. Close the window after the account appears as connected; setup will continue.

### Credential storage and safety

- gotohp can use its normal per-user config or a portable `gotohp.config` beside the app. To use the portable file, create an empty `gotohp.config` in the project folder before signing in. PhotoRelay uses that file when it exists.
- `.gitignore` excludes `gotohp.config`. Keep it private; never commit or share it. The shell runner applies `chmod 600` to the file when it exists.
- On macOS and Linux, add credentials with `./PhotoRelay-Windows.sh creds add`. The interactive prompt hides typed input and passes it to gotohp over standard input, avoiding command history and process-list exposure.
- Do not paste the token into a command, screenshot, issue, chat, or other shared file.

### Manage multiple accounts

On Windows, run these from PowerShell in the project folder:

```powershell
.\gotohp-cli-x64.exe --config .\gotohp.config creds list
.\gotohp-cli-x64.exe --config .\gotohp.config creds set user@gmail.com
.\gotohp-cli-x64.exe --config .\gotohp.config creds remove user@gmail.com
```

On macOS or Linux, use the shell runner:

```bash
./PhotoRelay-Windows.sh creds list
./PhotoRelay-Windows.sh creds set user@gmail.com
./PhotoRelay-Windows.sh creds remove user@gmail.com
```

The active account is marked with `*` in the account list. The Windows batch menu does not include account-management options; use the bundled CLI commands above.

## macOS and Linux quick start

1. Clone or extract the repository into a permanent folder and open a terminal there.
2. Run setup:

   ```bash
   chmod +x PhotoRelay-Windows.sh
   ./PhotoRelay-Windows.sh setup
   ```

3. Follow the authentication steps above. To keep a portable config in the project folder, create an empty `gotohp.config` before signing in.
4. Start a foreground watcher with `./PhotoRelay-Windows.sh watch`, or enable its user login service with `./PhotoRelay-Windows.sh enable`.

The shell runner uses `launchd` on macOS and a `systemd` user service on Linux. Its default folder discovery differs from the Windows `%USERPROFILE%\Pictures` default.

## Commands

### Windows

Run the included `PhotoRelay-Windows.bat` control menu, or call it as `.\PhotoRelay-Windows.bat` from PowerShell. (In Command Prompt, omit the `.\`.)

| Command | Action |
| --- | --- |
| `.\PhotoRelay-Windows.bat watch` | Start the watcher in the current console. |
| `.\PhotoRelay-Windows.bat silent` | Start the watcher hidden in the background. |
| `.\PhotoRelay-Windows.bat status` | Show upload and retry status. |
| `.\PhotoRelay-Windows.bat logs` | Show recent activity. |
| `.\PhotoRelay-Windows.bat enable` | Enable start at Windows sign-in. |
| `.\PhotoRelay-Windows.bat disable` | Disable this install's Startup shortcut. |
| `.\PhotoRelay-Windows.bat stop` | Stop the running watcher. |

### macOS and Linux

Use `./PhotoRelay-Windows.sh help` to see all available commands.

| Command | Action |
| --- | --- |
| `./PhotoRelay-Windows.sh setup` | Install supported dependencies and prepare the client. |
| `./PhotoRelay-Windows.sh watch` | Start a foreground watcher. |
| `./PhotoRelay-Windows.sh status` | Show upload and retry status. |
| `./PhotoRelay-Windows.sh logs` | Show recent activity. |
| `./PhotoRelay-Windows.sh enable` / `disable` | Enable or disable login startup. |
| `./PhotoRelay-Windows.sh stop` | Stop the background watcher. |
| `./PhotoRelay-Windows.sh verify` | Verify the bundled or downloaded client binary. |

## Watched folders and supported files

On Windows, the first setup uses only the current user's `Pictures` folder. The selected paths are stored in `watch-folders.txt`, one folder per line. Use `FolderManager.bat` to edit this list, then restart the watcher to apply changes. Setup does not automatically add Downloads, Desktop, Documents, or Music.

The Windows watcher currently accepts these extensions (case-insensitive):

- Images: `.jpg`, `.jpeg`, `.png`, `.heic`, `.webp`, `.gif`, `.dng`
- Videos: `.mp4`, `.mov`, `.mkv`, `.avi`

Files that are still growing or locked by another program stay queued until they are ready or disappear. The Windows watcher retries failed uploads up to three times and performs a safety scan every two minutes.

## Background startup

On Windows, `OneTime-Setup.bat` creates per-user Startup shortcuts. `StartPhotosWatcher.vbs` launches the PowerShell watcher hidden, and `PhotosTray.ps1` runs separately to display status. The shortcuts point back to this folder so the scripts can find their bundled dependencies. No Windows service or machine-wide startup entry is installed.

On macOS and Linux, `PhotoRelay-Windows.sh enable` configures a user login service. Use the corresponding `disable` command to remove it.

## Local data and account privacy

Each person must connect their own Google account. Credentials and runtime state are created locally after setup and are not included in the repository. The `.gitignore` excludes the credential config, WebView profile/cache, SQLite database, watched-folder list, tray status, and logs. Never commit or share these files.

Authentication is handled by the bundled `gotohp` application or its supported CLI flow. The setup section explains how to retrieve the required cookie; treat it as a password and never publish or share it.

## Troubleshooting

- **No uploads:** check that setup has created `watch-folders.txt` and that it lists the folder; in PowerShell use `.\PhotoRelay-Windows.bat status` and `.\PhotoRelay-Windows.bat logs` (omit `.\` in Command Prompt).
- **No tray icon:** check Windows' hidden-icons arrow. Start `PhotosTray.ps1` from PowerShell to see diagnostic errors.
- **Startup stopped after moving the folder:** run `OneTime-Setup.bat` again from the new location.
- **A file is not uploaded yet:** wait for the download or export to finish; unsupported extensions are skipped.
- **A file disappeared after upload:** check the local files setting in `PhotoRelay-Windows.bat`. Delete mode schedules cleanup after 30 seconds.

## Limitations

- PhotoRelay-Windows is an independent project and is not affiliated with or endorsed by Google.
- Upload behavior depends on the third-party `gotohp` client and Google service behavior. No storage quota, upload quality, or continued availability is guaranteed.
- Cloud-only placeholders must be downloaded locally before the watcher can read them.
- Keep independent backups of important media, especially when local-file deletion is enabled.

## Credits

- Upload and sign-in client: [`gotohp`](https://github.com/xob0t/gotohp), by [xob0t](https://github.com/xob0t).
- Windows SQLite integration: [`PSSQLite`](https://github.com/RamblingCookieMonster/PSSQLite), by RamblingCookieMonster.
