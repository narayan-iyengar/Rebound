# BallNet-R Training Data

Kept in-repo path but git-ignored. See `docs/SKYNET_AUTOSCORE_DESIGN.md` §6.

## Layout

```
training-data/
├── videos/
│   ├── sahil/     ← Narayan's recordings (from Photos.app export)
│   └── others/    ← teammate's dad's uploads (from yt-dlp)
├── frames/        ← extractor script fills this (Phase 1a)
├── labels/        ← labeling tool writes here (JSONL, tracked in git)
└── README.md
```

## What's tracked in git

Only `training-data/labels/**` and this README. Everything else is
gitignored — videos are private footage of minors, frames are large binary,
both are regenerable/re-downloadable.

## Lifecycle (from design doc §6)

1. **Download videos** into `videos/sahil/` or `videos/others/`
2. **Extract frames** — script drops candidate frames into `frames/`, deletes videos as it processes them
3. **Label** — labeling tool writes `labels/labels.jsonl` incrementally, autosaving
4. **Train** — training script reads frames + labels
5. **Cleanup** — after model validated on 3+ real games (ship-or-kill gate), delete `frames/`. Keep `labels/` forever.

## File naming convention

For videos, suggest:
`YYYY-MM-DD_team-vs-opponent[_venue].mov`

Examples:
- `2026-05-10_lava-vs-cal-swoosh.mov`
- `2026-06-27_lava-vs-justhoop.mov`
- `2026-06-14_[other-dad]_bulls-vs-hawks.mp4`

Consistent naming makes it easier to spot-check gym/opponent variety later.

## v3 hi-res sources (2026-07-06)

`videos_hires/` symlinks map 4K original recordings (exported from Photos,
`videos/originals/`) to their YouTube label filenames. 5 of 8 games have
frame-aligned 4K originals (verified by exact duration match); the other 3
fall back to YouTube 1080p. This matches Rebound's actual deployment
distribution (the app records 4K → downsamples for the AI pipeline), so
4K-sourced training frames are the correct distribution, not just higher quality.

4K-sourced (frame-aligned, exact duration match):
  Mar 22 Elements, Apr 18 Yellow Jackets (VAL), May 2 Midtown,
  Jun 21 Cal swoosh, Jun 27 SF Rebels
YouTube 1080p (no aligned original):
  Feb 8 East Bay, Feb 12 SJ Spartans, May 9 PA Flight

Regenerate symlinks: see git history for the ln -s block, or the
originals/ + sahil/ dirs.
