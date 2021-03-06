{- git-annex command
 -
 - Copyright 2010-2018 Joey Hess <id@joeyh.name>
 -
 - Licensed under the GNU AGPL version 3 or higher.
 -}

module Command.Move where

import Command
import qualified Command.Drop
import qualified Annex
import Annex.Content
import qualified Remote
import Annex.UUID
import Annex.Transfer
import Logs.Presence
import Logs.Trust
import Annex.NumCopies

import System.Log.Logger (debugM)

cmd :: Command
cmd = withGlobalOptions [jobsOption, jsonOptions, jsonProgressOption, annexedMatchingOptions] $
	command "move" SectionCommon
		"move content of files to/from another repository"
		paramPaths (seek <--< optParser)

data MoveOptions = MoveOptions
	{ moveFiles :: CmdParams
	, fromToOptions :: FromToHereOptions
	, removeWhen :: RemoveWhen
	, keyOptions :: Maybe KeyOptions
	, batchOption :: BatchMode
	}

optParser :: CmdParamsDesc -> Parser MoveOptions
optParser desc = MoveOptions
	<$> cmdParams desc
	<*> parseFromToHereOptions
	<*> pure RemoveSafe
	<*> optional (parseKeyOptions <|> parseFailedTransfersOption)
	<*> parseBatchOption

instance DeferredParseClass MoveOptions where
	finishParse v = MoveOptions
		<$> pure (moveFiles v)
		<*> finishParse (fromToOptions v)
		<*> pure (removeWhen v)
		<*> pure (keyOptions v)
		<*> pure (batchOption v)

data RemoveWhen = RemoveSafe | RemoveNever
	deriving (Show, Eq)

seek :: MoveOptions -> CommandSeek
seek o = startConcurrency stages $ do
	let go = whenAnnexed $ start (fromToOptions o) (removeWhen o)
	case batchOption o of
		Batch fmt -> batchFilesMatching fmt (go . toRawFilePath)
		NoBatch -> withKeyOptions (keyOptions o) False
			(commandAction . startKey (fromToOptions o) (removeWhen o))
			(withFilesInGit ww (commandAction . go))
			=<< workTreeItems ww (moveFiles o)
  where
	stages = case fromToOptions o of
		Right (FromRemote _) -> downloadStages
		Right (ToRemote _) -> commandStages
		Left ToHere -> downloadStages
	ww = WarnUnmatchLsFiles

start :: FromToHereOptions -> RemoveWhen -> RawFilePath -> Key -> CommandStart
start fromto removewhen f k = start' fromto removewhen afile k ai
  where
	afile = AssociatedFile (Just f)
	ai = mkActionItem (k, afile)

startKey :: FromToHereOptions -> RemoveWhen -> (Key, ActionItem) -> CommandStart
startKey fromto removewhen = 
	uncurry $ start' fromto removewhen (AssociatedFile Nothing)

start' :: FromToHereOptions -> RemoveWhen -> AssociatedFile -> Key -> ActionItem -> CommandStart
start' fromto removewhen afile key ai =
	case fromto of
		Right (FromRemote src) ->
			checkFailedTransferDirection ai Download $
				fromStart removewhen afile key ai =<< getParsed src
		Right (ToRemote dest) ->
			checkFailedTransferDirection ai Upload $
				toStart removewhen afile key ai =<< getParsed dest
		Left ToHere ->
			checkFailedTransferDirection ai Download $
				toHereStart removewhen afile key ai

describeMoveAction :: RemoveWhen -> String
describeMoveAction RemoveNever = "copy"
describeMoveAction _ = "move"

toStart :: RemoveWhen -> AssociatedFile -> Key -> ActionItem -> Remote -> CommandStart
toStart removewhen afile key ai dest = do
	u <- getUUID
	ishere <- inAnnex key
	if not ishere || u == Remote.uuid dest
		then stop -- not here, so nothing to do
		else toStart' dest removewhen afile key ai

