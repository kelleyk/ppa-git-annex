{- git-annex vector clocks
 -
 - We don't have a way yet to keep true distributed vector clocks.
 - The next best thing is a timestamp.
 -
 - Copyright 2017-2019 Joey Hess <id@joeyh.name>
 -
 - Licensed under the GNU AGPL version 3 or higher.
 -}

module Annex.VectorClock where

import Data.Time.Clock.POSIX
import Data.ByteString.Builder
import Control.Applicative
import Prelude

import Utility.Env
import Utility.TimeStamp
import Utility.QuickCheck
import qualified Data.Attoparsec.ByteString.Lazy as A

-- | Some very old logs did not have any time stamp at all;
-- Unknown is used for those.
data VectorClock = Unknown | VectorClock POSIXTime
	deriving (Eq, Ord, Show)

-- Unknown is oldest.
prop_VectorClock_sane :: Bool
prop_VectorClock_sane = Unknown < VectorClock 1

instance Arbitrary  VectorClock where
	arbitrary = VectorClock <$> arbitrary

currentVectorClock :: IO VectorClock
currentVectorClock = go =<< getEnv "GIT_ANNEX_VECTOR_CLOCK"
  where
	go Nothing = VectorClock <$> getPOSIXTime
	go (Just s) = case parsePOSIXTime s of
		Just t -> return (VectorClock t)
		Nothing -> VectorClock <$> getPOSIXTime

formatVectorClock :: VectorClock -> String
formatVectorClock Unknown = "0"
formatVectorClock (VectorClock t) = show t

buildVectorClock :: VectorClock -> Builder
buildVectorClock = string7 . formatVectorClock

parseVectorClock :: String -> Maybe VectorClock
parseVectorClock t = VectorClock <$> parsePOSIXTime t

vectorClockParser :: A.Parser VectorClock
vectorClockParser = VectorClock <$> parserPOSIXTime
