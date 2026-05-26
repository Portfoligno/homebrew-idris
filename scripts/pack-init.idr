-- Initialize pack state with symlinks for all installed Homebrew formulas.
--
-- Called by the pack wrapper on each invocation when the stamp file
-- indicates a change. Uses a stamp file to detect when the set of
-- installed formulas changes and re-initializes accordingly.
--
-- Usage: PACK_INIT_LIBEXEC=<path> idris2 --exec main scripts/pack-init.idr
--
-- Environment:
--   PACK_INIT_LIBEXEC  Path to the calling formula's libexec directory
--                      (contains COLLECTION, IDRIS2_COMMIT, idris2-toolchain/)
--   PACK_STATE_DIR     Override pack state directory
--   XDG_STATE_HOME     XDG state directory (default: ~/.local/state)

module Main

import Data.List
import Data.List1
import Data.String
import System
import System.Directory
import System.File.ReadWrite

%default total

-- Read entire file contents, returning empty string on failure.
covering
readFileOr : String -> String -> IO String
readFileOr path fallback = do
  Right contents <- readFile path
    | Left _ => pure fallback
  pure (trim contents)

-- Check if a path exists (file or directory).
covering
pathExists : String -> IO Bool
pathExists path = do
  Right _ <- openFile path Read
    | Left _ => do
        -- Could be a directory. Check via listing.
        Right _ <- listDir path
          | Left _ => pure False
        pure True
  pure True

-- Check if a path is a symlink by attempting readlink.
covering
isSymlink : String -> IO Bool
isSymlink path = do
  -- Use system command to check; Idris2 stdlib lacks direct symlink check.
  0 <- system ("test -L " ++ show path)
    | _ => pure False
  pure True

-- Read a symlink target.
covering
readLink : String -> IO (Maybe String)
readLink path = do
  -- Use system to capture readlink output via temp file.
  0 <- system ("readlink " ++ show path ++ " > /tmp/pack-init-readlink.tmp 2>/dev/null")
    | _ => pure Nothing
  target <- readFileOr "/tmp/pack-init-readlink.tmp" ""
  if target == ""
    then pure Nothing
    else pure (Just target)

-- Create a symlink.
covering
createSymlink : String -> String -> IO ()
createSymlink target linkPath = do
  _ <- system ("ln -sf " ++ show target ++ " " ++ show linkPath)
  pure ()

-- Create directories recursively.
covering
mkdirP : String -> IO ()
mkdirP path = do
  _ <- system ("mkdir -p " ++ show path)
  pure ()

-- Remove a file.
covering
removeFile : String -> IO ()
removeFile path = do
  _ <- system ("rm -f " ++ show path)
  pure ()

-- Try to remove an empty directory.
covering
tryRmdir : String -> IO ()
tryRmdir path = do
  _ <- system ("rmdir " ++ show path ++ " 2>/dev/null")
  pure ()

-- Remove a directory tree.
covering
rmTree : String -> IO ()
rmTree path = do
  _ <- system ("rm -rf " ++ show path)
  pure ()

-- Get pack state directory, respecting overrides.
covering
getPackStateDir : IO String
getPackStateDir = do
  Just envDir <- getEnv "PACK_STATE_DIR"
    | Nothing => do
        Just xdg <- getEnv "XDG_STATE_HOME"
          | Nothing => do
              Just home <- getEnv "HOME"
                | Nothing => pure "/tmp/pack"
              pure (home ++ "/.local/state/pack")
        pure (xdg ++ "/pack")
  pure envDir

-- Read metadata (COLLECTION, IDRIS2_COMMIT) from a libexec directory.
covering
readMetadata : String -> IO (Maybe (String, String))
readMetadata libexec = do
  collection <- readFileOr (libexec ++ "/COLLECTION") ""
  commit <- readFileOr (libexec ++ "/IDRIS2_COMMIT") ""
  if collection == "" || commit == ""
    then pure Nothing
    else pure (Just (collection, commit))

-- Walk up from a path to find the Homebrew opt directory.
-- Looks for "Cellar" or "opt" directory names in the path.
covering
findOptDir : String -> Maybe String
findOptDir path =
  let parts = forget (split (== '/') path)
  in findOpt parts []
  where
    findOpt : List String -> List String -> Maybe String
    findOpt [] _ = Nothing
    findOpt (x :: rest) acc =
      if x == "Cellar" || x == "opt"
        then Just (joinBy "/" (reverse acc) ++ "/opt")
        else findOpt rest (x :: acc)

