-- | Single source of truth for the v2 *expanded* @graph.json@ wire
-- format. One set of field tables drives both the generated JSON Schema
-- and the byte-level encoder, so they cannot drift: a field's wire name,
-- requiredness, schema fragment, and encoder live together in one row,
-- and a field can't be emitted without appearing in the schema.
--
-- * 'expandedSchemaJson' renders the schema (@agda-deps --emit-schema@);
--   CI diffs it against the committed @schema/graph-v2-expanded.schema.json@.
-- * 'encodeExpanded' encodes an 'ExpandedGraph' to wire JSON from the
--   *same* tables.
--
-- The generated schema is structural (no @description@ text, order
-- insignificant); the CI checker normalises both sides before comparing.
module AgdaDeps.Backend.Wire
  ( -- * Generated schema
    expandedSchemaJson
    -- * Wire encoding (single source of truth, shared with the schema)
  , ExpandedGraph(..)
  , WireDef(..)
  , WireEdge(..)
  , WireExternals(..)
  , encodeExpanded
  , validateExpanded
  , unsolvedModulesJson
    -- * Field-table machinery (exposed for tests / introspection)
  , Field(..)
  , SchemaDoc(..)
  , expandedFields
  , definitionFields
  , reexportFields
  , externalsSummaryFields
  , defsRegistry
  , objectSchemaOf
  , encodeObject
  , renderSchema
  ) where

import Data.List  ( intercalate )
import Data.Maybe ( mapMaybe )
import Data.Word  ( Word64 )
import qualified Data.Set as S

import AgdaDeps.Options ( DefState(..) )
import AgdaDeps.Deps    ( DefKind(..), DefAccess(..), UnsafeTag(..), EdgeProv, provTag )
import AgdaDeps.Util    ( jsString, jArray, jStrArray, jStrMap, jStrArrMap )

-- * Wire value types
--
-- Presentation-layer mirror of the expanded shape, built by
-- 'toExpandedGraph' in "AgdaDeps.Backend.GraphJson".