toStart' :: Remote -> RemoveWhen -> AssociatedFile -> Key -> ActionItem -> CommandStart
toStart' dest removewhen afile key ai = do
	fast <- Annex.getState Annex.fast
	if fast && removewhen == RemoveNever
		then ifM (expectedPresent dest key)
			( stop
			, go True (pure $ Right False)
			)
		else go False (Remote.hasKey dest key)
  where
	go fastcheck isthere =
		starting (describeMoveAction removewhen) (OnlyActionOn key ai) $
			toPerform dest removewhen key afile fastcheck =<< isthere

expectedPresent :: Remote -> Key -> Annex Bool
expectedPresent dest key = do
	remotes <- Remote.keyPossibilities key
	return $ dest `elem` remotes

toPerform :: Remote -> RemoveWhen -> Key -> AssociatedFile -> Bool -> Either String Bool -> CommandPerform
toPerform dest removewhen key afile fastcheck isthere =
	case isthere of
		Left err -> do
			showNote err
			stop
		Right False -> do
			showAction $ "to " ++ Remote.name dest
			ok <- notifyTransfer Upload afile $
				upload (Remote.uuid dest) key afile stdRetry $
					Remote.action . Remote.storeKey dest key afile
			if ok
				then finish False $
					Remote.logStatus dest key InfoPresent
				else do
					when fastcheck $
						warning "This could have failed because --fast is enabled."
					stop
		Right True -> finish True $
			unlessM (expectedPresent dest key) $
				Remote.logStatus dest key InfoPresent
  where
	finish deststartedwithcopy setpresentremote = case removewhen of
		RemoveNever -> do
			setpresentremote
			next $ return True
		RemoveSafe -> lockContentForRemoval key $ \contentlock -> do
			srcuuid <- getUUID
			let destuuid = Remote.uuid dest
			willDropMakeItWorse srcuuid destuuid deststartedwithcopy key afile >>= \case
				DropAllowed -> drophere setpresentremote contentlock "moved"
				DropCheckNumCopies -> do
					numcopies <- getAssociatedFileNumCopies afile
					(tocheck, verified) <- verifiableCopies key [srcuuid]
					verifyEnoughCopiesToDrop "" key (Just contentlock)
						 numcopies [srcuuid] verified
						 (UnVerifiedRemote dest : tocheck)
						 (drophere setpresentremote contentlock . showproof)
						 (faileddrophere setpresentremote)
				DropWorse -> faileddrophere setpresentremote
	showproof proof = "proof: " ++ show proof
	drophere setpresentremote contentlock reason = do
		liftIO $ debugM "move" $ unwords
			[ "Dropping from here"
			, "(" ++ reason ++ ")"
			]
		-- Drop content before updating location logs,
		-- in case disk space is very low this frees
		-- up space before writing data to disk.
		removeAnnex contentlock
		next $ do
			() <- setpresentremote
			Command.Drop.cleanupLocal key
	faileddrophere setpresentremote = do
		showLongNote "(Use --force to override this check, or adjust numcopies.)"
		showLongNote "Content not dropped from here."
		next $ do
			() <- setpresentremote
			return False

fromStart :: RemoveWhen -> AssociatedFile -> Key -> ActionItem -> Remote -> CommandStart
fromStart removewhen afile key ai src = case removewhen of
	RemoveNever -> stopUnless (not <$> inAnnex key) go
	RemoveSafe -> go
  where
	go = stopUnless (fromOk src key) $
		starting (describeMoveAction removewhen) (OnlyActionOn key ai) $
			fromPerform src removewhen key afile

fromOk :: Remote -> Key -> Annex Bool
fromOk src key = do
	u <- getUUID
	remotes <- Remote.keyPossibilities key
	return $ u /= Remote.uuid src && elem src remotes

