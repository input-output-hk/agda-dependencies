{-# LANGUAGE CPP #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Main (main) where

import qualified Control.Exception as E
import Control.Monad ( unless )
import qualified Data.ByteString.Lazy as BL
#ifndef mingw32_HOST_OS
import Data.Bits ( (.&.) )
#endif
import Data.List ( isPrefixOf )
import qualified Data.Text.Lazy as TL
import System.Directory
  ( createDirectory, createDirectoryIfMissing, createDirectoryLink
  , getTemporaryDirectory, listDirectory, removeFile, removePathForcibly )
import System.FilePath ( (</>) )
import System.IO ( hClose, openTempFile )
#ifndef mingw32_HOST_OS
import System.Posix.Files ( fileMode, getFileStatus, setFileMode )
#endif

import AgdaDeps.AtomicWrite
  ( atomicWriteLazyBytes, atomicWriteLazyText, atomicWriteString )
import AgdaDeps.Backend.Wire
  ( ExpandedGraph(..), WireDef(..), WireEdge(..), validateExpanded )
import AgdaDeps.Deps ( DefKind(..) )
import AgdaDeps.Layout ( Position(..), computePositions, sfdpNodeThreshold )
import AgdaDeps.Options ( DefState(..) )
import AgdaDeps.Precompute ( discoverAgdaFiles )

main :: IO ()
main = withTempDir $ \tmp -> do
  testAtomicWrites tmp
  testDiscovery tmp
  testFallbackLayout
  testWireValidation
  putStrLn "hardening tests OK"

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
