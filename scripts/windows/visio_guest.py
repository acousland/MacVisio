"""Run one PowerShell script against the Visio reference guest's signed-in desktop session.

Used by the reference probes. Inputs are copied into an isolated guest work directory, the script
runs through a one-off interactive scheduled task (Visio automation hangs in the SSH session) with
the product-key prompt closer alongside it, and everything the script writes to its output
directory is copied back.
"""
from __future__ import annotations

import base64
import datetime as dt
import re
import subprocess
import time
import uuid
from pathlib import Path

WINDOWS_DIR = Path(__file__).resolve().parent
PROMPT_PS = WINDOWS_DIR / "Close-VisioKeyPrompt.ps1"
TASK = "MacVisioReferenceProbe"


def _encoded(script: str) -> str:
    return base64.b64encode(script.encode("utf-16le")).decode("ascii")


def _quote(value: str) -> str:
    return "'" + str(value).replace("'", "''") + "'"


def _run(command: list[str], timeout: int) -> subprocess.CompletedProcess[str]:
    return subprocess.run(command, text=True, capture_output=True, timeout=timeout, check=False)


def run(script: Path, inputs: list[Path], output: Path, *, arguments: dict[str, str] | None = None,
        instance: str = "mondrian-win", user: str = "mondrian", timeout: int = 1800) -> int:
    """Run `script` in the guest desktop session and copy its output directory to `output`.

    The script receives -InputDirectory and -OutputDirectory plus `arguments` (values may refer to
    inputs by file name; they are passed as guest paths when they match an input). Returns the
    script's exit code.
    """
    shell = ["limactl", "shell", instance, "powershell.exe", "-NoLogo", "-NoProfile", "-NonInteractive", "-EncodedCommand"]
    root = r"C:\Users\%s\AppData\Local\Temp\MacVisio-Probe-%s-%s" % (
        user, dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ"), uuid.uuid4().hex[:8])
    folders = {name: root + "\\" + name for name in ("input", "scripts", "output")}
    made = _run(shell + [_encoded("New-Item -ItemType Directory -Force -Path " + ",".join(map(_quote, folders.values())) + " | Out-Null")], 60)
    if made.returncode:
        raise RuntimeError("Could not create the guest work directory: " + (made.stderr or made.stdout).strip())
    for sources, folder in (([str(p) for p in inputs], folders["input"]), ([str(script), str(PROMPT_PS)], folders["scripts"])):
        if sources:
            copied = _run(["limactl", "copy", "--backend=scp", *sources, f"{instance}:{folder.replace(chr(92), '/')}/"], 600)
            if copied.returncode:
                raise RuntimeError("Guest copy failed: " + (copied.stderr or copied.stdout).strip())
    names = {p.name for p in inputs}
    call = f"& {_quote(folders['scripts'] + chr(92) + script.name)} -InputDirectory {_quote(folders['input'])} -OutputDirectory {_quote(folders['output'])}"
    for key, value in (arguments or {}).items():
        if not re.fullmatch(r"[A-Za-z][A-Za-z0-9]*", key):
            raise ValueError(f"Unsafe argument name: {key}")
        call += f" -{key} {_quote(folders['input'] + chr(92) + value if value in names else value)}"
    done, console = root + r"\exit-code.txt", folders["output"] + r"\console.txt"
    launcher = "\n".join([
        f"Start-Process powershell.exe -WindowStyle Hidden -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',"
        f"{_quote(folders['scripts'] + chr(92) + PROMPT_PS.name)},'-StopFile',{_quote(done)},'-Log',{_quote(root + chr(92) + 'prompt.log')}",
        "Start-Sleep -Seconds 2",
        f"try {{ {call} *> {_quote(console)}; $code = $LASTEXITCODE; if ($null -eq $code) {{ $code = 0 }} }} catch {{ $_ | Out-File -Append {_quote(console)}; $code = 99 }}",
        f"Set-Content -LiteralPath {_quote(done)} -Value $code",
    ])
    register = (
        "$ErrorActionPreference = 'Stop'; "
        "if (-not (Get-Process explorer -ErrorAction SilentlyContinue)) { throw 'No signed-in desktop session in the guest.' }; "
        f"Set-Content -LiteralPath {_quote(root + chr(92) + 'launcher.ps1')} -Value {_quote(launcher)} -Encoding UTF8; "
        f"$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument {_quote('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"' + root + chr(92) + 'launcher.ps1\"')}; "
        f"$principal = New-ScheduledTaskPrincipal -UserId {_quote(user)} -LogonType Interactive -RunLevel Highest; "
        f"Register-ScheduledTask -TaskName {_quote(TASK)} -Action $action -Principal $principal -Force | Out-Null; "
        f"Start-ScheduledTask -TaskName {_quote(TASK)}"
    )
    started = _run(shell + [_encoded(register)], 60)
    if started.returncode:
        raise RuntimeError("Could not start the desktop-session task: " + (started.stderr or started.stdout).strip())
    poll = f"if (Test-Path -LiteralPath {_quote(done)}) {{ 'EXIT=' + (Get-Content -LiteralPath {_quote(done)} -Raw).Trim() }}"
    deadline, code = time.monotonic() + timeout, None
    try:
        while time.monotonic() < deadline:
            time.sleep(5)
            match = re.search(r"EXIT=(-?\d+)", _run(shell + [_encoded(poll)], 60).stdout)
            if match:
                code = int(match.group(1))
                break
    finally:
        _run(shell + [_encoded(f"Unregister-ScheduledTask -TaskName {_quote(TASK)} -Confirm:$false -ErrorAction SilentlyContinue")], 60)
    output.mkdir(parents=True, exist_ok=True)
    fetched = _run(["limactl", "copy", "--backend=scp", "--recursive", f"{instance}:{folders['output'].replace(chr(92), '/')}/.", str(output)], 600)
    if fetched.returncode:
        raise RuntimeError("Could not retrieve guest output: " + (fetched.stderr or fetched.stdout).strip())
    if code is None:
        raise RuntimeError(f"The guest script did not finish within {timeout} seconds; partial output is in {output}.")
    return code
