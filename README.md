Outbound Database — Windows Flutter app

Overview
- Windows desktop Flutter app to import dispatch .docx files, parse items, and maintain a deduplicated client+items database.
- Parser ported from Python to Dart: extracts paragraphs and tables from document.xml and applies regex heuristics.
- SQLite via sqflite_common_ffi; dedupe by normalized address+phone or GSTIN.

Quick start (Windows)
1. Install Flutter (stable) and enable Windows desktop: https://flutter.dev/desktop
2. From project folder: flutter pub get
3. Run: flutter run -d windows

Files
- lib/main.dart — UI and orchestration
- lib/parser.dart — .docx parsing and heuristics
- lib/db.dart — SQLite DB helper, dedupe/merge logic

Notes & next steps
- UI is minimal: preview parsed blocks and Save All. Add edit-in-place as needed.
- Item segregation/status: DC, Billed, Pending, Returned, Other.
- Duplicate serial numbers are skipped on save (to avoid duplicates). Adjust policy in lib/db.dart if needed.
- For production, set an explicit DB path (user profile/AppData) and better error handling.
