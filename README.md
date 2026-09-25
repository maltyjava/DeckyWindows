# DeckyWindows

Reproducible install of [Decky Loader](https://github.com/SteamDeckHomebrew/decky-loader) on a
Windows handheld (built for an **MSI Claw 8 EX AI+**), driven remotely over SSH.

Upstream builds Windows binaries in CI but never attaches them to releases, so the only
distribution route is building from source. The community wrapper
[`Draek2077/decky-loader-windows`](https://github.com/Draek2077/decky-loader-windows) does that,
but its prebuilt installer is pinned to an old version and two of its scripts break on a
non-domain machine. This repo automates the whole path and patches around both bugs.

## Usage

### Download `install_decky.exe` from [Releases](../../releases) — start here

One file, one run, any Windows machine. It prompts for UAC, asks where to install, fetches
Decky and sets everything up.

```
install_decky.exe                                  # prompts for location (default C:\Decky)
install_decky.exe -Path D:\Decky                   # non-interactive location
install_decky.exe -Path D:\Decky -Ref v3.2.9 -Yes  # fully unattended, pinned version
install_decky.exe -ForceBuild                      # ignore prebuilts, build from source
```

It prefers the **prebuilt `PluginLoader.exe`** published alongside it and falls back to
**building from source** (installing Python 3.11, Node and Git via winget) when no prebuilt
matches the newest upstream release. Prebuilt takes under a minute; a source build takes
10–20 minutes.

**Re-run it to update.** That is not a convenience — see below.

### Decky cannot update itself on Windows

`backend/decky_loader/updater.py` looks for a release asset named exactly `PluginLoader.exe`:

```python
download_filename = "PluginLoader" if ON_LINUX else "PluginLoader.exe"
for x in self.remoteVer["assets"]:
    if x["name"] == download_filename: ...
if download_url == None:
    raise Exception("Download url not found")
```

Upstream only ever publishes the Linux `PluginLoader`, so on Windows that lookup finds
nothing and throws. The source repo is hardcoded to `SteamDeckHomebrew/decky-loader`, so it
cannot be redirected at this repo's releases either. **The in-app updater will always
silently fail on Windows.** Running the installer again is the update path.

### Install location

Decky's own override is honoured rather than worked around
(`localplatform/localplatformwin.py`):

```python
path = os.getenv("UNPRIVILEGED_PATH")
if path == None:
    path = os.getenv("PRIVILEGED_PATH", os.path.join(os.path.expanduser("~"), "homebrew"))
```

The installer sets `UNPRIVILEGED_PATH` machine-wide to your chosen path, so nothing is
created in your home directory. On Windows privileged and unprivileged paths are the same,
so that one variable covers everything.

### Remotely over SSH

```bash
./deploy-remote.sh            # toolchain + build + install + verify
./deploy-remote.sh verify     # health check only
./deploy-remote.sh traceback  # startup traceback when :1337 will not bind
./deploy-remote.sh restart    # restart Decky (not Steam)
```

### Directly, in an elevated PowerShell

```powershell
.\bootstrap.ps1               # latest upstream stable
.\bootstrap.ps1 -Ref v3.2.6   # a specific tag
.\verify.ps1
```

`bootstrap.ps1` is idempotent — safe to re-run to recover after a Steam update breaks Decky.

> **Exit codes are not a reliable success signal.** git and PyInstaller write to stderr, which
> surfaces as a non-zero exit even on a clean build. Trust the verifier output and the installed
> state, not the return code.

## Why it is built this way

Five things cost real time to diagnose. They are all handled in `bootstrap.ps1`; this is the
record of *why* the code looks like it does.

### 1. Build with Python 3.11, never 3.13

`backend/pyproject.toml` allows `>=3.10,<3.14`, but that range is misleading. `watchdog` is
pinned `^4` (4.0.1), which predates Python 3.13's rework of `threading.Thread.start()`.
Built on 3.13 the loader compiles fine, then dies instantly with **no log files written**:

```
File "watchdog\observers\api.py", line 280, in start
File "threading.py", line 976, in start
TypeError: 'handle' must be a _ThreadHandle
```

The symptom is confusing because the build succeeds and processes appear to run — port 1337
just never binds. Upstream CI pins **3.11.7** (`.github/workflows/build-win.yml`); match it.

### 2. The Microsoft Store Python is unusable over SSH

`%LOCALAPPDATA%\Microsoft\WindowsApps\python.exe` is a 0-byte app-execution alias. Every
invocation from an elevated SSH session returns `Access is denied`, because Store apps need an
interactive user token. `py.exe` fails the same way — it resolves to the Store registration.

Install real interpreters with `winget --scope machine` and call them by full path. The build
venv is pre-seeded with the real 3.11 so upstream's `build.ps1` never invokes bare `python`.

### 3. `$env:USERDOMAIN` is `WORKGROUP` over SSH

Not the machine name. `Register-DeckyTask` in the wrapper's `lib\common.ps1` builds its principal
as `"$env:USERDOMAIN\$env:USERNAME"`, which on a non-domain machine is `WORKGROUP\youruser` —
an account with no SID:

```
Register-ScheduledTask : No mapping between account names and security IDs was done.
```

Patched to fall back to `$env:COMPUTERNAME` and bind the principal by resolved SID. This breaks
on *every* non-domain machine, which is essentially every handheld.

### 4. `update.ps1` splats an array, so arguments bind positionally

```powershell
$installArgs = @('-Ref', $Ref, '-NoBuild')
& install.ps1 @installArgs        # -> $Ref receives the literal string "-Ref"
```

PowerShell array splatting passes elements **positionally**; only hashtable splatting binds by
name. The observed failure is `A positional parameter cannot be found that accepts argument
'v3.2.6'`. Patched to a hashtable. Since `update.ps1` is the documented recovery path when a
Steam update breaks Decky, this bug makes recovery fail exactly when it is needed.

### 5. Do not pipe PowerShell scripts over SSH stdin

`ssh claw "powershell -Command -" < script.ps1` truncates silently mid-run: native commands
inside the script inherit stdin and drain the rest of the script. `scp` the file and run it with
`-File`, stdin redirected from `/dev/null`. `deploy-remote.sh` does this.

## Pinning a plugin against store updates

`pin-plugin.ps1` stops Decky offering an update over a locally patched plugin, without
renaming it:

```powershell
.\pin-plugin.ps1 -Plugin decky-steamgriddb          # pin
.\pin-plugin.ps1 -Plugin decky-steamgriddb -Unpin   # restore
```

Decky decides an update exists in `frontend/src/store.tsx`:

```js
compare(remotePlugin?.versions?.[0]?.name, curVer, '>')
```

a strict semver "greater than" against the version read from the plugin's **`package.json`**
(`backend/decky_loader/plugin/plugin.py`: `self.version = package_json["version"]`) — note
*not* `plugin.json`, which carries the display name but no version. Writing a version above
anything the store will publish makes that comparison permanently false: no update offered,
no nag, name unchanged. The original version is recorded in `.decky-pin.json` next to it so
the pin is reversible.

**Deliberately not done with file permissions.** Decky's install path uninstalls the plugin
*before* extracting the replacement, so a denied write mid-install can leave the plugin
deleted rather than protected. The version pin fails safe; an ACL does not.

A pin blocks *updates*, not a deliberate manual reinstall from the store. Decky must be
restarted to re-read the version, and the Steam UI reloaded before the frontend's cached
plugin list reflects it.

## Operational notes

- **Multiple `PluginLoader_noconsole` processes are normal, not orphans.** The count is
  `2 + 1 per installed plugin` (PyInstaller bootloader and child, plus one worker per plugin) —
  measured at 2 with no plugins, 5 with three, 6 with four. Exactly one owns `:1337`.
- **An unauthenticated `GET http://127.0.0.1:1337` returning 403 is healthy** — the backend is
  auth-gated. 403 means it is up.
- **A Steam restart does not restart Decky.** Restart Decky, not Steam:
  ```
  .\restart-decky.ps1
  ```
- **`schtasks /end` does not actually stop Decky.** It reports SUCCESS but leaves the loader's
  child processes alive, so the follow-up `/run` cannot take over and the *old* instance keeps
  running — silently serving stale plugin metadata. Observed with the task reporting
  `LastRunTime 15:46` while the live loader process had started at `13:36`, which made a
  correctly-applied plugin version pin look like it had failed. Always use
  `restart-decky.ps1`: it kills the tree, refuses to start a second instance if anything
  survived, and prints the new process start time so the restart is provable.
- **CSS Loader blinking, or a blank theme-install button, is a zombie CEF page — not a crash.**
  Steam's UI sometimes leaves an orphaned page in its target list (typically a duplicate `Menu`)
  that is still advertised on `:8080` but has no live execution context. CSS Loader injects into
  every target, hits that one, burns its full 5s `Runtime.evaluate` timeout, and retries forever —
  measured at a steady 10–15 failures per minute, indefinitely. Each cycle disrupts the CSS
  transaction, which is what makes themes blink out and return. Decky never actually restarts.

  Healthy targets answer `1+1` in 2–4 ms; the zombie never answers at all. Detect and clear it
  with `.\fix-css-loader.ps1` (add `-Repair` to restart Steam).

  Two dead ends worth not repeating: `/json/close/<id>` returns `200 Target is closing` and the
  page **stays**, because it is too wedged to process its own close; and `steam://restartgameui`
  does clear it but returns to desktop mode, after which — with AnyFSE managing the session —
  Steam may exit entirely. A full restart into Big Picture is the reliable repair.
- **Plugin support is partial on Windows.** Working: CSS Loader, Audio Loader, SteamGridDB,
  TabMaster, ProtonDB Badges, PlayTime, PlayCount, Web Browser, IsThereAnyDeal. Anything touching
  TDP, fan curves, or power management will not work — use MSI Center M or Handheld Companion.

## Verifying injection

`verify.ps1` proves the frontend actually loaded by evaluating JS in Steam's `SharedJSContext`
over the CEF debugging protocol. A healthy result:

```json
{"deckyGlobals":["deckyHasLoaded","deckyAuthToken","DeckyBackend","DeckyPluginLoader"],
 "loaderPresent":true,"pluginCount":3}
```

Checking only that the process is alive is not sufficient — the 3.13 build ran and served
nothing.
