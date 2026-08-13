-- Silent-unsolved-meta fixture (kept outside test/ so the main corpus
-- needs no --allow-unsolved-metas): the `record { go }` module-copy
-- supplies `A` and `n` but not `bad`, so elaboration inserts a
-- metavariable nothing can ever solve — plain `agda` rejects this file
-- with [UnsolvedMetaVariables] at `t = record { go }`. Under --allow-unsolved-metas
-- the module "succeeds" and the meta becomes an `unsolved#meta.*`
-- postulate; the graph must report it as a SILENT unsolved meta
-- (per-def `unsolvedMetas`, module rollup `unsolvedModules`), unlike an
-- honest interaction `?` (see Entry.agda). Locked by CI.
module MetaProbe where

data ⊥ : Set where

data ℕ : Set where
  zero : ℕ
  suc  : ℕ → ℕ

record R : Set₁ where
  field A   : Set
        n   : ℕ
        bad : ⊥

t : R
t = record { go }
  where module go where
  A = ℕ
  n = zero
  -- `bad` deliberately missing

use : ⊥
use = R.bad t
