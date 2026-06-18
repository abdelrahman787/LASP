# Quran Tasmee3 — Merged Stitch UI Design Export

All 9 generated screens (+ app icon) from both Google Stitch batches, merged into one set with clear names. The two batches used the identical design system, so `DESIGN.md` (design tokens: colors, typography, spacing, elevation rules) appears once at the root.

## Screens
| Folder | Screen |
|---|---|
| `01_session_report` | Post-recitation session report (score, mistake categories) |
| `02_home_dashboard` | Home / dashboard (continue-recitation card, evaluation summary, today's review, weak spots) |
| `03_mushaf_index` | Surah/Juz index + search |
| `04_mushaf_reading_page` | Mushaf reading page (cream theme, QCF-style layout) |
| `05_auth_login` | Login screen |
| `06_app_icon` | App icon (image only, no code) |
| `07_bookmarks` | Saved bookmarks list |
| `08_recitation_session` | Active "تسميع" session (hidden words, listening indicator, reveal controls) |
| `09_plan_detail` | Review plan detail (items, due dates, snooze/reset) |
| `10_settings` | Settings (account, recitation mode, theme, notifications) |

Each screen folder contains `code.html` (literal generated HTML/CSS — the source of truth for exact colors/blur/spacing/typography) and `screen.png` (visual reference). `06_app_icon` only has the image.

## Known issues to correct during implementation (do not copy literally)
See the separate corrections brief (`agent_apply_stitch_design.md`) for the 7 specific fixes required (mushaf page margins, broken bookmark-screen state overlap, plan-detail text overlap, settings mode-toggle mismatch, etc.).