fromPerform :: Remote -> RemoveWhen -> Key -> AssociatedFile -> CommandPerform
fromPerform src removewhen key afile = do
	showAction $ "from " ++ Remote.name src
	ifM (inAnnex key)
		( dispatch removewhen True True
		, dispatch removewhen False =<< go
		)
  where
	go = notifyTransfer Download afile $ 
		download (Remote.uuid src) key afile stdRetry $ \p ->
			getViaTmp (Remote.retrievalSecurityPolicy src) (RemoteVerify src) key $ \t ->
				Remote.verifiedAction $ Remote.retrieveKeyFile src key afile t p
	dispatch _ _ False = stop -- failed
	dispatch RemoveNever _ True = next $ return True -- copy complete
	dispatch RemoveSafe deststartedwithcopy True = lockContentShared key $ \_lck -> do
		let srcuuid = Remote.uuid src
		destuuid <- getUUID
		willDropMakeItWorse srcuuid destuuid deststartedwithcopy key afile >>= \case
			DropAllowed -> dropremote "moved"
			DropCheckNumCopies -> do
				numcopies <- getAssociatedFileNumCopies afile
				(tocheck, verified) <- verifiableCopies key [Remote.uuid src]
				verifyEnoughCopiesToDrop "" key Nothing numcopies [Remote.uuid src] verified
					tocheck (dropremote . showproof) faileddropremote
			DropWorse -> faileddropremote		
	showproof proof = "proof: " ++ show proof
	dropremote reason = do
		liftIO $ debugM "move" $ unwords
			[ "Dropping from remote"
			, show src
			, "(" ++ reason ++ ")"
			]
		ok <- Remote.action (Remote.removeKey src key)
		next $ Command.Drop.cleanupRemote key src ok
	faileddropremote = do
		showLongNote "(Use --force to override this check, or adjust numcopies.)"
		showLongNote $ "Content not dropped from " ++ Remote.name src ++ "."
		next $ return False

{- Moves (or copies) the content of an annexed file from reachable remotes
 - to the current repository.
 -
 - When moving, the content is removed from all the reachable remotes that
 - it can safely be removed from. -}
toHereStart :: RemoveWhen -> AssociatedFile -> Key -> ActionItem -> CommandStart
toHereStart removewhen afile key ai = case removewhen of
	RemoveNever -> stopUnless (not <$> inAnnex key) go
	RemoveSafe -> go
  where
	go = startingNoMessage (OnlyActionOn key ai) $ do
		rs <- Remote.keyPossibilities key
		forM_ rs $ \r ->
			includeCommandAction $
				starting (describeMoveAction removewhen) ai $
					fromPerform r removewhen key afile
		next $ return True

{- The goal of this command is to allow the user maximum freedom to move
 - files as they like, while avoiding making bad situations any worse
 - than they already were.
 -
 - When the destination repository already had a copy of a file
 - before the move operation began, dropping it from the source
 - repository reduces the number of copies, and should fail if
 - that would violate numcopies settings.
 -
 - On the other hand, when the destiation repository does not already
 - have a copy of a file, it can be dropped without making numcopies
 - worse, so the move is allowed even if numcopies is not met.
 -
 - Similarly, a file can move from an untrusted repository to another
 - untrusted repository, even if that is the only copy of the file.
 -
 - But, moving a file from a repository with higher trust to an untrusted
 - repository must still check that there are enough other copies to be
 - safe.
 -
 - Also, required content settings should not be violated.
 -
 - This function checks all that. It needs to know if the destination
 - repository already had a copy of the file before the move began.
 -}
willDropMakeItWorse :: UUID -> UUID -> Bool -> Key -> AssociatedFile -> Annex DropCheck
willDropMakeItWorse srcuuid destuuid deststartedwithcopy key afile =
	ifM (Command.Drop.checkRequiredContent srcuuid key afile)
		( if deststartedwithcopy
			then unlessforced DropCheckNumCopies
			else ifM checktrustlevel
				( return DropAllowed
				, unlessforced DropCheckNumCopies
				)
		, unlessforced DropWorse
		)
  where
	unlessforced r = ifM (Annex.getState Annex.force)
		( return DropAllowed
		, return r
		)
	checktrustlevel = do
		desttrust <- lookupTrust destuuid
		srctrust <- lookupTrust srcuuid
		return (desttrust > UnTrusted || desttrust >= srctrust)

data DropCheck = DropWorse | DropAllowed | DropCheckNumCopies
