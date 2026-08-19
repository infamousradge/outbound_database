# Outbound Database — Windows

A Windows Flutter desktop app for importing `.docx` dispatch documents, parsing items, storing them in SQLite, and exporting/importing CSV or JSON.

## GitHub Actions build

The repository is configured so the Windows/Visual Studio runner is generated automatically on the GitHub Windows runner. You do **not** need to commit the generated `windows/` directory.

The workflow does **not** assume that Flutter uses `build/windows/runner/Release`. It locates the actual `outbound_database.exe` under the `Release` directory, including the current `build/windows/x64/runner/Release` layout.

Workflow:

`.github/workflows/build-windows.yml`

It performs, in order:

1. Checkout
2. Install stable Flutter
3. Enable Windows desktop
4. Generate the Windows runner if it is missing
5. `flutter pub get`
6. `flutter pub deps`
7. `flutter analyze`
8. `flutter build windows --release`
9. Package the complete portable build into `OutboundDatabase-Windows-Portable.zip`
10. Install NSIS and create `OutboundDatabase-Setup.exe`
11. Upload both files as GitHub Actions artifacts
12. For `v*` tags, attach both files to a GitHub Release

## How to build on GitHub

1. Push this repository to GitHub.
2. Make sure the default branch is `main`.
3. Open **Actions**.
4. Select **Build Windows Release**.
5. Click **Run workflow**.
6. Open the completed workflow run.
7. Under **Artifacts**, download `outbound-database-windows`.
8. The artifact contains:
   - `OutboundDatabase-Windows-Portable.zip`
   - `OutboundDatabase-Setup.exe`
   - `build_windows_log.txt`

For a GitHub Release, create and push a tag such as `v0.1.0` and the workflow will attach the portable ZIP and installer EXE automatically. The workflow has `contents: write` permission so the release upload can succeed.

## Local Windows development

```powershell
flutter config --enable-windows-desktop
flutter create --platforms=windows --no-pub .
flutter pub get
flutter analyze
flutter run -d windows
```

## Database

The SQLite database is stored per Windows user under:

`%APPDATA%\OutboundDatabase\outbound_database.db`

The database is not stored inside the installed program directory.

## Important fixes in this build

- Windows runner generation happens **before** dependency/build steps.
- The build command is allowed to fail; the workflow now stops immediately on a non-zero exit code.
- Both current and older Flutter Windows release output layouts are handled.
- Analyzer diagnostics are uploaded as `analyze_log.txt`; info/lint diagnostics do not block the release build. Actual Flutter compilation errors do block the build.
- The workflow uploads the build log even if a later packaging step fails.
- NSIS produces a real installer named `OutboundDatabase-Setup.exe`.
- Dependency versions are modernized while keeping `sqflite_common_ffi` on the SQLite v2 line for predictable Windows builds.
- The parser's `ITEM` regular expression was corrected so `\s` is interpreted as whitespace instead of a literal backslash sequence.

## Repository contents

- `lib/main.dart` — Flutter UI
- `lib/parser.dart` — DOCX parsing
- `lib/db.dart` — SQLite persistence/deduplication
- `.github/workflows/build-windows.yml` — CI/CD
- `installer.nsi` — Windows installer definition
