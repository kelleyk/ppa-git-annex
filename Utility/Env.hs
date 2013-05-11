{- portable environment variables
 -
 - Copyright 2013 Joey Hess <joey@kitenet.net>
 -
 - Licensed under the GNU GPL version 3 or higher.
 -}

{-# LANGUAGE CPP #-}

module Utility.Env where

#ifdef __WINDOWS__
import Utility.Exception
import qualified System.Environment as E
#else
import qualified System.Posix.Env as PE
#endif

{- Posix getEnv is faster than the one in System.Environment,
 - so use when available. -}
getEnv :: String -> IO (Maybe String)
#ifndef __WINDOWS__
getEnv = PE.getEnv
#else
getEnv = catchMaybeIO . E.getEnv
#endif

getEnvDefault :: String -> String -> IO String
#ifndef __WINDOWS__
getEnvDefault = PE.getEnvDefault
#else
getEnvDefault var fallback = fromMaybe fallback <$> getEnv var
#endif

getEnvironment :: IO [(String, String)]
#ifndef __WINDOWS__
getEnvironment = PE.getEnvironment
#else
getEnvironment = E.getEnvironment
#endif

{- Returns True if it could successfully set the environment variable.
 -
 - There is, apparently, no way to do this in Windows. Instead,
 - environment varuables must be provided when running a new process. -}
setEnv :: String -> String -> Bool -> IO Bool
#ifndef __WINDOWS__
setEnv var val overwrite = do
	PE.setEnv var val overwrite
	return True
#else
setEnv _ _ _ = return False
#endif

{- Returns True if it could successfully unset the environment variable. -}
unsetEnv :: String -> IO Bool
#ifndef __WINDOWS__
unsetEnv var = do
	PE.unsetEnv var
	return True
#else
unsetEnv _ _ _ = return False
#endif
