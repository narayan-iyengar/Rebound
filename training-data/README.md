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
