{- Sqlite database used for incremental fsck. 
 -
 - Copyright 2015 Joey Hess <id@joeyh.name>
 -:
 - Licensed under the GNU GPL version 3 or higher.
 -}

{-# LANGUAGE QuasiQuotes, TypeFamilies, TemplateHaskell #-}
{-# LANGUAGE OverloadedStrings, GADTs, FlexibleContexts #-}

module Database.Fsck (
	newPass,
	openDb,
	closeDb,
	H.commitDb,
	H.DbHandle,
	addDb,
	inDb,
	FsckedId,
) where

import Database.Types
import qualified Database.Handle as H
import Locations
import Utility.Directory
import Annex
import Types.Key
import Annex.Perms
import Annex.LockFile

import Database.Persist.TH
import Database.Esqueleto hiding (Key)
import Control.Monad
import Control.Monad.IfElse
import Control.Monad.IO.Class (liftIO)
import System.Directory
import Data.Maybe
import Control.Applicative

{- Each key stored in the database has already been fscked as part
 - of the latest incremental fsck pass. -}
share [mkPersist sqlSettings, mkMigrate "migrateFsck"] [persistLowerCase|
Fscked
  key SKey
  UniqueKey key
|]

{- The database is removed when starting a new incremental fsck pass.
 -
 - This may fail, if other fsck processes are currently running using the
 - database. Removing the database in that situation would lead to crashes
 - or undefined behavior.
 -}
newPass :: Annex Bool
newPass = isJust <$> tryExclusiveLock gitAnnexFsckDbLock go
  where
	go = liftIO. nukeFile =<< fromRepo gitAnnexFsckDb

{- Opens the database, creating it atomically if it doesn't exist yet. -}
openDb :: Annex H.DbHandle
openDb = do
	db <- fromRepo gitAnnexFsckDb
	unlessM (liftIO $ doesFileExist db) $ do
		let newdb = db ++ ".new"
		h <- liftIO $ H.openDb newdb
		void $ liftIO $ H.runDb h $
			runMigrationSilent migrateFsck
		liftIO $ H.closeDb h
		setAnnexFilePerm newdb
		liftIO $ renameFile newdb db
	lockFileShared =<< fromRepo gitAnnexFsckDbLock
	liftIO $ H.openDb db

closeDb :: H.DbHandle -> Annex ()
closeDb h = do
	liftIO $ H.closeDb h
	unlockFile =<< fromRepo gitAnnexFsckDbLock

addDb :: H.DbHandle -> Key -> IO ()
addDb h = void . H.runDb' h commitPolicy . insert . Fscked . toSKey

inDb :: H.DbHandle -> Key -> IO Bool
inDb h k = H.runDb h $ do
	r <- select $ from $ \r -> do
		where_ (r ^. FsckedKey ==. val (toSKey k))
		return (r ^. FsckedKey)
	return $ not $ null r

{- Bundle up addDb transactions and commit after 60 seconds.
 - This is a balance between resuming where the last incremental
 - fsck left off, and making too many commits which slows down the fsck
 - of lots of small or not present files. -}
commitPolicy :: H.CommitPolicy
commitPolicy = H.CommitAfter (fromIntegral (60 :: Int))
