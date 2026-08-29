# DeckyWindows

Reproducible install of [Decky Loader](https://github.com/SteamDeckHomebrew/decky-loader) on a
Windows handheld (built for an **MSI Claw 8 EX AI+**), driven remotely over SSH.

Upstream builds Windows binaries in CI but never attaches them to releases, so the only
distribution route is building from source. The community wrapper
[`Draek2077/decky-loader-windows`](https://github.com/Draek2077/decky-loader-windows) does that,
but its prebuilt installer is pinned to an old version and two of its scripts break on a
non-domain machine. This repo automates the whole path and patches around both bugs.

## Usage

### On the handheld: double-click `installer.bat`

Copy this whole folder to the handheld and double-click **`installer.bat`**. It asks for
administrator rights via UAC, installs the toolchain, builds Decky, installs it, and runs the
verifier. Expect 10–20 minutes on a first run.

`installer.bat` must stay next to `bootstrap.ps1` and `verify.ps1` — it runs the local copies
rather than downloading them, since this repo is private.

To pin a version, drag a tag onto the file or run `installer.bat v3.2.6` from a prompt.

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
as `"$env:USERDOMAIN\$env:USERNAME"`, which on a non-domain machine is `WORKGROUP\youruser` — an
account with no SID:

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

## Operational notes

- **5 `PluginLoader_noconsole` processes from one task start is normal** (PyInstaller bootloader
  plus multiprocessing workers), not orphans. Exactly one owns `:1337`.
- **An unauthenticated `GET http://127.0.0.1:1337` returning 403 is healthy** — the backend is
  auth-gated. 403 means it is up.
- **A Steam restart does not restart Decky.** CSS Loader (`SDH-CssLoader`) then holds stale CEF
  tab IDs and spins forever on `Runtime.evaluate took more than 5s / Failed to connect to tab`
  every 5s, which destabilises Steam. Restart Decky, not Steam:
  ```
  schtasks /end /tn "Decky Loader" & schtasks /run /tn "Decky Loader"
  ```
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
