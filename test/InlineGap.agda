{-# OPTIONS --safe #-}
-- Characterisation fixture for the "inliner gap" backlog item.
--
-- Agda inlines every call to an @{-# INLINE #-}@ function into the
-- caller's body *during type-checking*, before the backend hook fires.
-- So in agda-deps's output:
--   * `twice` is dropped as a node (ignoreDef's funInline rule), and
--   * `useInline` / `aliasTwice` point straight at `Nat._+_`
--     (twice's inlined body) — NOT at `twice`.
-- The `⇝ twice` call edges are gone from the elaborated internal syntax
-- and cannot be recovered producer-side. Drop the `{-# INLINE #-}`
-- pragma and all three edges to `twice` reappear. See Backlog.md (#3 /
-- "Inliner gap") and the funInline gotcha in CLAUDE.md.
module InlineGap where

open import Nat using (Nat; zero; suc; _+_)

-- A trivial single-clause helper, marked INLINE.
twice : Nat → Nat
twice n = n + n
{-# INLINE twice #-}

-- Direct caller of the INLINE helper. Edge useInline ⇝ twice ?
useInline : Nat → Nat
useInline m = twice m

-- A trivial point-free alias (eta-contracted single clause).
aliasTwice : Nat → Nat
aliasTwice = twice

-- Caller of the alias. Edges useAlias ⇝ aliasTwice, aliasTwice ⇝ twice ?
useAlias : Nat → Nat
useAlias k = aliasTwice k
