-- Entry point for the --keep-going robustness fixture: imports one
-- healthy module and one that fails to type-check. agda-deps
-- --keep-going must still emit a graph with Good's definitions and
-- Broken tagged as a failed module.
module Entry where

open import Good
open import Broken

eight : Nat
eight = quadruple 2
