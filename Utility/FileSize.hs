{- File size.
 -
 - License: BSD-2-clause
 -}

{-# LANGUAGE CPP #-}
{-# OPTIONS_GHC -fno-warn-tabs #-}

module Utility.FileSize (
	FileSize,
	getFileSize,
	getFileSize',
) where

import System.PosixCompat.Files
#ifdef mingw32_HOST_OS
import Control.Exception (bracket)
import System.IO
#endif

type FileSize = Integer

{- Gets the size of a file.
 -
 - This is better than using fileSize, because on Windows that returns a
 - FileOffset which maxes out at 2 gb.
 - See https://github.com/jystic/unix-compat/issues/16
 -}
getFileSize :: FilePath -> IO FileSize
#ifndef mingw32_HOST_OS
getFileSize f = fmap (fromIntegral . fileSize) (getFileStatus f)
#else
getFileSize f = bracket (openFile f ReadMode) hClose hFileSize
#endif

{- Gets the size of the file, when its FileStatus is already known.
 -
 - On windows, uses getFileSize. Otherwise, the FileStatus contains the
 - size, so this does not do any work. -}
getFileSize' :: FilePath -> FileStatus -> IO FileSize
#ifndef mingw32_HOST_OS
getFileSize' _ s = return $ fromIntegral $ fileSize s
#else
getFileSize' f _ = getFileSize f
#endif
