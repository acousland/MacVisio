#!/usr/bin/env python3
"""Quick stable release: test, build, sign, notarise, staple, verify and package, then optionally publish.

    python3 scripts/quick-release.py 0.26.3 37 [--bump] [--publish]

For releases the owner asks for without the full stable gates (docs/DISTRIBUTION.md, "Quick releases").
Everything runs locally; there are no GitHub Actions.

- Write docs/RELEASE-<version>.md first. --bump sets scripts/Info.plist to the version and build and
  commits it with the notes; without it they must already match and be committed.
- Work and logs go to build/stable-<version>. Completed stages are recorded in progress.json, so a rerun
  resumes after the last completed stage (for example after restoring the notary login), but only for
  the same source commit.
- Nothing is published without --publish. Publishing fast-forwards origin/main to the release commit and
  creates the GitHub release v<version> with the zip, appcast and SHA256SUMS.

Every refusal and failure prints one "STOP:" line with what to do; the script never works around one.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import plistlib
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TEAM = "5NF98M544G"
PLATFORM_FLOOR = "27.0.1"
STAGES = ["tests", "build", "notarize", "staple", "verify", "package"]


class Stop(Exception):
    pass


def git(*args: str) -> str:
    return subprocess.check_output(["git", *args], cwd=ROOT, text=True).strip()


def quiet(args: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(args, cwd=ROOT, text=True, capture_output=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("version")
    parser.add_argument("build")
    parser.add_argument("--bump", action="store_true", help="set and commit scripts/Info.plist with the release notes")
    parser.add_argument("--publish", action="store_true", help="publish the GitHub release after packaging")
    parser.add_argument("--profile", default="renoir-notary", help="notarytool keychain profile")
    args = parser.parse_args()
    try:
        release(args)
        return 0
    except Stop as stop:
        print(f"STOP: {stop}", flush=True)
        return 1


def release(args: argparse.Namespace) -> None:
    version, build = args.version, args.build
    if not re.fullmatch(r"\d+\.\d+\.\d+", version) or not build.isdigit():
        raise Stop("Give the version as major.minor.patch and the build as a whole number.")
    notes = ROOT / f"docs/RELEASE-{version}.md"
    if not notes.exists():
        raise Stop(f"Write {notes.relative_to(ROOT)} first.")
    out = ROOT / f"build/stable-{version}"
    app = out / "MacVisio.app"
    release_dir = ROOT / f"build/releases/stable-candidates/{version}"

    # Preflight: everything that can be checked before spending time.
    plist_path = ROOT / "scripts/Info.plist"
    plist = plistlib.loads(plist_path.read_bytes())
    if (plist["CFBundleShortVersionString"], plist["CFBundleVersion"]) != (version, build):
        if not args.bump:
            raise Stop(f"scripts/Info.plist is {plist['CFBundleShortVersionString']} ({plist['CFBundleVersion']}); pass --bump to set it to {version} ({build}).")
        if out.exists():
            raise Stop(f"{out.relative_to(ROOT)} exists from an earlier attempt; move it aside before bumping.")
        text = plist_path.read_text()
        for old, new in ((plist["CFBundleShortVersionString"], version), (plist["CFBundleVersion"], build)):
            if text.count(f"<string>{old}</string>") != 1:
                raise Stop(f"Cannot find a unique {old} in scripts/Info.plist; edit it by hand.")
            text = text.replace(f"<string>{old}</string>", f"<string>{new}</string>")
        plist_path.write_text(text)
        git("add", "scripts/Info.plist", str(notes.relative_to(ROOT)))
        git("commit", "-q", "-m", f"Prepare {version} (build {build})")
        print(f"bumped scripts/Info.plist to {version} ({build}) and committed", flush=True)
    if git("status", "--porcelain", "--", "Sources", "Tests", "scripts", "Package.swift", "Package.resolved", str(notes.relative_to(ROOT))):
        raise Stop("Commit the source, test, script and release-note changes first.")
    source = git("rev-parse", "HEAD")
    identities = re.findall(r'\b[A-F0-9]{40} "(Developer ID Application:[^"]+)"',
                            quiet(["security", "find-identity", "-v", "-p", "codesigning"]).stdout)
    if len(identities) != 1 or not identities[0].endswith(f"({TEAM})"):
        raise Stop(f"Expected exactly one Developer ID Application identity for team {TEAM}; found {identities}.")
    if quiet(["xcrun", "notarytool", "history", "--keychain-profile", args.profile]).returncode:
        raise Stop(f"The notary login '{args.profile}' is missing. The owner restores it with: "
                   f"xcrun notarytool store-credentials {args.profile} --apple-id <apple id> --team-id {TEAM}")
    if args.publish:
        if quiet(["gh", "auth", "status"]).returncode:
            raise Stop("gh is not signed in; the owner runs: gh auth login")
        if quiet(["gh", "release", "view", f"v{version}"]).returncode == 0:
            raise Stop(f"Release v{version} is already published.")

    # Resume only the same commit's work.
    progress_path = out / "progress.json"
    progress = {"source": source, "version": version, "build": build, "done": []}
    if out.exists():
        if not progress_path.exists():
            raise Stop(f"{out.relative_to(ROOT)} exists without progress.json; move it aside to start again.")
        progress = json.loads(progress_path.read_text())
        if progress["source"] != source or progress["version"] != version or progress["build"] != build:
            raise Stop(f"{out.relative_to(ROOT)} was built from {progress['source'][:12]}; move it aside to release {source[:12]}.")
    out.mkdir(parents=True, exist_ok=True)

    def save() -> None:
        progress_path.write_text(json.dumps(progress, indent=2) + "\n")

    env = os.environ.copy()
    env.update(MACVISIO_APP_DIR=str(app), MACVISIO_RELEASE_CHANNEL="stable", MACVISIO_SIGNING_IDENTITY=identities[0])

    def run(command: list[str], log: str) -> str:
        with (out / log).open("w") as stream:
            code = subprocess.run(command, cwd=ROOT, env=env, stdout=stream, stderr=subprocess.STDOUT).returncode
        if code:
            tail = (out / log).read_text()[-1500:]
            raise Stop(f"{' '.join(command[:3])} failed (exit {code}); see {(out / log).relative_to(ROOT)}.\n{tail}")
        return (out / log).read_text()

    def stage(name: str, action) -> None:
        if name in progress["done"]:
            print(f"{name}: already done", flush=True)
            return
        print(f"{name}: running", flush=True)
        action()
        progress["done"].append(name)
        save()
        print(f"{name}: done", flush=True)

    save()

    def tests() -> None:
        swift = run(["swift", "test"], "swift-test.log")
        executed, skipped, failed = re.findall(r"Executed (\d+) tests, with (\d+) tests skipped and (\d+) failures", swift)[-1]
        if failed != "0":
            raise Stop(f"{failed} Swift tests failed; see build/stable-{version}/swift-test.log.")
        python = run(["python3", "-m", "unittest", "discover", "-s", "scripts/tests"], "python.log")
        progress["tests"] = {"swift": int(executed), "skipped": int(skipped), "python": int(re.search(r"Ran (\d+) tests", python).group(1))}

    def build_app() -> None:
        if app.exists():
            shutil.rmtree(app)
        run(["bash", "scripts/build-app.sh"], "build.log")
        info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
        if (info.get("MacVisioReleaseChannel"), info["CFBundleShortVersionString"], info["CFBundleVersion"], info["LSMinimumSystemVersion"]) != ("stable", version, build, PLATFORM_FLOOR):
            raise Stop("The built app's channel, version, build or platform floor is wrong.")

    def notarize() -> None:
        archive = out / "notary-submission.zip"
        archive.unlink(missing_ok=True)
        run(["ditto", "-c", "-k", "--keepParent", str(app), str(archive)], "notary-archive.log")
        result = json.loads(run(["xcrun", "notarytool", "submit", str(archive), "--keychain-profile", args.profile,
                                 "--wait", "--timeout", "20m", "--output-format", "json"], "notarization.json"))
        if result.get("status") != "Accepted":
            raise Stop(f"Notarisation returned {result.get('status')}; inspect with: xcrun notarytool log {result.get('id')} --keychain-profile {args.profile}")
        progress["notarization"] = result["id"]

    def staple() -> None:
        run(["xcrun", "stapler", "staple", str(app)], "staple.log")
        run(["spctl", "--assess", "--type", "execute", "--verbose=2", str(app)], "gatekeeper.log")

    def verify() -> None:
        original = (ROOT / "scripts/verify-app.py").read_text()
        anchors = ("build/bundle-verification.json", "root = pathlib.Path(__file__).resolve().parent.parent")
        if any(original.count(anchor) != 1 for anchor in anchors):
            raise Stop("scripts/verify-app.py changed shape; update quick-release.py's verifier substitution.")
        verifier = out / "verify-bundle.py"
        verifier.write_text(original.replace(anchors[0], f"build/stable-{version}/bundle-verification.json")
                            .replace(anchors[1], f"root = pathlib.Path({str(ROOT)!r})"))
        run(["python3", str(verifier)], "bundle-verification.log")
        for command in ("platform", "support"):
            run(["python3", "scripts/release_policy.py", command, str(app), "--output", str(out / f"{command}.json")], f"{command}.log")
        floor = json.loads((out / "platform.json").read_text())["minimumMacOSByArchitecture"]
        if floor != {"arm64": PLATFORM_FLOOR}:
            raise Stop(f"Unexpected platform floor {floor}.")

    def package() -> None:
        if release_dir.exists():
            shutil.rmtree(release_dir)  # an unfinished package from an earlier attempt; never a published one
        run(["bash", "scripts/package-release.sh", "--channel", "stable", "--candidate-only"], "package.log")
        executable = app / "Contents/MacOS/MacVisio"
        record = {"source_commit": source, "version": version, "build": build, "channel": "stable", "architecture": "arm64",
                  "qualified_platform_floor": PLATFORM_FLOOR, "new_executable_sha256": hashlib.sha256(executable.read_bytes()).hexdigest(),
                  "tests": progress.get("tests"), "notarized": True, "notarization_id": progress.get("notarization"),
                  "quick_release": True, "full_stable_gates": False}
        (out / "candidate.json").write_text(json.dumps(record, indent=2) + "\n")

    for name, action in zip(STAGES, (tests, build_app, notarize, staple, verify, package)):
        stage(name, action)
    assets = [release_dir / f"MacVisio-{version}.zip", release_dir / "appcast.xml", release_dir / "SHA256SUMS.txt"]
    print(f"Notarised candidate ready: {release_dir.relative_to(ROOT)}", flush=True)
    if not args.publish:
        print("Not published (pass --publish to publish).", flush=True)
        return

    quiet(["git", "fetch", "-q", "origin", "main"])
    if quiet(["git", "merge-base", "--is-ancestor", "origin/main", source]).returncode:
        raise Stop("origin/main has commits that are not in the release commit; main can only be fast-forwarded.")
    git("push", "-q", "origin", f"{source}:refs/heads/main")
    created = quiet(["gh", "release", "create", f"v{version}", *map(str, assets), "--target", source,
                     "--title", f"MacVisio {version}", "--notes-file", str(notes), "--latest"])
    if created.returncode:
        raise Stop(f"gh release create failed: {created.stderr.strip()}")
    progress["published"] = created.stdout.strip()
    save()
    print(f"Published: {created.stdout.strip()}", flush=True)


if __name__ == "__main__":
    sys.exit(main())
