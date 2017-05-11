{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE RankNTypes #-}
module Codec.Archive.Zip.Conduit.UnZip
  ( ZipEntry(..)
  , ZipInfo(..)
  , unZip
  ) where

import           Control.Applicative ((<|>), empty)
import           Control.Monad (when, unless, guard)
import qualified Data.Binary.Get as G
import           Data.Bits ((.&.), complement, testBit, shiftL, shiftR)
import qualified Data.ByteString as BS
import qualified Data.Conduit as C
import qualified Data.Conduit.List as CL
import           Data.Conduit.Serialization.Binary (sinkGet)
import           Data.Conduit.Zlib (WindowBits(..), decompress)
import           Data.Digest.CRC32 (crc32Update)
import           Data.Time (UTCTime(..), fromGregorian, timeOfDayToTime, TimeOfDay(..))
import           Data.Word (Word32, Word64)

data ZipEntry = ZipEntry
  { zipEntryName :: BS.ByteString
  , zipEntryTime :: UTCTime
  , zipEntrySize :: !Word64
  }

data ZipInfo = ZipInfo
  { zipComment :: BS.ByteString
  }

data Header m
  = FileHeader
    { fileDecompress :: C.Conduit BS.ByteString m BS.ByteString
    , fileEntry :: !ZipEntry
    , fileCRC :: !Word32
    , fileCSize :: !Word64
    , fileZip64 :: !Bool
    }
  | EndOfCentralDirectory
    { endInfo :: ZipInfo
    }

data ExtField = ExtField
  { extZip64 :: Bool
  , extZip64USize
  , extZip64CSize :: Word64
  }

{- ExtUnix
  { extUnixATime
  , extUnixMTime :: UTCTime
  , extUnixUID
  , extUnixGID :: Word16
  , extUnixData :: BS.ByteString
  }
-}

pass :: (Monad m, Integral n) => n -> C.Conduit BS.ByteString m BS.ByteString
pass 0 = return ()
pass n = C.await >>= maybe
  (fail $ "EOF in file data, expecting " ++ show ni ++ " more bytes")
  (\b ->
    let n' = ni - toInteger (BS.length b) in
    if n' < 0
      then do
        let (b', r) = BS.splitAt (fromIntegral n) b
        C.yield b'
        C.leftover r
      else do
        C.yield b
        pass n')
  where ni = toInteger n

crc32 :: Monad m => C.Consumer BS.ByteString m Word32
crc32 = CL.fold crc32Update 0

checkCRC :: Monad m => Word32 -> C.Conduit BS.ByteString m BS.ByteString
checkCRC t = C.passthroughSink crc32 $ \r -> unless (r == t) $ fail "CRC32 mismatch"

unZip :: C.ConduitM BS.ByteString (Either ZipEntry BS.ByteString) IO ZipInfo
unZip = next where
  next = do
    h <- sinkGet header
    case h of
      FileHeader{..} -> do
        C.yield $ Left fileEntry
        C.mapOutput Right $ pass fileCSize
          C..| (fileDecompress >> CL.sinkNull)
          C..| checkCRC fileCRC
        sinkGet $ dataDesc h
        next
      EndOfCentralDirectory{..} -> do
        return endInfo
  header = do
    sig <- G.getWord32le
    case sig of
      0x04034b50 -> fileHeader
      _ -> centralBody sig
  dataDesc h = -- this takes a bit of flexibility to account for the various cases
    (do -- with signature
      sig <- G.getWord32le
      guard (sig == 0x06054b50)
      dataDescBody h)
    <|> dataDescBody h -- without signature
    <|> return () -- none
  dataDescBody FileHeader{..} = do
    crc <- G.getWord32le
    let getSize = if fileZip64 then G.getWord64le else fromIntegral <$> G.getWord32le
    csiz <- getSize
    usiz <- getSize
    guard $ crc == fileCRC && csiz == fileCSize && usiz == zipEntrySize fileEntry
  dataDescBody _ = empty
  central = G.getWord32le >>= centralBody
  centralBody 0x02014b50 = centralHeader >> central
  centralBody 0x06064b50 = zip64EndDirectory >> central
  centralBody 0x07064b50 = G.skip 16 >> central
  centralBody 0x06054b50 = EndOfCentralDirectory <$> endDirectory
  centralBody sig = fail $ "Unknown header signature: " ++ show sig
  fileHeader = do
    ver <- G.getWord16le
    when (ver > 45) $ fail $ "Unsupported version: " ++ show ver
    gpf <- G.getWord16le
    when (gpf .&. complement 0o06 /= 0) $ fail $ "Unsupported flags: " ++ show gpf
    comp <- G.getWord16le
    dcomp <- case comp of
      0 | testBit gpf 3 -> fail "Unsupported uncompressed streaming file data"
        | otherwise -> return $ C.awaitForever C.yield -- idConduit
      8 -> return $ decompress (WindowBits (-15))
      _ -> fail $ "Unsupported compression method: " ++ show comp
    time <- G.getWord16le
    date <- G.getWord16le
    let mtime = UTCTime (fromGregorian
            (fromIntegral $ date `shiftR` 9 + 1980)
            (fromIntegral $ date `shiftR` 5 .&. 0x0f)
            (fromIntegral $ date            .&. 0x1f)
          )
          (timeOfDayToTime $ TimeOfDay
            (fromIntegral $ time `shiftR` 11)
            (fromIntegral $ time `shiftR` 5 .&. 0x3f)
            (fromIntegral $ time `shiftL` 1 .&. 0x3f)
          )
    crc <- G.getWord32le
    csiz <- G.getWord32le
    usiz <- G.getWord32le
    nlen <- fromIntegral <$> G.getWord16le
    elen <- fromIntegral <$> G.getWord16le
    name <- G.getByteString nlen
    let getExt ext = do
          t <- G.getWord16le
          z <- fromIntegral <$> G.getWord16le
          ext' <- G.isolate z $ case t of
            0x0001 -> do
              -- the zip specs claim "the Local header MUST include BOTH" but "only if the corresponding field is set to 0xFFFFFFFF"
              usiz' <- if usiz == maxBound then G.getWord64le else return $ extZip64USize ext
              csiz' <- if csiz == maxBound then G.getWord64le else return $ extZip64CSize ext
              return ext
                { extZip64 = True
                , extZip64USize = usiz'
                , extZip64CSize = csiz'
                }
            {-
            0x000d -> do
              atim <- G.getWord32le
              mtim <- G.getWord32le
              uid <- G.getWord16le
              gid <- G.getWord16le
              dat <- G.getByteString $ z - 12
              return ExtUnix
                { extUnixATime = posixSecondsToUTCTime atim
                , extUnixMTime = posixSecondsToUTCTime mtim
                , extUnixUID = uid
                , extUnixGID = gid
                , extUnixData = dat
                }
            -}
            _ -> ext <$ G.skip z
          getExt ext'
    ExtField{..} <- G.isolate elen $ getExt ExtField
      { extZip64 = False
      , extZip64USize = fromIntegral usiz
      , extZip64CSize = fromIntegral csiz
      }
    return FileHeader
      { fileEntry = ZipEntry
        { zipEntryName = name
        , zipEntryTime = mtime
        , zipEntrySize = extZip64USize
        }
      , fileDecompress = dcomp
      , fileCSize = extZip64CSize
      , fileCRC = crc
      , fileZip64 = extZip64
      }
  centralHeader = do
    -- ignore everything
    G.skip 24
    nlen <- fromIntegral <$> G.getWord16le
    elen <- fromIntegral <$> G.getWord16le
    clen <- fromIntegral <$> G.getWord16le
    G.skip $ 12 + nlen + elen + clen
  zip64EndDirectory = do
    len <- G.getWord64le
    G.skip $ fromIntegral len -- would not expect to overflow...
  endDirectory = do
    G.skip 16
    clen <- fromIntegral <$> G.getWord16le
    comm <- G.getByteString clen
    return ZipInfo
      { zipComment = comm
      }