-- Discover installed formula libexec directories (main + versioned).
-- Returns list of (commit, libexec_path) pairs.
covering
discoverFormulas : String -> IO (List (String, String))
discoverFormulas optDir = do
  -- Check main formula
  let mainLibexec = optDir ++ "/idris2-pack/libexec"
  mainMeta <- readMetadata mainLibexec
  let mainResults = case mainMeta of
        Just (_, commit) => [(commit, mainLibexec)]
        Nothing => []

  -- Check versioned formulas
  Right entries <- listDir optDir
    | Left _ => pure mainResults
  let versionedEntries = filter (\e => isPrefixOf "idris2-pack@" e) entries
  versionedResults <- traverse (\entry => do
    let vLibexec = optDir ++ "/" ++ entry ++ "/libexec"
    meta <- readMetadata vLibexec
    pure $ case meta of
      Just (_, commit) => [(commit, vLibexec)]
      Nothing => []
    ) (sort versionedEntries)
  pure (mainResults ++ concat versionedResults)

-- Compute stamp string: <collection>:<sorted,commits>
computeStamp : String -> List (String, String) -> String
computeStamp collection commits =
  let sortedCommits = sort (map fst commits)
  in collection ++ ":" ++ joinBy "," sortedCommits

-- Parse the collection part from a stamp string.
parseStampCollection : String -> String
parseStampCollection stamp =
  case break (== ':') (unpack stamp) of
    (before, _) => pack before

-- Create or update symlinks for all known formula commits.
covering
createSymlinks : String -> List (String, String) -> IO ()
createSymlinks installDir commits = do
  traverse_ (\(commit, libexec) => do
    let target = installDir ++ "/" ++ commit ++ "/idris2"
    let toolchain = libexec ++ "/idris2-toolchain"
    isSym <- isSymlink target
    if isSym
      then do
        mTarget <- readLink target
        case mTarget of
          Just currentTarget =>
            if currentTarget /= toolchain
              then do removeFile target
                      createSymlink toolchain target
              else pure ()
          Nothing => pure ()
      else do
        exists <- pathExists target
        if exists
          then pure ()  -- real directory (pack-managed), leave it
          else do mkdirP (installDir ++ "/" ++ commit)
                  createSymlink toolchain target
    ) commits

-- Clean up stale symlinks from previously-installed formulas.
covering
cleanupStaleSymlinks : String -> List (String, String) -> IO ()
cleanupStaleSymlinks installDir seenCommits = do
  let knownCommits = map fst seenCommits
  Right entries <- listDir installDir
    | Left _ => pure ()
  traverse_ (\commitDir => do
    let fullPath = installDir ++ "/" ++ commitDir
    let idris2Link = fullPath ++ "/idris2"
    isSym <- isSymlink idris2Link
    if isSym && not (elem commitDir knownCommits)
      then do
        mTarget <- readLink idris2Link
        case mTarget of
          Just linkTarget =>
            if isInfixOf "idris2-pack" linkTarget && isInfixOf "idris2-toolchain" linkTarget
              then do removeFile idris2Link
                      tryRmdir fullPath
              else pure ()
          Nothing => pure ()
      else pure ()
    ) entries

covering
main : IO ()
main = do
  Just libexec <- getEnv "PACK_INIT_LIBEXEC"
    | Nothing => do putStrLn "pack-init: PACK_INIT_LIBEXEC not set"
                    exitWith (ExitFailure 1)

  -- Read primary formula metadata
  Just (primaryCollection, primaryCommit) <- readMetadata libexec
    | Nothing => exitWith ExitSuccess  -- No metadata, nothing to do

  -- Build commit -> libexec mapping (caller takes precedence)
  let initial = [(primaryCommit, libexec)]

  -- Discover sibling formulas
  let mOptDir = findOptDir libexec
  siblings <- case mOptDir of
    Just optDir => discoverFormulas optDir
    Nothing => pure []

  -- Merge: primary takes precedence. Filter out duplicates by commit.
  let knownCommits = map fst initial
  let uniqueSiblings = filter (\(c, _) => not (elem c knownCommits)) siblings
  let allCommits = initial ++ uniqueSiblings

  -- Check stamp for early exit
  packState <- getPackStateDir
  let stampFile = packState ++ "/.brew-stamp"
  let newStamp = computeStamp primaryCollection allCommits

  oldStamp <- readFileOr stampFile ""

  if oldStamp == newStamp
    then exitWith ExitSuccess
    else pure ()

  -- Initialize
  mkdirP packState
  let installDir = packState ++ "/install"

  createSymlinks installDir allCommits
  cleanupStaleSymlinks installDir allCommits

  -- Config changes only when the primary collection changed
  let oldCollection = parseStampCollection oldStamp
  let collectionChanged = oldCollection /= primaryCollection

  if collectionChanged
    then do
      _ <- writeFile (packState ++ "/pack.toml")
                     ("collection = \"" ++ primaryCollection ++ "\"\n")
      rmTree (packState ++ "/db")
      pure ()
    else pure ()

  -- Write new stamp
  _ <- writeFile stampFile newStamp
  pure ()

  if collectionChanged
    then putStrLn ("pack: aligned state with collection " ++ primaryCollection)
    else putStrLn "pack: updated installed toolchain set"
