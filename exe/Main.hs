-- Copyright (c) 2019 The DAML Authors. All rights reserved.
-- SPDX-License-Identifier: Apache-2.0
{-# OPTIONS_GHC -Wno-dodgy-imports #-} -- GHC no longer exports def in GHC 8.6 and above
{-# OPTIONS_GHC -Wno-orphans #-}
{-# LANGUAGE CPP #-} -- To get precise GHC version
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE StandaloneDeriving #-}

module Main(main) where

import Module
import Arguments
import Data.Maybe
import Data.List.Extra
import Data.Void
import System.FilePath
import Control.Concurrent.Extra
import Control.Exception
import Control.Monad.Extra
import Control.Monad.IO.Class
import Data.Default
import System.Time.Extra
import Development.IDE.Core.Debouncer
import Development.IDE.Core.FileStore
import Development.IDE.Core.OfInterest
import Development.IDE.Core.Service
import Development.IDE.Core.Rules
import Development.IDE.Core.Shake
import Development.IDE.Core.RuleTypes
import Development.IDE.LSP.Protocol
import Development.IDE.Types.Location
import Development.IDE.Types.Diagnostics
import Development.IDE.Types.Options
import Development.IDE.Types.Logger
import Development.IDE.GHC.Util
import Development.IDE.Plugin
import Development.IDE.Plugin.Completions as Completions
import Development.IDE.Plugin.CodeAction as CodeAction
import qualified Data.Text as T
import qualified Data.Text.IO as T
import Language.Haskell.LSP.Messages
import Language.Haskell.LSP.Types (LspId(IdInt))
import Linker
import Data.Version
import Development.IDE.LSP.LanguageServer
import System.Directory.Extra as IO
import System.Environment
import System.IO
import System.Exit
import Paths_ghcide
import Development.GitRev
import Development.Shake (Action, action)
import qualified Data.HashSet as HashSet
import qualified Data.Map.Strict as Map

import GhcMonad
import HscTypes (HscEnv(..), ic_dflags)
import DynFlags (parseDynamicFlagsFull, flagsPackage, flagsDynamic)
import GHC hiding (def)
import qualified GHC.Paths

import HIE.Bios
import HIE.Bios.Types

-- Set the GHC libdir to the nix libdir if it's present.
getLibdir :: IO FilePath
getLibdir = fromMaybe GHC.Paths.libdir <$> lookupEnv "NIX_GHC_LIBDIR"

ghcideVersion :: IO String
ghcideVersion = do
  path <- getExecutablePath
  let gitHashSection = case $(gitHash) of
        x | x == "UNKNOWN" -> ""
        x -> " (GIT hash: " <> x <> ")"
  return $ "ghcide version: " <> showVersion version
             <> " (GHC: " <> VERSION_ghc
             <> ") (PATH: " <> path <> ")"
             <> gitHashSection

main :: IO ()
main = do
    -- WARNING: If you write to stdout before runLanguageServer
    --          then the language server will not work
    Arguments{..} <- getArguments

    if argsVersion then ghcideVersion >>= putStrLn >> exitSuccess
    else hPutStrLn stderr {- see WARNING above -} =<< ghcideVersion

    -- lock to avoid overlapping output on stdout
    lock <- newLock
    let logger p = Logger $ \pri msg -> when (pri >= p) $ withLock lock $
            T.putStrLn $ T.pack ("[" ++ upper (show pri) ++ "] ") <> msg

    whenJust argsCwd setCurrentDirectory

    dir <- getCurrentDirectory

    let plugins = Completions.plugin <> CodeAction.plugin
        onInitialConfiguration = const $ Right ()
        onConfigurationChange  = const $ Right ()

    if argLSP then do
        t <- offsetTime
        hPutStrLn stderr "Starting LSP server..."
        hPutStrLn stderr "If you are seeing this in a terminal, you probably should have run ghcide WITHOUT the --lsp option!"
        runLanguageServer def (pluginHandler plugins) onInitialConfiguration onConfigurationChange $ \getLspId event vfs caps -> do
            t <- t
            hPutStrLn stderr $ "Started LSP server in " ++ showDuration t
            -- very important we only call loadSession once, and it's fast, so just do it before starting
            session <- loadSession dir
            let options = (defaultIdeOptions $ return session)
                    { optReportProgress = clientSupportsProgress caps
                    , optShakeProfiling = argsShakeProfiling
                    }
            debouncer <- newAsyncDebouncer
            initialise caps (mainRule >> pluginRules plugins >> action kick) getLspId event (logger minBound) debouncer options vfs
    else do
        putStrLn $ "Ghcide setup tester in " ++ dir ++ "."
        putStrLn "Report bugs at https://github.com/digital-asset/ghcide/issues"

        putStrLn $ "\nStep 1/6: Finding files to test in " ++ dir
        files <- expandFiles (argFiles ++ ["." | null argFiles])
        -- LSP works with absolute file paths, so try and behave similarly
        files <- nubOrd <$> mapM canonicalizePath files
        putStrLn $ "Found " ++ show (length files) ++ " files"

        putStrLn "\nStep 2/6: Looking for hie.yaml files that control setup"
        cradles <- mapM findCradle files
        let ucradles = nubOrd cradles
        let n = length ucradles
        putStrLn $ "Found " ++ show n ++ " cradle" ++ ['s' | n /= 1]
        putStrLn "\nStep 3/6: Initializing the IDE"
        vfs <- makeVFSHandle
        grab <- loadSession dir
        ide <- initialise def mainRule (pure $ IdInt 0) (showEvent lock) (logger Info) (defaultIdeOptions $ return grab) vfs

        putStrLn "\nStep 4/6: Type checking the files"
        setFilesOfInterest ide $ Set.fromList $ map toNormalizedFilePath files
        results <- runActionSync ide $ uses TypeCheck $ map toNormalizedFilePath files
        let (worked, failed) = partition fst $ zip (map isJust results) files
        when (failed /= []) $
            putStr $ unlines $ "Files that failed:" : map ((++) " * " . snd) failed

        let files xs = let n = length xs in if n == 1 then "1 file" else show n ++ " files"
        putStrLn $ "\nCompleted (" ++ files worked ++ " worked, " ++ files failed ++ " failed)"

        unless (null failed) exitFailure


expandFiles :: [FilePath] -> IO [FilePath]
expandFiles = concatMapM $ \x -> do
    b <- IO.doesFileExist x
    if b then return [x] else do
        let recurse "." = True
            recurse x | "." `isPrefixOf` takeFileName x = False -- skip .git etc
            recurse x = takeFileName x `notElem` ["dist","dist-newstyle"] -- cabal directories
        files <- filter (\x -> takeExtension x `elem` [".hs",".lhs"]) <$> listFilesInside (return . recurse) x
        when (null files) $
            fail $ "Couldn't find any .hs/.lhs files inside directory: " ++ x
        return files


kick :: Action ()
kick = do
    files <- getFilesOfInterest
    void $ uses TypeCheck $ HashSet.toList files

-- | Print an LSP event.
showEvent :: Lock -> FromServerMessage -> IO ()
showEvent _ (EventFileDiagnostics _ []) = return ()
showEvent lock (EventFileDiagnostics (toNormalizedFilePath -> file) diags) =
    withLock lock $ T.putStrLn $ showDiagnosticsColored $ map (file,ShowDiag,) diags
showEvent lock e = withLock lock $ print e


cradleToSession :: Cradle a -> FilePath -> IO HscEnvEq
cradleToSession cradle file = do
    let showLine s = putStrLn ("> " ++ s)
    cradleRes <- runCradle (cradleOptsProg cradle) showLine file
    opts <- case cradleRes of
        CradleSuccess r -> pure r
        CradleFail err -> throwIO err
        -- TODO Rather than failing here, we should ignore any files that use this cradle.
        -- That will require some more changes.
        CradleNone -> fail "'none' cradle is not yet supported"
    pure opts

emptyHscEnv :: IO HscEnv
emptyHscEnv = do
    libdir <- getLibdir
    env <- runGhc (Just libdir) getSession
    initDynLinker env
    pure env

addPackageOpts :: HscEnv -> ComponentOptions -> IO HscEnv
addPackageOpts hscEnv opts = do
    runGhcEnv hscEnv $ do
        df <- getSessionDynFlags
        (df', _, _) <- parseDynamicFlagsFull flagsPackage True df (map noLoc $ componentOptions opts)
        _targets <- setSessionDynFlags df'
        getSession

tweakHscEnv :: HscEnv -> ComponentOptions -> IO HscEnv
tweakHscEnv hscEnv opts = do
    runGhcEnv hscEnv $ do
        df <- getSessionDynFlags
        (df', _, _) <- parseDynamicFlagsFull flagsDynamic True df (map noLoc $ componentOptions opts)
        modifySession $ \h -> h { hsc_dflags = df', hsc_IC = (hsc_IC h) { ic_dflags = df' } }
        getSession

deriving instance Ord ComponentOptions

targetToFile :: TargetId -> (NormalizedFilePath, Bool)
targetToFile (TargetModule mod) = (toNormalizedFilePath $ (moduleNameSlashes mod) -<.> "hs", False)
targetToFile (TargetFile f _) = (toNormalizedFilePath f, True)

loadSession :: FilePath -> IO (FilePath -> Action HscEnvEq)
loadSession dir = do
    hscEnvs <- newVar Map.empty
    fileToFlags <- newVar []
    -- This caches the mapping from Mod.hs -> hie.yaml
    cradleLoc <- memoIO $ \v -> do
        res <- findCradle v
        -- Sometimes we get C:, sometimes we get c:, and sometimes we get a relative path
        -- try and normalise that
        -- e.g. see https://github.com/digital-asset/ghcide/issues/126
        res' <- traverse makeAbsolute res
        return $ normalise <$> res'

    packageSetup <- memoIO $ \(hieYaml, opts) -> do
        hscEnv <- emptyHscEnv
        -- TODO This should definitely not call initSession
        targets <- runGhcEnv hscEnv $ initSession opts
        modifyVar_ fileToFlags $ \var -> do
            let xs = map (\target -> (targetToFile $ targetId target,opts)) targets
            print (map (fromNormalizedFilePath . fst . fst) xs)
            pure $ xs ++ var
        -- print (hieYaml, opts)
        modifyVar_ hscEnvs $ \m -> do
            oldHscEnv <- case Map.lookup hieYaml m of
                Nothing -> emptyHscEnv
                Just hscEnv -> pure hscEnv
            newHscEnv <- addPackageOpts oldHscEnv opts
            pure (Map.insert hieYaml newHscEnv m)

    session <- memoIO $ \(hieYaml, opts) -> do
        packageSetup (hieYaml, opts)
        hscEnv <- fmap (Map.lookup hieYaml) $ readVar hscEnvs
        -- TODO Handle the case where there is no hie.yaml
        newHscEnvEq =<< tweakHscEnv (fromJust hscEnv) opts

    lock <- newLock

    -- This caches the mapping from hie.yaml + Mod.hs -> [String]
    sessionOpts <- memoIO $ \(hieYaml, file) -> withLock lock $ do
        v <- readVar fileToFlags
        -- We sort so exact matches come first.
        case find (\((f', exact), _) -> fromNormalizedFilePath f' == file || not exact && fromNormalizedFilePath f' `isSuffixOf` file) v of
            Just (_, opts) -> do
                putStrLn $ "Cached component of " <> show file
                pure opts
            Nothing-> do
                putStrLn $ "Shelling out to cabal " <> show file
                cradle <- maybe (loadImplicitCradle $ addTrailingPathSeparator dir) loadCradle hieYaml
                opts <- cradleToSessionOpts cradle file
                pure opts
    return $ \file -> liftIO $ do
        hieYaml <- cradleLoc file
        opts <- sessionOpts (hieYaml, file)
        session (hieYaml, opts)

-- | Memoize an IO function, with the characteristics:
--
--   * If multiple people ask for a result simultaneously, make sure you only compute it once.
--
--   * If there are exceptions, repeatedly reraise them.
--
--   * If the caller is aborted (async exception) finish computing it anyway.
memoIO :: Ord a => (a -> IO b) -> IO (a -> IO b)
memoIO op = do
    ref <- newVar Map.empty
    return $ \k -> join $ mask_ $ modifyVar ref $ \mp ->
        case Map.lookup k mp of
            Nothing -> do
                res <- onceFork $ op k
                return (Map.insert k res mp, res)
            Just res -> return (mp, res)
