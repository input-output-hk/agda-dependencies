{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE PatternSynonyms #-}
-- | Phase-2 argument analysis: /match-constant/ positions — arguments whose
-- case split could be replaced by a wildcard without changing any clause.
--
-- Phase 1 ('AgdaDeps.Deps.argUsageOf') counts a case split as a use, so it
-- says nothing about
--
-- > f : Bool -> B -> B
-- > f true  b = b
-- > f false b = b
--
-- whose first argument is matched but whose match decides nothing. The
-- evidence is in @funCompiled@, the compiled case tree, which never reaches
-- the wire — so only a backend can see it.
--
-- __Report-only, and Low confidence by construction.__ Wildcarding is not
-- observationally neutral: @f x b@ was stuck on a neutral @x@ and afterwards
-- reduces. Definitional equality only grows, but downstream elaboration can
-- shift — so this is never presented with the certainty of phase 1's
-- @removable@, which is Agda's own verdict.
--
-- No CPP here: the one 2.8\/2.9 difference in the case-tree API (2.9's @Done@
-- is a pattern synonym over @CCDone@ with two extra fields) is bridged by
-- 'AgdaDeps.Util.ccDone'.
module AgdaDeps.MatchConstant
  ( matchConstantOf
  , matchConstantAnalysable
  ) where

import Data.Foldable ( toList )
import qualified Data.IntMap.Strict as IM
import qualified Data.Map.Strict as M
import Data.Maybe ( isJust, isNothing, listToMaybe )
import Data.Monoid ( Any(..) )

import Agda.Syntax.Abstract.Name ( QName )
import Agda.Syntax.Common ( unArg )
import Agda.Syntax.Internal
  ( Term, Type, Clause(..), Pattern'(..), DBPatVar
  , telToList, unDom
  )
import Agda.Syntax.Internal.Pattern ( foldPattern )
import Agda.TypeChecking.CompiledClause
  ( CompiledClauses, Case(..), WithArity(..), pattern Case )
import Agda.TypeChecking.Free ( freeIn )
import Agda.TypeChecking.Monad
  ( TCM, Definition(..)
  , pattern Function, funCompiled, funClauses
  , pattern Datatype, dataIxs
  , pattern Constructor, conData
  )
import Agda.TypeChecking.Monad.Signature ( droppedPars, getConstInfo )
import Agda.TypeChecking.Substitute ( applySubst, strengthenS, liftS, TelV(..) )
import Agda.TypeChecking.Telescope ( telView )
import Agda.Utils.Impossible ( impossible )

import AgdaDeps.Util ( ccDone )

-- | Is this definition in phase 2's population at all: a non-projection-like
-- 'Function' with a compiled case tree? Exposed so a measurement can report
-- findings as a fraction of the population rather than of all definitions.
matchConstantAnalysable :: Definition -> Bool
matchConstantAnalysable def = case theDef def of
  Function{ funCompiled = mcc } -> droppedPars def == 0 && isJust mcc
  _                             -> False

-- | Positions whose case split is /collapsible to a wildcard/, ascending,
-- over the definition's __elaborated__ telescope — the same index space
-- 'AgdaDeps.Deps.rawArgUsage' returns, so the caller's section shift applies
-- to this list unchanged.
--
-- A position is reported when __every__ @Case@ node in the tree that splits
-- on it is collapsible. That is stronger than "the @Case@ node at the root of
-- the tree": one argument can be split in several subtrees (@f true true@ /
-- @f true false@ / @f false …@), and wildcarding it in the source removes
-- /all/ of those splits at once, so one load-bearing split anywhere
-- disqualifies the position.
--
-- Conservative by construction; every uncertainty is a silent skip:
--
--   * any @Fail@ (absurd) branch inside a compared subtree, so a
--     coverage-bearing match is never reported;
--   * @litBranches@ and @etaBranch@ anywhere — v1 handles @conBranches@ plus
--     the catch-all only, as the design note permits;
--   * @projPatterns@ (copattern \/ record construction: those branches are
--     projections, not a match);
--   * a split whose constructors do not all come from one plain @data@ type
--     with @dataIxs == 0@ (indexed families refine other arguments' types);
--   * any dot or @IApplyP@ pattern in the definition's clauses — bluntly the
--     whole definition. That guard does double duty: it is also what makes
--     "every pattern at a @Done@ leaf is a variable" true, which is what lets
--     'viewCollapsed' read the leaf's context size off the leaf itself.
matchConstantOf :: Definition -> TCM [Int]
matchConstantOf def = case theDef def of
  Function{ funCompiled = Just cc, funClauses = cls }
    | droppedPars def == 0
    , not (any clauseHasDotP cls) -> do
        verdicts <- collect (initialFrame cls cc) cc
        let cands = IM.keys (IM.filter id verdicts)
        -- The type check costs a reducing 'telView', so it is paid only for a
        -- definition that already has a candidate — a fraction of a percent.
        if null cands then pure [] else do
          TelV tel core <- telView (defType def)
          -- Hoisted out of the filter: the domain list is the same for every
          -- candidate.
          pure (filter (typeIndependent (map (snd . unDom) (telToList tel)) core)
                       cands)
  _ -> pure []

-- | __The guard that makes the property true in a dependently typed
-- setting.__ Identical branch bodies are not enough: the branches' /types/
-- can differ, because matching refines them. The standard library is full of
--
-- > not-involutive : forall x -> not (not x) == x
-- > not-involutive true  = refl
-- > not-involutive false = refl
--
-- where both bodies are the very same term (@refl@ carries no visible
-- arguments — a constructor's parameters are dropped in internal syntax) and
-- yet @not-involutive _ = refl@ does not typecheck: the goal type is only
-- @not (not x) == x@ after @x@ is known. The split is load-bearing for
-- /type-checking/, not for computing.
--
-- So a position is reported only when its variable does not occur in the rest
-- of the type — no later domain, and not the codomain. Then every branch has
-- the same goal type, identical bodies really do mean identical clauses, and
-- the wildcarded clause type-checks. Same @freeIn@ arithmetic as
-- 'AgdaDeps.Deps.removableRequiresOf': inside domain @j@, the binder at @i@
-- has index @j-1-i@, and in the codomain (under all @n@ binders) it has
-- index @n-1-i@.
--
-- This is /not/ a re-implementation of @dependentPolarity@ (which the design
-- note rightly warned against): it is a plain occurrence check, and it is
-- required for soundness rather than for tiering.
typeIndependent :: [Type] -> Type -> Int -> Bool
typeIndependent doms core i =
  not (freeIn (n - 1 - i) core)
    && not (or [ freeIn (j - 1 - i) d | (j, d) <- zip [0 ..] doms, j > i ])
  where
    n = length doms

-- | Per original argument: was /every/ @Case@ node found on it collapsible?
-- One argument can be split in several subtrees and wildcarding removes them
-- all, so the verdicts for a position are conjoined as the walk merges them.
type Verdicts = IM.IntMap Bool

-- | Walk the whole tree, testing every split whose position still maps back
-- to an original argument.
collect :: Frame -> CompiledClauses -> TCM Verdicts
collect fr cc = case cc of
  Case n bs -> do
    let p = unArg n
    here <- case originalOf fr p of
      Nothing -> pure IM.empty
      Just i  -> do
        ok <- collapsible p bs
        pure (IM.singleton i ok)
    subs <- mapM (uncurry collect) (branchFrames fr p bs)
    pure (foldr (IM.unionWith (&&)) here subs)
  _ -> pure IM.empty

-- ** The current pattern spine

-- | What a node's argument positions mean: for each current position, the
-- original argument index it came from, or 'Nothing' for a variable an
-- earlier split introduced (a constructor field).
--
-- The convention is Agda's own, read off @splitC@
-- (@TypeChecking\/CompiledClause\/Compile.hs@): splitting position @n@ with a
-- constructor of arity @k@ rewrites the pattern list @ps0 ++ [p] ++ ps1@ to
-- @ps0 ++ qs ++ ps1@ — the field variables take the split position's place
-- and everything after it shifts by @k-1@. A literal branch drops the
-- position outright; the catch-all leaves the list untouched.
newtype Frame = Frame [Maybe Int]

-- | At the root, position @i@ /is/ argument @i@. Length comes from the
-- clauses' own pattern list (the list @compileClauses@ was handed), with the
-- deepest position the tree mentions as a floor.
initialFrame :: [Clause] -> CompiledClauses -> Frame
initialFrame cls cc = Frame (map Just [0 .. n - 1])
  where
    n = max (maxPos cc + 1)
            (maybe 0 (length . namedClausePats) (listToMaybe cls))
    maxPos :: CompiledClauses -> Int
    maxPos = \case
      Case k bs -> maximum (unArg k : map maxPos (toList bs))
      _         -> 0

originalOf :: Frame -> Int -> Maybe Int
originalOf (Frame m) p = case drop p m of
  (x : _) -> x
  []      -> Nothing

-- | The frame each branch's subtree lives in, paired with that subtree.
branchFrames :: Frame -> Int -> Case CompiledClauses -> [(Frame, CompiledClauses)]
branchFrames (Frame m) p bs =
  [ (Frame (before ++ replicate (arity wa) Nothing ++ after), content wa)
  | wa <- M.elems (conBranches bs) ++ [ wa' | Just (_, wa') <- [etaBranch bs] ]
  ]
    ++ [ (Frame (before ++ after), sub) | sub <- M.elems (litBranches bs) ]
    ++ [ (Frame m, sub) | Just sub <- [catchallBranch bs] ]
  where
    (before, rest) = splitAt p m
    after          = drop 1 rest

-- ** Collapsibility of one split

-- | The @Case@ shapes v1 can express: no copatterns, no literal branches, no
-- eta-expansion. 'collapsible' and 'viewCollapsed' must reject exactly the
-- same set — were they to drift, 'collapsible' could accept a split whose
-- branches 'viewCollapsed' silently cannot express (or the reverse), so the
-- rule lives in one place.
supportedCase :: Case c -> Bool
supportedCase bs =
  not (projPatterns bs) && null (litBranches bs) && isNothing (etaBranch bs)

-- | Is the split at current position @p@ decorative — every branch computing
-- the same thing, none of them looking at the matched value?
--
-- Each branch is re-expressed in the /collapsed/ context (the split position
-- deleted, no fields added) and the results compared. The branch kinds differ
-- only in how many context variables sit at the split position, which is what
-- lets one rule cover them all:
--
--   * a constructor branch of arity @k@ has the @k@ field variables there;
--   * the catch-all keeps the matched variable itself, so @k = 1@ — and
--     "does not look at the fields" becomes "does not look at the matched
--     value", which is exactly the right condition for it;
--   * a literal branch has nothing there (@k = 0@) — not reached in v1, which
--     skips nodes carrying literal branches.
--
-- Every branch must yield a view: a branch this pass cannot express must
-- /reject/ the split, never quietly shrink the comparison to a
-- trivially-equal singleton.
collapsible :: Int -> Case CompiledClauses -> TCM Bool
collapsible p bs
  | not (supportedCase bs)      = pure False
  | M.null (conBranches bs)     = pure False
  | not sameView                = pure False
  | otherwise                   = plainDatatype (M.keys (conBranches bs))
  where
    branchSlabs =
      [ (arity wa, content wa) | wa <- M.elems (conBranches bs) ]
        ++ [ (1, sub) | Just sub <- [catchallBranch bs] ]
    sameView = case traverse (\ (k, sub) -> viewCollapsed (Slab p k) sub) branchSlabs of
      Just (v : vs) -> all (== v) vs
      _             -> False

-- | Every listed constructor belongs to one plain, non-indexed @data@ type.
-- A @Record@ (eta, and its "constructors" behave differently), an indexed
-- family, or a constructor whose parent cannot be read is a skip.
plainDatatype :: [QName] -> TCM Bool
plainDatatype [] = pure False
plainDatatype cs = do
  parents <- mapM parentOf cs
  pure $ case parents of
    (Just d : rest) -> all (== Just d) rest
    _               -> False
  where
    parentOf c = do
      cdef <- getConstInfo c
      case theDef cdef of
        Constructor{ conData = d } -> do
          ddef <- getConstInfo d
          pure $ case theDef ddef of
            Datatype{ dataIxs = 0 } -> Just d
            _                       -> Nothing
        _ -> pure Nothing

-- ** Re-expressing a branch in the collapsed context

-- | The variables a collapse has to delete from a branch's context:
-- @Slab pos size@ — @size@ variables starting at pattern position @pos@.
-- Deliberately no context length: it is read off each @Done@ leaf instead
-- (see 'viewCollapsed'), so no arithmetic can drift on the way down.
data Slab = Slab !Int !Int

-- | A branch subtree, canonicalised for comparison: positions collapsed,
-- bodies re-indexed into the common context, and everything that is not
-- semantics dropped — name suggestions, and on 2.9 the originating clause
-- number and recursion flag, all of which differ between branches that are
-- otherwise identical. That is the trap the design note flagged: comparing
-- @Done@ nodes whole finds nothing.
data View
  = VCase !Int ![(QName, Int, View)] !(Maybe View)
  | VBody !Term
  deriving (Eq)

-- | 'Nothing' when the subtree cannot be expressed without the slab: it
-- splits on a slab variable, mentions one in a body, or contains a shape v1
-- does not handle (@Fail@, literal, eta, copattern).
viewCollapsed :: Slab -> CompiledClauses -> Maybe View
viewCollapsed (Slab pos size) cc = case cc of
  Case n bs
    | not (supportedCase bs)      -> Nothing
    | q >= pos && q < pos + size  -> Nothing  -- splits on a slab variable
    | otherwise -> do
        cons <- mapM branch (M.toAscList (conBranches bs))
        cat  <- traverse (viewCollapsed (slabUnder q 1)) (catchallBranch bs)
        pure (VCase (collapsePos q) cons cat)
    where
      q = unArg n
      branch (c, wa) = do
        v <- viewCollapsed (slabUnder q (arity wa)) (content wa)
        pure (c, arity wa, v)
      -- A nested split removes the variable at @q@ and puts @k@ in its place,
      -- so the slab keeps its identity but can move: a split *before* the
      -- slab shifts it by @k-1@; one *after* it leaves it where it is.
      slabUnder q' k
        | q' < pos  = Slab (pos - 1 + k) size
        | otherwise = Slab pos size
      collapsePos q'
        | q' < pos  = q'
        | otherwise = q' - size
  _ -> do
    (ctxLen, b) <- ccDone cc
    -- Positions count from the left, de Bruijn indices from the right, so the
    -- slab occupies indices [ctxLen-pos-size .. ctxLen-1-pos]. @ctxLen@ is the
    -- leaf's own bound-variable count — every pattern at a leaf is a variable
    -- (the dot-pattern guard in 'matchConstantOf' is what buys that), so it is
    -- the context size, and nothing has to be tracked down the tree.
    let below = ctxLen - pos - size
    if any (`freeIn` b) [below .. ctxLen - 1 - pos]
      -- Check before substituting: 'strengthenS' with 'impossible' throws on a
      -- variable that is actually used.
      then Nothing
      else Just (VBody (applySubst (liftS below (strengthenS impossible size)) b))

-- ** Pattern shapes that disqualify a whole definition

-- | Does any clause carry a dot pattern or a cubical @IApplyP@? Blunter than
-- the design note's "no dot pattern may mention a variable bound at the
-- position": tracking which pattern variables a dot pattern mentions is
-- exactly the index bookkeeping that went wrong in phase 1, and with the
-- @dataIxs == 0@ gate already in place the extra loss is small. It also
-- underwrites 'viewCollapsed''s leaf-context-size identity.
-- Agda's own generic subpattern fold, so a future nesting @Pattern'@
-- constructor is descended into rather than silently skipped.
clauseHasDotP :: Clause -> Bool
clauseHasDotP = getAny . foldPattern dotOrIApply . namedClausePats
  where
    -- The annotation is load-bearing: it is what resolves @foldPattern@'s
    -- 'PatternLike' instance chain down to the de Bruijn pattern.
    dotOrIApply :: Pattern' DBPatVar -> Any
    dotOrIApply = \case
      DotP{}    -> Any True
      IApplyP{} -> Any True
      _         -> mempty
