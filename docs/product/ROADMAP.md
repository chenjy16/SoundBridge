# Product Roadmap — Superseded

This roadmap is retained as a stable link for existing references. It is no
longer the current product plan.

Use the current [SoundBridge Product Roadmap and Specification](SOUNDBRIDGE-PRODUCT-ROADMAP-AND-SPECIFICATION.md) for
product positioning, scope, feature priorities, Free/Pro hypotheses, and the
release sequence.

## Why this document was superseded

The former plan positioned per-application volume as the first paid capability
and proposed Process Tap as a future architecture option. The current strategy
repositions SoundBridge as **system-wide audio enhancement for macOS** and
explicitly excludes per-application control, Process Tap, and migration to a
Aggregate Device-based architecture migration.

The old plan's technical feasibility investigation was tied to that excluded
product direction, so it is not carried forward as a roadmap item. The current
product specification instead preserves the existing Driver + Host + Shared
Memory/SPSC Ring Buffer + DSP Engine path and prioritizes reliability, DSP,
headphone/speaker personalization, and system-wide audio profiles.

The previous document remains available in Git history. This file intentionally
contains no active feature commitments; its only purpose is to redirect readers
to the authoritative product strategy.
