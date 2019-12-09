{- git-annex worktree files
 -
 - Copyright 2013-2019 Joey Hess <id@joeyh.name>
 -
 - Licensed under the GNU AGPL version 3 or higher.
 -}

module Annex.WorkTree where

import Annex.Common
import Annex.Link
import Annex.CatFile
import Annex.Content
import Annex.ReplaceFile
import Annex.CurrentBranch
import Annex.InodeSentinal
import Utility.InodeCache
import Git.FilePath
import qualified Git.Ref
import qualified Git.LsTree
import qualified Git.Types
import Database.Types
import qualified Database.Keys
import qualified Database.Keys.SQL
import Config
import qualified Utility.RawFilePath as R

{- Looks up the key corresponding to an annexed file in the work tree,
 - by examining what the file links to.
 -
 - An unlocked file will not have a link on disk, so fall back to
 - looking for a pointer to a key in git.
 -
 - When in an adjusted branch that may have hidden the file, looks for a
 - pointer to a key in the original branch.
 -}
lookupFile :: RawFilePath -> Annex (Maybe Key)
lookupFile = lookupFile' catkeyfile
  where
	catkeyfile file =
		ifM (liftIO $ doesFileExist $ fromRawFilePath file)
			( catKeyFile file
			, catKeyFileHidden file =<< getCurrentBranch
			)

lookupFileNotHidden :: RawFilePath -> Annex (Maybe Key)
lookupFileNotHidden = lookupFile' catkeyfile
  where
	catkeyfile file =
		ifM (liftIO $ doesFileExist $ fromRawFilePath file)
			( catKeyFile file
			, return Nothing
			)

lookupFile' :: (RawFilePath -> Annex (Maybe Key)) -> RawFilePath -> Annex (Maybe Key)
lookupFile' catkeyfile file = isAnnexLink file >>= \case
	Just key -> return (Just key)
	Nothing -> catkeyfile file

{- Modifies an action to only act on files that are already annexed,
 - and passes the key on to it. -}
whenAnnexed :: (RawFilePath -> Key -> Annex (Maybe a)) -> RawFilePath -> Annex (Maybe a)
whenAnnexed a file = ifAnnexed file (a file) (return Nothing)

ifAnnexed :: RawFilePath -> (Key -> Annex a) -> Annex a -> Annex a
ifAnnexed file yes no = maybe no yes =<< lookupFile file

{- Find all unlocked files and update the keys database for them. 
 - 
 - This is expensive, and so normally the associated files are updated
 - incrementally when changes are noticed. So, this only needs to be done
 - when initializing/upgrading a v6+ mode repository.
 -
 - Also, the content for the unlocked file may already be present as
 - an annex object. If so, populate the pointer file with it.
 - But if worktree file does not have a pointer file's content, it is left
 - as-is.
 -}
scanUnlockedFiles :: Annex ()
scanUnlockedFiles = whenM (inRepo Git.Ref.headExists <&&> not <$> isBareRepo) $ do
	Database.Keys.runWriter $
		liftIO . Database.Keys.SQL.dropAllAssociatedFiles
	(l, cleanup) <- inRepo $ Git.LsTree.lsTree Git.LsTree.LsTreeRecursive Git.Ref.headRef
	forM_ l $ \i -> 
		when (isregfile i) $
			maybe noop (add i)
				=<< catKey (Git.LsTree.sha i)
	liftIO $ void cleanup
  where
	isregfile i = case Git.Types.toTreeItemType (Git.LsTree.mode i) of
		Just Git.Types.TreeFile -> True
		Just Git.Types.TreeExecutable -> True
		_ -> False
	add i k = do
		let tf = Git.LsTree.file i
		Database.Keys.runWriter $
			liftIO . Database.Keys.SQL.addAssociatedFileFast (toIKey k) tf
		whenM (inAnnex k) $ do
			f <- fromRepo $ fromTopFilePath tf
			liftIO (isPointerFile f) >>= \case
				Just k' | k' == k -> do
					destmode <- liftIO $ catchMaybeIO $
						fileMode <$> R.getFileStatus f
					ic <- replaceFile (fromRawFilePath f) $ \tmp ->
						linkFromAnnex k tmp destmode >>= \case
							LinkAnnexOk -> 
								withTSDelta (liftIO . genInodeCache tmp)
							LinkAnnexNoop -> return Nothing
							LinkAnnexFailed -> liftIO $ do
								writePointerFile (toRawFilePath tmp) k destmode
								return Nothing
					maybe noop (restagePointerFile (Restage True) f) ic
				_ -> noop
