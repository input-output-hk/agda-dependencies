{-# LANGUAGE CPP #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Main (main) where

import qualified Control.Exception as E
import Control.Monad ( foldM, unless )
import qualified Data.ByteString.Lazy as BL
#ifndef mingw32_HOST_OS
import Data.Bits ( (.&.) )
#endif
import Data.List ( isPrefixOf, permutations )
import qualified Data.Text.Lazy as TL
import System.Directory
  ( createDirectory, createDirectoryIfMissing, createDirectoryLink, createFileLink
  , getTemporaryDirectory, listDirectory, removeFile, removePathForcibly
  , withCurrentDirectory )
import System.FilePath ( (</>) )
import System.IO ( hClose, openTempFile )
#ifndef mingw32_HOST_OS
import System.Posix.Files ( fileMode, getFileStatus, setFileMode )
#endif

import AgdaDeps.AtomicWrite
  ( atomicWriteLazyBytes, atomicWriteLazyText, atomicWriteString )
import AgdaDeps.Arguments
  ( Argument(..), normalizeArguments, renderArguments, sourceRoots, firstSource
  , hasOption, lastOptionValue, inferredFormat )
import Agda.Utils.GetOpt ( OptDescr(..), ArgDescr(..), ArgOrder(Permute), getOpt' )
import AgdaDeps.Backend.Wire
  ( ExpandedGraph(..), WireDef(..), WireEdge(..), validateExpanded )
import AgdaDeps.Deps ( DefKind(..) )
import AgdaDeps.Layout ( Position(..), computePositions, sfdpNodeThreshold )
import AgdaDeps.Options
  ( DefState(..), OutputFormat(..), Options(..), ColorPalette(..)
  , defaultOptions, colorOpt, applyCliPalette )
import AgdaDeps.Precompute ( discoverAgdaFiles )
import AgdaDeps.Util ( underCwd )

main :: IO ()
main = withTempDir $ \tmp -> do
  testAtomicWrites tmp
  testDiscovery tmp
  testContainment tmp
  testArguments
  testCliPalette
  testFallbackLayout
  testWireValidation
  putStrLn "hardening tests OK"

-- Compare normalisation with Agda's actual GetOpt on short clusters,
-- attached/required/optional operands, unknown options and '--'. Values
-- deliberately look like flags and source files to catch rescanning.
testArguments :: IO ()
testArguments = do
  let tagged name value = name ++ ":" ++ value
      descriptors =
        [ Option ['o'] ["out-dir"] (ReqArg (tagged "out") "DIR") ""
        , Option ['i'] ["include-path", "include"] (ReqArg (tagged "include") "DIR") ""
        , Option ['l'] ["library"] (ReqArg (tagged "library") "LIB") ""
        , Option [] ["config"] (ReqArg (tagged "config") "PATH") ""
        , Option [] ["format"] (ReqArg (tagged "format") "FMT") ""
        , Option ['q'] ["quiet"] (NoArg "quiet") ""
        , Option ['?'] ["help"] (OptArg (tagged "help" . maybe "bare" id) "TOPIC") ""
        ]
      syntax = map (fmap (const ())) descriptors
      parse = getOpt' Permute descriptors
      tokens = ["-", "--", "Entry.agda", "--unknown", "--quiet", "-q?warning",
                "-ZqiDIR", "-o", "-o=literal", "-iDIR", "-lLIB", "--config",
                "--config=--quiet", "--help", "--help=warning", "-?warning",
                "--out-dir", "--out-dir=last.json", "--quiet=yes", "--include=DIR"]
  mapM_ (\argv -> case normalizeArguments syntax argv of
      Left e -> let (_, _, _, errors) = parse argv in
        assert ("normalisation rejected valid argv: " ++ show argv)
          (not (null e) && not (null errors))
      Right args -> assert ("normalisation disagrees with GetOpt: " ++ show argv)
        (parse argv == parse (renderArguments args)))
    (concat [sequence (replicate n tokens) | n <- [0..3]])
  let normalized argv = either (error . ("invalid test argv: " ++)) id
                          (normalizeArguments syntax argv)
      operands = normalized ["--config", "--quiet", "--", "-iOther", "Entry.agda"]
  assert "option values or '--' operands were inspected as flags"
    (not (hasOption "--quiet" operands) && sourceRoots operands == ["."]
      && firstSource operands == Just "Entry.agda"
      && lastOptionValue "--config" operands == Just "--quiet")
  assert "attached include/library arguments lost"
    (sourceRoots (normalized ["-iDIR", "-lLIB"]) == ["DIR"]
      && hasOption "--library" (normalized ["-lLIB"]))
  assert "format inference does not use the last output"
    (inferredFormat (normalized ["-ofirst.dot", "-o", "last.json"]) == Just FmtJson
      && inferredFormat (normalized ["-ofirst.json", "--out-dir=last.dot"]) == Just FmtDot
      && inferredFormat (normalized ["-ofirst.json", "-o", "directory"]) == Nothing
      && inferredFormat (normalized ["-olast.json", "--format=dot"]) == Nothing)
  assert "end-of-options marker lost"
    (EndOptions `elem` operands)

-- All placements of a theme and four explicit colour choices must produce
-- the same palette. Exercise the shared actions used by both argv parsers.
testCliPalette :: IO ()
testCliPalette = do
  let base = ColorPalette "#110000" "#220000" "#330000" "#440000"
      later = ColorPalette "#001100" "#002200" "#003300" "#004400"
      chosen = ColorPalette "#111111" "#222222" "#333333" "#444444"
      seed = defaultOptions{ optColors = base }
      theme palette = pure . applyCliPalette palette
      defined = colorOpt "color-defined" Defined "#111111"
      hole = colorOpt "color-hole" Hole "#333333"
      colours =
        [ defined
        , colorOpt "color-postulate" Postulate "#222222"
        , hole
        , colorOpt "color-failed" Failed "#444444"
        ]
      parse :: [Options -> Either String Options] -> Either String Options
      parse = foldM (\opts action -> action opts) seed
      expect label expected actions = case parse actions of
        Left e -> ioError (userError (label ++ ": " ++ e))
        Right opts -> assert label (optColors opts == expected)
  mapM_ (expect "CLI palette depends on flag order" chosen)
    (permutations (theme later : colours))
  expect "CLI theme did not replace the config palette" later [theme later]
  expect "last theme or per-state override lost"
    later{ colorDefined = "#abcdef", colorHole = "#333333" }
    [ defined, theme base, hole
    , colorOpt "color-defined" Defined "#abcdef", theme later ]
  case parse [colorOpt "color-defined" Defined "invalid", theme later, defined] of
    Left _ -> pure ()
    Right _ -> ioError (userError "a later palette choice hid an invalid CLI colour")

assert :: String -> Bool -> IO ()
assert label ok = unless ok (ioError (userError label))

withTempDir :: (FilePath -> IO a) -> IO a
withTempDir action = E.bracket acquire removePathForcibly action
  where
    acquire = do
      base <- getTemporaryDirectory
      (path, h) <- openTempFile base "agda-deps-hardening"
      hClose h
      removeFile path
      createDirectory path
      pure path

testAtomicWrites :: FilePath -> IO ()
testAtomicWrites tmp = do
  let stringPath = tmp </> "string.txt"
      textPath   = tmp </> "text.txt"
      bytesPath  = tmp </> "bytes.bin"
  atomicWriteString stringPath "old"
#ifndef mingw32_HOST_OS
  setFileMode stringPath 0o640
#endif
  atomicWriteString stringPath "replacement"
  stringBody <- strictReadFile stringPath
  assert "atomic string replacement changed content" (stringBody == "replacement")
#ifndef mingw32_HOST_OS
  mode <- fileMode <$> getFileStatus stringPath
  assert "atomic replacement changed existing file permissions"
    (mode .&. 0o777 == 0o640)
#endif

  atomicWriteLazyText textPath (TL.pack "λ-text")
  textBody <- strictReadFile textPath
  assert "atomic lazy Text changed content" (textBody == "λ-text")

  let expectedBytes = BL.pack [0, 1, 2, 127, 128, 255]
  atomicWriteLazyBytes bytesPath expectedBytes
  bytesBody <- BL.readFile bytesPath
  BL.length bytesBody `seq`
    assert "atomic lazy bytes changed content" (bytesBody == expectedBytes)

  entries <- listDirectory tmp
  assert "atomic writer left a temporary file"
    (not (any ("." `isPrefixOf`) entries))

testDiscovery :: FilePath -> IO ()
testDiscovery tmp = do
  let root   = tmp </> "scan"
      nested = root </> "z"
      hidden = root </> ".hidden"
      first  = root </> "A.agda"
      second = nested </> "B.lagda.md"
  createDirectoryIfMissing True nested
  createDirectoryIfMissing True hidden
  writeFile first "module A where\n"
  writeFile second "module B where\n"
  writeFile (hidden </> "Ignored.agda") "module Ignored where\n"
  -- A canonical visited-directory set must make this alias harmless.  Some
  -- platforms disallow directory symlinks for unprivileged users; discovery
  -- determinism is still tested there without the alias.
  createDirectoryLink root (root </> "loop")
    `E.catch` \(_ :: E.IOException) -> pure ()
  files <- discoverAgdaFiles root
  assert "source discovery is not deterministic or followed a directory alias"
    (files == [first, second])

testContainment :: FilePath -> IO ()
testContainment tmp = do
  let root = tmp </> "project"
      sibling = tmp </> "project-old"
      local = root </> "Local.agda"
      external = sibling </> "External.agda"
  createDirectoryIfMissing True (root </> "nested")
  createDirectory sibling
  writeFile local "module Local where\n"
  writeFile external "module External where\n"
  withCurrentDirectory root $ do
    inside <- underCwd
    let expect label expected path = do
          actual <- inside path
          assert label (actual == expected)
    expect "local source classified external" True local
    expect "relative local source classified external" True "Local.agda"
    expect "sibling prefix classified internal" False external
    expect "dot-dot escape classified internal" False
      (root </> ".." </> "project-old" </> "External.agda")
    expect "dot-dot descendant classified external" True
      (root </> "nested" </> ".." </> "Local.agda")
    expect "missing source classified internal" False (root </> "Missing.agda")
#ifndef mingw32_HOST_OS
    let outgoing = root </> "Outgoing.agda"
        incoming = sibling </> "Incoming.agda"
        directoryAlias = root </> "alias"
        broken = root </> "Broken.agda"
    createFileLink external outgoing
    createFileLink local incoming
    createDirectoryLink sibling directoryAlias
    createFileLink (sibling </> "Missing.agda") broken
    expect "outgoing symlink classified internal" False outgoing
    expect "incoming symlink classified external" True incoming
    expect "directory symlink classified internal" False
      (directoryAlias </> "External.agda")
    -- Resolve the directory alias before '..': this path lands at tmp,
    -- rather than at root as a lexical normalisation would suggest.
    expect "symlink dot-dot escape classified internal" False
      (directoryAlias </> ".." </> "project-old" </> "External.agda")
    expect "broken symlink classified internal" False broken
#endif

testFallbackLayout :: IO ()
testFallbackLayout = do
  let nodes = [ (i, i `mod` 7) | i <- [0 .. sfdpNodeThreshold] ]
  a <- computePositions nodes []
  b <- computePositions nodes []
  let coords = map (\p -> (posX p, posY p))
  assert "fallback layout omitted nodes" (length a == length nodes)
  assert "fallback layout is not deterministic" (coords a == coords b)

testWireValidation :: IO ()
testWireValidation = do
  assert "minimal expanded graph failed validation" (null (validateExpanded validGraph))
  assertFinding "duplicate definition names"
    validGraph { egDefs = [wireDef, wireDef { wdId = 1 }] }
  assertFinding "duplicate definition ids"
    validGraph { egDefs = [wireDef, wireDef { wdName = "M.g" }] }
  assertFinding "module edge endpoints absent"
    validGraph { egModuleEdges = [WireEdge ("M", "Missing")] }
  assertFinding "subterm hash/depth row lengths differ"
    validGraph { egSubtermHashes = Just [[1]], egSubtermDepths = Just [[]] }
  assertFinding "moduleFiles keys absent"
    validGraph { egModuleFiles = [("Missing", "Missing.agda")] }
  assertFinding "moduleFiles keys absent"
    validGraph { egDefs = [], egModuleFiles = [("Missing", "Missing.agda")] }
  assertFinding "externalModules entries absent"
    validGraph { egExternals = ["Missing"] }
  where
    assertFinding prefix graph =
      assert ("wire validator missed: " ++ prefix)
        (any (prefix `isPrefixOf`) (validateExpanded graph))

validGraph :: ExpandedGraph
validGraph = ExpandedGraph
  { egNodeKeyVersion = 3
  , egProducer = "test"
  , egModules = ["M"]
  , egEntryModule = Just "M"
  , egExternals = []
  , egFailed = []
  , egDefs = [wireDef]
  , egDefEdges = []
  , egDefEdgeProv = []
  , egModuleEdges = []
  , egTransModEdges = []
  , egModuleFiles = [("M", "M.agda")]
  , egSourceFiles = ["M.agda"]
  , egReExports = []
  , egModuleOptionEscapes = []
  , egModuleEffectiveOptions = []
  , egUnsolvedModules = []
  , egSubtermHashes = Nothing
  , egSubtermDepths = Nothing
  , egExternalsSummary = Nothing
  }

wireDef :: WireDef
wireDef = WireDef
  { wdId = 0
  , wdName = "M.f"
  , wdModule = "M"
  , wdState = Defined
  , wdKind = DKFunction
  , wdLine = Just 1
  , wdAccess = Nothing
  , wdType = Nothing
  , wdUnsafe = []
  , wdUnsolvedMetas = 0
  , wdArgUsage = Nothing
  , wdX = Nothing
  , wdY = Nothing
  }

strictReadFile :: FilePath -> IO String
strictReadFile path = do
  body <- readFile path
  length body `seq` pure body
