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
-- manifest and renders the eleven <%= ENV.fetch('...') %> markers of the
-- committed ERB body with the real `erb` engine -- the same engine and the same
-- env contract scripts/update-formula.hell uses for the main formula. The three
-- multi-line block tokens (RESOURCE_BLOCKS, LIBRARY_INSTALL_BLOCKS, BOTTLE_BLOCK)
-- are themselves built by per-element erb renders of the shared templates/*.rb.erb
-- partials (one erb invocation per resource / per --install step / per bottle
-- line, joined here with the centralized separators); only scalars and those
-- joins remain in code. All eleven main tokens are delivered through the
-- environment (never on erb's command line) and the MAIN render's stdout is
-- captured verbatim with NO post-render surgery. The dated specifics that USED to
-- be patched in after erb -- the bottle block, the class rename Idris2Pack ->
-- Idris2PackAT<date>, and the keg_only :versioned_formula insert -- are three of
-- the eleven tokens, pre-formatted as DATA in buildErbEnv (CLASS_NAME,
-- BOTTLE_BLOCK, KEG_ONLY) and rendered by erb. `erb` is therefore a render-time
-- dependency, located via $IDRIS2_PACK_PIN_ERB, $HOMEBREW_RUBY_PATH's sibling
-- erb, or /usr/bin/erb -- no regex, no hashing, no network. A missing/short/
-- non-hex field, a missing erb env var, an unrendered tag, or an unknown version
-- is a hard error (die), never a silent default.
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
-- Rendering (every block value built by per-element erb renders, joined here;
-- the final main render is then a pure erb pass with no post-erb surgery)
-- ===========================================================================

||| version "2026.06.05" -> "20260605"
classSuffix : String -> String
classSuffix = pack . filter (/= '.') . unpack

-- Inter-element separators, centralized (these are the relocated concatenation:
-- the only Ruby-structure strings the producer still owns are these joins).
sepResources, sepInstallBlocks, sepInstallSteps, sepBottleLines : String
sepResources     = "\n\n"   -- between resource blocks
sepInstallBlocks = "\n\n"   -- between library install blocks
sepInstallSteps  = "\n"     -- between --install steps within a block
sepBottleLines   = "\n"     -- between bottle lines (rebuild + sha lines)

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

||| The repo-root templates/ directory holding the per-element erb partials
||| (kept out of Formula/ so brew's *.rb loader and cmdPrune never see them).
templatesDir : String -> String
templatesDir root = root ++ "/templates"

resourceTmpl, installStepTmpl, installBlockTmpl, bottleShaTmpl, bottleRebuildTmpl :
  String -> String
resourceTmpl      root = templatesDir root ++ "/resource.rb.erb"
installStepTmpl   root = templatesDir root ++ "/install-step.rb.erb"
installBlockTmpl  root = templatesDir root ++ "/install-block.rb.erb"
bottleShaTmpl     root = templatesDir root ++ "/bottle-sha.rb.erb"
bottleRebuildTmpl root = templatesDir root ++ "/bottle-rebuild.rb.erb"

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

||| Spawn the located erb on a template PATH (a structured argv element, never
||| an interpolated command string), capture stdout verbatim, gate the exit
||| status, and reject any unrendered tag. The caller sets the environment first.
||| `extraArgs` carries renderer FLAGS only (e.g. ["-T", "-"] for element trim
||| mode) -- never data. The main render passes [] so its behavior is unchanged.
covering
erbCapture : (erbAbs : String) -> (extraArgs : List String) ->
             (templateAbs : String) -> IO String
erbCapture erbAbs extraArgs templateAbs = do
  -- Typed argv list -> escapeCmd quotes each element. Token DATA is NOT here;
  -- only the located erb binary, the trim FLAGS, and the template PATH (each a
  -- structured list element, never a hand-built command string, never data).
  Right h <- popen (erbAbs :: extraArgs ++ [templateAbs]) Read
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

||| Render ONE element template: set ONLY this element's vars (overwrite=True so
||| each iteration replaces the previous element's values -- no stale leak),
||| capture with `-T -` trim mode. Each partial ends with a `<% -%>` tag, so the
||| trim consumes the file's single trailing newline and the rendered element has
||| NO trailing newline -- the joins below own every inter-element separator.
covering
renderElement : (erbAbs : String) -> (templateAbs : String) ->
                List (String, String) -> IO String
renderElement erbAbs templateAbs pairs = do
  traverse_ setEnvOrDie pairs
  erbCapture erbAbs ["-T", "-"] templateAbs

||| RESOURCE_BLOCKS: render each library's resource block, join with "\n\n".
covering
renderResources : (erbAbs : String) -> (root : String) -> List Lib -> IO String
renderResources erbAbs root libs = do
  blocks <- traverse one libs
  pure (joinBy sepResources blocks)
  where
    covering
    one : Lib -> IO String
    one l = renderElement erbAbs (resourceTmpl root)
      [ ("RES_NAME",   l.name)
      , ("RES_URL",    l.url)
      , ("RES_SHA256", l.sha256)
      ]

||| LIBRARY_INSTALL_BLOCKS: for each library render one --install step per ipkg,
||| join the steps with "\n", feed them to the block wrapper, then join the
||| blocks with "\n\n". Iteration and nesting stay here; templates never loop.
covering
renderInstalls : (erbAbs : String) -> (root : String) -> List Lib -> IO String
renderInstalls erbAbs root libs = do
  blocks <- traverse lib libs
  pure (joinBy sepInstallBlocks blocks)
  where
    covering
    step : String -> IO String
    step s = renderElement erbAbs (installStepTmpl root) [ ("STEP", s) ]
    covering
    lib : Lib -> IO String
    lib l = do
      steps <- traverse step l.ipkgs
      renderElement erbAbs (installBlockTmpl root)
        [ ("INS_NAME",  l.name)
        , ("INS_STEPS", joinBy sepInstallSteps steps)
        ]

||| BOTTLE_BLOCK: an optional `rebuild` line (only when rebuild /= 0) prepended
||| to the per-arch sha lines, joined with "\n". The alignment pad is computed
||| HERE as DATA (maxLen - len(os) + 1 spaces over the entry's tags) and passed
||| as B_PAD; the template does no arithmetic. B_PREFIX is "" for real shas.
covering
renderBottleBlock : (erbAbs : String) -> (root : String) -> Entry -> IO String
renderBottleBlock erbAbs root e = do
  let maxLen = foldl (\a, t => max a (length t)) 0 (map os e.entries)
  rebLines <- if e.rebuild == 0
                then pure []
                else do r <- renderElement erbAbs (bottleRebuildTmpl root)
                                 [ ("B_REBUILD", show e.rebuild) ]
                        pure [r]
  shaLines <- traverse (sha maxLen) e.entries
  pure (joinBy sepBottleLines (rebLines ++ shaLines))
  where
    covering
    sha : Nat -> BottleEntry -> IO String
    sha maxLen be = do
      let pad = pack (replicate (minus maxLen (length be.os) + 1) ' ')
      renderElement erbAbs (bottleShaTmpl root)
        [ ("B_PREFIX", "")
        , ("B_CELLAR", e.cellar)
        , ("B_OS",     be.os)
        , ("B_PAD",    pad)
        , ("B_SHA256", be.sha256)
        ]

||| Assemble the 11 main ERB tokens. The first eight mirror the producer's env
||| in scripts/update-formula.hell; three are now built by per-element erb
||| renders (RESOURCE_BLOCKS, LIBRARY_INSTALL_BLOCKS, BOTTLE_BLOCK); CLASS_NAME
||| and KEG_ONLY are dated-formula literals. IO because the three block values
||| come from erb subprocesses; the element keys (RES_*, STEP, INS_*, B_*) are
||| disjoint from these 11, so no leftover element var collides with the render.
covering
buildErbEnv : (erbAbs : String) -> (root : String) -> Entry ->
              IO (List (String, String))
buildErbEnv erbAbs root e = do
  resources <- renderResources   erbAbs root e.libs
  installs  <- renderInstalls    erbAbs root e.libs
  bottle    <- renderBottleBlock erbAbs root e
  pure
    [ ("VERSION",                e.version)
    , ("COLLECTION",             e.collection)
    , ("PACK_COMMIT",            e.packCommit)
    , ("PACK_SHA256",            e.packSha)
    , ("IDRIS2_COMMIT",          e.idris2Commit)
    , ("IDRIS2_SHA256",          e.idris2Sha)
    , ("RESOURCE_BLOCKS",        resources)
    , ("LIBRARY_INSTALL_BLOCKS", installs)
    , ("CLASS_NAME",             "Idris2PackAT" ++ classSuffix e.version)
    , ("BOTTLE_BLOCK",           bottle)
    , ("KEG_ONLY",               "  keg_only :versioned_formula\n\n")
    ]

||| Materialize one version: select, build the 11 tokens (each block value via
||| per-element erb renders joined here), render the MAIN template verbatim (no
||| trim, no post-erb surgery), and write deterministically.
covering
materializeOne : String -> JSON -> (erbAbs : String) -> String -> IO ()
materializeOne root root_json erbAbs v = do
  entry <- orDie (selectEntry v root_json)
  -- Defensive: the keyed entry's own version must equal the request.
  when (entry.version /= v) $
    abort ("manifest inconsistency: key " ++ v ++
           " maps to version " ++ entry.version)
  env <- buildErbEnv erbAbs root entry
  traverse_ setEnvOrDie env
  out <- erbCapture erbAbs [] (erbPath root)
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
