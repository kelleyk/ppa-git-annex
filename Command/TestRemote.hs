{- git-annex command
 -
 - Copyright 2014-2020 Joey Hess <id@joeyh.name>
 -
 - Licensed under the GNU AGPL version 3 or higher.
 -}

{-# LANGUAGE RankNTypes #-}

module Command.TestRemote where

import Command
import qualified Annex
import qualified Remote
import qualified Types.Remote as Remote
import qualified Types.Backend as Backend
import Types.KeySource
import Annex.Content
import Annex.WorkTree
import Backend
import Logs.Location
import qualified Backend.Hash
import Utility.Tmp
import Utility.Metered
import Utility.DataUnits
import Utility.CopyFile
import Types.Messages
import Types.Export
import Types.RemoteConfig
import Types.ProposedAccepted
import Annex.SpecialRemote.Config (exportTreeField)
import Remote.Helper.Chunked
import Remote.Helper.Encryptable (encryptionField, highRandomQualityField)
import Git.Types

import Test.Tasty
import Test.Tasty.Runners
import Test.Tasty.HUnit
import "crypto-api" Crypto.Random
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as L
import qualified Data.Map as M
import Data.Either
import Control.Concurrent.STM hiding (check)

cmd :: Command
cmd = command "testremote" SectionTesting
	"test transfers to/from a remote"
	paramRemote (seek <$$> optParser)

data TestRemoteOptions = TestRemoteOptions
	{ testRemote :: RemoteName
	, sizeOption :: ByteSize
	, testReadonlyFile :: [FilePath]
	}

optParser :: CmdParamsDesc -> Parser TestRemoteOptions
optParser desc = TestRemoteOptions
	<$> argument str ( metavar desc )
	<*> option (str >>= maybe (fail "parse error") return . readSize dataUnits)
		( long "size" <> metavar paramSize
		<> value (1024 * 1024)
		<> help "base key size (default 1MiB)"
		)
	<*> many testreadonly
  where
	testreadonly = option str
		( long "test-readonly" <> metavar paramFile
		<> help "readonly test object"
		)

seek :: TestRemoteOptions -> CommandSeek
seek = commandAction . start 

start :: TestRemoteOptions -> CommandStart
start o = starting "testremote" (ActionItemOther (Just (testRemote o))) $ do
	fast <- Annex.getState Annex.fast
	r <- either giveup disableExportTree =<< Remote.byName' (testRemote o)
	ks <- case testReadonlyFile o of
		[] -> if Remote.readonly r
			then giveup "This remote is readonly, so you need to use the --test-readonly option."
			else do
				showAction "generating test keys"
				mapM randKey (keySizes basesz fast)
		fs -> mapM (getReadonlyKey r) fs
	let r' = if null (testReadonlyFile o)
		then r
		else r { Remote.readonly = True }
	let drs = if Remote.readonly r'
		then [Described "remote" (pure (Just r'))]
		else remoteVariants (Described "remote" (pure r')) basesz fast
	unavailr  <- Remote.mkUnavailable r'
	let exportr = if Remote.readonly r'
		then return Nothing
		else exportTreeVariant r'
	perform drs unavailr exportr ks
  where
	basesz = fromInteger $ sizeOption o

perform :: [Described (Annex (Maybe Remote))] -> Maybe Remote -> Annex (Maybe Remote) -> [Key] -> CommandPerform
perform drs unavailr exportr ks = do
	st <- liftIO . newTVarIO =<< Annex.getState id
	let tests = testGroup "Remote Tests" $ mkTestTrees
		(runTestCase st) 
		drs
		(pure unavailr)
		exportr
		(map (\k -> Described (desck k) (pure k)) ks)
	ok <- case tryIngredients [consoleTestReporter] mempty tests of
		Nothing -> error "No tests found!?"
		Just act -> liftIO act
	rs <- catMaybes <$> mapM getVal drs
	next $ cleanup rs ks ok
  where
	desck k = unwords [ "key size", show (fromKey keySize k) ]

remoteVariants :: Described (Annex Remote) -> Int -> Bool -> [Described (Annex (Maybe Remote))]
remoteVariants dr basesz fast = 
	concatMap encryptionVariants $
		map chunkvariant (chunkSizes basesz fast)
  where
	chunkvariant sz = Described (getDesc dr ++ " chunksize=" ++ show sz) $ do
		r <- getVal dr
		adjustChunkSize r sz

adjustChunkSize :: Remote -> Int -> Annex (Maybe Remote)
adjustChunkSize r chunksize = adjustRemoteConfig r $
	M.insert chunkField (Proposed (show chunksize))

-- Variants of a remote with no encryption, and with simple shared
-- encryption. Gpg key based encryption is not tested.
encryptionVariants :: Described (Annex (Maybe Remote)) -> [Described (Annex (Maybe Remote))]
encryptionVariants dr = [noenc, sharedenc]
  where
	noenc = Described (getDesc dr ++ " encryption=none") $
		getVal dr >>= \case
			Nothing -> return Nothing
			Just r -> adjustRemoteConfig r $
				M.insert encryptionField (Proposed "none")
	sharedenc = Described (getDesc dr ++ " encryption=shared") $
		getVal dr >>= \case
			Nothing -> return Nothing
			Just r -> adjustRemoteConfig r $
				M.insert encryptionField (Proposed "shared") .
				M.insert highRandomQualityField (Proposed "false")

-- Variant of a remote with exporttree disabled.
disableExportTree :: Remote -> Annex Remote
disableExportTree r = maybe (error "failed disabling exportree") return 
		=<< adjustRemoteConfig r (M.delete exportTreeField)

-- Variant of a remote with exporttree enabled.
exportTreeVariant :: Remote -> Annex (Maybe Remote)
exportTreeVariant r = ifM (Remote.isExportSupported r)
	( adjustRemoteConfig r $
		M.insert encryptionField (Proposed "none") . 
		M.insert exportTreeField (Proposed "yes")
	, return Nothing
	)

-- Regenerate a remote with a modified config.
adjustRemoteConfig :: Remote -> (Remote.RemoteConfig -> Remote.RemoteConfig) -> Annex (Maybe Remote)
adjustRemoteConfig r adjustconfig = do
	repo <- Remote.getRepo r
	let ParsedRemoteConfig _ origc = Remote.config r
	Remote.generate (Remote.remotetype r)
		repo
		(Remote.uuid r)
		(adjustconfig origc)
		(Remote.gitconfig r)
		(Remote.remoteStateHandle r)

data Described t = Described
	{ getDesc :: String
	, getVal :: t
	}

type RunAnnex = forall a. Annex a -> IO a

runTestCase :: TVar Annex.AnnexState -> RunAnnex
runTestCase stv a = do
	st <- atomically $ readTVar stv
	(r, st') <- Annex.run st $ do
		Annex.setOutput QuietOutput 
		a
	atomically $ writeTVar stv st'
	return r

-- Note that the same remotes and keys should be produced each time
-- the provided actions are called.
mkTestTrees
	:: RunAnnex
	-> [Described (Annex (Maybe Remote))]
	-> Annex (Maybe Remote)
	-> Annex (Maybe Remote)
	-> [Described (Annex Key)]
	-> [TestTree]
mkTestTrees runannex mkrs mkunavailr mkexportr mkks = concat $
	[ [ testGroup "unavailable remote" (testUnavailable runannex mkunavailr (getVal (Prelude.head mkks))) ]
	, [ testGroup (desc mkr mkk) (test runannex (getVal mkr) (getVal mkk)) | mkk <- mkks, mkr <- mkrs ]
	, [ testGroup (descexport mkk1 mkk2) (testExportTree runannex mkexportr (getVal mkk1) (getVal mkk2)) | mkk1 <- take 2 mkks, mkk2 <- take 2 (reverse mkks) ]
	]
   where
	desc r k = intercalate "; " $ map unwords
		[ [ getDesc k ]
		, [ getDesc r ]
		]
	descexport k1 k2 = intercalate "; " $ map unwords
		[ [ "exporttree=yes" ]
		, [ getDesc k1 ]
		, [ getDesc k2 ]
		]

test :: RunAnnex -> Annex (Maybe Remote) -> Annex Key -> [TestTree]
test runannex mkr mkk =
	[ check "removeKey when not present" $ \r k ->
		whenwritable r $ isRight <$> tryNonAsync (remove r k)
	, check ("present " ++ show False) $ \r k ->
		whenwritable r $ present r k False
	, check "storeKey" $ \r k ->
		whenwritable r $ isRight <$> tryNonAsync (store r k)
	, check ("present " ++ show True) $ \r k ->
		whenwritable r $ present r k True
	, check "storeKey when already present" $ \r k ->
		whenwritable r $ isRight <$> tryNonAsync (store r k)
	, check ("present " ++ show True) $ \r k -> present r k True
	, check "retrieveKeyFile" $ \r k -> do
		lockContentForRemoval k removeAnnex
		get r k
	, check "fsck downloaded object" fsck
	, check "retrieveKeyFile resume from 33%" $ \r k -> do
		loc <- fromRawFilePath <$> Annex.calcRepo (gitAnnexLocation k)
		tmp <- prepTmp k
		partial <- liftIO $ bracket (openBinaryFile loc ReadMode) hClose $ \h -> do
			sz <- hFileSize h
			L.hGet h $ fromInteger $ sz `div` 3
		liftIO $ L.writeFile tmp partial
		lockContentForRemoval k removeAnnex
		get r k
	, check "fsck downloaded object" fsck
	, check "retrieveKeyFile resume from 0" $ \r k -> do
		tmp <- prepTmp k
		liftIO $ writeFile tmp ""
		lockContentForRemoval k removeAnnex
		get r k
	, check "fsck downloaded object" fsck
	, check "retrieveKeyFile resume from end" $ \r k -> do
		loc <- fromRawFilePath <$> Annex.calcRepo (gitAnnexLocation k)
		tmp <- prepTmp k
		void $ liftIO $ copyFileExternal CopyAllMetaData loc tmp
		lockContentForRemoval k removeAnnex
		get r k
	, check "fsck downloaded object" fsck
	, check "removeKey when present" $ \r k -> 
		whenwritable r $ isRight <$> tryNonAsync (remove r k)
	, check ("present " ++ show False) $ \r k -> 
		whenwritable r $ present r k False
	]
  where
	whenwritable r a
		| Remote.readonly r = return True
		| otherwise = a
	check desc a = testCase desc $ do
		let a' = mkr >>= \case
			Just r -> do
				k <- mkk
				a r k
			Nothing -> return True
		runannex a' @? "failed"
	present r k b = (== Right b) <$> Remote.hasKey r k
	fsck _ k = case maybeLookupBackendVariety (fromKey keyVariety k) of
		Nothing -> return True
		Just b -> case Backend.verifyKeyContent b of
			Nothing -> return True
			Just verifier -> verifier k (serializeKey k)
	get r k = getViaTmp (Remote.retrievalSecurityPolicy r) (RemoteVerify r) k $ \dest ->
		tryNonAsync (Remote.retrieveKeyFile r k (AssociatedFile Nothing) dest nullMeterUpdate) >>= \case
			Right v -> return (True, v)
			Left _ -> return (False, UnVerified)
	store r k = Remote.storeKey r k (AssociatedFile Nothing) nullMeterUpdate
	remove r k = Remote.removeKey r k

testExportTree :: RunAnnex -> Annex (Maybe Remote) -> Annex Key -> Annex Key -> [TestTree]
testExportTree runannex mkr mkk1 mkk2 =
	[ check "check present export when not present" $ \ea k1 _k2 ->
		not <$> checkpresentexport ea k1
	, check "remove export when not present" $ \ea k1 _k2 -> 
		isRight <$> tryNonAsync (removeexport ea k1)
	, check "store export" $ \ea k1 _k2 ->
		isRight <$> tryNonAsync (storeexport ea k1)
	, check "check present export after store" $ \ea k1 _k2 ->
		checkpresentexport ea k1
	, check "store export when already present" $ \ea k1 _k2 ->
		isRight <$> tryNonAsync (storeexport ea k1)
	, check "retrieve export" $ \ea k1 _k2 -> 
		retrieveexport ea k1
	, check "store new content to export" $ \ea _k1 k2 ->
		isRight <$> tryNonAsync (storeexport ea k2)
	, check "check present export after store of new content" $ \ea _k1 k2 ->
		checkpresentexport ea k2
	, check "retrieve export new content" $ \ea _k1 k2 ->
		retrieveexport ea k2
	, check "remove export" $ \ea _k1 k2 -> 
		isRight <$> tryNonAsync (removeexport ea k2)
	, check "check present export after remove" $ \ea _k1 k2 ->
		not <$> checkpresentexport ea k2
	, check "retrieve export fails after removal" $ \ea _k1 k2 ->
		not <$> retrieveexport ea k2
	, check "remove export directory" $ \ea _k1 _k2 ->
		isRight <$> tryNonAsync (removeexportdirectory ea)
	, check "remove export directory that is already removed" $ \ea _k1 _k2 ->
		isRight <$> tryNonAsync (removeexportdirectory ea)
	-- renames are not tested because remotes do not need to support them
	]
  where
	testexportdirectory = "testremote-export"
	testexportlocation = mkExportLocation (toRawFilePath (testexportdirectory </> "location"))
	check desc a = testCase desc $ do
		let a' = mkr >>= \case
			Just r -> do
				let ea = Remote.exportActions r
				k1 <- mkk1
				k2 <- mkk2
				a ea k1 k2
			Nothing -> return True
		runannex a' @? "failed"
	storeexport ea k = do
		loc <- fromRawFilePath <$> Annex.calcRepo (gitAnnexLocation k)
		Remote.storeExport ea loc k testexportlocation nullMeterUpdate
	retrieveexport ea k = withTmpFile "exported" $ \tmp h -> do
		liftIO $ hClose h
		tryNonAsync (Remote.retrieveExport ea k testexportlocation tmp nullMeterUpdate) >>= \case
			Left _ -> return False
			Right () -> verifyKeyContent RetrievalAllKeysSecure AlwaysVerify UnVerified k tmp
	checkpresentexport ea k = Remote.checkPresentExport ea k testexportlocation
	removeexport ea k = Remote.removeExport ea k testexportlocation
	removeexportdirectory ea = case Remote.removeExportDirectory ea of
		Just a -> a (mkExportDirectory (toRawFilePath testexportdirectory))
		Nothing -> noop

testUnavailable :: RunAnnex -> Annex (Maybe Remote) -> Annex Key -> [TestTree]
testUnavailable runannex mkr mkk =
	[ check isLeft "removeKey" $ \r k ->
		Remote.removeKey r k
	, check isLeft "storeKey" $ \r k -> 
		Remote.storeKey r k (AssociatedFile Nothing) nullMeterUpdate
	, check (`notElem` [Right True, Right False]) "checkPresent" $ \r k ->
		Remote.checkPresent r k
	, check (== Right False) "retrieveKeyFile" $ \r k ->
		getViaTmp (Remote.retrievalSecurityPolicy r) (RemoteVerify r) k $ \dest ->
			tryNonAsync (Remote.retrieveKeyFile r k (AssociatedFile Nothing) dest nullMeterUpdate) >>= \case
				Right v -> return (True, v)
				Left _ -> return (False, UnVerified)
	, check (== Right False) "retrieveKeyFileCheap" $ \r k -> case Remote.retrieveKeyFileCheap r of
		Nothing -> return False
		Just a -> getViaTmp (Remote.retrievalSecurityPolicy r) (RemoteVerify r) k $ \dest -> 
			unVerified $ isRight
				<$> tryNonAsync (a k (AssociatedFile Nothing) dest)
	]
  where
	check checkval desc a = testCase desc $ 
		join $ runannex $ mkr >>= \case
			Just r -> do
				k <- mkk
				v <- either (Left  . show) Right
					<$> tryNonAsync (a r k)
				return $ checkval v
					@? ("(got: " ++ show v ++ ")")
			Nothing -> return noop

cleanup :: [Remote] -> [Key] -> Bool -> CommandCleanup
cleanup rs ks ok
	| all Remote.readonly rs = return ok
	| otherwise = do
		forM_ rs $ \r -> forM_ ks (Remote.removeKey r)
		forM_ ks $ \k -> lockContentForRemoval k removeAnnex
		return ok

chunkSizes :: Int -> Bool -> [Int]
chunkSizes base False =
	[ 0 -- no chunking
	, base `div` 100
	, base `div` 1000
	, base
	]
chunkSizes _ True =
	[ 0
	]

keySizes :: Int -> Bool -> [Int]
keySizes base fast = filter want
	[ 0 -- empty key is a special case when chunking
	, base
	, base + 1
	, base - 1
	, base * 2
	]
  where
	want sz
		| fast = sz <= base && sz > 0
		| otherwise = sz > 0

randKey :: Int -> Annex Key
randKey sz = withTmpFile "randkey" $ \f h -> do
	gen <- liftIO (newGenIO :: IO SystemRandom)
	case genBytes sz gen of
		Left e -> giveup $ "failed to generate random key: " ++ show e
		Right (rand, _) -> liftIO $ B.hPut h rand
	liftIO $ hClose h
	let ks = KeySource
		{ keyFilename = toRawFilePath f
		, contentLocation = toRawFilePath f
		, inodeCache = Nothing
		}
	k <- case Backend.getKey Backend.Hash.testKeyBackend of
		Just a -> a ks nullMeterUpdate
		Nothing -> giveup "failed to generate random key (backend problem)"
	_ <- moveAnnex k f
	return k

getReadonlyKey :: Remote -> FilePath -> Annex Key
getReadonlyKey r f = lookupFile (toRawFilePath f) >>= \case
	Nothing -> giveup $ f ++ " is not an annexed file"
	Just k -> do
		unlessM (inAnnex k) $
			giveup $ f ++ " does not have its content locally present, cannot test it"
		unlessM ((Remote.uuid r `elem`) <$> loggedLocations k) $
			giveup $ f ++ " is not stored in the remote being tested, cannot test it"
		return k
