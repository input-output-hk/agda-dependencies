-- | Generic JSON graph artifact emitted with @--format=json@.
--
-- Shares the v2 graph.json schema with the HTML output via
-- 'AgdaDeps.Backend.GraphJson', so downstream tooling sees the same
-- shape as the in-browser viewer.
module AgdaDeps.Backend.Json
  ( renderJson
  ) where

import AgdaDeps.Options ( JsonMode(..) )

import AgdaDeps.Backend.GraphJson
  ( GraphInput, GraphJsonOutput(..)
  , buildGraphJson, buildExpandedJson )

-- | Emit the v2 graph.json for a fully-assembled 'GraphInput'. The
-- caller ("AgdaDeps.Backend") sets the JSON-specific fields
-- (@giReExports@, @giPackedAnalytical@) on the shared base input.
renderJson :: JsonMode -> GraphInput -> String
renderJson mode gi =
  case mode of
    JsonPacked   -> gjoGraphJson (buildGraphJson gi)
    JsonExpanded -> buildExpandedJson gi
