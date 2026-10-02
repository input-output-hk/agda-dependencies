{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE RecordWildCards #-}
-- | Dependency analysis: walks each 'Definition' to extract its direct
-- lemma/postulate/data dependencies ('computeDefAD' / 'compileDefAD'),
-- classifies it as 'Defined' / 'Postulate' / 'Hole' ('classifyDefWith'),
-- and filters compiler-generated definitions out of the graph
-- ('ignoreDef'). Node identity is 'nodeKey' / 'hashQName'; edge
-- provenance is 'EdgeProv' / 'tagOneWith'.
module AgdaDeps.Deps
  ( -- * Node identity
    NodeRef(..)
  , mkRef
  , nrSrcLoc

    -- * The per-definition record
  , ADDef(..)
  , withDependencyProvenance
  , DefKind(..)
  , defKindCode
  , DefAccess(..)
  , UnsafeTag(..)
  , ArgUsage(..)
  , ArgBinder(..)
  , BinderHiding(..)

    -- * Module-level soundness escapes and effective options
  , optionEscapes
  , effectiveOptionFlags

    -- * Edge provenance
  , EdgeProv(..)
  , edgeProvCode
  , provTag

    -- * Hashing & node collection
  , nodeKey
  , moduleKey
  , nodeKeyVersion
  , hashQName
  , collectAllQNames
    -- ** QName-level identity (producer-side: live interface QNames)
  , nodeKeyOfQ
  , moduleKeyOfQ

    -- * Building 'ADDef's (the backend's @compileDef@ hook)
  , compileDefAD

    -- * Silent (non-interaction) unsolved metas
  , unsolvedInterfaceLines
  , liveSilentMetaLines

    -- * Post-passes over the collected defs
  , contractIgnoredEdges
  , addInstanceMethodEdges
  , partiallyAppliedSet

    -- * Side channels: one reset for all of them
  , IgnoredEdgeMap
  , UnsaturatedMap
  , MethodProviderMap
  , SideChannels(..)
  , readSideChannels
  , readUnsaturatedRefs
  , sideChannelDelta
  , mergeSideChannels
  , resetSideChannels
  ) where

import Prelude hiding ( foldl' )
import Control.Monad ( filterM, unless, when )
import Control.Monad.IO.Class ( MonadIO(liftIO) )
import Data.Binary ( Binary )
import qualified Data.Binary as B
import Data.IORef ( IORef, modifyIORef', newIORef, readIORef, writeIORef )
import Data.Containers.ListUtils ( nubOrd )
import Data.List ( foldl', isInfixOf, isPrefixOf, sort )
import Data.Maybe ( fromMaybe, isJust, mapMaybe, maybeToList )
import Data.Map.Strict ( Map )
import qualified Data.Map.Strict as M
import qualified Data.IntMap.Strict as IM
import qualified Data.IntSet as IS
import Data.Set ( Set )
import qualified Data.Set as S
import Data.Sequence ( Seq, (|>) )
import qualified Data.Sequence as Seq
import Data.Word ( Word8, Word32, Word64 )
import System.Environment ( lookupEnv )
import System.IO ( hPutStrLn, stderr )
import System.IO.Unsafe ( unsafePerformIO )

import Agda.Utils.Hash ( hashString )
import Agda.Utils.Lens ( (^.) )

import Agda.Syntax.Abstract.Name ( QName, nameBindingSite )
import Agda.Syntax.Common
  ( unArg, namedThing, Hiding(..), getHiding, notVisible )
import Agda.Syntax.Internal
  ( qnameName, qnameModule, MetaId, Clause(..)
  , Pattern'(..), DBPatVar(dbPatVarIndex)
  , Term(Pi, Def), Type, Telescope, Dom
  , arity, isProperApplyElim
  , telToList, unAbs, absName, unDom, unEl
  , Suggest(suggestName)
  )
import Agda.Syntax.Internal.Generic ( foldTerm )
import Agda.Syntax.Internal.Names ( namesIn )
import Agda.Syntax.Internal.MetaVars ( allMetasList )
import Agda.Syntax.Position ( rStart, posLine, posPos, rangeFile, rangeFilePath )
import Agda.Utils.FileName ( filePath )
import Agda.Utils.Size ( size )
import qualified Agda.Utils.Maybe.Strict as Strict

-- Silent-unsolved-meta detection: the split between an honest interaction
-- @?@ and a silently-inserted unsolved meta is read from each interface's
-- stored highlighting ('iHighlighting'): Agda's @warningHighlighting@ marks
-- 'UnsolvedMetaVariables' ranges with the 'UnsolvedMeta' aspect and
-- 'UnsolvedConstraints' with 'UnsolvedConstraint', while
-- 'UnsolvedInteractionMetas' produce no aspect. Identical modules/fields on
-- Agda 2.8 and 2.9 — no CPP.
import Agda.Interaction.Highlighting.Precise ( HighlightingInfo )
import qualified Agda.Interaction.Highlighting.Range as HR
import qualified Agda.Utils.RangeMap as RangeMap
import Agda.Syntax.Common.Aspect
  ( Aspects(otherAspects), OtherAspect(UnsolvedMeta, UnsolvedConstraint) )
import qualified Data.HashMap.Strict as HMap
import qualified Data.Text.Lazy as TL

import Agda.Syntax.Common.Pretty ( Pretty(..), prettyShow, render, (<+>), vcat, pshow )

import Agda.TypeChecking.Monad
  ( TCM
  , Definition(..), Defn(..)
  , Projection(..)
  , pattern Function, funWith, funExtLam, funInline, funIsKanOp, funClauses
  , funProjection, funTerminates
  , pattern Primitive, primClauses
  , pattern PrimitiveSort
  , pattern Axiom
  , pattern DataOrRecSig
  , pattern Datatype
  , pattern Record
  , pattern Constructor
  , Polarity(..)
  )
-- Argument-usage analysis ('argUsageOf') reads two fields Agda already
-- fills in during positivity/polarity checking. 'Polarity' rides in on the
-- re-export chain above (Monad -> Monad.Base -> Monad.Base.Types), but
-- 'Occurrence' is imported plainly into Monad.Base and NOT re-exported, so
-- it needs its own import. Same modules and fields on 2.8 and 2.9 — no CPP.
import Agda.TypeChecking.Positivity.Occurrence ( Occurrence(..) )
-- 'defInstance' comes in via 'Agda.TypeChecking.Monad' alongside 'Defn'.
import Agda.TypeChecking.Monad.Base
  ( Interface, miInterface, iHighlighting, iSignature, iSource
  , sigDefinitions )
import Agda.TypeChecking.Monad.Imports ( getVisitedModules )
import Agda.TypeChecking.Monad.MetaVars
  ( lookupMetaInstantiation, isOpenMeta, getInteractionMetas, getUnsolvedMetas )
import Agda.TypeChecking.Monad.Context ( addContext )
import Agda.TypeChecking.Monad.Options ( withShowAllArguments )
import Agda.TypeChecking.Monad.Signature ( droppedPars, getConstInfo, lookupSection )
import Agda.TypeChecking.Pretty ( prettyTCM )
-- @--erasure@ is read off each interface's /effective/ options
-- ('iOptionsUsed'), which fold in the command line and the @.agda-lib@
-- @flags:@ — see 'effectiveOptionFlags'. Same accessor on 2.8 and 2.9.
import Agda.Interaction.Options ( PragmaOptions, optErasure )
import Agda.TypeChecking.Reduce ( normalise )
import Agda.TypeChecking.Free ( freeIn )
import Agda.TypeChecking.Telescope ( telView )
import Agda.TypeChecking.Substitute ( TelV(..), absBody )

import Agda.Compiler.Backend ( IsMain )

import AgdaDeps.Options ( Options(..), DefState(..), isExcludedModule )
import AgdaDeps.MatchConstant ( matchConstantAnalysable, matchConstantOf )
import AgdaDeps.TypeExport (captureTypeDefinition)
import AgdaDeps.TermCanon ( subtermHashes )
import AgdaDeps.NodeKey
  ( bindingLineOfQ, moduleKeyOfQ, nodeKeyFromPretty, nodeKeyOfQ )
import AgdaDeps.Util ( fromCode, isWithFun )

-- | Structural classification of a definition, derived from its
-- 'Defn' shape (e.g. record-field projections vs. regular functions).
data DefKind
  = DKFunction
  | DKProjection
  | DKDatatype
  | DKRecord
  | DKConstructor
  | DKPostulate
  | DKPrimitive
  | DKOther
  deriving (Show, Eq, Enum, Bounded)

-- | Stable numeric code shared by packed output and the fragment cache.
defKindCode :: DefKind -> Word8
defKindCode DKFunction    = 0
defKindCode DKProjection  = 1
defKindCode DKDatatype    = 2
defKindCode DKRecord      = 3
defKindCode DKConstructor = 4
defKindCode DKPostulate   = 5
defKindCode DKPrimitive   = 6
defKindCode DKOther       = 7

-- | Whether a definition is declared @private@ in its defining module.
-- 'Nothing' on 'ADDef._access' means it could not be determined and is
-- treated as \"public\".
data DefAccess
  = AccPrivate
  | AccPublic
  deriving (Show, Eq, Enum, Bounded)

-- | A soundness escape a definition uses /directly/. Orthogonal to
-- 'DefState' (a 'Defined' def can carry escapes). Emitted as the optional
-- per-def @unsafe@ wire array, omitted when empty.
--
--   * 'UNonTerminating' — @{-# NON_TERMINATING #-}@ (@funTerminates = Just False@).
--   * 'UTrustMe' — body/type references @primTrustMe@.
--
-- No @{-# TERMINATING #-}@ tag: the ordinary termination checker also sets
-- @funTerminates = Just True@, so it's indistinguishable from a normal proof.
data UnsafeTag
  = UNonTerminating
  | UTrustMe
  deriving (Show, Eq, Ord, Enum, Bounded)

-- | Arguments a definition never actually uses, read straight off the
-- analysis Agda already ran for positivity\/polarity checking. Nothing is
-- computed here beyond two field reads, a zip and a walk of the type's
-- 'Pi' spine ('piSpine', which the arity count pays for anyway) — see
-- 'argUsageOf'.
--
-- Both index lists are ascending /telescope positions, implicits
-- included/, over the definition's __own reduced telescope__: the
-- elaborated spine with the enclosing section's prefix subtracted.
--
-- __That is not the signature line, and can be longer than it.__
-- @dependentPolarity@ walks a /reduced/ spine, so a type whose codomain
-- only becomes a function after unfolding a definition contributes
-- positions no binder on the source line corresponds to
-- (@f : (A : Set) -> Tracer A@ with @Tracer A = ⋯ -> ⋯ -> A -> A@ has
-- 'auArity' 4 off one written binder). Those positions carry real
-- information — "the proof never inspects this hypothesis" — so they are
-- reported, and 'auSyntacticArity' is what /labels/ them rather than
-- dropping them. See 'argUsageOf' for the section-prefix half of the
-- story.
data ArgUsage = ArgUsage
  { auRemovable :: ![Int]
    -- ^ @Unused@ /and/ 'Nonvariant', /and/ deletable ('guardDeletable'):
    -- the binder and the argument at every call site can go.
  , auRemovableRequires :: ![(Int, [Int])]
    -- ^ Which /other/ 'auRemovable' positions must be removed alongside a
    -- given one, transitively. Ascending by key; only positions with a
    -- non-empty requirement appear, so this is empty whenever every
    -- removal stands alone (always, for a single-index verdict). See
    -- 'removableRequiresOf'.
  , auOccursInBody :: ![Int]
    -- ^ The 'auRemovable' positions whose variable the /elaborated body/
    -- still mentions — so deleting the binder is not a local edit. See
    -- 'occursInBodyOf'. Ascending, a subset of 'auRemovable'.
  , auErasable  :: ![Int]
    -- ^ @Unused@ but not 'Nonvariant': used only in types, so an @\@0@
    -- candidate rather than a removal.
  , auArity     :: !Int
    -- ^ Reduced-telescope positions this verdict ranges over; every index
    -- in either list is @< auArity@.
  , auSyntacticArity :: !Int
    -- ^ How many of those positions are on the __signature line__: the
    -- length of the syntactic 'Pi' spine ('piSpine'), section prefix
    -- subtracted. Always @<= auArity@; a position @>= auSyntacticArity@
    -- exists only after unfolding and has no binder to strike out. This
    -- is the same boundary an absent 'auBinders' entry marks, stated as a
    -- number so a consumer need not infer it from a gap.
  , auPartiallyApplied :: !Bool
    -- ^ Is this definition referenced somewhere in the graph with fewer
    -- arguments than its arity? Then its arity /is/ its interface and no
    -- position is really removable, whatever the polarity says. Unlike
    -- every other field this is not a property of the definition alone,
    -- so the producer cannot know it until every module is compiled: it
    -- is 'False' here and back-filled at emission time from
    -- 'partiallyAppliedSet'.
  , auBinders   :: ![(Int, ArgBinder)]
    -- ^ How each /reported/ position is written, for a report line that
    -- says @argument 0 ({A : Set})@ rather than @argument 0@. Sparse and
    -- ascending: only positions appearing in 'auRemovable' or
    -- 'auErasable', and only those the syntactic spine actually reaches
    -- (see 'piSpine') — a position with no entry is not a claim that it
    -- is explicit.
  } deriving (Show, Eq)

-- | Surface facts about one binder, read off the syntactic 'Pi' spine of
-- the definition's type: enough to name it in a report line without the
-- consumer re-parsing the source signature.
--
-- The sibling @--with-signatures@ @type@ field carries the whole reified
-- type, but it is /not/ re-indexed onto the definition's own binders, so a
-- consumer cannot slice a position out of it. 'abType' is that slice, cut
-- at the right index.
data ArgBinder = ArgBinder
  { abHiding :: !BinderHiding
    -- ^ Always known: a spine position has an argument info.
  , abName   :: !(Maybe String)
    -- ^ The binder name /as Agda spells it/, or 'Nothing' when the spine
    -- has none (@Nat -> Nat@ binds nothing to name). Never guessed:
    -- Agda's own 'suggestName' is what maps its @\"_\"@ placeholder to
    -- 'Nothing'.
    --
    -- A name containing a @.@ (e.g. @\"P.A\"@) is a binder Agda /inserted/
    -- by generalising a @variable@ declaration — specifically one of the
    -- mentioned variable's own dependencies. A source binder name can
    -- never contain @.@, so that is a sound test rather than a guess, and
    -- it is worth making: such a position has no binder on the signature
    -- line to delete or annotate. It is reported as-is because that is
    -- exactly the name Agda's own printer uses (it appears in the sibling
    -- @--with-signatures@ @type@ string too), so dropping it would lose
    -- the consumer's only signal. Positions for a generalised variable
    -- that the signature /mentions/ carry its plain name and are
    -- indistinguishable from a written binder here.
  , abType   :: !(Maybe String)
    -- ^ The binder's domain, reified to one line by 'prettyTCM' in the
    -- context of the binders before it — under @--with-signatures@ only,
    -- 'Nothing' otherwise (see 'attachBinderTypes').
    --
    -- The /type/ is what names a binder in a proof development: premises
    -- are routinely written unnamed (@∙ premise₁@ bullet style), and on
    -- the corpus this feature was first measured against, 63 of 94 mapped
    -- @removable@ positions had no name at all. It is also what separates
    -- a dead /hypothesis/ (the finding a prover cares about) from a dead
    -- level or datum.
    --
    -- Reified internal syntax, not source text: instance and implicit
    -- arguments Agda solved are shown as it prints them. Never
    -- normalised — @--normalise-signatures@ governs the whole-type
    -- @type@ field only, because reducing a domain destroys exactly the
    -- head symbol that makes it recognisable.
  } deriving (Show, Eq)

-- | How a binder is written, hence how a call site passes it. The
-- distinction a report line cannot omit: \"argument 0\" of
-- @{a : Set} -> List a -> List a@ reads as the first @List@ to almost
-- anyone, and it is the @{a : Set}@.
data BinderHiding
  = BHExplicit
  | BHImplicit
  | BHInstance
  deriving (Show, Eq, Enum, Bounded)

-- | Per-argument \"never used\" verdict for a definition, or 'Nothing'
-- when there is nothing to report (the overwhelmingly common case, so it
-- costs one constructor tag).
--
-- __Indices are over the definition's own binders.__ Agda prepends the
-- enclosing section's telescope to every definition inside it, so for a
-- @where@ helper or a def in a parametrised @module M (n : Nat) where@,
-- the elaborated telescope 'defPolarity' \/ 'defArgOccurrences' index is
-- /longer/ than the signature as written. A @where@ helper that ignores
-- its parent's arguments would otherwise report those parent binders as
-- \"removable\" — binders that do not exist on its source line and cannot
-- be deleted from it. So the raw verdict is shifted down by the section
-- telescope size and anything landing in that prefix is dropped, leaving
-- exactly the positions a reader could strike off the signature.
--
-- The 'lookupSection' is a plain state read (two 'Map' lookups, no
-- reduction), gated on there being something to report. Do not read that
-- gate as \"rare\": 'auErasable' fires on the ubiquitous @{A : Set}@
-- implicit used only in later types, so roughly a quarter of definitions
-- reach it. Only 'auRemovable' is rare.
--
-- Agda runs this analysis for /every/ mutual block, plain functions
-- included (@Rules.Decl.checkPositivity_@ → @computePolarity@), and
-- serialises both lists into the interface, so the verdict is available
-- cross-module with no re-checking. The two fields compose
-- interprocedurally — an occurrence \"as argument @i@ of @g@\" is composed
-- with @g@'s own stored occurrence for that argument — so an argument
-- threaded into a @where@-helper that discards it reads @Unused@ in the
-- parent too. 'computePolarity' also post-processes with
-- @dependentPolarity@, demoting to 'Invariant' any argument a later
-- relevant argument's type (or the codomain) depends on, which is what
-- keeps type-dependent arguments out of 'auRemovable'.
--
-- Scope, phase 1 — only non-projection-like 'Function's:
--
-- * Projection(-like) functions and constructors drop their parameters
--   from /both/ lists, so the indices are shifted off the telescope by
--   @droppedPars@. Testing @droppedPars == 0@ is exactly that condition;
--   a later phase wanting these rows can add the offset back rather than
--   emitting a misaligned one.
-- * @Axiom@ \/ @Primitive@ have no body for an argument to go unused in,
--   and for @Datatype@ \/ @Record@ the polarity signal means something
--   else: @enablePhantomTypes@ deliberately purges 'Nonvariant' to
--   'Covariant' on parameters so phantom types keep working.
--
-- Padding: the classifying pass stops when /either/ list runs out, which
-- implements the rule that any index past the end of one counts as used. That
-- is deliberately more conservative than Agda's own @getArgOccurrence@,
-- which falls back to a @telView@-driven computation for an out-of-range
-- index; silence is the right answer for a missing entry, and we do not
-- want that cost here.
argUsageOf :: Options -> Definition -> TCM (Maybe ArgUsage)
argUsageOf opts def = do
  res <- phase1
  -- Runs for *every* definition, not just those with a phase-1 verdict: a
  -- match-constant position is exactly the case phase 1 says nothing about,
  -- so gating the probe on a phase-1 finding would measure almost nothing.
  when matchConstantProbe $ probeMatchConstant def res
  pure res
  where
    phase1 = case rawArgUsage def of
      Nothing -> pure Nothing
      -- An erasable-only verdict makes no deletion claim, so it needs neither
      -- the deletability guard nor a telescope: no 'telView' is paid for the
      -- 96% of findings that are erasable-only.
      Just au0 | null (auRemovable au0) -> finish au0
               | otherwise -> do
        TelV tel core <- telView (defType def)
        let guarded = guardDeletable [piSpineOf (defType def), telSpine tel core] au0
            -- Reads clause patterns already in hand; only ever runs for a def
            -- that survived the guard with a removable position.
            withBody = guarded
              { auOccursInBody =
                  occursInBodyOf (theDef def) (auRemovable guarded) }
        finish withBody
    -- Nothing survived: report nothing rather than an object of empty lists.
    -- Binder types are attached in RAW spine space and then ride through the
    -- shift, so 'dropSectionPrefix' stays the single home of the re-indexing.
    finish au
      | null (auRemovable au) && null (auErasable au) = pure Nothing
      | otherwise = do
          typed <- attachBinderTypes opts def au
          k     <- sectionPrefixSize def
          pure (dropSectionPrefix k typed)

-- | Phase-2 measurement scaffold, off unless @AGDA_DEPS_MATCH_CONSTANT@ is
-- set in the environment. Deliberately a stderr dump rather than a wire
-- field: the match-constant analysis (see "AgdaDeps.MatchConstant") walks a
-- case tree per definition, which is a real cost, and the consumer asked for
-- measured yield before any wire commitment.
--
-- Two line kinds, so a corpus run can be counted with @grep@:
--
-- > MC-CAND <name>                                  -- in the population
-- > MC-HIT  <name> mc=[…] rem=[…] era=[…] arity=n   -- has a finding
--
-- @rem@ \/ @era@ are the /phase-1/ verdict for the same definition, so
-- "already reported for some other position" is a property of one line.
matchConstantProbe :: Bool
matchConstantProbe =
  unsafePerformIO (isJust <$> lookupEnv "AGDA_DEPS_MATCH_CONSTANT")
{-# NOINLINE matchConstantProbe #-}

-- | Run the analysis and dump it. Positions go through the same
-- 'shiftOntoOwnBinders' as phase 1's, so the numbers reported are the ones a
-- wire field would carry.
probeMatchConstant :: Definition -> Maybe ArgUsage -> TCM ()
probeMatchConstant def mau =
  when (matchConstantAnalysable def) $ do
    raw <- matchConstantOf def
    k   <- sectionPrefixSize def
    let mc   = shiftOntoOwnBinders k raw
        name = nodeKeyOfQ (defName def)
    liftIO $ hPutStrLn stderr $ "MC-CAND " ++ name
    unless (null mc) $ liftIO $ hPutStrLn stderr $
      "MC-HIT " ++ name ++ " mc=" ++ show mc
        ++ " rem=" ++ show (maybe [] auRemovable mau)
        ++ " era=" ++ show (maybe [] auErasable mau)
        ++ " arity=" ++ show (maybe (-1) auArity mau)

-- | One view of a type's @Pi@ spine: the domains by position, how many there
-- are, and the final codomain. Two views are consulted for every occurrence
-- question (see 'deletableRemovable'), because neither alone is sound:
--
--   * the __syntactic__ spine ('piSpineOf') is the type as written, which is
--     what a source deletion has to respect — but it stops at a type that
--     only becomes a function after unfolding;
--   * the __reduced__ spine (Agda's @telView@) sees through such a type — but
--     reduction can /erase/ an occurrence entirely: a codomain @Irrel n p@
--     whose @Irrel@ ignores its second argument reduces to @Wrap n@, and the
--     binder the source still mentions has vanished.
--
-- A position is rejected if /either/ view finds an occurrence, which is the
-- conservative direction: it can only shrink the removable set.
data Spine = Spine
  { spDoms   :: !(IM.IntMap Type)  -- ^ domain at each position
  , spHidden :: !IS.IntSet
    -- ^ Positions whose binder is implicit or instance, hence supplied by
    -- inference rather than by the call site. 'orphanedHidden' is the only
    -- reader: those are the binders a removal elsewhere can strand.
  , spLen  :: !Int
  , spCore :: Type               -- ^ the codomain, under all 'spLen' binders
  }

-- | Build a view from its domains in position order. The one place
-- @spLen == IM.size spDoms@ is established, so the invariant holds by
-- construction for both views rather than in two parallel spellings.
mkSpine :: [Dom Type] -> Type -> Spine
mkSpine ds core = Spine
  { spDoms   = IM.fromList indexed
  , spHidden = IS.fromList [ i | (i, d) <- zip [0 ..] ds, notVisible d ]
  , spLen    = length indexed
  , spCore   = core
  }
  where
    -- One walk: the length is the indexing's, so the two cannot disagree.
    indexed = zip [0 ..] (map unDom ds)

-- | The reduced view, from @telView@'s output.
telSpine :: Telescope -> Type -> Spine
telSpine tel core = mkSpine (map (fmap snd) (telToList tel)) core

-- | The syntactic view: walk the @Pi@ spine of the type as stored, without
-- reducing anything.
--
-- __Descend with 'absBody', never @unAbs@.__ A non-dependent @Pi@ is stored as
-- @NoAbs@, whose body is /not/ under the binder — @unAbs@ hands it back
-- unshifted, so a walk using it silently mixes two de Bruijn index spaces and
-- every later occurrence test is answered about the wrong variable.
-- @absBody@ is Agda's accessor for exactly this: it @raise@s a @NoAbs@ body by
-- one. (@telView@ is safe for the same reason — @underAbstraction@ goes through
-- @absBody@.) The sibling 'piSpine' may use @unAbs@ because it reads only
-- hiding and names, never an index.
piSpineOf :: Type -> Spine
piSpineOf t0 = mkSpine ds core
  where
    (ds, core) = go t0
    go t = case unEl t of
      Pi d b -> let (rest, c) = go (absBody b) in (d : rest, c)
      _      -> ([], t)

-- | Is the binder at position @i@ free in the codomain of this view?
-- Positions count from the left and de Bruijn indices from the right, so
-- under all @spLen@ binders the binder at @i@ is @spLen-1-i@. A view too
-- short to say anything about @i@ answers 'False' — it casts no veto — which
-- is the same convention 'freeInDomain' uses for a missing domain.
freeInCore :: Spine -> Int -> Bool
freeInCore sp i
  | i >= spLen sp = False
  | otherwise     = freeIn (spLen sp - 1 - i) (spCore sp)

-- | Is the binder at position @i@ free in the domain at position @j@? Inside
-- domain @j@ the binder at @i@ has index @j-1-i@.
freeInDomain :: Spine -> Int -> Int -> Bool
freeInDomain sp i j =
  maybe False (freeIn (j - 1 - i)) (IM.lookup j (spDoms sp))

-- | Is position @i@'s variable free anywhere the removal of @set@ leaves
-- standing — the codomain, or the domain of a later argument that stays?
--
-- The single occurrence question both rules of 'deletableRemovable''s fixpoint
-- ask; they only differ in what they conclude from the answer. For a position
-- /being/ removed an occurrence is fatal (its binder is going, so whatever
-- still mentions it breaks — 'deletableRemovable'). For a hidden position
-- /not/ being removed it is a reprieve, because inference still has somewhere
-- to read the binder from ('orphanedHidden'). Sharing one definition is what
-- keeps them agreeing: they run in the same fixpoint, whose termination
-- argument assumes they measure the same thing.
--
-- Occurrences inside another /removable/ domain do not count: that domain is
-- going too. Keeping that exemption is what makes rule 1 a filter rather than
-- a wrecking ball (see 'deletableRemovable'), and rule 2 needs exactly the
-- same blindness.
freeOutsideRemoval :: Spine -> IS.IntSet -> Int -> Bool
freeOutsideRemoval sp set i =
  freeInCore sp i
    || any (freeInDomain sp i)
           [ j | j <- [ i + 1 .. spLen sp - 1 ], not (j `IS.member` set) ]

-- | Drop the @removable@ positions whose binder cannot actually be deleted,
-- and re-derive everything that depends on the set.
--
-- @removable@ comes from Agda's own verdict, which answers "does the
-- definition's /meaning/ depend on this value" — not "can this binder be
-- deleted". The two come apart for an argument that occurs in the type only at
-- an __irrelevant__ position: @dependentPolarity@ tests occurrence with
-- @relevantInIgnoringSortAnn@, whose @RelevantIn@ monoid /discards/ occurrences
-- under irrelevance (@withVarOcc o x | isIrrelevant o = mempty@,
-- @TypeChecking\/Free.hs@), so such an argument is never demoted to
-- 'Invariant', and @defArgOccurrences@ does not count it either. Both signals
-- are right about their own question; neither is deletability. Reported by the
-- consumer repo; on the standard library it affected 67 of the 145 definitions
-- carrying a @removable@ finding (145 -> 98 defs, 244 -> 142 positions), in
-- three shapes: an irrelevant binder (42); a /relevant/ binder whose only
-- occurrence is at a callee's irrelevant argument position (5 — which no test on
-- the binder itself can see); and an occurrence hidden by /reduction/ (20 — see
-- 'Spine').
--
-- 'auErasable' is untouched: it claims an @\@0@ candidate, not a removal, so
-- occurrences in the type are exactly what it is about.
guardDeletable :: [Spine] -> ArgUsage -> ArgUsage
guardDeletable spines au = au
  { auRemovable         = keep
  , auRemovableRequires = removableRequiresOf keep spines
  , auBinders           = [ b | b@(i, _) <- auBinders au, i `IS.member` reported ]
  }
  where
    keep     = deletableRemovable (auRemovable au) spines
    -- 'auBinders' annotates *reported* positions, so a position the guard
    -- dropped must lose its entry too.
    reported = reportedPositions keep (auErasable au)

-- | The removable positions whose binder can actually be deleted: those whose
-- variable occurs nowhere that survives the deletion.
--
-- The shape is Agda's own @relevantInIgnoringNonvariant@ condition — "ignore
-- the domains of the other 'Nonvariant' arguments, they are going too" — re-run
-- with 'freeIn', which has no relevance filter. So position @i@ is kept unless
-- its variable is free in
--
--   * the codomain, or
--   * the domain of a later position that is __not itself being removed__.
--
-- Occurrences inside another /surviving removable/ domain are fine: that domain
-- goes as well, which is exactly what 'removableRequiresOf' records. Keeping
-- that exemption is what makes this a filter rather than a wrecking ball — a
-- jointly-removable chain like @(X : Set) -> X -> Vec X n -> …@ has its earlier
-- positions free in later removable domains by construction, so a guard without
-- it would reject every multi-index verdict (pinned by @ArgUsage.chain@).
--
-- Hence the fixpoint: rejecting one position can strand an earlier one that
-- only occurred inside it. Iterating to the greatest stable subset is cheap —
-- arities are small and this runs only for a definition that already has a
-- removable finding.
deletableRemovable :: [Int] -> [Spine] -> [Int]
deletableRemovable removable spines = go (IS.fromList removable)
  where
    go !set
      | IS.null doomed = IS.toAscList set
      | otherwise      = go (IS.difference set doomed)
      where
        -- Every spine votes on both rules. Both shrink @set@, so interleaving
        -- them in one fixpoint is what makes them agree: rejecting a position
        -- for either reason resurrects a domain, which can strand an earlier
        -- position (rule 1) or re-solve a hidden binder (rule 2).
        doomed = IS.unions
          [ IS.fromList [ i | i <- IS.toAscList set
                            , freeOutsideRemoval sp set i ]
              `IS.union` orphanedHidden sp set
          | sp <- spines ]

-- | Rule 2 of the fixpoint: the removals that would leave an /earlier/
-- hidden binder unsolvable.
--
-- 'deletableRemovable' asks whether position @i@'s own variable survives the
-- deletion. That is not the whole question. A hidden or instance binder is
-- supplied by inference, and inference has to have somewhere to read it
-- from: @typeOf : {A : Set} -> A -> Set@ has a genuinely unused value
-- argument, and Agda's verdict on it is right — the /meaning/ does not
-- depend on it. Delete it anyway and @{A}@ is unsolvable at every call site,
-- because that argument's domain was its only occurrence. The definition
-- exists to drive inference; its arity is its interface.
--
-- So: for each hidden binder @j@ that is __not itself being removed__, if
-- every occurrence of @j@'s variable is inside a domain that /is/ being
-- removed, reject the removals that hold those occurrences. A binder free
-- nowhere to begin with is left alone (nothing changed for it — a caller was
-- already passing it explicitly).
--
-- Rejecting /every/ position that mentions @j@ is deliberate rather than
-- minimal: @{A : Set} -> A -> A -> Set@ could keep either occurrence and
-- drop the other, but which one is arbitrary, and the shape is rare enough
-- that a rule with no arbitrary choice in it is worth more than the extra
-- finding. Same conservative direction as the guard it joins: this can only
-- shrink the removable set.
--
-- Necessary, not sufficient: a surviving occurrence does not prove the
-- binder is /inferable/ from it (that would be a unification question, not
-- an occurrence one). The consumer repo asked for exactly this filter after
-- an accepted @removable@ verdict broke a build.
orphanedHidden :: Spine -> IS.IntSet -> IS.IntSet
orphanedHidden sp set = IS.unions (map blamed (IS.toAscList (spHidden sp)))
  where
    blamed j
      -- j is going too, so it needs no solution; or it is still readable
      -- somewhere the deletion leaves standing.
      | j `IS.member` set             = IS.empty
      | freeOutsideRemoval sp set j   = IS.empty
      -- Everything that mentioned j is being removed. Blame all of it — which
      -- is also 'IS.empty' when j occurred nowhere to begin with, the binder a
      -- caller was already passing explicitly.
      | otherwise = IS.fromList
          [ i | i <- [ j + 1 .. spLen sp - 1 ]
              , i `IS.member` set
              , freeInDomain sp j i ]

-- | Which other removable positions must go with each one.
--
-- If binder @i@ is deleted, every part of the type that still mentions its
-- variable breaks. 'deletableRemovable' has already rejected @i@ if its
-- variable occurs in the codomain or in a surviving argument's domain, so the
-- only place left for it is the domain of another __removable__ argument later
-- in the telescope. So @i@ requires @j@ whenever @j > i@ is removable and
-- @i@'s variable is free in @j@'s domain — then transitively, since removing
-- @j@ drags in whatever @j@ requires.
--
-- (Before the deletability guard this reasoning leaned on 'computePolarity'
-- having ruled out every other position, which is true only up to relevance —
-- the hole that produced the irrelevant-argument defect. The guard now
-- establishes the premise directly.)
--
-- The relation is forward-only (@j > i@ always), which is what makes it a
-- DAG and lets the closure be a plain DFS with no cycle check. It also
-- means a shifted-away section prefix can never be the target of a
-- surviving requirement, so 'dropSectionPrefix' can renumber safely.
--
-- Occurrence uses 'freeIn' rather than Agda's own
-- @relevantInIgnoringSortAnn@: erring towards /more/ requirements only ever
-- makes a suggested removal larger, never unsound.
removableRequiresOf :: [Int] -> [Spine] -> [(Int, [Int])]
removableRequiresOf removable spines =
  [ (i, reqs) | i <- removable, let reqs = closure i, not (null reqs) ]
  where
    -- Direct requirements: j's domain still mentions the variable bound at
    -- i, in *either* view (see 'Spine' — the reduced one can erase the
    -- occurrence, and under-reporting a requirement is what strands a
    -- binder). Inside domain j, the binder at i has de Bruijn index j-1-i.
    -- 'removable' is ascending, so 'dropWhile' is the later-positions
    -- filter. Materialised once per source position: 'closure' revisits
    -- these sets, and each entry costs a 'freeIn' walk of a domain.
    direct = IM.fromList
      [ (i, IS.fromList
              [ j
              | j <- dropWhile (<= i) removable
              , any (\ sp -> freeInDomain sp i j) spines
              ])
      | i <- removable ]
    edges i = IM.findWithDefault IS.empty i direct
    -- Seeded with i's direct targets rather than i itself: the relation
    -- only points forward, so i can never be reached back and needs no
    -- removing from the result.
    closure i = IS.toAscList (go IS.empty (IS.toAscList (edges i)))
      where
        go !seen []       = seen
        go !seen (x : xs)
          | x `IS.member` seen = go seen xs
          | otherwise          = go (IS.insert x seen) (IS.toAscList (edges x) ++ xs)

-- | How many leading binders Agda prepended to this definition from its
-- enclosing section — the ones that are not this definition's to remove.
sectionPrefixSize :: Definition -> TCM Int
sectionPrefixSize def = size <$> lookupSection (qnameModule (defName def))

-- | Drop the indices pointing into a @k@-binder section prefix and re-base
-- the rest onto the definition's own binders.
--
-- The single home of that rule: 'dropSectionPrefix' and the phase-2 probe
-- must shift identically, or the probe's numbers drift from phase 1's while
-- both still look plausible.
shiftOntoOwnBinders :: Int -> [Int] -> [Int]
shiftOntoOwnBinders k = map (subtract k) . filter (>= k)

-- | The positions that carry an 'auBinders' entry: exactly the reported ones.
-- Shared between the raw verdict and the guard so a name annotation can never
-- desynchronise from the verdict it annotates.
reportedPositions :: [Int] -> [Int] -> IS.IntSet
reportedPositions rm er = IS.fromList rm `IS.union` IS.fromList er

-- | Re-index an 'ArgUsage' from the elaborated telescope to the
-- definition's own, dropping the @k@ section-inherited leading binders
-- and everything that pointed into them. Yields 'Nothing' when nothing
-- survives, so a @where@ helper that only \"wastes\" its parent's
-- arguments correctly reports nothing at all.
dropSectionPrefix :: Int -> ArgUsage -> Maybe ArgUsage
dropSectionPrefix k au@(ArgUsage rm rq ob er ar sa pa bs)
  | k <= 0                = Just au
  | null rm' && null er'  = Nothing
  | otherwise             = Just (ArgUsage rm' rq' ob' er'
                                           (max 0 (ar - k)) (max 0 (sa - k))
                                           pa bs')
  where
    shift = shiftOntoOwnBinders k
    rm'   = shift rm
    ob'   = shift ob
    er'   = shift er
    -- Requirements point forward, so a surviving key's targets all survive
    -- too; a key inside the prefix goes with its binder.
    rq'   = [ (i - k, shift js) | (i, js) <- rq, i >= k ]
    -- Names must be re-indexed with the verdict they annotate, or they
    -- reintroduce exactly the misalignment this shift exists to fix.
    bs'   = [ (i - k, b) | (i, b) <- bs, i >= k ]

-- | The raw verdict, indices over the /elaborated/ telescope. Pure: two
-- field reads, a zip and a walk of the type's 'Pi' spine. 'argUsageOf'
-- wraps it to re-index onto the definition's own binders.
rawArgUsage :: Definition -> Maybe ArgUsage
rawArgUsage def@Defn{..}
  | not analysable                  = Nothing
  | null removable && null erasable = Nothing
  -- Requirements need a reducing 'telView', body occurrences need the
  -- guarded set, binder types need a context, and 'auPartiallyApplied' needs
  -- the whole corpus; 'argUsageOf' and the emitter fill those in.
  | otherwise = Just (ArgUsage removable [] [] erasable
                               telArity synArity False binders)
  where
    analysable = case theDef of
      Function{} -> droppedPars def == 0
      _          -> False
    -- One strict pass: the two stored lists are zipped, classified and
    -- counted together. This runs for every non-ignored function, so it
    -- allocates no intermediate tuples and walks neither list twice.
    -- Stopping when *either* list runs out IS the padding rule — any
    -- position past the end of one of them counts as used.
    (removable, erasable, analysed) = classify 0 [] [] defArgOccurrences defPolarity
    classify !i !rm !er (o : os) (p : ps) = case o of
      Unused | p == Nonvariant -> classify (i + 1) (i : rm) er os ps
             | otherwise       -> classify (i + 1) rm (i : er) os ps
      _                        -> classify (i + 1) rm er os ps
    classify !i !rm !er _ _ = (reverse rm, reverse er, i)
    -- The syntactic 'Pi' spine (no reduction), widened to cover every
    -- analysed position: 'dependentPolarity' walks a *reduced* spine, so
    -- the stored lists can outrun the unreduced one. The 'max' keeps
    -- @index < auArity@ true without paying for a reduction here.
    spine    = piSpine defType
    synArity = length spine
    telArity = max synArity analysed
    -- Reported positions only, in one pass over the spine we already walk
    -- for 'telArity' — so names cost what the count costs. Positions past
    -- the end of the spine (the outrun case above) simply get no entry.
    -- The two verdict lists are disjoint by construction (each index is
    -- classified once) and each ascending, so this stays ascending.
    reported = reportedPositions removable erasable
    binders  = [ (i, b) | (i, b) <- zip [0 ..] spine, i `IS.member` reported ]

-- | The definition's binders as /written/, read off the syntactic 'Pi'
-- spine of its type. Pure and __non-reducing__: hiding is in the domain's
-- argument info and the name in the 'Abs', both sitting on the very spine
-- Agda's own @arity@ counts — so this returns the binders for what the
-- count already cost. A 'telView' would be the wrong tool twice over: it
-- reduces, and a source binder name is not a fact reduction can reveal.
--
-- The result can be __shorter__ than the stored polarity \/ occurrence
-- lists, which 'dependentPolarity' derived from a /reduced/ spine (a type
-- that only becomes a function after unfolding a definition). A position
-- past the end therefore gets no entry at all — silence, not a default,
-- for the same reason the padding rule counts an unlisted position as
-- used.
piSpine :: Type -> [ArgBinder]
piSpine = go . unEl
  where
    -- 'abType' is left 'Nothing' here: rendering a domain needs the context
    -- of the binders before it, hence TCM. 'attachBinderTypes' fills it in
    -- for the surviving positions under @--with-signatures@.
    go (Pi d b) = ArgBinder (hidingOf (getHiding d)) (suggestName b) Nothing
                    : go (unEl (unAbs b))
    go _        = []
    hidingOf Hidden     = BHImplicit
    hidingOf Instance{} = BHInstance
    hidingOf NotHidden  = BHExplicit
    -- 'suggestName' is Agda's own placeholder-aware accessor: it maps the
    -- @"_"@ a nameless domain (@Nat -> Nat@) carries to 'Nothing', so we
    -- never report a name Agda invented.

-- | Which of @removable@'s positions the /elaborated body/ still mentions.
--
-- Agda's verdict composes interprocedurally: an argument threaded into a
-- callee that discards it reads @Unused@ in the caller too (that is what
-- @f2@ in @test\/ArgUsage.agda@ pins). Sound — but it means the reported
-- positions are two different edits wearing one label. If the body never
-- names the binder, deleting it is a local edit. If it does, the value is
-- being passed somewhere, and the deletion is a multi-definition change
-- that has to reach the callee too.
--
-- The distinction is invisible from the wire without this field, and it is
-- the one the consumer repo hit as a false positive: an instance argument
-- that never appears syntactically in the source body, but which /instance
-- search/ resolves from — the elaborated body holds the binder's variable
-- as the callee's instance argument, so the verdict is @Unused@ (the callee
-- discards it) while the removal breaks the call. Instance resolution needs
-- no special case here: it is exactly a body occurrence at a position whose
-- 'abHiding' is 'BHInstance'.
--
-- Positions are read off each clause's patterns, because a clause body is
-- indexed by the /clause/ telescope, not the definition's: position @i@'s
-- variable is whatever @namedClausePats !! i@ binds. Conservative wherever
-- that mapping is not a plain variable — an argument matched on ('ConP',
-- 'LitP') is being inspected, so its binder cannot go; a copattern clause
-- ('ProjP') shifts the correspondence, so nothing is claimed about it; a
-- position past the patterns is bound by a lambda we would have to follow.
-- Only a dot pattern is safely 'False': it binds nothing and the body
-- cannot name it. So the field over-reports rather than under-reports, and
-- a position /absent/ from it is a real "this is a local edit".
occursInBodyOf :: Defn -> [Int] -> [Int]
occursInBodyOf Function{ funClauses = cls } removable =
  [ i | i <- removable, any (`mentions` i) analysed ]
  where
    -- Per-clause facts, computed once per clause rather than once per
    -- (clause, position): whether a copattern shifts the correspondence, and
    -- the patterns to index into.
    analysed = [ (any isProjP pats, pats, clauseBody cl)
               | cl <- cls, let pats = namedClausePats cl ]
    mentions (hasProj, pats, body) i
      | hasProj   = True
      | otherwise = case drop i pats of
          []      -> True
          (p : _) -> case namedThing (unArg p) of
            VarP _ v -> maybe False (freeIn (dbPatVarIndex v)) body
            DotP{}   -> False
            _        -> True
    isProjP p = case namedThing (unArg p) of
      ProjP{} -> True
      _       -> False
occursInBodyOf _ _ = []

-- | Fill in 'abType' for the reported positions, under @--with-signatures@
-- only (it costs a 'prettyTCM' per reported position, and the sibling @type@
-- field is behind the same flag).
--
-- __Runs before 'dropSectionPrefix', in raw spine space.__ The strings then
-- ride through the shift on the 'ArgBinder's that carry them, re-keyed with
-- the verdict they annotate — exactly how 'abName' and 'abHiding' stay
-- aligned. Rendering afterwards would mean adding the prefix size back to
-- an already-shifted index, giving the section shift a second home: and
-- where a wrong shift merely /drops/ a field here, arithmetic there would
-- attach the neighbouring binder's type to a reported position — a silently
-- wrong string on a wire artifact the schema calls a contract.
--
-- Only 'auBinders' keys are rendered, and 'auBinders' only ever holds
-- positions the syntactic spine reaches, so every key resolves.
attachBinderTypes :: Options -> Definition -> ArgUsage -> TCM ArgUsage
attachBinderTypes opts def au
  | not (optWithSignatures opts) = pure au
  | null (auBinders au)          = pure au
  | otherwise = do
      let wanted = IS.fromList (map fst (auBinders au))
      tys <- renderPiDomains opts wanted (defType def)
      pure au { auBinders = [ (i, b { abType = IM.lookup i tys })
                            | (i, b) <- auBinders au ] }

-- | Reify the domains at @wanted@ positions of a type's syntactic 'Pi'
-- spine, each in the context of the binders before it.
--
-- The context is what makes the strings readable: a domain mentioning an
-- earlier binder prints that binder's name rather than a de Bruijn index.
-- The 'prettyTCM' call sits /outside/ the 'addContext' for its own binder
-- and inside every earlier one, which is exactly the scope the domain is
-- written in. Descent is by 'absBody' for the reason 'piSpineOf' documents.
renderPiDomains :: Options -> IS.IntSet -> Type -> TCM (IM.IntMap String)
renderPiDomains opts wanted = go 0
  where
    go :: Int -> Type -> TCM (IM.IntMap String)
    go !i t = case unEl t of
      Pi d b -> do
        rest <- addContext (absName b, d) (go (i + 1) (absBody b))
        if i `IS.member` wanted
          then do
            s <- reifyTypeLine opts (unDom d)
            pure (IM.insert i s rest)
          else pure rest
      _ -> pure IM.empty

-- | Reify a type to a single line, honouring @--show-implicit@.
--
-- The one home of that recipe: the per-def @type@ field and each
-- 'ArgBinder''s @type@ must agree on how implicits are shown and on the
-- whitespace collapse, or two halves of the same signature print in two
-- conventions. @--normalise-signatures@ stays at the call site — it applies
-- to the whole-type field only, deliberately (reducing a domain destroys the
-- head symbol that makes a binder recognisable).
reifyTypeLine :: Options -> Type -> TCM String
reifyTypeLine opts ty = do
  doc <- (if optShowImplicit opts then withShowAllArguments else id)
           (prettyTCM ty)
  pure (unwords (words (render doc)))

-- | Effective-option flags worth reporting per module. Not a safety
-- question (that is 'safetyRelevantOptionFlags') but an /actionability/
-- one: whether the advice a finding carries can be taken at all.
--
-- @--erasure@ is the whole list. Without it @\@0@ is a syntax error
-- (@[AttributeKindNotEnabled]@), so every @erasable@ verdict in that module
-- is un-appliable however true it is — 41% of one consumer's total output,
-- unactionable as configured, with nothing on the wire to say so.
--
-- __The table, not a mirror of one.__ 'effectiveOptionFlags' folds over this
-- list, so adding a flag is one tuple here rather than an edit in two places
-- that have to agree — the same discipline as 'safetyRelevantOptionFlags',
-- which 'optionEscapes' intersects against.
--
-- Each entry pairs the wire spelling with Agda's own accessor rather than a
-- token test: @--erase-record-parameters@ and an explicit @--erased-matches@
-- both imply @optErasure@, and that accessor is where the implication lives.
actionabilityRelevantOptions :: [(String, PragmaOptions -> Bool)]
actionabilityRelevantOptions = [ ("--erasure", optErasure) ]

-- | The 'actionabilityRelevantOptions' a module's __effective__ options
-- enable, ascending. Empty for a module that enables none.
--
-- Read from 'iOptionsUsed', NOT 'iFilePragmaOptions': the opposite of the
-- rule 'optionEscapes' follows, and deliberately. A file @OPTIONS@ pragma is
-- a property /of the file/, so attributing it needs the file's own tokens;
-- \"can I write @\@0@ here\" is a property of the options actually in force,
-- which is mostly where the flag really lives — a @flags:@ line in the
-- @.agda-lib@, or the command line.
--
-- Derived from 'actionabilityRelevantOptions', which is where a second flag
-- goes.
effectiveOptionFlags :: PragmaOptions -> [String]
effectiveOptionFlags po =
  [ flag | (flag, enabled) <- actionabilityRelevantOptions, enabled po ]

-- | File-level @{-# OPTIONS ⋯ #-}@ flags that make @agda --safe@ reject a
-- whole module — the module-level analogue of 'UnsafeTag'. The
-- /unconditional single-flag/ escapes from Agda's
-- @Agda.Interaction.Options.Base.unsafePragmaOptions@; RE-SYNC on an Agda
-- bump. A superset across the supported range, so one set serves 2.8 and
-- 2.9 (no CPP).
--
-- Not covered: combination-conditional escapes (e.g. @--without-K@ +
-- @--flat-split@), which a file-token scan can't evaluate without the
-- resolved 'PragmaOptions'; and per-block declaration pragmas (e.g.
-- @{-# NO_POSITIVITY_CHECK #-}@), which are not @OPTIONS@ and never appear
-- in @iFilePragmaOptions@.
safetyRelevantOptionFlags :: Set String
safetyRelevantOptionFlags = S.fromList
  [ "--allow-unsolved-metas"
  , "--allow-incomplete-matches"
  , "--no-positivity-check"
  , "--no-termination-check"
  , "--type-in-type"
  , "--omega-in-omega"
  , "--sized-types"
  , "--injective-type-constructors"
  , "--irrelevant-projections"
  , "--experimental-irrelevance"
  , "--rewriting"
  , "--local-rewriting"
  , "--cumulativity"
  , "--allow-exec"
  , "--no-load-primitives"
  ]

-- | Keep only the safety-relevant flags ('safetyRelevantOptionFlags') from
-- a module's raw file-level @OPTIONS@ tokens, deduplicated and ascending.
-- Empty when the module declares no file-level escape. Pure: the caller
-- hands it the flattened @iFilePragmaOptions@ token list.
optionEscapes :: [String] -> [String]
optionEscapes toks =
  S.toAscList (S.intersection safetyRelevantOptionFlags (S.fromList toks))

-- | 'nodeKey' of Agda's @primTrustMe@ primitive. Survives 'namesIn' even
-- though the primitive itself is filtered from the node set.
trustMeNodeKey :: String
trustMeNodeKey = "Agda.Builtin.TrustMe.primTrustMe"

-- | How an outbound edge was discovered; emitted as a wire tag (see
-- 'provTag'). Precedence when several apply to the same @(src, dst)@:
-- 'ESignature' > 'EModuleLocal' > 'EBody' > 'EUnknown'.
--
-- There is deliberately no @with@ tag. One existed and could never fire:
-- it was emitted when a dep equalled the source's @funWith@, but @funWith@
-- is non-empty on /exactly/ the definitions 'ignoreDef' drops (it names a
-- with-function's parent), so the tag could only be computed while walking
-- a definition that is never emitted — and 'contractIgnoredEdges' discards
-- inside-chain provenance anyway. A dependency reached only through a
-- with-abstraction therefore arrives on the parent tagged 'EBody', which
-- is the honest answer: post-elaboration we cannot tell it from any other
-- body reference. Recovering it would mean tagging at contraction time
-- (see Backlog.md) — a deliberate wire-content change, not a bug fix.
data EdgeProv
  = ESignature  -- ^ Target appears in @defType@.
  | EBody       -- ^ Target appears only in @theDef@ (not @defType@, not a helper).
  | EModuleLocal -- ^ Target is an anonymous-module helper (@where@-block or
                -- parameterised-section member; Agda spells both alike). A
                -- locally-scoped helper, not ownership. Wire tag: @module-local@.
  | EUnknown    -- ^ Catch-all: instance-method provider edges, or contracted
                -- edges whose chain source provenance was indeterminate.
  deriving (Show, Eq, Ord, Enum, Bounded)
  -- 'Enum' only enumerates the constructors (schema order); the numeric
  -- code is 'edgeProvCode', which skips the retired code 3.

-- | Combine two provenances by precedence, when contraction or
-- instance-method extension reaches the same @(src, dst)@ pair twice.
provPrec :: EdgeProv -> EdgeProv -> EdgeProv
provPrec a b
  | precRank a >= precRank b = a
  | otherwise                = b
  where
    precRank :: EdgeProv -> Int
    precRank ESignature   = 4
    precRank EModuleLocal = 2
    precRank EBody        = 1
    precRank EUnknown     = 0

-- | Wire tag for 'EdgeProv', emitted in expanded JSON's
-- @definitionEdgesProvenance@ array.
provTag :: EdgeProv -> String
provTag ESignature   = "signature"
provTag EBody        = "body"
provTag EModuleLocal = "module-local"
provTag EUnknown     = "unknown"

-- | Stable numeric code shared by packed output and the fragment cache.
-- Code 3 belonged to the retired @with@ tag and remains reserved.
edgeProvCode :: EdgeProv -> Word8
edgeProvCode ESignature   = 0
edgeProvCode EBody        = 1
edgeProvCode EModuleLocal = 2
edgeProvCode EUnknown     = 4

-- | One node in the dependency graph: a definition plus its direct deps
-- and classification. Invariant: @M.keysSet _depsProv == _deps@ (every
-- kept dep carries exactly one 'EdgeProv' tag).
data ADDef = ADDef
  { _name   :: NodeRef          -- ^ identity of the definition
  , _deps   :: !(Set NodeRef)   -- ^ its dependencies (named free variables)
  , _depsProv :: !(Map NodeRef EdgeProv)
                                -- ^ per-dep provenance tag.
                                -- Invariant: @M.keysSet _depsProv == _deps@.
  , _state  :: !DefState        -- ^ classification used for node colouring
  , _kind   :: !DefKind         -- ^ structural shape from Agda's 'Defn'
  , _line   :: !(Maybe Int)     -- ^ 1-indexed start line of the binding site
  , _access :: !(Maybe DefAccess)
                                -- ^ public/private as seen in the defining
                                -- module's scope. 'Nothing' when unknown.
  , _subtermHashes :: !(Maybe [Word64])
                                -- ^ Canonical-form hashes for every subterm
                                -- in @defType@/@theDef@; under
                                -- @--with-term-hashes@ only. See 'AgdaDeps.TermCanon'.
  , _subtermDepths :: !(Maybe [Int])
                                -- ^ Parallel to '_subtermHashes': AST depth
                                -- of each emitted subterm.
  , _sig    :: !(Maybe String)
                                -- ^ Reified @defType@ (one line, implicits
                                -- hidden) under @--with-signatures@ only;
                                -- emitted as the per-def @"type"@ field.
  , _unsafe :: ![UnsafeTag]
                                -- ^ Direct soundness escapes (see 'UnsafeTag').
                                -- Always computed; emitted as the optional
                                -- @"unsafe"@ array, omitted when empty.
  , _unsolvedMetas :: !Int
                                -- ^ Count of /silent/ unsolved metavariables
                                -- this def mentions: non-interaction open
                                -- metas (missing record fields, failed
                                -- instance search, unsolved @_@) — honest
                                -- interaction @?@s are NOT counted (they only
                                -- set '_state' = 'Hole'). Always computed;
                                -- emitted as the optional per-def
                                -- @"unsolvedMetas"@ field, omitted when 0.
  , _argUsage :: !(Maybe ArgUsage)
                                -- ^ Arguments this def never uses, read
                                -- off Agda's own positivity\/polarity
                                -- analysis (see 'argUsageOf'). Always
                                -- computed; 'Nothing' when there is
                                -- nothing to report, and the optional
                                -- per-def @"argUsage"@ object is then
                                -- omitted.
  } deriving (Show)

instance Pretty ADDef where
  pretty ADDef{..} = vcat [ pshow "Name:"  <+> pretty _name
                          , pshow "State:" <+> pshow _state
                          , pshow "Kind:"  <+> pshow _kind
                          , pshow "Line:"  <+> pshow _line
                          , pshow "Access:" <+> pshow _access
                          , pshow "Deps:"  <+> pretty _deps
                          , pshow "DepsProv:" <+> pshow (M.toAscList _depsProv)
                          , pshow "Unsafe:" <+> pshow _unsafe
                          , pshow "UnsolvedMetas:" <+> pshow _unsolvedMetas
                          , pshow "ArgUsage:" <+> pshow _argUsage ]

-- ** 'Binary' instances for the @--incremental@ fragment cache.
-- Identity is 'NodeRef', not 'QName', so the payload is plain data
-- serialised with 'Data.Binary' — no Agda 'EmbPrj'. Enums are tagged
-- 'Word8's; an out-of-range tag @fail@s the decode (a cache miss).

-- | Decode an enum tag by inverting its code function ('fromCode').
getCode :: (Bounded a, Enum a) => String -> (a -> Word8) -> B.Get a
getCode what code = B.getWord8 >>= maybe (fail what) pure . fromCode code

instance Binary EdgeProv where
  put = B.putWord8 . edgeProvCode
  get = getCode "EdgeProv" edgeProvCode

instance Binary DefKind where
  put = B.putWord8 . defKindCode
  get = getCode "DefKind" defKindCode

instance Binary DefAccess where
  put = B.putWord8 . accessCode
  get = getCode "DefAccess" accessCode

instance Binary UnsafeTag where
  put = B.putWord8 . unsafeCode
  get = getCode "UnsafeTag" unsafeCode

-- | Fragment-cache codes for the enums with no packed-wire code.
accessCode :: DefAccess -> Word8
accessCode AccPrivate = 0
accessCode AccPublic  = 1

unsafeCode :: UnsafeTag -> Word8
unsafeCode UNonTerminating = 0
unsafeCode UTrustMe        = 1

hidingCode :: BinderHiding -> Word8
hidingCode BHExplicit = 0
hidingCode BHImplicit = 1
hidingCode BHInstance = 2

instance Binary ADDef where
  -- '_deps' is derived (@M.keysSet _depsProv@), so it is not serialised but
  -- rebuilt on 'get' — the invariant can never round-trip inconsistent.
  put (ADDef n _ dp s k l a sh sd sg u um au) =
       B.put n *> B.put dp *> B.put s *> B.put k *> B.put l
    *> B.put a *> B.put sh *> B.put sd *> B.put sg *> B.put u *> B.put um
    *> B.put au
  get = do
    n <- B.get; dp <- B.get; s <- B.get; k <- B.get; l <- B.get
    a <- B.get; sh <- B.get; sd <- B.get; sg <- B.get; u <- B.get
    um <- B.get; au <- B.get
    pure (ADDef n (M.keysSet dp) dp s k l a sh sd sg u um au)

instance Binary ArgUsage where
  -- 'auPartiallyApplied' is always 'False' on this side of the wire (it is
  -- back-filled at emission from the whole corpus), so it round-trips
  -- exactly; it is written rather than assumed so the instance stays a
  -- total mirror of the record.
  put (ArgUsage r q o e a s p b) =
    B.put r *> B.put q *> B.put o *> B.put e *> B.put a *> B.put s
      *> B.put p *> B.put b
  get = ArgUsage <$> B.get <*> B.get <*> B.get <*> B.get <*> B.get <*> B.get
                 <*> B.get <*> B.get

instance Binary ArgBinder where
  put (ArgBinder h n t) = B.put h *> B.put n *> B.put t
  get = ArgBinder <$> B.get <*> B.get <*> B.get

instance Binary BinderHiding where
  put = B.putWord8 . hidingCode
  get = getCode "BinderHiding" hidingCode

-- | Precomputed, serialisable node identity carried through 'ADDef', the
-- side-channels and the emitters. Everything downstream of the per-module
-- walk consumes only these projections — never a live 'QName' or TCM
-- lookup — so a cached fragment round-trips as plain 'Binary' data.
-- Built once, at the producer boundary, by 'mkRef'.
data NodeRef = NodeRef
  { nrKey       :: !String            -- ^ 'nodeKey' — the canonical identity string
  , nrHash      :: !Word64            -- ^ @hashString nrKey@ (fast 'Eq'\/'Ord', and 'hashQName')
  , nrModule    :: !String            -- ^ 'moduleKey' — owning-module attribution
  , nrLine      :: !(Maybe Int)       -- ^ 'bindingLine' — 1-indexed binding-site line
  , nrFile      :: !(Maybe FilePath)  -- ^ binding-site source file (for 'nrSrcLoc')
  , nrShort     :: !String            -- ^ unqualified display name: last @.@-segment of @prettyShow@
  , nrIgnorable :: !Bool              -- ^ precomputed @ignoreDef@, so
                                      --   'contractIgnoredEdges' needs no TCM on cached defs
  , nrArity     :: !Int
    -- ^ Arity for the saturation test ('unsaturatedTargets'): @max@ of the
    -- syntactic @Pi@ spine and the stored occurrence list, for the same
    -- reason 'rawArgUsage' takes that @max@ — a partial application whose
    -- last argument only appears after an unfolding must still count.
    --
    -- Rides along here rather than in a memo of its own because it comes
    -- off the very 'getConstInfo' this bundle already pays for, and every
    -- name the saturation test asks about is a dependency that gets a
    -- 'NodeRef' anyway. Same rationale as 'nrIgnorable': precompute the
    -- one signature lookup so nothing downstream needs TCM.
  , nrWhereHelper :: !Bool            -- ^ @"._." `isInfixOf` prettyShow@ — the
                                      --   module-local (where/anon-module) marker.
                                      --   Serialised: not derivable from 'nrKey' (has @._.@ stripped).
  }

-- 'Eq'\/'Ord' compare the (hash, key) pair — hash first for Int-fast
-- containers, key to break the rare collision. A live ref and a rehydrated
-- cached ref with the same identity compare equal.
instance Eq NodeRef where
  a == b = nrHash a == nrHash b && nrKey a == nrKey b
instance Ord NodeRef where
  compare a b = compare (nrHash a) (nrHash b) <> compare (nrKey a) (nrKey b)
instance Show NodeRef where
  show = nrKey
instance Pretty NodeRef where
  pretty = pretty . nrKey
instance Binary NodeRef where
  -- 'nrHash' is derived (@hashString nrKey@) and rebuilt on 'get'.
  -- 'nrWhereHelper' (h) IS serialised: 'nrKey' has the @._.@ marker
  -- stripped by 'liftAnonSegments', so it can't be recovered. So is
  -- 'nrArity' (i): it comes from the signature, which a cache hit never
  -- consults.
  put (NodeRef a _ c d e f g h i) =
    B.put a >> B.put c >> B.put d >> B.put e >> B.put f >> B.put g >> B.put h
      >> B.put i
  get = do
    a <- B.get; c <- B.get; d <- B.get; e <- B.get; f <- B.get; g <- B.get
    h <- B.get; i <- B.get
    pure (NodeRef a (hashString a) c d e f g h i)

-- ** QName-level identity logic (producer boundary only)
--
-- 'nodeKeyOfQ' / 'moduleKeyOfQ' live in "AgdaDeps.NodeKey" (shared with
-- the subterm hasher) and are re-exported from here.

-- | @(source file, 1-indexed line)@ of a 'QName''s binding occurrence.
-- Surfaced on the wire as 'nrSrcLoc'.
srcLocOfQ :: QName -> Maybe (FilePath, Word32)
srcLocOfQ qn = (\(file, ln, _) -> (file, ln)) <$> bindingSiteOf qn

-- | A 'QName''s binding site as (source file, start line, start character
-- offset), when Agda recorded both a file and a position.
bindingSiteOf :: QName -> Maybe (FilePath, Word32, Word32)
bindingSiteOf qn = do
  let bindRange = nameBindingSite (qnameName qn)
  rf <- Strict.toLazy (rangeFile bindRange)
  p  <- rStart bindRange
  return (filePath (rangeFilePath rf), posLine p, posPos p)

-- | Build the precomputed 'NodeRef' for a 'QName', memoised per 'QName'.
-- A 'NodeRef' is a deterministic function of its 'QName' (its one impure
-- input, the @getConstInfo@ below, is process-stable), so the bundle is built
-- once per distinct name regardless of edge count. The cache is
-- process-lived: 'QName' identity is stable, nothing to reset.
--
-- That single 'getConstInfo' is the module's only per-name signature lookup:
-- both 'nrIgnorable' and 'nrArity' are read off the same 'Definition'. Don't
-- add a second memo for a third such field — put it here.
mkRef :: QName -> TCM NodeRef
mkRef qn = do
  cache <- liftIO (readIORef nodeRefCacheRef)
  case M.lookup qn cache of
    Just r  -> return r
    Nothing -> do
      d <- getConstInfo qn
      let !ign   = ignoreDef d
          !ar    = max (arity (defType d)) (length (defArgOccurrences d))
          !raw   = prettyShow qn
          !mbLn  = bindingLineOfQ qn
          !key   = nodeKeyFromPretty raw mbLn
          !short = (reverse . takeWhile (/= '.') . reverse) raw
          !isWH  = "._." `isInfixOf` raw   -- where-helper marker
          !r = NodeRef
            { nrKey       = key
            , nrHash      = hashString key
            , nrModule    = moduleKeyOfQ qn
            , nrLine      = mbLn
            , nrFile      = fst <$> srcLocOfQ qn
            , nrShort     = short
            , nrIgnorable = ign
            , nrArity     = ar
            , nrWhereHelper = isWH
            }
      liftIO $ modifyIORef' nodeRefCacheRef (M.insert qn r)
      return r

{-# NOINLINE nodeRefCacheRef #-}
nodeRefCacheRef :: IORef (Map QName NodeRef)
nodeRefCacheRef = unsafePerformIO (newIORef M.empty)

-- ** Blessed identity accessors (NodeRef; used everywhere downstream)

-- | Canonical node-identity string. See 'nodeKeyOfQ'.
nodeKey :: NodeRef -> String
nodeKey = nrKey

-- | Owning-module attribution string. See 'moduleKeyOfQ'.
moduleKey :: NodeRef -> String
moduleKey = nrModule

-- | @(source file, line)@ of the binding occurrence, if fully known.
nrSrcLoc :: NodeRef -> Maybe (FilePath, Word32)
nrSrcLoc r = (,) <$> nrFile r <*> (fromIntegral <$> nrLine r)

-- | Version of the node-key convention emitted by 'nodeKeyOfQ'. Stamped
-- into @graph.json@ so a consumer can detect a stale-format cached graph.
-- Bump whenever the key shape changes. Currently 3 (anonymous-module
-- segments lifted into the nearest named ancestor).
nodeKeyVersion :: Int
nodeKeyVersion = 3

-- | Stable integer ID for a node, shared by every renderer. The hash of
-- 'nodeKey', so distinct same-named @where@/anonymous-module helpers hash
-- to distinct ids.
hashQName :: NodeRef -> Int
hashQName = fromIntegral . nrHash

-- | Every node that appears in the graph (definition identities plus
-- their dependencies), deduplicated by 'hashQName'. Result is in
-- ascending hashQName order. 'IM.insert' is "last write wins" on hash
-- collision.
collectAllQNames :: [ADDef] -> [NodeRef]
collectAllQNames defs = IM.elems (foldl' addDef IM.empty defs)
  where
    addDef :: IM.IntMap NodeRef -> ADDef -> IM.IntMap NodeRef
    addDef !acc ADDef{..} =
      let !acc1 = IM.insert (hashQName _name) _name acc
      in S.foldl' (\ !m qn -> IM.insert (hashQName qn) qn m) acc1 _deps

-- ** building ADDefs

-- | Apply module exclusions to the separate signature and body walks.
-- Keeping the two sets separate lets edge provenance retain its current
-- signature-over-body precedence.
filteredDependencySets
  :: [String] -> [QName] -> [QName] -> (Set QName, Set QName)
filteredDependencySets excludes rawSig rawBody =
  (S.fromList (filter keep rawSig), S.fromList (filter keep rawBody))
  where
    keep qn = not (isExcludedModule excludes (moduleKeyOfQ qn))

-- | Convert the filtered live 'QName' dependency sets to serializable
-- 'NodeRef's and attach provenance. The ascending QName walk and
-- 'M.fromList' retain the producer's deterministic last-wins behavior if two
-- live names collide as 'NodeRef's.
dependencyProvenance
  :: Set QName -> Set QName -> TCM (Map NodeRef EdgeProv)
dependencyProvenance sigNames bodyNames =
  M.fromList <$> mapM one (S.toAscList (S.union sigNames bodyNames))
  where
    one q = do
      r <- mkRef q
      let !p = tagOneWith sigNames bodyNames q (nrWhereHelper r)
      pure (r, p)

-- | Replace an 'ADDef''s dependency provenance and derive the parallel set.
-- Use this at replacement sites so the record invariant cannot drift.
withDependencyProvenance :: Map NodeRef EdgeProv -> ADDef -> ADDef
withDependencyProvenance prov d =
  let !deps = M.keysSet prov
  in d { _deps = deps, _depsProv = prov }

-- | Build an 'ADDef' for a *kept* (non-ignored) definition.
--
-- Collects raw 'QName' dependencies via 'namesIn' and stores them
-- verbatim in '_deps' (including references to ignored helpers such as
-- @with-NNN@). 'postCompileAD' later calls 'contractIgnoredEdges' to
-- contract those out and apply the per-QName ignore filter.
computeDefAD :: Options -> Definition -> TCM ADDef
computeDefAD opts def@Defn{..} = do
  let excludes = optExcludeModules opts
      -- Walk 'defType' and 'theDef' separately to record which set each
      -- name came from. Raw walks are shared with 'classifyDefWith' (one
      -- traversal each); 'ignoreDef' is applied later in
      -- 'contractIgnoredEdges'.
      !rawSig    = namesIn defType
      !rawBody   = namesIn theDef
      (!sigNames, !bodyNames) =
        filteredDependencySets excludes rawSig rawBody
      -- Distinct raw names: the per-name string tests below ('prettyShow'
      -- each) run once per name, not once per occurrence.
      rawNames = nubOrd (rawSig ++ rawBody)
  -- Reuse the raw (pre-exclude) name walks: a synthetic @unsolved#meta.*@
  -- name in an excluded module must still flip the Hole classification.
  (st, silentMetas) <- classifyDefWith rawNames def
  let !kd      = classifyKind def
      !termPairs = if optWithTermHashes opts
                     then Just (concatMap (subtermHashes (optMinTermDepth opts))
                                          (definitionTerms def))
                     else Nothing
      (!termHs, !termDs) = case termPairs of
        Just ps -> let (hs, ds) = unzip ps in (Just hs, Just ds)
        Nothing -> (Nothing, Nothing)
  -- Reify 'defType' via 'prettyTCM', collapsed to one line.
  -- '--normalise-signatures' reduces first; '--show-implicit' shows
  -- implicit/irrelevant arguments.
  sigStr <- if optWithSignatures opts
              then do
                ty <- if optNormaliseSignatures opts then normalise defType
                                                     else pure defType
                Just <$> reifyTypeLine opts ty
              else pure Nothing
  -- Soundness escapes, computed from data already in hand (no extra
  -- term traversals): the termination-pragma marker on 'theDef' plus a
  -- scan of the raw (pre-exclude) name walks for @primTrustMe@.
  let termTag = case theDef of
        Function{ funTerminates = Just False } -> [UNonTerminating]
        _                                      -> []
      usesTrustMe = any ((== trustMeNodeKey) . nodeKeyOfQ) rawNames
      !unsafeTags = termTag ++ [ UTrustMe | usesTrustMe ]
  -- Never-used arguments, read off Agda's positivity/polarity analysis.
  -- The state read inside only fires for a def that has a finding.
  argUsage <- argUsageOf opts def
  -- Convert to 'NodeRef' at the producer boundary: everything downstream
  -- is identity-as-data.
  nameRef  <- mkRef defName
  when (optWithTypeTerms opts) $ captureTypeDefinition (nrFile nameRef) def
  -- Tag each edge as its 'NodeRef' is built (one pass), reading the
  -- precomputed 'nrWhereHelper' bit instead of a per-edge 'prettyShow'.
  -- 'S.toAscList' fixes the key order, so 'M.fromList''s last-wins on
  -- colliding NodeRefs is deterministic.
  !depsProvR <- dependencyProvenance sigNames bodyNames
  let !depsR = M.keysSet depsProvR
  return ADDef
    { _name   = nameRef
    , _deps   = depsR
    , _depsProv = depsProvR
    , _state  = st
    , _kind   = kd
    , _line   = nrLine nameRef
    , _access = Nothing  -- back-filled in postCompile from the source's private blocks
    , _subtermHashes = termHs
    , _subtermDepths = termDs
    , _sig    = sigStr
    , _unsafe = unsafeTags
    , _unsolvedMetas = silentMetas
    , _argUsage = argUsage
    }

-- | Every 'Term' reachable from a 'Definition' for fingerprinting
-- purposes: the type's underlying 'Term' (via 'unEl') plus every
-- clause body that's actually present. For 'Datatype' / 'Record' /
-- 'Constructor' / 'Axiom' the body has no 'Term'-shaped content, so
-- only the type contributes.
definitionTerms :: Definition -> [Term]
definitionTerms Defn{..} = unEl defType : bodyTerms theDef
  where
    bodyTerms (Function   { funClauses  = cls }) = mapMaybe clauseBody cls
    bodyTerms (Primitive  { primClauses = cls }) = mapMaybe clauseBody cls
    bodyTerms _                                  = []

-- | Tag a single outgoing edge by precedence:
-- signature > module-local > body > unknown. The module-local test
-- is the target's precomputed 'nrWhereHelper' bit (@"._." `isInfixOf`
-- prettyShow@), passed in, so no per-edge 'prettyShow' is paid.
tagOneWith
  :: S.Set QName        -- ^ names from @defType@
  -> S.Set QName        -- ^ names from @theDef@
  -> QName              -- ^ the dep to tag
  -> Bool               -- ^ target's 'nrWhereHelper'
  -> EdgeProv
tagOneWith sigNames bodyNames qn isWhere
  | qn `S.member` sigNames        = ESignature
  | isWhere                       = EModuleLocal
  | qn `S.member` bodyNames       = EBody
  | otherwise                     = EUnknown

-- | Per-definition entry point used by the Agda backend hook.
--
-- For *ignored* definitions (with-helpers, pattern lambdas, Kan ops,
-- module-instantiation copies, …) records the raw out-edges into
-- 'ignoredEdgesRef' before returning 'Nothing', so 'contractIgnoredEdges'
-- can stitch real-to-real edges across chains of ignored defs.
--
-- Side-effect: for instance binders (see 'recordInstanceMethods') records
-- the binder as a provider for each projection method it supplies into
-- 'methodProvidersRef' (consumed by 'addInstanceMethodEdges').
compileDefAD :: Options -> env -> IsMain -> Definition -> TCM (Maybe ADDef)
compileDefAD opts _ _ def@Defn{..}
  | ignoreDef def = do
      -- Recorded for ignored defs too: a partial application inside a
      -- with-helper or a pattern lambda is still a partial application of
      -- its target, and those bodies live nowhere else.
      recordUnsaturatedOf def
      -- Record raw out-edges without applying 'ignoreDef' (refs to
      -- other ignored defs are kept so the closure pass can chain through).
      -- Module-exclusion still applies.
      let !rawSig  = namesIn defType
          !rawBody = namesIn theDef
          (!sigNames, !bodyNames) =
            filteredDependencySets excludes rawSig rawBody
      -- Convert to NodeRef at the boundary (see 'computeDefAD'); tag edges
      -- off the precomputed 'nrWhereHelper' bit.
      nameRef  <- mkRef defName
      prov <- dependencyProvenance sigNames bodyNames
      recordIgnoredDef nameRef prov
      return Nothing
  | isExcludedModule excludes (moduleKeyOfQ defName) = return Nothing
  | otherwise = do
      recordInstanceMethods def
      recordUnsaturatedOf def
      Just <$> computeDefAD opts def
  where
    excludes = optExcludeModules opts

-- | Record this definition's unsaturated references ('unsaturatedTargets')
-- into the side channel, keyed by the definition itself. No entry is written
-- for a definition with none, so the map stays sparse.
recordUnsaturatedOf :: Definition -> TCM ()
recordUnsaturatedOf def = do
  tgts <- unsaturatedTargets def
  unless (S.null tgts) $ do
    srcRef <- mkRef (defName def)
    liftIO $ modifyIORef' unsaturatedRefsRef (M.insertWith S.union srcRef tgts)

-- | If @def@ looks like an instance binder, record it as a provider for
-- every projection method it dispatches. Two signals:
--
--   1. 'defInstance' is 'Just _' (any @instance ⋯@); credited even when no
--      method names are recoverable from the body (e.g. @R ∋ record { ⋯ }@).
--   2. Body is a 'Function' whose head pattern is a 'ProjP' (the
--      @R ∋ λ where ._method → …@ copattern-lambda idiom); the projection
--      'QName's are the supplied methods.
recordInstanceMethods :: Definition -> TCM ()
recordInstanceMethods Defn{..} =
  let isInstance = isJust defInstance
      methods    = projectionMethods theDef
  in when (isInstance || not (null methods)) $ do
       binderRef  <- mkRef defName
       methodRefs <- mapM mkRef methods
       recordMethodProviders binderRef methodRefs
  where
    -- Pull the projection QName off each clause's head pattern. The
    -- @R ∋ λ where@ shape has one ProjP per clause; anything else yields [].
    projectionMethods :: Defn -> [QName]
    projectionMethods (Function { funClauses = cls }) =
      mapMaybe headProj cls
    projectionMethods _ = []

    headProj :: Clause -> Maybe QName
    headProj cl = case namedClausePats cl of
      (p : _) -> case namedThing (unArg p) of
                   ProjP _ q -> Just q
                   _         -> Nothing
      _ -> Nothing

-- ** Side-channel: edges through ignored defs
--
-- Raw out-edges of each ignored def that 'compileDefAD' drops, keyed by the
-- ignored def, so a kept def referencing it can see what it transitively
-- reaches. Mutable global state, not persisted. The per-edge 'EdgeProv' is
-- the same tagging as kept defs; contraction discards the inside-chain
-- provenance and inherits the kept def's tag (see 'contractWith').
type IgnoredEdgeMap = Map NodeRef (Map NodeRef EdgeProv)

{-# NOINLINE ignoredEdgesRef #-}
ignoredEdgesRef :: IORef IgnoredEdgeMap
ignoredEdgesRef = unsafePerformIO $ newIORef M.empty

-- | Clear the side-channel map. Called at the start of a compile so
-- repeated in-process invocations stay independent.
resetIgnoredEdges :: MonadIO m => m ()
resetIgnoredEdges = liftIO $ writeIORef ignoredEdgesRef M.empty

-- | Record an ignored def's out-edges (strict 'modifyIORef'').
recordIgnoredDef :: MonadIO m => NodeRef -> Map NodeRef EdgeProv -> m ()
recordIgnoredDef qn deps =
  liftIO $ modifyIORef' ignoredEdgesRef (M.insert qn deps)

-- | Read the ignored-edges map. Used by the fragment cache's write
-- path to extract a module's slice.
readIgnoredEdges :: MonadIO m => m IgnoredEdgeMap
readIgnoredEdges = liftIO $ readIORef ignoredEdgesRef

-- | Union a cached module's ignored-edges slice back in (fragment
-- cache hit: the module's @compileDef@ hooks never ran, so its
-- entries must come from the fragment). Left-biased on collision —
-- a freshly-recorded entry wins over a cached one.
mergeIgnoredEdges :: MonadIO m => IgnoredEdgeMap -> m ()
mergeIgnoredEdges extra =
  liftIO $ modifyIORef' ignoredEdgesRef (`M.union` extra)

-- ** Side-channel: unsaturated (partially applied) references
--
-- Which definitions are referenced somewhere with fewer arguments than
-- their arity. A definition used as a /value/ has its arity as its
-- interface — @EagerlyAfterT t = Eager ∩¹ AfterT t@ needs @AfterT t@ to be
-- a unary predicate — so no argument of it is removable however dead the
-- polarity analysis finds it. Consumed as the per-def
-- 'auPartiallyApplied' flag.

-- | Source definition -> the targets it references unsaturated.
--
-- Keyed by /source/ rather than accumulated as a flat target set for one
-- reason: @--incremental@. A fragment must carry exactly the module's own
-- contribution, and a def belongs to exactly one module, so the key set is
-- a sound per-module slice. A flat set's per-module delta would depend on
-- which module happened to see a target first, and would go stale the run
-- after that module stopped contributing.
type UnsaturatedMap = Map NodeRef (Set NodeRef)

{-# NOINLINE unsaturatedRefsRef #-}
unsaturatedRefsRef :: IORef UnsaturatedMap
unsaturatedRefsRef = unsafePerformIO $ newIORef M.empty

-- | Clear the side-channel map, for the same reason 'resetIgnoredEdges'
-- does: repeated in-process invocations must stay independent.
resetUnsaturatedRefs :: MonadIO m => m ()
resetUnsaturatedRefs = liftIO $ writeIORef unsaturatedRefsRef M.empty

-- | Read the map, for the fragment cache's write path.
readUnsaturatedRefs :: MonadIO m => m UnsaturatedMap
readUnsaturatedRefs = liftIO $ readIORef unsaturatedRefsRef

-- | Union a cached module's slice back in (fragment cache hit: the
-- module's @compileDef@ hooks never ran).
mergeUnsaturatedRefs :: MonadIO m => UnsaturatedMap -> m ()
mergeUnsaturatedRefs extra =
  liftIO $ modifyIORef' unsaturatedRefsRef (M.unionWith S.union extra)

-- | Flatten to the target side: every definition referenced unsaturated
-- anywhere in the compiled corpus. Sources drop out — the flag is a
-- property of the definition being referenced.
partiallyAppliedSet :: UnsaturatedMap -> Set NodeRef
partiallyAppliedSet = M.foldl' S.union S.empty

-- | The definitions this one references with fewer arguments than they
-- take. Walks the same terms 'definitionTerms' collects for fingerprinting
-- — the type plus every clause body — with Agda's own generic fold.
--
-- Only @Def@ heads are measured. A @Con@ application carries no data
-- parameters in its elims, so comparing its length against the
-- constructor's type arity would report every constructor as partial.
--
-- The applied count is the leading run of @Apply@ elims — Agda's
-- 'isProperApplyElim', which excludes @IApply@ deliberately: a @Proj@
-- eliminates the /result/, so nothing past it is an argument of this head,
-- and undercounting a cubical path application errs towards reporting a
-- partial application, which is the direction that withholds a finding
-- rather than offering an unsafe one.
--
-- Arity comes off 'nrArity', so the signature lookup is the one 'mkRef'
-- already memoises: every name asked about here is a dependency of this
-- definition, hence gets a 'NodeRef' regardless.
unsaturatedTargets :: Definition -> TCM (Set NodeRef)
unsaturatedTargets def =
  S.fromList . mapMaybe id <$> mapM shortOfArity (M.toAscList minApplied)
  where
    -- One 'mkRef' per distinct target: only the fewest arguments any site
    -- passes can be short of the arity. Single-use, so the site list streams
    -- into the map instead of being retained beside it.
    minApplied :: Map QName Int
    minApplied = M.fromListWith min (foldTerm one (definitionTerms def))
      where
        one (Def f es) = [(f, countApply 0 es)]
        one _          = []
        -- Counted, not materialised: this runs at every 'Def' node of every
        -- definition, and a 'takeWhile' would allocate a cell per argument
        -- only to measure the list's length.
        countApply !n (e : es) | isProperApplyElim e = countApply (n + 1) es
        countApply !n _                              = n
    shortOfArity (f, n) = do
      r <- mkRef f
      pure $! if n < nrArity r then Just r else Nothing

-- ** Side-channel: instance-method providers
--
-- Records (method -> [binders]) for each instance binder checked, so
-- 'postCompileAD' can add reverse edges (method usages credit the
-- binder, which is otherwise reached only via instance resolution).

-- | Method @QName@ -> list of instance binders that provide it.
-- A method may be implemented by several binders; the list preserves
-- insertion order, matching Agda's compile order.
type MethodProviderMap = Map NodeRef [NodeRef]

{-# NOINLINE methodProvidersRef #-}
methodProvidersRef :: IORef MethodProviderMap
methodProvidersRef = unsafePerformIO $ newIORef M.empty

-- | Clear the providers map at the start of a compile so repeated
-- in-process invocations stay independent.
resetMethodProviders :: MonadIO m => m ()
resetMethodProviders = liftIO $ writeIORef methodProvidersRef M.empty

-- | Clear every per-run side channel, so repeated in-process invocations
-- stay independent. Keep this aligned with 'SideChannels': omitting a reset
-- silently leaks state from the previous run into the next graph.
--
-- The per-'QName' memos ('nodeRefCacheRef', 'silentSpansCacheRef') are
-- deliberately NOT here: they cache deterministic functions of a name, which
-- no run invalidates.
resetSideChannels :: MonadIO m => m ()
resetSideChannels = do
  resetIgnoredEdges
  resetMethodProviders
  resetUnsaturatedRefs

-- | Read the providers map. Used by 'Backend.postCompileAD'.
readMethodProviders :: MonadIO m => m MethodProviderMap
readMethodProviders = liftIO $ readIORef methodProvidersRef

-- | Union a cached module's provider slice back in (fragment cache
-- hit). Per-method binder lists are appended; downstream
-- 'addInstanceMethodEdges' treats them as a set, so order is
-- immaterial.
mergeMethodProviders :: MonadIO m => MethodProviderMap -> m ()
mergeMethodProviders extra =
  liftIO $ modifyIORef' methodProvidersRef (M.unionWith (++) extra)

-- | One observation of every per-run side channel. The maps remain backed by
-- their separate 'IORef's; this record only makes snapshot, delta, and replay
-- exhaustive at their shared call sites.
data SideChannels = SideChannels
  { sideIgnored     :: IgnoredEdgeMap
  , sideProviders   :: MethodProviderMap
  , sideUnsaturated :: UnsaturatedMap
  }

-- | Read all side channels in their established order.
readSideChannels :: MonadIO m => m SideChannels
readSideChannels = do
  ignored     <- readIgnoredEdges
  providers   <- readMethodProviders
  unsaturated <- readUnsaturatedRefs
  pure (SideChannels ignored providers unsaturated)

-- | Contributions recorded between two snapshots. The three channels have
-- deliberately different growth rules; keep their delta logic explicit.
sideChannelDelta :: SideChannels -> SideChannels -> SideChannels
sideChannelDelta before after = SideChannels
  { sideIgnored = M.difference
      (sideIgnored after) (sideIgnored before)
  , sideProviders = M.differenceWith newProviderPrefix
      (sideProviders after) (sideProviders before)
  , sideUnsaturated = M.difference
      (sideUnsaturated after) (sideUnsaturated before)
  }
  where
    -- Providers grow by prepending binders per method key, so the new
    -- contribution is the current list's prefix.
    newProviderPrefix new old =
      case take (length new - length old) new of
        [] -> Nothing
        xs -> Just xs

-- | Replay a cached module's side-channel slices in the established order.
-- Each field delegates to its channel-specific collision rule.
mergeSideChannels :: MonadIO m => SideChannels -> m ()
mergeSideChannels channels = do
  mergeIgnoredEdges (sideIgnored channels)
  mergeMethodProviders (sideProviders channels)
  mergeUnsaturatedRefs (sideUnsaturated channels)

-- | Append @binder@ to the providers list for each of @methods@. An
-- empty @methods@ list is a no-op (the binder is still recorded by the
-- defInstance-marker path when its method names can't be recovered).
recordMethodProviders :: MonadIO m => NodeRef -> [NodeRef] -> m ()
recordMethodProviders binder methods =
  liftIO $ modifyIORef' methodProvidersRef $ \m ->
    foldl' (\acc method ->
              M.insertWith (\_ old -> binder : old) method [binder] acc)
           m
           methods

-- | After contraction, walk every kept def's @_deps@ and append edges
-- to any registered providers. Purely additive: forward edges stay in
-- place.
--
-- Added edges are tagged 'EUnknown' (provider links are inferred from
-- method dispatch, not a syntactic walk). 'M.union' is left-biased, so
-- existing tags in '_depsProv' are preserved.
--
-- Complexity: O(D * d), D = number of kept defs, d = average |deps|.
addInstanceMethodEdges :: [ADDef] -> TCM [ADDef]
addInstanceMethodEdges defs = do
  providers <- readMethodProviders
  if M.null providers
    then pure defs
    else pure (map (extendOne providers) defs)
  where
    extendOne :: MethodProviderMap -> ADDef -> ADDef
    extendOne providers d =
      let !extra = S.foldl' (collect providers) S.empty (_deps d)
      in if S.null extra
           then d
           else withDependencyProvenance
                  (M.union (_depsProv d) (M.fromSet (const EUnknown) extra)) d

    collect :: MethodProviderMap -> Set NodeRef -> NodeRef -> Set NodeRef
    collect providers !acc qn = case M.lookup qn providers of
      Nothing -> acc
      Just bs -> foldl' (flip S.insert) acc bs

-- | Post-pass: rewrite each 'ADDef'@._deps@ + @._depsProv@ by contracting
-- through the side-channel of ignored defs, then drop leaf deps that
-- 'ignoreDef' classifies as ignorable. Called once from 'postCompileAD'
-- after every def is processed (so the side-channel is complete).
--
-- Expansion is memoized per ignored-def key ('buildIgnoredClosure'): each
-- hidden key's closure of real, non-ignored targets is computed once. At
-- the kept-def boundary each real target inherits the kept def's
-- provenance towards the chain entry (the hidden helper).
contractIgnoredEdges :: [ADDef] -> TCM [ADDef]
contractIgnoredEdges defs = do
  hidden <- liftIO $ readIORef ignoredEdgesRef
  let memo = buildIgnoredClosure hidden
  pure (map (rewriteOne hidden memo) defs)
  where
    -- Expand a kept def's raw dep map through the hidden chain and drop
    -- ignored targets in the SAME pass. Ignorability is the precomputed
    -- 'nrIgnorable' bit (built in 'mkRef'), so this is a pure Bool read —
    -- no TCM on rehydrated cache-hit defs.
    rewriteOne hidden memo d =
      let expanded  = contractWith hidden memo (_depsProv d)
          !keptProv = M.filterWithKey (\ k _ -> not (nrIgnorable k)) expanded
      in withDependencyProvenance keptProv d

    -- Expand a kept def's raw dep map: every ignored-def key is replaced by
    -- its cached closure of real targets (each inheriting the kept def's tag
    -- towards the key); every other QName keeps its original tag. A target
    -- reached by two paths gets the higher-precedence tag via 'provPrec'.
    contractWith
      :: IgnoredEdgeMap
      -> Map NodeRef (Set NodeRef)
      -> Map NodeRef EdgeProv
      -> Map NodeRef EdgeProv
    contractWith hidden memo srcMap =
      M.foldlWithKey' step M.empty srcMap
      where
        step !acc qn provFromSrc = case M.lookup qn memo of
          Just realTargets ->
            -- Inherit @provFromSrc@ for every real target reached
            -- through the hidden chain entered at @qn@.
            S.foldl'
              (\ !m realTgt -> M.insertWith provPrec realTgt provFromSrc m)
              acc realTargets
          Nothing
            | M.member qn hidden ->
                -- In 'hidden' but missing from memo (a cycle member): BFS.
                let !extra = bfsClosure hidden (S.singleton qn)
                in S.foldl'
                     (\ !m realTgt -> M.insertWith provPrec realTgt provFromSrc m)
                     acc extra
            | otherwise -> M.insertWith provPrec qn provFromSrc acc

-- | Standalone BFS closure, the fallback in 'contractIgnoredEdges' and
-- 'buildIgnoredClosure' (cycle members). @frontier0@ is the set of
-- starting QNames; the result is every reachable QName that's *not* an
-- ignored-def key. 'EdgeProv' tags inside the closure are discarded.
bfsClosure :: IgnoredEdgeMap -> Set NodeRef -> Set NodeRef
bfsClosure hidden frontier0 =
  let initial :: Seq NodeRef
      initial = Seq.fromList (S.toList frontier0)
      (_, kept) = go initial IS.empty S.empty
  in kept
  where
    go :: Seq NodeRef -> IS.IntSet -> Set NodeRef
       -> (IS.IntSet, Set NodeRef)
    go q !visited !kept = case Seq.viewl q of
      Seq.EmptyL -> (visited, kept)
      qn Seq.:< rest ->
        let !h = hashQName qn
        in if IS.member h visited
             then go rest visited kept
             else
               let !visited' = IS.insert h visited
               in case M.lookup qn hidden of
                    Just inner ->
                      -- Provenance tags inside @inner@ are discarded;
                      -- only reachability matters.
                      let !rest' = M.foldlWithKey' (\ !q' k _ -> q' |> k) rest inner
                      in go rest' visited' kept
                    Nothing ->
                      let !kept' = S.insert qn kept
                      in go rest visited' kept'

-- | Build a per-ignored-key cache of the set of *real* (non-ignored)
-- targets each hidden def reaches transitively. Provenance inside the
-- chain is dropped; 'contractWith' assigns the final provenance.
--
-- Algorithm: Kahn's topological sort on the hidden→hidden subgraph plus
-- a bottom-up dynamic-programming union, visiting each hidden node and
-- each hidden-to-hidden edge exactly once. Any key not emitted by Kahn
-- (a cycle member) falls back to a per-key BFS via 'bfsClosure'.
--
-- Each key's adjacency is partitioned once into
-- @(hiddenDeps, nonHiddenDeps)@; the DP step at key @k@ is
-- @closure[k] = nonHiddenDeps[k] ∪ ⋃ closure[d] for d in hiddenDeps[k]@.
buildIgnoredClosure :: IgnoredEdgeMap -> Map NodeRef (Set NodeRef)
buildIgnoredClosure hidden = withCycles
  where
    keys :: Set NodeRef
    keys = M.keysSet hidden

    -- Forward adjacency partitioned once into (hiddenDeps, nonHiddenDeps);
    -- per-edge provenance inside the chain is discarded.
    adj :: Map NodeRef (Set NodeRef, Set NodeRef)
    adj = M.map partitionEntry hidden
      where
        partitionEntry :: Map NodeRef EdgeProv -> (Set NodeRef, Set NodeRef)
        partitionEntry m =
          let !ks = M.keysSet m
          in S.partition (`S.member` keys) ks

    -- Reverse adjacency on the hidden→hidden subgraph.
    revAdj :: Map NodeRef (Set NodeRef)
    revAdj = M.foldlWithKey' addRev M.empty adj
      where
        addRev !m k (hDeps, _) =
          S.foldl'
            (\ !acc d -> M.insertWith S.union d (S.singleton k) acc)
            m hDeps

    -- Initial out-degree: number of hidden deps each key has.
    outDeg0 :: Map NodeRef Int
    outDeg0 = M.map (S.size . fst) adj

    -- Seed Kahn's with every node whose hidden-deps set is empty.
    seed :: Seq NodeRef
    seed = Seq.fromList
      [ k | (k, (h, _)) <- M.toList adj, S.null h ]

    -- Bottom-up DP. By the Kahn invariant, every hidden dep of @k@ is
    -- in @memo@ when @k@ is popped, so the union is a straight lookup.
    kahn :: Map NodeRef (Set NodeRef) -> Map NodeRef Int -> Seq NodeRef
         -> Map NodeRef (Set NodeRef)
    kahn !memo !deg q = case Seq.viewl q of
      Seq.EmptyL    -> memo
      k Seq.:< rest ->
        let (hDeps, nDeps) = M.findWithDefault (S.empty, S.empty) k adj
            !closed        = S.foldl' unionMemo nDeps hDeps
            unionMemo !acc d =
              S.union acc (M.findWithDefault S.empty d memo)
            !memo'         = M.insert k closed memo
            preds          = M.findWithDefault S.empty k revAdj
            (deg', rest')  = S.foldl' decrement (deg, rest) preds
            decrement (!d, !qq) p =
              let !nv = M.findWithDefault 0 p d - 1
                  !d' = M.insert p nv d
              in if nv <= 0
                   then (d', qq |> p)
                   else (d', qq)
        in kahn memo' deg' rest'

    !partial = kahn M.empty outDeg0 seed

    -- Cycle fallback: any key not emitted by Kahn (out-degree > 0) is
    -- part of a directed cycle in the hidden subgraph; compute its
    -- closure with 'bfsClosure'.
    cycleMembers :: Set NodeRef
    cycleMembers = keys `S.difference` M.keysSet partial

    withCycles :: Map NodeRef (Set NodeRef)
    withCycles
      | S.null cycleMembers = partial
      | otherwise           =
          S.foldl' addCycle partial cycleMembers
      where
        addCycle !m k =
          let !c = bfsClosure hidden (S.singleton k)
          in M.insert k c m

-- ** classification

-- | True when a 'QName' is one of the synthetic @unsolved#meta.*@
-- postulates Agda generates under @--allow-unsolved-metas@ (via
-- @openMetasToPostulates@).
isUnsolvedMetaName :: QName -> Bool
isUnsolvedMetaName qn = "unsolved#meta." `isPrefixOf` prettyShow (qnameName qn)

-- | Structural classification from 'theDef'. In Agda 2.9 'funProjection'
-- is @Either ProjectionLikenessMissing Projection@; a 'Right' carrying a
-- 'projProper' 'Just' is a record-field projection ('DKProjection'), the
-- rest are plain functions.
classifyKind :: Definition -> DefKind
classifyKind Defn{ theDef = d } = case d of
  Function{}    -> case funProjection d of
                     Right p | isJust (projProper p) -> DKProjection
                     _                               -> DKFunction
  Datatype{}    -> DKDatatype
  Record{}      -> DKRecord
  Constructor{} -> DKConstructor
  Axiom{}       -> DKPostulate
  Primitive{}   -> DKPrimitive
  _             -> DKOther

-- | Classify a 'Definition' as fully-defined, postulate, or hole-bearing.
-- Holes: an open 'MetaV' left in 'defType'/'theDef', a reference to an
-- @unsolved#meta.*@ name (Agda's @openMetasToPostulates@ output under
-- @--allow-unsolved-metas@), or the def's own name being such a marker.
-- The caller supplies the distinct names of the @defType@/@theDef@ walks,
-- so 'computeDefAD' avoids a second traversal. They must be the *raw*
-- (pre-exclude-filter) names.
--
-- Also returns the def's /silent/ unsolved-meta count ('_unsolvedMetas'):
-- distinct referenced @unsolved#meta.*@ markers that are silent
-- ('markerIsSilent'; the def's own name counts when it is such a marker)
-- plus distinct open metas that are not interaction points. State semantics
-- are unchanged — a silent meta also implies the state the old classifier
-- assigned ('Hole', or 'Postulate' for an 'Axiom'-typed def); the count is
-- the additive discriminator between an honest @?@ and silently-missing
-- evidence (missing record field, failed instance search, unsolved @_@).
classifyDefWith :: [QName] -> Definition -> TCM (DefState, Int)
classifyDefWith rawNames Defn{..}
  | isUnsolvedMetaName defName = do
      silent <- markerIsSilent defName
      return (Hole, if silent then 1 else 0)
  | otherwise = do
      let markers = filter isUnsolvedMetaName rawNames
          metas   = nubOrd (allMetasList defType ++ metasInDefn theDef)
      openMs     <- filterM isMetaUnsolved metas
      silentRefs <- filterM markerIsSilent markers
      silentOpen <-
        if null openMs then pure [] else do
          iset <- getInteractionMetaSet
          pure [ m | m <- openMs, not (S.member m iset) ]
      let !cnt = length silentRefs + length silentOpen
          !st  = case theDef of
            Axiom{}                -> Postulate
            _ | not (null markers) -> Hole
              | not (null openMs)  -> Hole
              | otherwise          -> Defined
      return (st, cnt)
  where
    isMetaUnsolved :: MetaId -> TCM Bool
    isMetaUnsolved m = isOpenMeta <$> lookupMetaInstantiation m

-- | Collect metavariables in a 'Defn' by walking the cases that carry
-- term content ('Defn' has no 'AllMetas' instance).
metasInDefn :: Defn -> [MetaId]
metasInDefn = \case
  Function{ funClauses = cls } -> concatMap metasInClause cls
  Primitive{ primClauses = cls } -> concatMap metasInClause cls
  AbstractDefn d -> metasInDefn d
  _ -> []  -- Datatype/Record/Constructor/Axiom/etc. carry no Term bodies
  where
    metasInClause Clause{ clauseTel = tel, clauseBody = body, clauseType = ty } =
      allMetasList tel ++ allMetasList body ++ allMetasList ty

-- ** silent (non-interaction) unsolved metas
--
-- Agda's own split between an honest interaction @?@
-- (@UnsolvedInteractionMetas@) and a silently-inserted unsolved meta
-- (@UnsolvedMetaVariables@: missing record field, failed instance search,
-- unsolved @_@) survives to backend time through two signals:
--
--   * /Interfaces/ (imported modules, whose open metas
--     @openMetasToPostulates@ turned into @unsolved#meta.*@ markers):
--     @warningHighlighting@ folded an 'UnsolvedMeta' aspect over each
--     silent meta's range into 'iHighlighting' *before* postulation, and
--     interaction metas got no aspect — so a marker is silent iff its
--     binding site falls inside an 'UnsolvedMeta' span of its file.
--   * /Live state/ (the main module, which is never postulated): open
--     metas minus 'getInteractionMetas'.

-- | Merged character-offset spans (half-open, 1-based 'posPos' space)
-- carrying the given aspect in an interface's stored highlighting.
aspectSpans :: OtherAspect -> HighlightingInfo -> [(Int, Int)]
aspectSpans asp hi = mergeSpans
  [ (HR.from r, HR.to r)
  | (r, m) <- RangeMap.toList hi
  , asp `S.member` otherAspects m
  ]

-- | Sort and coalesce overlapping/adjacent spans. One meta's range can be
-- split across several 'RangeMap' entries when token highlighting merged
-- into it, so raw entry counts are meaningless; merged spans support the
-- membership test and per-line reporting.
mergeSpans :: [(Int, Int)] -> [(Int, Int)]
mergeSpans = go . sort
  where
    go ((a1, b1) : (a2, b2) : rest)
      | a2 <= b1  = go ((a1, max b1 b2) : rest)
    go (s : rest) = s : go rest
    go []         = []

-- | Source file → 'UnsolvedMeta' spans, over every visited interface.
-- Built once per process on first demand (backend hooks run only after all
-- modules are checked, so the visited set is complete). A file appears
-- only when it has at least one silent span; its path is recovered from
-- the binding site of any of the interface's own definitions (always
-- available when the module has an @unsolved#meta.*@ marker to test —
-- the marker itself carries the meta's range).
getSilentSpansByFile :: TCM (Map FilePath [(Int, Int)])
getSilentSpansByFile = do
  cached <- liftIO (readIORef silentSpansCacheRef)
  case cached of
    Just m  -> return m
    Nothing -> do
      visited <- getVisitedModules
      let m = M.fromList
            [ (f, spans)
            | mi <- M.elems visited
            , let iface = miInterface mi
                  spans = aspectSpans UnsolvedMeta (iHighlighting iface)
            , not (null spans)
            , f <- take 1 (ifaceFiles iface)
            ]
      liftIO (writeIORef silentSpansCacheRef (Just m))
      return m

-- | Candidate source paths of an interface, from its signature defs'
-- binding sites (a def's binding site is always in its own file).
ifaceFiles :: Interface -> [FilePath]
ifaceFiles iface =
  [ f
  | q <- HMap.keys (iSignature iface ^. sigDefinitions)
  , (f, _) <- maybeToList (srcLocOfQ q)
  ]

{-# NOINLINE silentSpansCacheRef #-}
silentSpansCacheRef :: IORef (Maybe (Map FilePath [(Int, Int)]))
silentSpansCacheRef = unsafePerformIO (newIORef Nothing)

-- | MetaIds of unsolved interaction points, memoised once per process
-- (like 'getSilentSpansByFile', the set is final by backend time).
getInteractionMetaSet :: TCM (Set MetaId)
getInteractionMetaSet = do
  cached <- liftIO (readIORef interactionMetaSetRef)
  case cached of
    Just s  -> return s
    Nothing -> do
      s <- S.fromList <$> getInteractionMetas
      liftIO (writeIORef interactionMetaSetRef (Just s))
      return s

{-# NOINLINE interactionMetaSetRef #-}
interactionMetaSetRef :: IORef (Maybe (Set MetaId))
interactionMetaSetRef = unsafePerformIO (newIORef Nothing)

-- | Whether an @unsolved#meta.*@ marker stands for a /silent/ unsolved
-- meta (as opposed to an honest interaction @?@): its binding site — the
-- original meta's range — falls inside an 'UnsolvedMeta' highlighting span
-- of its file. Unresolvable locations default to 'False' (never a false
-- alarm on an honest hole).
markerIsSilent :: QName -> TCM Bool
markerIsSilent qn = do
  spansByFile <- getSilentSpansByFile
  return $ fromMaybe False $ do
    (file, _, pos) <- bindingSiteOf qn
    spans <- M.lookup file spansByFile
    let off = fromIntegral pos
    pure (any (\(a, b) -> off >= a && off < b) spans)

-- | Per-interface rollup: @(silent unsolved-meta lines, unsolved-constraint
-- lines)@, both ascending and 1-indexed. Meta lines are exact — one entry
-- per silent @unsolved#meta.*@ marker in the interface's signature (the
-- main module has none; its live metas come from 'liveSilentMetaLines').
-- Constraint lines are the lines opening each 'UnsolvedConstraint'
-- highlighting span (deduplicated; a span count would be distorted by
-- range coalescing).
unsolvedInterfaceLines :: Interface -> TCM ([Int], [Int])
unsolvedInterfaceLines iface = do
  let markers = [ q | q <- HMap.keys (iSignature iface ^. sigDefinitions)
                    , isUnsolvedMetaName q ]
  silent <- filterM markerIsSilent markers
  let metaLs = sort [ fromIntegral ln | q <- silent
                                      , (_, ln) <- maybeToList (srcLocOfQ q) ]
      conLs  = nubOrd
        [ offsetToLine (iSource iface) a
        | (a, _) <- aspectSpans UnsolvedConstraint (iHighlighting iface)
        ]
  return (metaLs, conLs)

-- | 1-indexed line containing a 1-based character offset of a source text.
offsetToLine :: TL.Text -> Int -> Int
offsetToLine src off =
  1 + fromIntegral (TL.count (TL.singleton '\n') (TL.take (fromIntegral off - 1) src))

-- | Source lines of the /live/ silent unsolved metas: open metas that are
-- not interaction points, read from TCM state. Non-empty only for the main
-- module (imports were postulated into markers before their state was
-- discarded), so the caller attributes these to the entry module.
liveSilentMetaLines :: TCM [Int]
liveSilentMetaLines = do
  rs <- getUnsolvedMetas
  return $ sort [ fromIntegral (posLine p) | r <- rs, p <- maybeToList (rStart r) ]

-- ** filtering

-- | True for the defs Agda synthesises for a @variable@ block (the
-- @GeneralizeTel@ record, its @mkGeneralizeTel@ constructor, and
-- @generalizedField-*@ projections) — none user-written, all dropped.
--
-- 2.8/2.9 delta: 2.9 prefixes each with a @NoName@ segment 'prettyShow'
-- renders as a leading @.@ (name contains @..@); 2.8 spells
-- @GeneralizeTel@/@mkGeneralizeTel@ without it. Matching the base name on
-- 'qnameName' catches both; the @..@ test covers other @NoName@-qualified
-- generated defs. Pinned by @test/Test.agda@'s @variable a b : Set@.
isGeneralizeName :: QName -> Bool
isGeneralizeName qn =
     ".." `isInfixOf` prettyShow qn
  || "GeneralizeTel" `isInfixOf` n
  || "generalizedField-" `isInfixOf` n
  where n = prettyShow (qnameName qn)

ignoreDef :: Definition -> Bool
-- Module-instantiation copies ('defCopy'): alias nodes re-exporting the
-- real def under an importing module. Short-circuits before 'theDef', so it
-- catches all kinds (Function/Record/Datatype/Constructor), not just the
-- Function case 'funInline' covers.
ignoreDef Defn{..} | defCopy = True
-- Auto-generated @variable@-block names (see 'isGeneralizeName').
ignoreDef Defn{..} | isGeneralizeName defName = True
ignoreDef Defn{..} = case theDef of

  -- Pattern-lambda / with-generated / Kan-op functions.
  Function{..} | isJust funExtLam || isWithFun funWith || isJust funIsKanOp -> True
  -- Do NOT remove: drops user @{-# INLINE #-}@ functions. Agda inlines every
  -- call site during type-checking, so an INLINE function has zero incoming
  -- edges by hook time — keeping it adds a false-"dead" orphan.
  d@Function{} | d ^. funInline -> True

  -- Primitive functions with no clauses (keeps builtin ones).
  Primitive{..} -> null primClauses

  -- Level.
  Axiom{} | prettyShow defName == "Agda.Primitive.Level" -> True

  -- Other kinds not wanted as nodes.
  PrimitiveSort{} -> True
  DataOrRecSig{} -> True
  GeneralizableVar _ -> True

  _ -> False
