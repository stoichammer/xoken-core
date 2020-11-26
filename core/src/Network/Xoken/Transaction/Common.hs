{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}

{-|
Module      : Network.Xoken.Transaction.Common
Copyright   : Xoken Labs
License     : Open BSV License

Stability   : experimental
Portability : POSIX

Code related to transactions parsing and serialization.
-}
module Network.Xoken.Transaction.Common
    ( Tx(..)
    , TxIn(..)
    , TxOut(..)
    , OutPoint(..)
    , TxHash(..)
    , TxShortHash(..)
    , txHash
    , hexToTxHash
    , txHashToHex
    , getTxShortHash
    , nosigTxHash
    , nullOutPoint
    , genesisTx
    , makeCoinbaseTx
    ) where

import qualified Codec.Serialise as CBOR
import Control.Applicative ((<|>))
import Control.Monad ((<=<), forM_, guard, liftM2, mzero, replicateM)
import Data.Aeson as A
import Data.Bits
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as C
import qualified Data.ByteString.Short as BSS
import Data.Char
import Data.Hashable (Hashable)
import Data.List (foldl')
import Data.List as L
import Data.Maybe (fromMaybe, maybe)
import Data.Serialize as S
import Data.String (IsString, fromString)
import Data.String.Conversions (cs)
import qualified Data.Text as T
import Data.Word (Word32, Word64)
import Data.Word
import GHC.Generics
import Network.Xoken.Crypto.Hash
import Network.Xoken.Network.Common
import Network.Xoken.Script.Common
import Network.Xoken.Util
import Numeric as N
import Text.Read as R

-- | Transaction id: hash of transaction excluding witness data.
newtype TxHash =
    TxHash
        { getTxHash :: Hash256
        }
    deriving (Eq, Ord, Generic, Hashable, Serialize, CBOR.Serialise)

instance Show TxHash where
    showsPrec _ = shows . txHashToHex

instance Read TxHash where
    readPrec = do
        R.String str <- R.lexP
        maybe R.pfail return $ hexToTxHash $ cs str

instance IsString TxHash where
    fromString s =
        let e = error "Could not read transaction hash from hex string"
         in fromMaybe e $ hexToTxHash $ cs s

instance FromJSON TxHash where
    parseJSON = withText "txid" $ maybe mzero return . hexToTxHash

instance ToJSON TxHash where
    toJSON = A.String . txHashToHex

-- | Transaction hash excluding signatures.
nosigTxHash :: Tx -> TxHash
nosigTxHash tx = TxHash $ doubleSHA256 $ S.encode tx {txIn = map clearInput $ txIn tx}
  where
    clearInput ti = ti {scriptInput = B.empty}

-- | Convert transaction hash to hex form, reversing bytes.
txHashToHex :: TxHash -> T.Text
txHashToHex (TxHash h) = encodeHex (B.reverse (S.encode h))

-- | Convert transaction hash from hex, reversing bytes.
hexToTxHash :: T.Text -> Maybe TxHash
hexToTxHash hex = do
    bs <- B.reverse <$> decodeHex hex
    h <- either (const Nothing) Just (S.decode bs)
    return $ TxHash h

type TxShortHash = Word32

getTxShortHash :: TxHash -> Int -> TxShortHash
getTxShortHash (TxHash h) numbits = do
    case runGet getWord32host (S.encode h) of
        Left e -> 0
        Right num ->
            if numbits > 32
                then 0
                else shiftR num (32 - numbits)

-- | Data type representing a transaction.
data Tx =
    Tx
      -- | transaction data format version
        { txVersion :: !Word32
      -- | list of transaction inputs
        , txIn :: ![TxIn]
      -- | list of transaction outputs
        , txOut :: ![TxOut]
      -- | earliest mining height or time
        , txLockTime :: !Word32
        }
    deriving (Show, Read, Eq, Ord, Generic, Hashable, CBOR.Serialise)

-- | Compute transaction hash.
txHash :: Tx -> TxHash
txHash tx = TxHash (doubleSHA256 (S.encode tx))

instance IsString Tx where
    fromString = fromMaybe e . (eitherToMaybe . S.decode <=< decodeHex) . cs
      where
        e = error "Could not read transaction from hex string"

instance Serialize Tx where
    get = parseLegacyTx
    put tx = putLegacyTx tx

putInOut :: Tx -> Put
putInOut tx = do
    putVarInt $ length (txIn tx)
    forM_ (txIn tx) put
    putVarInt $ length (txOut tx)
    forM_ (txOut tx) put

putLegacyTx :: Tx -> Put
putLegacyTx tx = do
    putWord32le (txVersion tx)
    putInOut tx
    putWord32le (txLockTime tx)

parseLegacyTx :: Get Tx
parseLegacyTx = do
    v <- getWord32le
    is <- replicateList =<< S.get
    os <- replicateList =<< S.get
    l <- getWord32le
    return Tx {txVersion = v, txIn = is, txOut = os, txLockTime = l}
  where
    replicateList (VarInt c) = replicateM (fromIntegral c) S.get

instance FromJSON Tx where
    parseJSON = withText "Tx" $ maybe mzero return . (eitherToMaybe . S.decode <=< decodeHex)

instance ToJSON Tx where
    toJSON (Tx v i o l) = object ["version" .= v, "ins" .= i, "outs" .= o, "locktime" .= l]
    -- toJSON = A.String . encodeHex . S.encode

-- | Data type representing a transaction input.
data TxIn =
    TxIn
           -- | output being spent
        { prevOutput :: !OutPoint
           -- | signatures and redeem script
        , scriptInput :: !ByteString
           -- | lock-time using sequence numbers (BIP-68)
        , txInSequence :: !Word32
        }
    deriving (Eq, Show, Read, Ord, Generic, Hashable, CBOR.Serialise)

instance Serialize TxIn where
    get = TxIn <$> S.get <*> (readBS =<< S.get) <*> getWord32le
      where
        readBS (VarInt len) = getByteString $ fromIntegral len
    put (TxIn o s q) = do
        put o
        putVarInt $ B.length s
        putByteString s
        putWord32le q

-- | Data type representing a transaction output.
data TxOut =
    TxOut
            -- | value of output is satoshi
        { outValue :: !Word64
            -- | pubkey script
        , scriptOutput :: !ByteString
        }
    deriving (Eq, Show, Read, Ord, Generic, Hashable, CBOR.Serialise)

instance Serialize TxOut where
    get = do
        val <- getWord64le
        (VarInt len) <- S.get
        TxOut val <$> getByteString (fromIntegral len)
    put (TxOut o s) = do
        putWord64le o
        putVarInt $ B.length s
        putByteString s

instance ToJSON TxOut where
    toJSON (TxOut v s) = object ["value" .= v, "script" .= s]

instance ToJSON TxIn where
    toJSON (TxIn op scr seq) = object ["outpoint" .= op, "script" .= scr, "sequence" .= seq]

instance ToJSON ByteString where
    toJSON a = A.String $ encodeHex a

-- | The 'OutPoint' refers to a transaction output being spent.
data OutPoint =
    OutPoint
      -- | hash of previous transaction
        { outPointHash :: !TxHash
      -- | position of output in previous transaction
        , outPointIndex :: !Word32
        }
    deriving (Show, Read, Eq, Ord, Generic, Hashable, CBOR.Serialise)

instance FromJSON OutPoint where
    parseJSON = withText "OutPoint" $ maybe mzero return . (eitherToMaybe . S.decode <=< decodeHex)

instance ToJSON OutPoint where
    toJSON (OutPoint h i) = object ["hash" .= h, "index" .= i]

instance Serialize OutPoint where
    get = do
        (h, i) <- liftM2 (,) S.get getWord32le
        return $ OutPoint h i
    put (OutPoint h i) = put h >> putWord32le i

-- | Outpoint used in coinbase transactions.
nullOutPoint :: OutPoint
nullOutPoint =
    OutPoint
        {outPointHash = "0000000000000000000000000000000000000000000000000000000000000000", outPointIndex = maxBound}

-- | Transaction from Genesis block.
genesisTx :: Tx
genesisTx = Tx 1 [txin] [txout] locktime
  where
    txin = TxIn outpoint inputBS maxBound
    txout = TxOut 5000000000 (encodeOutputBS output)
    locktime = 0
    outpoint = OutPoint z maxBound
    Just inputBS =
        decodeHex $
        fromString $
        "04ffff001d0104455468652054696d65732030332f4a616e2f323030392043686" ++
        "16e63656c6c6f72206f6e206272696e6b206f66207365636f6e64206261696c6f" ++ "757420666f722062616e6b73"
    output =
        PayPK $
        fromString $
        "04678afdb0fe5548271967f1a67130b7105cd6a828e03909a67962e0ea1f61deb" ++
        "649f6bc3f4cef38c4f35504e51ec112de5c384df7ba0b8d578a4c702b6bf11d5f"
    z = "0000000000000000000000000000000000000000000000000000000000000000"

makeCoinbaseTx :: Word32 -> Tx
makeCoinbaseTx ht = 
    let txin = TxIn nullOutPoint inputBS maxBound
        txout = TxOut 5000000000 (encodeOutputBS output)
        inputBS = 
          makeCoinbaseMsg $ fromIntegral ht
        output =
          PayPK $
          fromString $
          "04678afdb0fe5548271967f1a67130b7105cd6a828e03909a67962e0ea1f61deb" ++
          "649f6bc3f4cef38c4f35504e51ec112de5c384df7ba0b8d578a4c702b6bf11d5f"
    in Tx 2 [txin] [txout] 0

makeCoinbaseMsg :: Word64 -> ByteString
makeCoinbaseMsg ht = let msg = runPut $ putWord8 (fromIntegral $ getVarIntBytesUsed ht) >> putVarInt ht
                         pf = B.length msg
                     in runPut $ putWord8 (fromIntegral pf) >> put msg
