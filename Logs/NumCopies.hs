{- git-annex numcopies log
 -
 - Copyright 2014 Joey Hess <joey@kitenet.net>
 -
 - Licensed under the GNU GPL version 3 or higher.
 -}

{-# OPTIONS_GHC -fno-warn-orphans #-}

module Logs.NumCopies (
	module Types.NumCopies,
	setGlobalNumCopies,
	getGlobalNumCopies,
	globalNumCopiesLoad,
	getFileNumCopies,
	getGlobalFileNumCopies,
	getNumCopies,
	numCopiesCheck,
	deprecatedNumCopies,
	defaultNumCopies
) where

import Common.Annex
import qualified Annex
import Types.NumCopies
import Logs
import Logs.SingleValue
import Logs.Trust
import Annex.CheckAttr
import qualified Remote

instance SingleValueSerializable NumCopies where
	serialize (NumCopies n) = show n
	deserialize = NumCopies <$$> readish

setGlobalNumCopies :: NumCopies -> Annex ()
setGlobalNumCopies = setLog numcopiesLog

{- Value configured in the numcopies log. Cached for speed. -}
getGlobalNumCopies :: Annex (Maybe NumCopies)
getGlobalNumCopies = maybe globalNumCopiesLoad (return . Just)
	=<< Annex.getState Annex.globalnumcopies

globalNumCopiesLoad :: Annex (Maybe NumCopies)
globalNumCopiesLoad = do
	v <- getLog numcopiesLog
	Annex.changeState $ \s -> s { Annex.globalnumcopies = v }
	return v

defaultNumCopies :: NumCopies
defaultNumCopies = NumCopies 1

fromSources :: [Annex (Maybe NumCopies)] -> Annex NumCopies
fromSources = fromMaybe defaultNumCopies <$$> getM id

{- The git config annex.numcopies is deprecated. -}
deprecatedNumCopies :: Annex (Maybe NumCopies)
deprecatedNumCopies = annexNumCopies <$> Annex.getGitConfig

{- Value forced on the command line by --numcopies. -}
getForcedNumCopies :: Annex (Maybe NumCopies)
getForcedNumCopies = Annex.getState Annex.forcenumcopies

{- Numcopies value from any of the non-.gitattributes configuration
 - sources. -}
getNumCopies :: Annex NumCopies
getNumCopies = fromSources
	[ getForcedNumCopies
	, getGlobalNumCopies
	, deprecatedNumCopies
	]

{- Numcopies value for a file, from any configuration source, including the
 - deprecated git config. -}
getFileNumCopies :: FilePath -> Annex NumCopies
getFileNumCopies f = fromSources
	[ getForcedNumCopies
	, getFileNumCopies' f
	, deprecatedNumCopies
	]

{- This is the globally visible numcopies value for a file. So it does
 - not include local configuration in the git config or command line
 - options. -}
getGlobalFileNumCopies :: FilePath  -> Annex NumCopies
getGlobalFileNumCopies f = fromSources
	[ getFileNumCopies' f
	]

getFileNumCopies' :: FilePath  -> Annex (Maybe NumCopies)
getFileNumCopies' file = maybe getGlobalNumCopies (return . Just) =<< getattr
  where
	getattr = (NumCopies <$$> readish)
		<$> checkAttr "annex.numcopies" file

{- Checks if numcopies are satisfied for a file by running a comparison
 - between the number of (not untrusted) copies that are
 - belived to exist, and the configured value. -}
numCopiesCheck :: FilePath -> Key -> (Int -> Int -> v) -> Annex v
numCopiesCheck file key vs = do
	NumCopies needed <- getFileNumCopies file
	have <- trustExclude UnTrusted =<< Remote.keyLocations key
	return $ length have `vs` needed
