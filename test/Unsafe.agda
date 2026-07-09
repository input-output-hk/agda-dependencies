-- R12 fixture: soundness escapes beyond postulates/holes.
--
-- No `--safe` here on purpose — this file deliberately contains the very
-- escapes an `agda --safe` audit rejects, so each def below must surface
-- an `unsafe` tag in graph.json while its `state` stays "D".
module Unsafe where

open import Nat using (Nat; zero; suc; _+_)
open import Agda.Builtin.Equality using (_≡_)
open import Agda.Builtin.TrustMe using (primTrustMe)

-- {-# NON_TERMINATING #-} → funTerminates = Just False → ["non-terminating"].
{-# NON_TERMINATING #-}
loop : Nat → Nat
loop n = loop n

-- {-# TERMINATING #-} → funTerminates = Just True, which Agda ALSO writes
-- for every ordinary proven-terminating def, so it can't be told apart and
-- carries NO tag. Control: confirms a terminating def stays untagged.
{-# TERMINATING #-}
countdown : Nat → Nat
countdown zero    = zero
countdown (suc n) = countdown n

-- Body references primTrustMe → ["trustme"].
trustEq : (m n : Nat) → m ≡ n
trustEq m n = primTrustMe

-- Control: an ordinary total function — must carry NO `unsafe` field.
double : Nat → Nat
double n = n + n
