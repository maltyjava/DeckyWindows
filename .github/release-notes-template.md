Decky Loader **{{REF}}** ({{CHANNEL}}) built for Windows.

Upstream publishes only the Linux `PluginLoader` binary, so these Windows builds do not
exist anywhere else — and that is also why Decky's in-app updater does nothing on Windows
(`updater.py` looks for an asset named exactly `PluginLoader.exe`).

### Install

Download **install_decky.exe** and run it. It offers an install location, fetches these
prebuilt binaries, registers autostart and enables Steam's CEF debugging flag.

```
install_decky.exe                 # newest stable
install_decky.exe -Prerelease     # newest prerelease
install_decky.exe -Path D:\Decky  # choose where it goes
```

Re-run the installer to update — it is the only update path on Windows.

### Which channel?

Use **stable** unless a Steam client update has broken something. When Steam changes its
internal UI, the fix usually lands in a prerelease first — that is what this channel is for,
and it is the same reason prereleases matter on the Steam Deck.

### Files

| file | purpose |
|---|---|
| `install_decky.exe` | the installer — this is the one you want |
| `PluginLoader.exe` | Decky backend, console build (for diagnostics) |
| `PluginLoader_noconsole.exe` | Decky backend, what autostart runs |

Built from `SteamDeckHomebrew/decky-loader` at `{{REF}}` with Python 3.11.7 / Node 20,
matching upstream's own `build-win.yml`.
