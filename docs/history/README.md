# Design history

Current requirements belong in [UI_DESIGN.md](../UI_DESIGN.md), [ARCHITECTURE.md](../ARCHITECTURE.md), and the [release checklist](../SMOKE_TEST.md).

The September reports described retired shelf layouts, earlier test counts, and local review builds. Their complete text is preserved in the published Git history at the fixed revision below, rather than maintained beside current instructions. All native screenshots remain in this folder.

| Record | Preserved report |
| --- | --- |
| Design assessment | [DESIGN_REVIEW_2026-27.md](https://github.com/akkolli/clipbored/blob/58c03a240c577e136de5ecceb7a1ce4cd1bd5ee7/docs/history/DESIGN_REVIEW_2026-27.md) |
| First design implementation | [DESIGN_UPDATE_2026-27.md](https://github.com/akkolli/clipbored/blob/58c03a240c577e136de5ecceb7a1ce4cd1bd5ee7/docs/history/DESIGN_UPDATE_2026-27.md) |
| Goldfish redesign | [GOLDFISH_DESIGN_REBUILD.md](https://github.com/akkolli/clipbored/blob/58c03a240c577e136de5ecceb7a1ce4cd1bd5ee7/docs/history/GOLDFISH_DESIGN_REBUILD.md) |
| Early release review | [RELEASE_REVIEW.md](https://github.com/akkolli/clipbored/blob/58c03a240c577e136de5ecceb7a1ce4cd1bd5ee7/docs/history/RELEASE_REVIEW.md) |
| September code reductions | [CODEBASE_CLEANUP.md](https://github.com/akkolli/clipbored/blob/58c03a240c577e136de5ecceb7a1ce4cd1bd5ee7/docs/history/CODEBASE_CLEANUP.md) |

The enduring decisions are: local-first Mac capture; stable content geometry during hover; independent destination, content, search, and order; explicit onboarding consent; drafts retained after failed saves; owned child previews; native keyboard/VoiceOver controls; and clearly labeled copy fallback and unencrypted archive backup. The current guides describe their shipping implementation.

September 21 fixtures show the original review and first implementation. September 22 fixtures show the Goldfish redesign and its interaction refinements:

- [Design fixtures](goldfish-design-2026-09-21/README.md)
- [Goldfish card and settings fixtures](goldfish-design-2026-09-22/README.md)
- [Interaction fixtures](goldfish-interactions-2026-09-22/README.md)

Offscreen synthetic renders are visual evidence, not certification of VoiceOver, multi-display/Spaces, older macOS, Intel hardware, or animation frame pacing. Live verification and limitations remain in the preserved reports. Four byte-identical screenshot duplicates share canonical files; originals remain in Git history.

For offline access, use `git show 58c03a240c577e136de5ecceb7a1ce4cd1bd5ee7:docs/history/<report>.md`.
