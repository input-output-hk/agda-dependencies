{-# LANGUAGE BangPatterns      #-}
{-# LANGUAGE PatternSynonyms   #-}
-- | Term canonicalisation for AST-level subterm fingerprinting,
-- emitted for downstream clustering tooling.
--
-- 'subtermHashes' produces the same byte sequence (and thus hash) for
-- two Agda 'Term's that differ only in bound-variable names, source
-- positions, meta-variable identities, or modality annotations.
--
-- Encoding is a hand-rolled tagged 'ShowS' walk over the 'Term'
-- constructors:
--
--   * 'Var' uses Agda's de-Bruijn indices directly; the display
--     'absName' on 'Lam' / 'Pi' is discarded.
--   * 'MetaV' identities are replaced by a sentinel.
--   * 'QName' references go through 'prettyShow' (same convention as
--     'AgdaDeps.Deps.hashQName').
--   * 'ArgInfo' is reduced to its 'Hiding' bit; relevance, quantity,
--     modality, and origin are dropped.
--   * 'ConInfo', 'ProjOrigin', and 'DummyTermKind' are dropped.
module AgdaDeps.TermCanon
  ( -- * Subterm walk
    subtermHashes
  ) where

import           Data.Word        ( Word64 )

import           Agda.Syntax.Common
                   ( Arg(..), Hiding(..), getHiding )
import           Agda.Syntax.Internal
                   ( Term(..), pattern Var
                   , Elim, Elim'(..), Elims
                   , Abs, unAbs
                   , Dom, unDom
                   , Type, unEl
                   , ConHead, conName
                   )
import           Agda.Syntax.Common.Pretty ( prettyShow )
import           Agda.Utils.Hash ( hashString )

-- | Hash every subterm of @t@ whose AST depth is at least @minDepth@,
-- including @t@ itself if it qualifies. Order is the depth-first
-- pre-order traversal of 'Term' nodes.
--
-- Depth definition (used for filtering only — never emitted):
--
--   * Atomic 'Var' / 'Lit' / 'Sort' / 'Level' / 'Dummy' / 'Proj' all
--     have depth 1.
--   * A 'Lam' / 'DontCare' over a body of depth d has depth d+1.
--   * A 'Pi' over (dom of depth d_d, body of depth d_b) has depth
--     max(d_d, d_b) + 1.
--   * A 'Def' / 'Con' / applied 'Var' / 'MetaV' / 'Dummy' with elims
--     of maximum depth d_e has depth d_e + 1 (or 1 if the elim list
--     is empty).
--   * For 'Elim': 'Apply (Arg _ u)' inherits @u@'s depth, 'Proj' is
--     1, 'IApply u v w' is max of the three.
--
-- A threshold of @1@ emits every subterm; @3@ is the recommended
-- default, suppressing the @Var 0 []@ / single-'Sort' / empty-elim
-- noise.
--
-- Walks once bottom-up: each subterm's canonical encoding and depth
-- are built together and the emit decision made at each node.
subtermHashes :: Int -> Term -> [(Word64, Int)]
subtermHashes !minD t = case canonAndSubs minD t of (_, _, hs) -> hs

-- | Bottom-up traversal returning (canonical encoding, AST depth,
-- accumulated (hash, depth) pairs for qualifying subterms). The
-- encoding is reused by the parent; the depth drives the filter; the
-- pairs are the return value.
canonAndSubs :: Int -> Term -> (ShowS, Int, [(Word64, Int)])
canonAndSubs !minD t0 = case t0 of
  Var n es ->
    let (esEnc, esD, esHs) = canonElimsSubs minD es
        !d   = if null es then 1 else esD + 1
        enc  = ('V':) . shows n . esEnc
    in (enc, d, emit minD d enc esHs)
  Lam _ b ->
    let (bEnc, bD, bHs) = canonAndSubs minD (unAbs b)
        !d  = bD + 1
        enc = ('L':) . bEnc
    in (enc, d, emit minD d enc bHs)
  Lit l ->
    let enc = ('I':) . encStr (prettyShow l)
    in (enc, 1, emit minD 1 enc [])
  Def qn es ->
    let (esEnc, esD, esHs) = canonElimsSubs minD es
        !d  = if null es then 1 else esD + 1
        enc = ('D':) . encStr (prettyShow qn) . esEnc
    in (enc, d, emit minD d enc esHs)
  Con ch _ es ->
    let (esEnc, esD, esHs) = canonElimsSubs minD es
        !d  = if null es then 1 else esD + 1
        enc = ('C':) . encStr (prettyShow (conName ch)) . esEnc
    in (enc, d, emit minD d enc esHs)
  Pi dom bod ->
    let (dEnc, dD, dHs) = canonAndSubsDom minD dom
        (bEnc, bD, bHs) = canonAndSubs minD (unEl (unAbs bod))
        !d  = max dD bD + 1
        enc = ('P':) . dEnc . bEnc
    in (enc, d, emit minD d enc (dHs ++ bHs))
  Sort s ->
    let enc = ('S':) . encStr (prettyShow s)
    in (enc, 1, emit minD 1 enc [])
  Level l ->
    let enc = ('Z':) . encStr (prettyShow l)
    in (enc, 1, emit minD 1 enc [])
  MetaV _ es ->
    -- MetaId wildcarded — only the eliminations carry shape information.
    let (esEnc, esD, esHs) = canonElimsSubs minD es
        !d  = if null es then 1 else esD + 1
        enc = ('M':) . esEnc
    in (enc, d, emit minD d enc esHs)
  DontCare u ->
    let (uEnc, uD, uHs) = canonAndSubs minD u
        !d  = uD + 1
        enc = ('X':) . uEnc
    in (enc, d, emit minD d enc uHs)
  Dummy k es ->
    -- 'DummyTermKind' has no 'Pretty' instance; use 'show' for a
    -- stable tag.
    let (esEnc, esD, esHs) = canonElimsSubs minD es
        !d  = if null es then 1 else esD + 1
        enc = ('Y':) . encStr (show k) . esEnc
    in (enc, d, emit minD d enc esHs)

-- | Cons the current node's (hash, depth) pair onto the children's
-- list only when the node's depth qualifies.
emit :: Int -> Int -> ShowS -> [(Word64, Int)] -> [(Word64, Int)]
emit !threshold !d enc childHs
  | d >= threshold = (mkHash enc, d) : childHs
  | otherwise      = childHs

canonAndSubsDom :: Int -> Dom Type -> (ShowS, Int, [(Word64, Int)])
canonAndSubsDom !minD d =
  let (tEnc, tD, tHs) = canonAndSubs minD (unEl (unDom d))
  in (('p':) . tEnc, tD, tHs)

canonElimsSubs :: Int -> Elims -> (ShowS, Int, [(Word64, Int)])
canonElimsSubs !minD es =
  let n = length es
      triples = map (canonElimSubs minD) es
      encs = [ e | (e, _, _) <- triples ]
      ds   = [ d | (_, d, _) <- triples ]
      hss  = [ h | (_, _, h) <- triples ]
  in ( ('[':) . shows n . foldr (\f g -> ('|':) . f . g) id encs . (']':)
     , foldr max 0 ds
     , concat hss )

canonElimSubs :: Int -> Elim -> (ShowS, Int, [(Word64, Int)])
canonElimSubs !minD (Apply a) =
  let h            = getHiding a
      (uEnc, uD, uHs) = canonAndSubs minD (unArg a)
  in ( ('A':) . encHiding h . uEnc , uD , uHs )
canonElimSubs !_minD (Proj _ qn) =
  ( ('R':) . encStr (prettyShow qn) , 1 , [] )
canonElimSubs !minD (IApply u v w) =
  let (uEnc, uD, uHs) = canonAndSubs minD u
      (vEnc, vD, vHs) = canonAndSubs minD v
      (wEnc, wD, wHs) = canonAndSubs minD w
  in ( ('J':) . uEnc . vEnc . wEnc , maximum [uD, vD, wD] , uHs ++ vHs ++ wHs )

encHiding :: Hiding -> ShowS
encHiding Hidden     = ('h':)
encHiding NotHidden  = ('n':)
encHiding Instance{} = ('i':)

-- | Length-prefixed string. The length prefix prevents adjacent
-- strings from concatenating into the same byte stream (e.g. \"ab\" +
-- \"\" should differ from \"a\" + \"b\").
encStr :: String -> ShowS
encStr s = shows (length s) . (':':) . (s ++)

-- | Force a 'ShowS' into a 'String' and hash it.
mkHash :: ShowS -> Word64
mkHash f = fromIntegral (hashString (f ""))