-- | The whole expanded @graph.json@ document.
data ExpandedGraph = ExpandedGraph
  { egNodeKeyVersion :: Int
  , egProducer       :: String
  , egModules        :: [String]
  , egEntryModule    :: Maybe String
  , egExternals      :: [String]              -- ^ externalModules (ascending)
  , egFailed         :: [String]              -- ^ failedModules (ascending)
  , egDefs           :: [WireDef]
  , egDefEdges       :: [WireEdge]
  , egDefEdgeProv    :: [EdgeProv]            -- ^ parallel to 'egDefEdges'
  , egModuleEdges    :: [WireEdge]
  , egTransModEdges  :: [WireEdge]
  , egModuleFiles    :: [(String, String)]    -- ^ ascending by key
  , egSourceFiles    :: [String]
  , egReExports      :: [(String, String, [String], [(String, String)])]
  , egModuleOptionEscapes :: [(String, [String])]
    -- ^ Per module, the file-level @{-# OPTIONS ⋯ #-}@ soundness escapes
    -- ('AgdaDeps.Deps.optionEscapes'), ascending by module; only modules
    -- with an escape appear. Emitted as the optional @moduleOptionEscapes@
    -- object; omitted when empty so escape-free corpora stay byte-identical.
  , egUnsolvedModules :: [(String, ([Int], [Int]))]
    -- ^ Per top-level module, @(silent unsolved-meta lines, unsolved-
    -- constraint lines)@ (see 'AgdaDeps.Deps.unsolvedInterfaceLines'),
    -- ascending by module; only modules with at least one entry appear.
    -- Under @--allow-unsolved-metas@ these modules \"succeeded\" with
    -- un-produced evidence, so @failedModules: []@ alone must not be read
    -- as \"compiles\". Emitted as the optional @unsolvedModules@ object;
    -- omitted when empty.
  , egSubtermHashes  :: Maybe [[Word64]]      -- ^ present iff any def carries hashes; parallel to 'egDefs'
  , egSubtermDepths  :: Maybe [[Int]]
  , egExternalsSummary :: Maybe WireExternals
  }

-- | One definition node.
data WireDef = WireDef
  { wdId     :: Int
  , wdName   :: String
  , wdModule :: String
  , wdState  :: DefState
  , wdKind   :: DefKind
  , wdLine   :: Maybe Int
  , wdAccess :: Maybe DefAccess
  , wdType   :: Maybe String
  , wdUnsafe :: [UnsafeTag]   -- ^ soundness escapes; omitted when empty
  , wdUnsolvedMetas :: Int    -- ^ silent unsolved metas; omitted when 0
  , wdX      :: Maybe Float
  , wdY      :: Maybe Float
  }

-- | A directed edge as a (source, target) wire-name pair.
newtype WireEdge = WireEdge (String, String)

-- | The @externals_summary@ diagnostic; lists pre-sorted ascending as
-- the wire format expects.
data WireExternals = WireExternals
  { weModules            :: [String]
  , wePostulatesByModule :: [(String, [String])]
  }

-- * Wire tags for the reused enums (the expanded-format spelling).

wireState :: DefState -> String
wireState Defined   = "D"
wireState Postulate = "P"
wireState Hole      = "H"
wireState Failed    = "F"

wireKind :: DefKind -> String
wireKind DKFunction    = "function"
wireKind DKProjection  = "projection"
wireKind DKDatatype    = "datatype"
wireKind DKRecord      = "record"
wireKind DKConstructor = "constructor"
wireKind DKPostulate   = "postulate"
wireKind DKPrimitive   = "primitive"
wireKind DKOther       = "other"

wireAccess :: DefAccess -> String
wireAccess AccPrivate = "private"
wireAccess AccPublic  = "public"

wireUnsafe :: UnsafeTag -> String
wireUnsafe UNonTerminating = "non-terminating"
wireUnsafe UTrustMe        = "trustme"

-- * The JSON-Schema model (draft 2020-12 subset)

-- | The subset of JSON Schema the expanded wire format uses; one
-- constructor per shape in @graph-v2-expanded.schema.json@.
data SchemaDoc
  = SObject [String] [(String, SchemaDoc)] Bool
    -- ^ required names, properties, @additionalProperties@ boolean.
  | SArray SchemaDoc (Maybe Int) (Maybe Int)   -- ^ items, minItems, maxItems
  | SMap SchemaDoc                             -- ^ object, additionalProperties = schema
  | SString (Maybe [String])                   -- ^ optional enum
  | SInteger (Maybe Int)                       -- ^ optional minimum
  | SConstInt Int
  | SConstStr String
  | SNullableType String                       -- ^ @type: [<t>, "null"]@
  | SRef String                                -- ^ @#/$defs/<name>@
  deriving (Eq, Show)

-- * Field tables: the single source for BOTH schema and encoder.

-- | One field of a wire object: wire name, schema fragment, encoder.
-- Three flavours distinguish schema-requiredness from emission:
--
--   * 'Required' — in the schema @required@ list; always emitted.
--   * 'Additive' — not @required@ (older readers stay valid) but always
--     emitted by the current producer.
--   * 'Optional' — not required; emitted only when the encoder yields
--     'Just' (flag-gated fields).
data Field a
  = Required String SchemaDoc (a -> String)
  | Additive String SchemaDoc (a -> String)
  | Optional String SchemaDoc (a -> Maybe String)

fName :: Field a -> String
fName (Required n _ _) = n
fName (Additive n _ _) = n
fName (Optional n _ _) = n

fSchema :: Field a -> SchemaDoc
fSchema (Required _ s _) = s
fSchema (Additive _ s _) = s
fSchema (Optional _ s _) = s

fInRequired :: Field a -> Bool
fInRequired Required{} = True
fInRequired _          = False

-- | Object schema from a field table. @additionalProperties@ is @true@
-- so a future additive field can't fail v2 validation.
objectSchemaOf :: [Field a] -> SchemaDoc
objectSchemaOf fs =
  SObject [ fName f | f <- fs, fInRequired f ]
          [ (fName f, fSchema f) | f <- fs ]
          True

-- | Encode an object from a field table, in field-table (byte) order.
-- 'Optional' fields whose encoder yields 'Nothing' are omitted.
--
-- Keep the eta form (@encodeObject fs = \\a -> …@): it binds @prepared@ to
-- @fs@ so each field's @"name":@ prefix is escaped once per table, not per
-- record (the definitions / reexports arrays run this per row).
encodeObject :: [Field a] -> a -> String
encodeObject fs = \a -> "{" ++ intercalate "," (mapMaybe (emit a) prepared) ++ "}"
  where
    -- No local signature: @a@ here would be fresh (no ScopedTypeVariables).
    prepared =
      [ case f of
          Required n _ e -> (jsString n ++ ":", Just . e)
          Additive n _ e -> (jsString n ++ ":", Just . e)
          Optional n _ e -> (jsString n ++ ":", e)
      | f <- fs ]
    emit a (pfx, enc) = (pfx ++) <$> enc a

-- * Encoder helpers

-- | The generic array/object encoders ('jArray', 'jStrArray', 'jStrMap',
-- 'jStrArrMap') live in "AgdaDeps.Util" so this expanded path and the
-- packed/lazy path in "AgdaDeps.Backend.GraphJson" share one byte layout.

encEdge :: WireEdge -> String
encEdge (WireEdge (a, b)) = "[" ++ jsString a ++ "," ++ jsString b ++ "]"

-- | The @unsolvedModules@ object: module → @{metas, constraints}@ line
-- arrays. Shared with the packed emitter in "AgdaDeps.Backend.GraphJson"
-- so both forms produce identical bytes for the field.
unsolvedModulesJson :: [(String, ([Int], [Int]))] -> String
unsolvedModulesJson rows =
  "{" ++ intercalate "," [ jsString m ++ ":" ++ entry e | (m, e) <- rows ] ++ "}"
  where
    entry (ms, cs) =
      "{\"metas\":" ++ jArray show ms
      ++ ",\"constraints\":" ++ jArray show cs ++ "}"

-- * The field tables

-- | Top-level expanded object, in emission order.
expandedFields :: [Field ExpandedGraph]
expandedFields =
  [ Required "v"                         (SConstInt 2)            (const "2")
  , Required "schemaVersion"             (SConstInt 2)            (const "2")
  , Additive "nodeKeyVersion"            (SInteger (Just 1))      (show . egNodeKeyVersion)
  , Additive "producer"                  (SString Nothing)        (jsString . egProducer)
  , Required "mode"                      (SConstStr "expanded")   (const (jsString "expanded"))
  , Required "modules"                   strArr                   (jStrArray . egModules)
  , Required "entryModule"               (SNullableType "string") (maybe "null" jsString . egEntryModule)
  , Required "externalModules"           strArr                   (jStrArray . egExternals)
  , Required "failedModules"             strArr                   (jStrArray . egFailed)
  , Required "definitions"               (arrOf (SRef "definition")) (jArray (encodeObject definitionFields) . egDefs)
  , Required "definitionEdges"           (arrOf (SRef "edge"))    (jArray encEdge . egDefEdges)
  , Additive "definitionEdgesProvenance" (arrOf (SRef "provenance")) (jArray (jsString . provTag) . egDefEdgeProv)
  , Required "moduleEdges"               (arrOf (SRef "edge"))    (jArray encEdge . egModuleEdges)
  , Required "transitiveModuleEdges"     (arrOf (SRef "edge"))    (jArray encEdge . egTransModEdges)
  , Required "moduleFiles"               (SMap (SString Nothing)) (jStrMap . egModuleFiles)
  , Required "sourceFiles"               strArr                   (jStrArray . egSourceFiles)
  , Required "reexports"                 (arrOf (SRef "reexport")) (jArray (encodeObject reexportFields) . egReExports)
  , Optional "moduleOptionEscapes"       (SMap (arrOf (SString Nothing)))
      (\g -> let es = egModuleOptionEscapes g
             in if null es then Nothing else Just (jStrArrMap es))
  , Optional "unsolvedModules"           (SMap (SRef "unsolvedModule"))
      (\g -> let um = egUnsolvedModules g
             in if null um then Nothing else Just (unsolvedModulesJson um))
  , Optional "definitionSubtermHashes"   (arrOf nats)             (fmap (jArray natArr) . egSubtermHashes)
  , Optional "definitionSubtermDepths"   (arrOf nats)             (fmap (jArray natArrI) . egSubtermDepths)
  , Optional "externals_summary"         (SRef "externalsSummary") (fmap (encodeObject externalsSummaryFields) . egExternalsSummary)
  ]
  where
    strArr   = arrOf (SString Nothing)
    nats     = arrOf (SInteger (Just 0))
    natArr   = jArray (show :: Word64 -> String)
    natArrI  = jArray (show :: Int -> String)

arrOf :: SchemaDoc -> SchemaDoc
arrOf s = SArray s Nothing Nothing

-- | The @definition@ object (@$defs/definition@), in @defJson@ order.
definitionFields :: [Field WireDef]
definitionFields =
  [ Required "id"     (SInteger Nothing)       (show . wdId)
  , Required "name"   (SString Nothing)        (jsString . wdName)
  , Required "module" (SString Nothing)        (jsString . wdModule)
  , Required "state"  (SRef "state")           (jsString . wireState . wdState)
  , Required "kind"   (SRef "kind")            (jsString . wireKind . wdKind)
  , Optional "line"   (SInteger (Just 1))      (fmap show . wdLine)
  , Optional "access" (SRef "access")          (fmap (jsString . wireAccess) . wdAccess)
  , Optional "type"   (SString Nothing)        (fmap jsString . wdType)
  , Optional "unsafe" (arrOf (SRef "unsafeTag"))
      (\d -> if null (wdUnsafe d) then Nothing
             else Just (jArray (jsString . wireUnsafe) (wdUnsafe d)))
  , Optional "unsolvedMetas" (SInteger (Just 1))
      (\d -> if wdUnsolvedMetas d <= 0 then Nothing
             else Just (show (wdUnsolvedMetas d)))
  , Required "x"      (SNullableType "number") (maybe "null" show . wdX)
  , Required "y"      (SNullableType "number") (maybe "null" show . wdY)
  ]

-- | The @reexport@ object (@$defs/reexport@), encoded from a
-- @(from, to, names, renames)@ row. @renames@ maps each renamed
-- in-scope alias to the canonical @nodeKey@ (a member of @names@);
-- it is optional and omitted when the row has no renamed entries, so
-- rename-free corpora stay byte-identical.
reexportFields :: [Field (String, String, [String], [(String, String)])]
reexportFields =
  [ Required "from"    (SString Nothing)         (\(f, _, _, _) -> jsString f)
  , Required "to"      (SString Nothing)         (\(_, t, _, _) -> jsString t)
  , Required "names"   (arrOf (SString Nothing)) (\(_, _, ns, _) -> jStrArray ns)
  , Optional "renames" (SMap (SString Nothing))  (\(_, _, _, rs) -> if null rs then Nothing else Just (jStrMap rs))
  ]

-- | The @externalsSummary@ object (@$defs/externalsSummary@).
externalsSummaryFields :: [Field WireExternals]
externalsSummaryFields =
  [ Required "modules"              (arrOf (SString Nothing))        (jStrArray . weModules)
  , Required "postulates_by_module" (SMap (arrOf (SString Nothing))) (jStrArrMap . wePostulatesByModule)
  ]

-- | Shared @$defs@ shapes, mirroring the committed schema.
defsRegistry :: [(String, SchemaDoc)]
defsRegistry =
  [ ("edge",       SArray (SString Nothing) (Just 2) (Just 2))
  , ("state",      SString (Just ["D", "P", "H", "F"]))
  , ("kind",       SString (Just [ "function", "projection", "datatype"
                                  , "record", "constructor", "postulate"
                                  , "primitive", "other" ]))
  , ("access",     SString (Just ["private", "public"]))
  , ("provenance", SString (Just [ "signature", "body", "module-local"
                                  , "with", "unknown" ]))
  , ("unsafeTag",  SString (Just [ "non-terminating", "trustme" ]))
  , ("unsolvedModule",
      SObject ["metas", "constraints"]
              [ ("metas",       arrOf (SInteger (Just 1)))
              , ("constraints", arrOf (SInteger (Just 1))) ]
              True)
  , ("definition",       objectSchemaOf definitionFields)
  , ("reexport",         objectSchemaOf reexportFields)
  , ("externalsSummary", objectSchemaOf externalsSummaryFields)
  ]

-- * Rendering the schema to text

jobj :: [(String, String)] -> String
jobj kvs = "{" ++ intercalate "," [ jsString k ++ ":" ++ v | (k, v) <- kvs ] ++ "}"

jarr :: [String] -> String
jarr xs = "[" ++ intercalate "," xs ++ "]"

jbool :: Bool -> String
jbool b = if b then "true" else "false"

-- | Render a 'SchemaDoc' to a compact JSON Schema fragment.
renderSchema :: SchemaDoc -> String
renderSchema sd = case sd of
  SObject reqd props addP ->
    jobj $ [ ("type", jsString "object")
           , ("additionalProperties", jbool addP) ]
        ++ [ ("required", jarr (map jsString reqd)) | not (null reqd) ]
        ++ [ ("properties", jobj [ (k, renderSchema v) | (k, v) <- props ]) ]
  SArray items mn mx ->
    jobj $ [ ("type", jsString "array")
           , ("items", renderSchema items) ]
        ++ [ ("minItems", show n) | Just n <- [mn] ]
        ++ [ ("maxItems", show n) | Just n <- [mx] ]
  SMap val ->
    jobj [ ("type", jsString "object")
         , ("additionalProperties", renderSchema val) ]
  SString Nothing   -> jobj [ ("type", jsString "string") ]
  SString (Just es) -> jobj [ ("type", jsString "string")
                            , ("enum", jarr (map jsString es)) ]
  SInteger Nothing  -> jobj [ ("type", jsString "integer") ]
  SInteger (Just m) -> jobj [ ("type", jsString "integer"), ("minimum", show m) ]
  SConstInt n       -> jobj [ ("const", show n) ]
  SConstStr s       -> jobj [ ("const", jsString s) ]
  SNullableType t   -> jobj [ ("type", jarr [jsString t, jsString "null"]) ]
  SRef name         -> jobj [ ("$ref", jsString ("#/$defs/" ++ name)) ]

-- | The generated JSON Schema for the expanded @graph.json@, as text.
expandedSchemaJson :: String
expandedSchemaJson = jobj
  [ ("$schema", jsString "https://json-schema.org/draft/2020-12/schema")
  , ("title",   jsString "agda-deps v2 graph.json (expanded mode)")
  , ("type",    jsString "object")
  , ("additionalProperties", jbool True)
  , ("required", jarr (map jsString [ fName f | f <- expandedFields, fInRequired f ]))
  , ("properties", jobj [ (fName f, renderSchema (fSchema f)) | f <- expandedFields ])
  , ("$defs", jobj [ (n, renderSchema d) | (n, d) <- defsRegistry ])
  ]

-- | Encode an 'ExpandedGraph' to wire JSON.
encodeExpanded :: ExpandedGraph -> String
encodeExpanded = encodeObject expandedFields

-- | Structural invariants the JSON Schema cannot express: the parallel
-- arrays line up, and every edge endpoint names a definition. Returns
-- human-readable violations ('[]' = valid); 'buildExpandedJson' aborts
-- on a non-empty result rather than emit a malformed graph.
validateExpanded :: ExpandedGraph -> [String]
validateExpanded eg = concat
  [ ck (length (egDefEdgeProv eg) == length (egDefEdges eg))
       "definitionEdgesProvenance length /= definitionEdges length"
  , maybe [] (\hs -> ck (length hs == nDefs)
       "definitionSubtermHashes length /= definitions length") (egSubtermHashes eg)
  , maybe [] (\ds -> ck (length ds == nDefs)
       "definitionSubtermDepths length /= definitions length") (egSubtermDepths eg)
  , ck (null danglers)
       ("definitionEdges endpoints absent from definitions, e.g. "
        ++ show (take 3 danglers))
  ]
  where
    nDefs    = length (egDefs eg)
    names    = S.fromList (map wdName (egDefs eg))
    danglers = [ (s, t) | WireEdge (s, t) <- egDefEdges eg
                        , not (S.member s names) || not (S.member t names) ]
    ck cond msg = if cond then [] else [msg]
