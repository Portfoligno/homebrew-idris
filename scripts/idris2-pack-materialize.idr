-- Materialize a dated idris2-pack@<date>.rb into the tapped working tree from
-- the committed versions.json + Formula/idris2-pack.rb.erb.
--
-- This is the logic behind the external brew command `brew idris2-pack-pin`.
-- The committed entry point cmd/brew-idris2-pack-pin is a thin POSIX sh
-- launcher that compiles this source on first use with the idris2-pack keg's
-- idris2 (Chez backend, -p contrib) into the gitignored build/ tree, caching
-- the result and recompiling only when this source changes. No binary is
-- committed, so pinning requires idris2-pack (which provides idris2 + Chez)
-- to be installed first.
--
-- It COPIES per-version data (URLs, SHAs, commits, ipkg steps) out of the
-- manifest and renders the eight <%= ENV.fetch('...') %> markers of the
-- committed ERB body with the real `erb` engine -- the same engine and the same
-- env contract scripts/update-formula.hell uses for the main formula. The eight
-- tokens are delivered through the environment (never on erb's command line) and
-- erb's stdout is captured verbatim. Three non-ERB transforms then run in Idris
-- by guarded literal replacement: the bottle block over the placeholder comment,
-- the class rename Idris2Pack -> Idris2PackAT<date>, and the keg_only
-- :versioned_formula insert. `erb` is therefore a render-time dependency, located
-- via $IDRIS2_PACK_PIN_ERB, $HOMEBREW_RUBY_PATH's sibling erb, or /usr/bin/erb --
-- no regex, no hashing, no network. A missing/short/non-hex field, a missing erb
-- env var, a missing template anchor, an unrendered tag, or an unknown version is
-- a hard error (die), never a silent default.
--
-- Usage (as the brew external command, argv0 = .../cmd/brew-idris2-pack-pin):
--   brew idris2-pack-pin <YYYY.MM.DD> [<YYYY.MM.DD> ...]   materialize one/more
--   brew idris2-pack-pin --all                             materialize every entry
--   brew idris2-pack-pin --list                            list manifest versions
--   brew idris2-pack-pin --prune                           remove generated @*.rb
--                                                          not in the manifest
--   brew idris2-pack-pin --install <YYYY.MM.DD>            materialize then
--                                                          exec `brew install ...`
--
-- The tap root comes from HOMEBREW_IDRIS_TAP, which the sh launcher exports
-- (the compiled binary runs from build/, so its argv0 is not under cmd/);
-- otherwise it is derived from argv0 by stripping "/cmd/brew-idris2-pack-pin".

module Main

import Data.List
import Data.List1
import Data.Maybe
import Data.String
import System
import System.Directory
import System.File
import Language.JSON
import Language.JSON.Data

%default total

-- ===========================================================================
-- Small fail-loud helpers
-- ===========================================================================

||| Abort with a message on stderr and a non-zero exit code.
covering
abort : String -> IO a
abort msg = do
  ignore (fPutStrLn stderr ("idris2-pack-pin: " ++ msg))
  exitFailure

||| Collapse an Either into IO, dying on Left.
covering
orDie : Either String a -> IO a
orDie (Left e)  = abort e
orDie (Right x) = pure x

-- ===========================================================================
-- Typed JSON accessors (fail-loud, no sentinels)
-- ===========================================================================

field : String -> JSON -> Either String JSON
field k (JObject kvs) =
  maybe (Left ("missing field: " ++ k)) Right (lookup k kvs)
field k _ = Left ("expected an object while reading field: " ++ k)

asString : JSON -> Either String String
asString (JString s) = Right s
asString _           = Left "expected a JSON string"

asArray : JSON -> Either String (List JSON)
asArray (JArray xs) = Right xs
asArray _           = Left "expected a JSON array"

||| Read an integer that the JSON encodes as a (whole) number.
asInt : JSON -> Either String Integer
asInt (JNumber d) = Right (cast d)
asInt _           = Left "expected a JSON number"

strField : String -> JSON -> Either String String
strField k j = field k j >>= asString

||| A sha256 must be exactly 64 hex characters; anything else is a hard error
||| rather than a value that would mis-pour. Uses Prelude.isHexDigit.
shaField : String -> JSON -> Either String String
shaField k j = do
  s <- strField k j
  let cs = unpack s
  if length cs == 64 && all isHexDigit cs
    then Right s
    else Left ("field '" ++ k ++ "' is not a 64-hex sha256: " ++ s)

-- ===========================================================================
-- Manifest data model
-- ===========================================================================

record Lib where
  constructor MkLib
  name   : String
  url    : String
  sha256 : String
  ipkgs  : List String   -- ordered --install steps from one tarball

record BottleEntry where
  constructor MkBottleEntry
  os     : String
  sha256 : String

record Entry where
  constructor MkEntry
  version      : String
  collection   : String
  packCommit   : String
  packSha      : String
  idris2Commit : String
  idris2Sha    : String
  rootUrl      : String
  rebuild      : Integer        -- 0 => no rebuild line
  cellar       : String
  entries      : List BottleEntry
  libs         : List Lib

parseLib : JSON -> Either String Lib
parseLib j = do
  name  <- strField "name"   j
  url   <- strField "url"    j
  sha   <- shaField "sha256" j
  steps <- field "ipkgs" j >>= asArray >>= traverse asString
  case steps of
    [] => Left ("library '" ++ name ++ "' has an empty ipkgs list")
    _  => Right (MkLib name url sha steps)

parseBottleEntry : JSON -> Either String BottleEntry
parseBottleEntry j = do
  o   <- strField "os"     j
  sha <- shaField "sha256" j
  Right (MkBottleEntry o sha)

parseEntry : JSON -> Either String Entry
parseEntry j = do
  ver  <- strField "version"    j
  col  <- strField "collection" j
  pk   <- field "pack"   j
  pCom <- strField "commit" pk
  pSha <- shaField "sha256" pk
  id2  <- field "idris2" j
  iCom <- strField "commit" id2
  iSha <- shaField "sha256" id2
  bot  <- field "bottle" j
  root <- strField "root_url" bot
  reb  <- field "rebuild" bot >>= asInt
  cel  <- strField "cellar" bot
  ents <- field "entries" bot >>= asArray >>= traverse parseBottleEntry
  case ents of
    [] => Left ("version '" ++ ver ++ "' has no bottle entries")
    _  => pure ()
  libs <- field "libraries" j >>= asArray >>= traverse parseLib
  Right (MkEntry ver col pCom pSha iCom iSha root reb cel ents libs)

||| The manifest's .versions object as an ordered association list.
manifestVersions : JSON -> Either String (List (String, JSON))
manifestVersions root = do
  vs <- field "versions" root
  case vs of
    JObject kvs => Right kvs
    _           => Left "manifest .versions must be an object"

selectEntry : String -> JSON -> Either String Entry
selectEntry v root = do
  kvs <- manifestVersions root
  case lookup v kvs of
    Just j  => parseEntry j
    Nothing =>
      Left ("version not in manifest: " ++ v ++ "\navailable: "
            ++ unwords (map fst kvs))

-- ===========================================================================
-- Rendering (erb for the 8 tokens; guarded literal transforms for the rest)
-- ===========================================================================

||| Split on the FIRST occurrence of `n`; returns (before, Just after) or
||| (whole, Nothing) when absent. `n` is assumed non-empty by callers.
splitFirst : String -> String -> (String, Maybe String)
splitFirst n s = go "" s
  where
    go : String -> String -> (String, Maybe String)
    go acc cur =
      if isPrefixOf n cur
        then (acc, Just (substr (length n) (length cur) cur))
        else case strUncons cur of
               Nothing       => (acc ++ cur, Nothing)
               Just (c, rst) => go (acc ++ singleton c) (assert_smaller cur rst)

||| Replace every occurrence of `n` with `r` in `s` (Idris base has no
||| Text.replace; recurse over the tail after each match).
covering
replaceAll : String -> String -> String -> String
replaceAll n r s =
  case n of
    "" => s
    _  => case splitFirst n s of
            (pre, Nothing)   => pre
            (pre, Just rest) => pre ++ r ++ replaceAll n r rest

||| Guarded literal replacement of all occurrences. Dies (Left) if the anchor
||| is absent, so an ERB drift is a hard error not a silent no-op.
covering
replaceChecked : String -> String -> String -> String -> Either String String
replaceChecked label needle repl haystack =
  if isInfixOf needle haystack
    then Right (replaceAll needle repl haystack)
    else Left (label ++ ": anchor not found: " ++ needle)

renderResource : Lib -> String
renderResource l =
  "  resource \"" ++ l.name ++ "\" do\n" ++
  "    url \"" ++ l.url ++ "\"\n" ++
  "    sha256 \"" ++ l.sha256 ++ "\"\n" ++
  "  end"

renderInstall : Lib -> String
renderInstall l =
  let steps = map (\s => "      system idris2_bin, \"--install\", \"" ++ s ++ "\"") l.ipkgs
  in "    resource(\"" ++ l.name ++ "\").stage do\n" ++
     joinBy "\n" steps ++ "\n" ++
     "    end"

||| The bottle block over the placeholder comment lines, alignment computed
||| from tag lengths (longest tag gets a single space; shorter tags get
||| extra spaces so the opening quotes line up).
renderBottle : Entry -> String
renderBottle e =
  let tags   = map os e.entries
      maxLen = foldl (\a, t => max a (length t)) 0 tags
      rebLn  = if e.rebuild == 0 then [] else ["    rebuild " ++ show e.rebuild]
      shaLn  = map (renderShaLine maxLen) e.entries
  in joinBy "\n" (rebLn ++ shaLn)
  where
    renderShaLine : Nat -> BottleEntry -> String
    renderShaLine maxLen be =
      let pad = pack (replicate (minus maxLen (length be.os) + 1) ' ')
      in "    sha256 cellar: :" ++ e.cellar ++ ", " ++ be.os ++ ":" ++ pad ++
         "\"" ++ be.sha256 ++ "\""

||| The 3-line placeholder comment block in the .erb (lines 12-14). Stored as
||| one literal anchor; replaced wholesale by the rendered bottle block.
bottlePlaceholder : String
bottlePlaceholder =
  "    # sha256 lines auto-generated by `brew bottle --merge --write`\n" ++
  "    # sha256 cellar: :any, arm64_sequoia: \"...\"\n" ++
  "    # sha256 cellar: :any, arm64_sonoma:  \"...\""

||| version "2026.06.05" -> "20260605"
classSuffix : String -> String
classSuffix = pack . filter (/= '.') . unpack

||| The 8 ERB tokens as (name, value) pairs -- the SAME strings the old inline
||| replacement used, so erb's output is byte-identical to the old pipeline.
||| Mirrors the producer's env in scripts/update-formula.hell.
erbEnv : Entry -> List (String, String)
erbEnv e =
  [ ("VERSION",                e.version)
  , ("COLLECTION",             e.collection)
  , ("PACK_COMMIT",            e.packCommit)
  , ("PACK_SHA256",            e.packSha)
  , ("IDRIS2_COMMIT",          e.idris2Commit)
  , ("IDRIS2_SHA256",          e.idris2Sha)
  , ("RESOURCE_BLOCKS",        joinBy "\n\n" (map renderResource e.libs))
  , ("LIBRARY_INSTALL_BLOCKS", joinBy "\n\n" (map renderInstall  e.libs))
  ]

||| The three NON-ERB transforms, applied to erb's output in order: the bottle
||| block over the comment placeholder, the class rename, and the keg_only
||| insert -- all by guarded literal replacement, lifted verbatim from the old
||| renderFormula Steps C and D.
covering
applyVersionedTransforms : Entry -> String -> Either String String
applyVersionedTransforms e erbOut = do
  -- Step C: the final bottle block over the placeholder comment block.
  s9 <- replaceChecked "bottle block" bottlePlaceholder (renderBottle e) erbOut
  -- Step D: class rename + keg_only insert.
  s10 <- replaceChecked "class rename"
           "class Idris2Pack < Formula"
           ("class Idris2PackAT" ++ classSuffix e.version ++ " < Formula") s9
  replaceChecked "keg_only insert"
    "  end\n\n  depends_on"
    "  end\n\n  keg_only :versioned_formula\n\n  depends_on" s10

-- ===========================================================================
-- Tap-root discovery + paths
-- ===========================================================================

||| argv0 = ".../Library/Taps/<user>/homebrew-idris/cmd/brew-idris2-pack-pin".
||| Strip the trailing "/cmd/<name>" to recover the tap working-tree root.
stripCmdTail : List String -> Maybe (List String)
stripCmdTail (name :: cmdSeg :: rest) =
  if cmdSeg == "cmd" then Just (reverse rest) else Nothing
stripCmdTail _ = Nothing

tapRootFromArgv0 : String -> Maybe String
tapRootFromArgv0 p =
  let parts : List String := forget (split (\c => c == '/') p)
  in map (joinBy "/") (stripCmdTail (reverse parts))

covering
resolveTapRoot : String -> IO String
resolveTapRoot self = do
  override <- getEnv "HOMEBREW_IDRIS_TAP"
  case override of
    Just r  => pure r
    Nothing => case tapRootFromArgv0 self of
      Just r  => pure r
      Nothing => abort ("cannot derive tap root from argv0: " ++ self ++
                        "\nset HOMEBREW_IDRIS_TAP to the tap working-tree root")

manifestPath : String -> String
manifestPath root = root ++ "/versions.json"

erbPath : String -> String
erbPath root = root ++ "/Formula/idris2-pack.rb.erb"

formulaPath : String -> String -> String
formulaPath root v = root ++ "/Formula/idris2-pack@" ++ v ++ ".rb"

-- ===========================================================================
-- IO actions
-- ===========================================================================

covering
readManifest : String -> IO JSON
readManifest root = do
  let mp = manifestPath root
  Right raw <- readFile mp
    | Left err => abort ("cannot read manifest " ++ mp ++ ": " ++ show err)
  case JSON.parse raw of
    Just j  => pure j
    Nothing => abort ("invalid JSON in " ++ mp)

||| ".../bin/ruby" -> Just ".../bin/erb": replace the final '/'-separated
||| component (ruby) with erb. brew exports HOMEBREW_RUBY_PATH to external
||| commands, and portable-ruby ships erb beside ruby.
siblingErb : String -> Maybe String
siblingErb ruby =
  let parts : List String := forget (split (== '/') ruby)
  in case dropLast parts of
       []   => Nothing
       dirs => Just (joinBy "/" dirs ++ "/erb")
  where
    -- All components except the final one (the ruby binary name).
    dropLast : List String -> List String
    dropLast xs = reverse (drop 1 (reverse xs))

||| Locate an ABSOLUTE erb, failing loud if none exist. Order:
|||   1. $IDRIS2_PACK_PIN_ERB (override; if set but missing -> hard error),
|||   2. dirname($HOMEBREW_RUBY_PATH)/erb (brew's own portable-ruby erb),
|||   3. /usr/bin/erb (macOS system erb),
|||   4. else abort.
||| Bare PATH is deliberately NOT trusted (determinism).
covering
locateErb : IO String
locateErb = do
  ov <- getEnv "IDRIS2_PACK_PIN_ERB"
  case ov of
    Just p  => do
      ok <- exists p
      if ok then pure p
            else abort ("IDRIS2_PACK_PIN_ERB set but not found: " ++ p)
    Nothing => do
      hrp <- getEnv "HOMEBREW_RUBY_PATH"
      firstExisting (mapMaybe id [ hrp >>= siblingErb, Just "/usr/bin/erb" ])
  where
    erbMissingMsg : String
    erbMissingMsg =
      "erb (Ruby's template engine) is required to materialize dated formulae "
      ++ "but was not found. Tried $IDRIS2_PACK_PIN_ERB, $HOMEBREW_RUBY_PATH's "
      ++ "sibling erb, and /usr/bin/erb. Install Ruby (`brew install ruby`) or "
      ++ "set IDRIS2_PACK_PIN_ERB to an erb executable."
    covering
    firstExisting : List String -> IO String
    firstExisting []        = abort erbMissingMsg
    firstExisting (c :: cs) = do
      ok <- exists c
      if ok then pure c else firstExisting cs

||| Set one env var for the erb child, failing loud on a genuine system error.
||| overwrite=True guarantees our value wins over any pre-existing var AND that
||| each version in a loop overwrites the previous one's values (no stale leak).
covering
setEnvOrDie : (String, String) -> IO ()
setEnvOrDie (k, v) = do
  ok <- setEnv k v True
  when (not ok) $ abort ("cannot set environment variable " ++ k ++ " for erb")

||| Decode a pclose/wait status into a human-readable note for the error text.
||| The gate itself is just `st /= 0`; this only formats the message.
exitNote : Int -> String
exitNote st =
  if st `mod` 256 == 0
    then "exit code "        ++ show ((st `div` 256) `mod` 256)
    else "killed by signal " ++ show (st `mod` 128)

||| Render the 8 ERB tokens with the real erb engine: locate an absolute erb,
||| push the tokens through the environment (never on the command line), spawn
||| `erb <templatePath>` capturing stdout verbatim, check the exit status, and
||| guard against any unrendered tag. Fails loud at each stage.
covering
runErb : (erbAbs : String) -> (templateAbs : String) -> Entry -> IO String
runErb erbAbs templateAbs e = do
  traverse_ setEnvOrDie (erbEnv e)
  -- Typed argv list -> escapeCmd quotes each element. Token DATA is NOT here;
  -- only the located erb binary and the template PATH (a structured list
  -- element, never a hand-built command string, never interpolated data).
  Right h <- popen [erbAbs, templateAbs] Read
    | Left err => abort ("cannot start erb on " ++ templateAbs ++ ": " ++ show err)
  Right out <- fRead h
    | Left err => abort ("error reading erb output for " ++ templateAbs ++ ": " ++ show err)
  st <- pclose h
  when (st /= 0) $
    abort ("erb failed (" ++ exitNote st ++ ") rendering " ++ templateAbs)
  -- A rendered formula never contains "<%="; if it does, a tag was left
  -- unrendered (or removed from the template) -- a hard error, not a silent pass.
  when (isInfixOf "<%=" out) $
    abort ("erb left an unrendered tag while rendering " ++ templateAbs)
  pure out

||| Materialize one version: select, render via erb, apply the versioned
||| transforms, write (overwriting deterministically).
covering
materializeOne : String -> JSON -> (erbAbs : String) -> String -> IO ()
materializeOne root root_json erbAbs v = do
  entry <- orDie (selectEntry v root_json)
  -- Defensive: the keyed entry's own version must equal the request.
  when (entry.version /= v) $
    abort ("manifest inconsistency: key " ++ v ++
           " maps to version " ++ entry.version)
  erbOut <- runErb erbAbs (erbPath root) entry
  out    <- orDie (applyVersionedTransforms entry erbOut)
  let fp = formulaPath root v
  Right () <- writeFile fp out
    | Left err => abort ("cannot write " ++ fp ++ ": " ++ show err)
  ignore (fPutStrLn stderr ("materialized " ++ fp))

covering
cmdList : String -> JSON -> IO ()
cmdList _ root_json = do
  kvs <- orDie (manifestVersions root_json)
  traverse_ (putStrLn . fst) kvs

covering
cmdAll : String -> JSON -> (erbAbs : String) -> IO ()
cmdAll root root_json erbAbs = do
  kvs <- orDie (manifestVersions root_json)
  traverse_ (\(v, _) => materializeOne root root_json erbAbs v) kvs

||| Remove generated Formula/idris2-pack@<date>.rb whose date is not in the
||| manifest. Only touches files matching the dated pattern; never the main
||| formula or the template.
covering
cmdPrune : String -> JSON -> IO ()
cmdPrune root root_json = do
  kvs <- orDie (manifestVersions root_json)
  let known = map fst kvs
  let dir = root ++ "/Formula"
  Right names <- listDir dir
    | Left err => abort ("cannot list " ++ dir ++ ": " ++ show err)
  traverse_ (pruneOne known dir) names
  where
    -- Extract <date> from "idris2-pack@<date>.rb", else Nothing.
    datedName : String -> Maybe String
    datedName n =
      if isPrefixOf "idris2-pack@" n && isSuffixOf ".rb" n
        then let mid = substr (length "idris2-pack@")
                              (minus (length n) (length "idris2-pack@" + length ".rb"))
                              n
             in Just mid
        else Nothing
    covering
    pruneOne : List String -> String -> String -> IO ()
    pruneOne known dir n =
      case datedName n of
        Nothing => pure ()
        Just d  =>
          if elem d known
            then pure ()
            else do
              let fp = dir ++ "/" ++ n
              Right () <- removeFile fp
                | Left err => abort ("cannot remove " ++ fp ++ ": " ++ show err)
              ignore (fPutStrLn stderr ("pruned " ++ fp))

||| Materialize <date> then exec `brew install <tap>/idris2-pack@<date>`.
||| Arguments are passed as a typed list to `system` via a single argv-style
||| command; brew is on PATH for the external command.
covering
cmdInstall : String -> JSON -> (erbAbs : String) -> String -> IO ()
cmdInstall root root_json erbAbs v = do
  materializeOne root root_json erbAbs v
  let spec = "Portfoligno/idris/idris2-pack@" ++ v
  -- run brew install; propagate failure as a non-zero exit.
  code <- system ["brew", "install", spec]
  when (code /= 0) (exitWith (ExitFailure 1))

-- ===========================================================================
-- Entry point
-- ===========================================================================

usage : String
usage = unlines
  [ "usage:"
  , "  brew idris2-pack-pin <YYYY.MM.DD> [<YYYY.MM.DD> ...]"
  , "  brew idris2-pack-pin --all"
  , "  brew idris2-pack-pin --list"
  , "  brew idris2-pack-pin --prune"
  , "  brew idris2-pack-pin --install <YYYY.MM.DD>"
  ]

covering
main : IO ()
main = do
  argv <- getArgs
  case argv of
    [] => abort ("empty argv (no program name)\n" ++ usage)
    (self :: rest) => do
      root <- resolveTapRoot self
      case rest of
        [] => abort usage
        ["--list"] => do
          j <- readManifest root
          cmdList root j
        ["--all"] => do
          j <- readManifest root
          erb <- locateErb
          cmdAll root j erb
        ["--prune"] => do
          j <- readManifest root
          cmdPrune root j
        ["--install", v] => do
          j <- readManifest root
          erb <- locateErb
          cmdInstall root j erb v
        ("--install" :: _) => abort ("--install takes exactly one version\n" ++ usage)
        args =>
          if any (isPrefixOf "--") args
            then abort ("unknown option among: " ++ unwords args ++ "\n" ++ usage)
            else do
              j <- readManifest root
              erb <- locateErb
              traverse_ (materializeOne root j erb) args
