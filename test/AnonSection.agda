{-# OPTIONS --safe #-}
module AnonSection where

open import Nat using (Nat; zero; suc; _+_)

-- Parameterised anonymous-module section. Agda desugars `module _ (n)`
-- into an anonymous sub-module and lifts each definition, prepending the
-- section parameter to its type (`helper : (n : Nat) → Nat`). The
-- backend must:
--   * re-home `helper` / `client` to module `AnonSection` (no phantom
--     `AnonSection._` module node), and
--   * name them `AnonSection.helper@…` / `AnonSection.client@…` (the
--     anonymous `_` segment lifted away, the `@line` disambiguator kept),
--   * tag the sibling edge `client ⇝ helper` `module-local` (helper is a
--     locally-scoped section member, not a top-level declared name).
-- Regression for the "anonymous-module blind spot" (nodeKeyVersion 3).
module _ (n : Nat) where
  helper : Nat
  helper = n + zero

  client : Nat
  client = helper + helper

-- Nested sections lift through *both* anonymous levels
-- (`AnonSection._._.deep` ↦ `AnonSection.deep@…`).
module _ (a : Nat) where
  module _ (b : Nat) where
    deep : Nat
    deep = a + b

-- A top-level consumer of a section definition. `client` is a
-- section-local member, so this edge is tagged `module-local` — the
-- honest meaning of the tag is "the target is an anonymous-module-local
-- helper", independent of which definition reaches it (it does *not*
-- claim `client` is a where-helper *of* `useSection`).
useSection : Nat
useSection = client (suc zero)
