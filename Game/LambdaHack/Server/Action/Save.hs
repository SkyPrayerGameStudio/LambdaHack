-- | Saving and restoring server game state.
module Game.LambdaHack.Server.Action.Save
  ( saveGameBkpSer, saveGameSer, restoreGameSer
  ) where

import Control.Concurrent
import qualified Control.Exception as Ex hiding (handle)
import Control.Monad
import System.Directory
import System.FilePath
import System.IO
import System.IO.Unsafe (unsafePerformIO)

import Game.LambdaHack.Common.State
import Game.LambdaHack.Server.Config
import Game.LambdaHack.Server.State
import Game.LambdaHack.Utils.File

-- TODO: Refactor the client and server Save.hs, after
-- https://github.com/kosmikus/LambdaHack/issues/37.

saveLock :: MVar ()
{-# NOINLINE saveLock #-}
saveLock = unsafePerformIO newEmptyMVar

-- | Save game to the backup savefile, in case of crashes.
-- This is only a backup, so no problem is the game is shut down
-- before saving finishes, so we don't wait on the mvar. However,
-- if a previous save is already in progress, we skip this save.
saveGameBkpSer :: Config -> State -> StateServer -> IO ()
saveGameBkpSer Config{configAppDataDir} s ser = do
  b <- tryPutMVar saveLock ()
  when b $
    void $ forkIO $ do
      let saveFile = configAppDataDir </> "server.sav"
          saveFileBkp = saveFile <.> ".bkp"
      encodeEOF saveFile (s, ser)
      renameFile saveFile saveFileBkp
      takeMVar saveLock

-- | Save a simple serialized version of the current state.
-- Protected by a lock to avoid corrupting the file.
saveGameSer :: Config -> State -> StateServer -> IO ()
saveGameSer Config{configAppDataDir} s ser = do
  putMVar saveLock ()
  let saveFile = configAppDataDir </> "server.sav"
  encodeEOF saveFile (s, ser)
  takeMVar saveLock

-- | Restore a saved game, if it exists. Initialize directory structure
-- and cope over data files, if needed.
restoreGameSer :: Config -> (FilePath -> IO FilePath)
               -> IO (Maybe (State, StateServer))
restoreGameSer Config{ configAppDataDir
                     , configRulesCfgFile
                     , configScoresFile }
               pathsDataFile = do
  -- Create user data directory and copy files, if not already there.
  tryCreateDir configAppDataDir
  tryCopyDataFiles pathsDataFile
    [ (configRulesCfgFile <.> ".default", configRulesCfgFile <.> ".ini")
    , (configScoresFile, configScoresFile) ]
  let saveFile = configAppDataDir </> "server.sav"
      saveFileBkp = saveFile <.> ".bkp"
  sb <- doesFileExist saveFile
  bb <- doesFileExist saveFileBkp
  when sb $ renameFile saveFile saveFileBkp
  -- If the savefile exists but we get IO or decoding errors, we show them,
  -- back up the savefile, move it out of the way and start a new game.
  -- If the savefile was randomly corrupted or made read-only,
  -- that should solve the problem. Serious IO problems (e.g. failure
  -- to create a user data directory) terminate the program with an exception.
  Ex.catch
    (if sb
       then do
         (s, ser) <- strictDecodeEOF saveFileBkp
         return $ Just (s, ser)
       else
         if bb
           then do
             (s, ser) <- strictDecodeEOF saveFileBkp
             let msg = "No server savefile found. "
                       ++ "Restoring from a backup savefile."
             hPutStrLn stderr msg
             return $ Just (s, ser)
           else return Nothing
    )
    (\ e -> case e :: Ex.SomeException of
              _ -> do
                let msg =
                      "Starting a new game, because server restore failed. "
                      ++ "The error message was: "
                      ++ (unwords . lines) (show e)
                hPutStrLn stderr msg
                return Nothing
    )
