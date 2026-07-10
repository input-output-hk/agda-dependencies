{-# OPTIONS --type-in-type #-}
-- R15 fixture: a file-level {-# OPTIONS #-} soundness escape.
--
-- The file-level `--type-in-type` must surface in graph.json's
-- `moduleOptionEscapes` as `["--type-in-type"]`. The per-block
-- `{-# NO_POSITIVITY_CHECK #-}` below is a DECLARATION pragma, not an
-- OPTIONS pragma, so it never lives in the interface's
-- `iFilePragmaOptions` and must NOT appear in `moduleOptionEscapes` —
-- this fixture pins that boundary (see AgdaDeps.Deps.optionEscapes and
-- the CLAUDE.md gotcha). No `--safe` here on purpose.
module OptionEscapes where

-- Typechecks only with universe checking off (`--type-in-type`): Set : Set.
bigType : Set
bigType = Set

-- A non-strictly-positive datatype, accepted only because of the
-- block-local positivity waiver — which stays invisible to the
-- module-level OPTIONS scan (no `--no-positivity-check` in the file).
{-# NO_POSITIVITY_CHECK #-}
data Rec : Set where
  rec : (Rec → Rec) → Rec
