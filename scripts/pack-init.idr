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
import System.File.Handle
import System.File.ReadWrite

%default total

-- ===========================================================================
-- FFI: Symlink primitives (Chez backend, single-expression wrappers)
-- ===========================================================================

||| Check if path is a symbolic link.
||| Chez built-in: file-symbolic-link? returns #t/#f.
%foreign "scheme,chez:(lambda (path) (if (file-symbolic-link? path) 1 0))"
prim__isSymlink : String -> PrimIO Int

||| Create a symbolic link: symlink(target, linkpath).
||| Returns 0 on success, -1 on error.
%foreign "scheme,chez:(lambda (target link) ((foreign-procedure \"symlink\" (string string) int) target link))"
prim__symlink : String -> String -> PrimIO Int

||| Read a symbolic link target: readlink(path, buf, 4096).
||| Returns the target string as AnyPtr, or #f on error.
%foreign "scheme,chez:(lambda (path) (let* ([bv (make-bytevector 4096)] [n ((foreign-procedure \"readlink\" (string u8* int) int) path bv 4096)]) (if (< n 0) #f (utf8->string (bytevector-copy bv 0 n)))))"
prim__readlink : String -> PrimIO AnyPtr

||| Check if an AnyPtr is null (#f in Chez).
%foreign "scheme,chez:(lambda (x) (if (eq? x #f) 1 0))"
prim__isNull : AnyPtr -> PrimIO Int

||| Cast a non-null AnyPtr to String (caller must ensure non-null).
%foreign "scheme,chez:(lambda (x) x)"
prim__anyPtrToString : AnyPtr -> PrimIO String

-- ===========================================================================
-- File I/O wrappers (stdlib + FFI)
-- ===========================================================================

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
  Right h <- openFile path Read
    | Left _ => do
        -- Could be a directory. Check via listing.
        Right _ <- listDir path
          | Left _ => pure False
        pure True
  closeFile h
  pure True

-- Symlink check result.
-- IsLink: the path is a symlink.
-- NotLink: the path exists but is not a symlink.
-- NoEntry: the path does not exist (or is inaccessible).
data LinkStatus = IsLink | NotLink | NoEntry

-- Check if a path is a symbolic link (with existence info).
-- Note: file-symbolic-link? returns #f on both "not a symlink" AND
-- lstat errors. We use pathExists to disambiguate non-existence.
covering
checkSymlink : String -> IO LinkStatus
checkSymlink path = do
  r <- primIO (prim__isSymlink path)
  if r == 1
    then pure IsLink
    else do
      exists <- pathExists path
      pure (if exists then NotLink else NoEntry)

-- Read a symlink target.
covering
readLink : String -> IO (Maybe String)
readLink path = do
  ptr <- primIO (prim__readlink path)
  isNull <- primIO (prim__isNull ptr)
  if isNull == 1
    then pure Nothing
    else do
      target <- primIO (prim__anyPtrToString ptr)
      pure (Just target)

-- Create a symlink (force: remove existing target first).
-- Returns True on success, False on failure.
covering
createSymlink : String -> String -> IO Bool
createSymlink target linkPath = do
  _ <- removeFile linkPath  -- remove existing (ignore errors)
  r <- primIO (prim__symlink target linkPath)
  pure (r == 0)

-- Create directories recursively (like mkdir -p), helper.
covering
mkdirPGo : Bool -> String -> List String -> IO ()
mkdirPGo isRoot pfx dirs =
  case dirs of
    [] => pure ()
    (d :: ds) => do
      let dir = if pfx == "" || pfx == "."
                  then d
                  else pfx ++ "/" ++ d
      let fullDir = if isRoot && pfx == ""
                      then "/" ++ d
                      else dir
      Right _ <- createDir fullDir
        | Left FileExists => pure ()
        | Left err => die ("pack-init: mkdir failed for " ++ fullDir ++ ": " ++ show err)
      mkdirPGo isRoot fullDir ds

-- Create directories recursively (like mkdir -p).
covering
mkdirP : String -> IO ()
mkdirP path =
  let components = filter (/= "") (forget (split (== '/') path))
      isRooted = isPrefixOf "/" path
  in mkdirPGo isRooted (if isRooted then "" else ".") components

-- Remove a file (ignore errors).
covering
removeFileForce : String -> IO ()
removeFileForce path = do
  _ <- removeFile path
  pure ()

-- Try to remove an empty directory (ignore errors).
covering
tryRmdir : String -> IO ()
tryRmdir path = do
  _ <- removeDir path
  pure ()

-- Remove a directory tree recursively.
covering
rmTree : String -> IO ()
rmTree path = do
  Right entries <- listDir path
    | Left _ => do _ <- removeFile path; pure ()  -- not a dir, try as file
  traverse_ (\e => rmTree (path ++ "/" ++ e)) entries
  _ <- removeDir path
  pure ()

-- ===========================================================================
-- Application logic
-- ===========================================================================

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
    status <- checkSymlink target
    case status of
      IsLink => do
        mTarget <- readLink target
        case mTarget of
          Just currentTarget =>
            if currentTarget /= toolchain
              then do removeFileForce target
                      ok <- createSymlink toolchain target
                      when (not ok) $
                        die ("pack-init: symlink failed: "
                             ++ toolchain ++ " -> " ++ target)
              else pure ()
          Nothing =>
            die ("pack-init: readlink failed on symlink: " ++ target)
      NotLink => pure ()  -- real directory (pack-managed), leave it
      NoEntry => do
        mkdirP (installDir ++ "/" ++ commit)
        ok <- createSymlink toolchain target
        when (not ok) $
          die ("pack-init: symlink failed: "
               ++ toolchain ++ " -> " ++ target)
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
    status <- checkSymlink idris2Link
    case status of
      IsLink =>
        if not (elem commitDir knownCommits)
          then do
            mTarget <- readLink idris2Link
            case mTarget of
              Just linkTarget =>
                if isInfixOf "idris2-pack" linkTarget && isInfixOf "idris2-toolchain" linkTarget
                  then do removeFileForce idris2Link
                          tryRmdir fullPath
                  else pure ()
              Nothing =>
                putStrLn ("pack-init: warning: cannot read symlink: " ++ idris2Link)
          else pure ()
      _ => pure ()
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
      Right _ <- writeFile (packState ++ "/pack.toml")
                           ("collection = \"" ++ primaryCollection ++ "\"\n")
        | Left err => die ("pack-init: failed to write pack.toml: " ++ show err)
      rmTree (packState ++ "/db")
      pure ()
    else pure ()

  -- Write new stamp
  Right _ <- writeFile stampFile newStamp
    | Left err => die ("pack-init: failed to write stamp: " ++ show err)
  pure ()

  if collectionChanged
    then putStrLn ("pack: aligned state with collection " ++ primaryCollection)
    else putStrLn "pack: updated installed toolchain set"
