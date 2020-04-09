{- Web url logs.
 -
 - Copyright 2011-2014 Joey Hess <id@joeyh.name>
 -
 - Licensed under the GNU AGPL version 3 or higher.
 -}

module Logs.Web (
	URLString,
	getUrls,
	getUrlsWithPrefix,
	setUrlPresent,
	setUrlMissing,
	knownUrls,
	Downloader(..),
	getDownloader,
	setDownloader,
	setDownloader',
	setTempUrl,
	removeTempUrl,
) where

import qualified Data.Map as M

import Annex.Common
import qualified Annex
import Logs
import Logs.Presence
import Logs.Location
import qualified Annex.Branch
import Annex.CatFile
import qualified Git
import qualified Git.LsFiles
import Utility.Url
import Annex.UUID
import qualified Types.Remote as Remote

{- Gets all urls that a key might be available from. -}
getUrls :: Key -> Annex [URLString]
getUrls key = do
	config <- Annex.getGitConfig
	l <- go $ urlLogFile config key : oldurlLogs config key
	tmpl <- Annex.getState (maybeToList . M.lookup key . Annex.tempurls)
	return (tmpl ++ l)
  where
	go [] = return []
	go (l:ls) = do
		us <- currentLogInfo l
		if null us
			then go ls
			else return $ map (decodeBS  . fromLogInfo) us

getUrlsWithPrefix :: Key -> String -> Annex [URLString]
getUrlsWithPrefix key prefix = filter (prefix `isPrefixOf`) 
	. map (fst . getDownloader)
	<$> getUrls key

setUrlPresent :: Key -> URLString -> Annex ()
setUrlPresent key url = do
	us <- getUrls key
	unless (url `elem` us) $ do
		config <- Annex.getGitConfig
		addLog (urlLogFile config key)
			=<< logNow InfoPresent (LogInfo (encodeBS url))
	-- If the url does not have an OtherDownloader, it must be present
	-- in the web.
	case snd (getDownloader url) of
		OtherDownloader -> return ()
		_ -> logChange key webUUID InfoPresent

setUrlMissing :: Key -> URLString -> Annex ()
setUrlMissing key url = do
	config <- Annex.getGitConfig
	addLog (urlLogFile config key)
		=<< logNow InfoMissing (LogInfo (encodeBS url))
	-- If the url was a web url (not OtherDownloader) and none of
	-- the remaining urls for the key are web urls, the key must not
	-- be present in the web.
	when (isweb url) $
		whenM (null . filter isweb <$> getUrls key) $
			logChange key webUUID InfoMissing
  where
	isweb u = case snd (getDownloader u) of
		OtherDownloader -> False
		_ -> True

{- Finds all known urls. -}
knownUrls :: Annex [(Key, URLString)]
knownUrls = do
	{- Ensure the git-annex branch's index file is up-to-date and
	 - any journaled changes are reflected in it, since we're going
	 - to query its index directly. -}
	_ <- Annex.Branch.update
	Annex.Branch.commit =<< Annex.Branch.commitMessage
	Annex.Branch.withIndex $ do
		top <- fromRepo Git.repoPath
		(l, cleanup) <- inRepo $ Git.LsFiles.stagedDetails [top]
		r <- mapM getkeyurls l
		void $ liftIO cleanup
		return $ concat r
  where
	getkeyurls (f, s, _) = case urlLogFileKey f of
		Just k -> zip (repeat k) <$> geturls s
		Nothing -> return []
	geturls Nothing = return []
	geturls (Just logsha) =
		map (decodeBS . fromLogInfo) . getLog 
			<$> catObject logsha

setTempUrl :: Key -> URLString -> Annex ()
setTempUrl key url = Annex.changeState $ \s ->
	s { Annex.tempurls = M.insert key url (Annex.tempurls s) }

removeTempUrl :: Key -> Annex ()
removeTempUrl key = Annex.changeState $ \s ->
	s { Annex.tempurls = M.delete key (Annex.tempurls s) }

data Downloader = WebDownloader | YoutubeDownloader | QuviDownloader | OtherDownloader
	deriving (Eq, Show)

{- To keep track of how an url is downloaded, it's mangled slightly in
 - the log, with a prefix indicating when a Downloader is used. -}
setDownloader :: URLString -> Downloader -> String
setDownloader u WebDownloader = u
setDownloader u QuviDownloader = "quvi:" ++ u
setDownloader u YoutubeDownloader = "yt:" ++ u
setDownloader u OtherDownloader = ":" ++ u

setDownloader' :: URLString -> Remote -> String
setDownloader' u r
	| Remote.uuid r == webUUID = setDownloader u WebDownloader
	| otherwise = setDownloader u OtherDownloader

getDownloader :: URLString -> (URLString, Downloader)
getDownloader u = case separate (== ':') u of
	("yt", u') -> (u', YoutubeDownloader)
	-- quvi is not used any longer; youtube-dl should be able to handle
	-- all urls it did.
	("quvi", u') -> (u', YoutubeDownloader)
	("", u') -> (u', OtherDownloader)
	_ -> (u, WebDownloader)
