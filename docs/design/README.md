# CTMS UI Design Brief (from `ctms.pen`)

Source of truth: `D:\ctms\ctms.pen` (pen.dev / Pencil). PNG exports (2x) of each frame are in this folder.
Read a PNG with the Read tool. For exact values (padding, sizes, colours, copy) use the Pencil MCP `execute` tool with
`uri: "file:///d%3A/ctms/ctms.pen"` and `Print(Get("<nodeId>", {depth: 4, resolveVariables: true}))` (read-only; never
modify the design; load it with `ToolSearch select:mcp__pencil__execute`).

| Frame | Node id | PNG | Size | App target |
|---|---|---|---|---|
| Student: Live bus (phone, light) | `H7VF2` | `H7VF2.png` | 390x844 | `app/lib/features/student/student_home_screen.dart` (Live tab + bottom nav) |
| Driver: Active journey (phone, **dark**) | `Dj29g` | `Dj29g.png` | 390x844 | `app/lib/features/driver/driver_home_screen.dart` |
| Admin: Fleet pulse (phone) | `M4tRS` | `M4tRS.png` | 390x844 | `app/lib/features/admin/admin_home_screen.dart` (Live/home tab + nav) |
| Admin: Fleet pulse (tablet) | `OGW7p` | `OGW7p.png` | ~794 wide | same screen at width >= 600 (rail + map + side panel) |

## Design language: "Kashmir University"
Variables in the file (light / dark): `ku-olive` #5C7D1F / #A3C964, `ku-bg` #FBFAF5 / #121A14, `ku-surface` #FFFFFF / #1D2A20,
`ku-text` #213021 / #F4F7EC, `ku-muted` #687768 / #B8C5B6, `ku-border` #DDE5D7 / #3B4A3C; fixed: `ku-maroon` #7C1E21,
`ku-gold` #D79B28, `ku-blue` #3170CD. Fonts: headings **Newsreader** (serif), UI **Geist**, numbers/data **IBM Plex Mono**
(use tabular figures for ETAs, clocks, distances). The unused shadcn-style variables (`--primary` orange etc.) are template
leftovers: ignore them.

## Decisions (already made; do not re-litigate)
1. Theme follows the system light/dark. The **driver workspace always uses the dark theme** (night driving, as in the design).
2. Status colours stay semantic and always carry text/icon: on time = olive/green, delayed = gold, breakdown = maroon-red, stale = grey.
3. Fonts are **bundled assets** (no runtime download, no new package): OFL TTFs for Newsreader, Geist, IBM Plex Mono under
   `app/assets/fonts/`, declared in `pubspec.yaml`. Record them in `docs/v1/allowed-apis.md`.
4. Behaviour, API calls, providers and routing are **unchanged**. This is a visual re-skin plus the layout changes shown in the
   frames. If a frame shows data we do not have (e.g. "Covered 4.2 km"), derive it from existing fields or hide that element and
   say so in your report; never invent fake numbers.
5. Admin: phone uses bottom nav (Live, Fleet, Routes, More); tablet/wide (>= 600) uses a left rail + map + attention panel as in `OGW7p`.
   Existing admin tabs, dialogs and the students tab must keep working and keep their keys used by tests.

## Rules for every agent
- Repo conventions in `CLAUDE.md`. Look up any new library API via context7 and add it to `docs/v1/allowed-apis.md` first (prefer none).
- Keep existing widget `Key`s and public behaviour so tests keep passing; update tests only when the visible text/structure legitimately changed, and add widget tests for new components.
- Verify with `cd app && flutter analyze && flutter test` (both must be clean) before reporting.
- Commit only your own files in one step: `git commit -m "..." -- <paths>`. Never `--amend`. No `Co-Authored-By` or "Generated with" lines. Other agents share this working tree: touch only the files your brief names.
- Do not run `flutter build`/install on devices; the lead does that.
- Report concisely: files changed, what matches the frame, what was derived or hidden, anything not matched.
