{-# LANGUAGE DeriveFunctor #-}

module Network.Xoken.Script.Interpreter where

import           Data.Maybe                     ( maybe )
import           Data.Foldable                  ( toList )
import           Data.Word                      ( Word8 )
import           Data.Bits                      ( complement
                                                , (.&.)
                                                , (.|.)
                                                , xor
                                                , shiftL
                                                , shiftR
                                                )
import qualified Data.ByteString               as BS
import qualified Data.Serialize                as S
import qualified Data.Sequence                 as Seq
import           Control.Monad
import           Control.Monad.Free             ( Free(Pure, Free)
                                                , liftF
                                                )
import           Network.Xoken.Script.Common
import           Network.Xoken.Script.OpenSSL_BN

type Elem = BS.ByteString
type Stack = Seq.Seq Elem
type InterpreterResult = (Stack, Maybe InterpreterError)

data InterpreterError
  = StackUnderflow
  | NoDecoding {length_bytes :: Int, bytestring :: BS.ByteString}
  | NotEnoughBytes {expected :: Word8, actual :: Int}
  | TooMuchToLShift Integer
  | ConversionError
  | Unimplemented ScriptOp
  | Message String
  deriving (Show, Eq)

data InterpreterCommands a
    = Terminate InterpreterError
    | Push Elem a
    | Pop (Elem -> a)
    | Peek (Elem -> a)
    | PopN Int ([Elem] -> a)
    | PeekN Int ([Elem] -> a)
    | StackSize (Elem -> a)
    | Num Elem (BN -> a)
    | Bin BN (Elem -> a)
    deriving (Functor)

type Cmd = Free InterpreterCommands

interpret :: Script -> InterpreterResult
interpret script = interpretCmd (mapM_ opcode $ scriptOps script) Seq.empty

interpretCmd :: Cmd () -> Stack -> InterpreterResult
interpretCmd (Pure ()        ) stack = (stack, Nothing)
interpretCmd (Free (Push x m)) stack = interpretCmd m (x Seq.<| stack)
interpretCmd (Free (Pop k   )) stack = case Seq.viewl stack of
  x Seq.:< rest -> interpretCmd (k x) rest
  _             -> (stack, Just StackUnderflow)
interpretCmd (Free (Peek k)) stack = case Seq.viewl stack of
  x Seq.:< _ -> interpretCmd (k x) stack
  _          -> (stack, Just StackUnderflow)
interpretCmd (Free (PopN n k)) stack
  | length topn == n = interpretCmd (k $ reverse $ toList topn) rest
  | otherwise        = (stack, Just StackUnderflow)
  where (topn, rest) = Seq.splitAt n stack
interpretCmd (Free (PeekN n k)) stack
  | length topn == n = interpretCmd (k $ reverse $ toList topn) stack
  | otherwise        = (stack, Just StackUnderflow)
  where topn = Seq.take n stack
interpretCmd (Free (StackSize k)) stack =
  interpretCmd (k $ S.encode $ length stack) stack
interpretCmd (Free (Terminate e)) stack = (stack, Just e)

num :: Elem -> Cmd BN
num x = liftF (Num x id)

bin :: BN -> Cmd Elem
bin n = liftF (Bin n id)

terminate :: InterpreterError -> Cmd ()
terminate e = liftF (Terminate e)

stacksize :: Cmd Elem
stacksize = liftF (StackSize id)

push :: Elem -> Cmd ()
push x = liftF (Push x ())

pop :: Cmd Elem
pop = liftF (Pop id)

peek :: Cmd Elem
peek = liftF (Peek id)

pushn :: [Elem] -> Cmd ()
pushn = sequence_ . map push

popn :: Int -> Cmd [Elem]
popn n = liftF (PopN n id)

peekn :: Int -> Cmd [Elem]
peekn n = liftF (PeekN n id)

arrange :: Int -> ([Elem] -> [Elem]) -> Cmd ()
arrange n f = popn n >>= pushn . f

arrangepeek :: Int -> ([Elem] -> [Elem]) -> Cmd ()
arrangepeek n f = peekn n >>= pushn . f

unary :: (Elem -> Elem) -> Cmd ()
unary f = pop >>= push . f

binary :: (Elem -> Elem -> Elem) -> Cmd ()
binary f = do
  x2 <- pop
  x1 <- pop
  push $ f x1 x2

truth :: Bool -> Elem
truth x = S.encode (if x then 1 else 0 :: Int)

btruth :: (a1 -> a2 -> Bool) -> a1 -> a2 -> Elem
btruth = ((truth .) .)

arith :: [Elem] -> Cmd [BN]
arith = mapM num

pushint :: Int -> Cmd ()
pushint = push . S.encode

pushdata :: Int -> BS.ByteString -> Cmd ()
pushdata n bs = case S.decode bs1 of
  Right bytes -> if fromIntegral bytes <= BS.length bs2
    then push bs2
    else terminate $ NotEnoughBytes { expected = bytes, actual = BS.length bs2 }
  _ -> terminate $ NoDecoding { length_bytes = n, bytestring = bs1 }
  where (bs1, bs2) = BS.splitAt n bs

opcode :: ScriptOp -> Cmd ()
-- Pushing Data
opcode (OP_PUSHDATA bs OPCODE ) = push bs
opcode (OP_PUSHDATA bs OPDATA1) = pushdata 1 bs
opcode (OP_PUSHDATA bs OPDATA2) = pushdata 2 bs
opcode (OP_PUSHDATA bs OPDATA4) = pushdata 4 bs
opcode OP_0                     = pushint 0
opcode OP_1NEGATE               = pushint (-1)
opcode OP_1                     = pushint 1
opcode OP_2                     = pushint 2
opcode OP_3                     = pushint 3
opcode OP_4                     = pushint 4
opcode OP_5                     = pushint 5
opcode OP_6                     = pushint 6
opcode OP_7                     = pushint 7
opcode OP_8                     = pushint 8
opcode OP_9                     = pushint 9
opcode OP_10                    = pushint 10
opcode OP_11                    = pushint 11
opcode OP_12                    = pushint 12
opcode OP_13                    = pushint 13
opcode OP_14                    = pushint 14
opcode OP_15                    = pushint 15
opcode OP_16                    = pushint 16
-- Stack operations
opcode OP_2DROP                 = pop >> pop >> pure ()
opcode OP_2DUP                  = arrangepeek 2 (\[x1, x2] -> [x1, x2])
opcode OP_3DUP                  = arrangepeek 3 (\[x1, x2, x3] -> [x1, x2, x3])
opcode OP_2OVER                 = arrangepeek 4 (\[x1, x2, x3, x4] -> [x1, x2])
opcode OP_2ROT =
  arrange 6 (\[x1, x2, x3, x4, x5, x6] -> [x3, x4, x5, x6, x1, x2])
opcode OP_2SWAP = arrange 4 (\[x1, x2, x3, x4] -> [x3, x4, x1, x2])
opcode OP_IFDUP = peek >>= \x1 -> when (x1 /= BS.singleton 0) (push x1)
opcode OP_DEPTH = stacksize >>= push
opcode OP_DROP  = pop >> pure ()
opcode OP_DUP   = peek >>= push
opcode OP_NIP   = arrange 2 (\[x1, x2] -> [x2])
opcode OP_OVER  = arrangepeek 2 (\[x1, x2] -> [x1])
opcode OP_ROT   = arrange 3 (\[x1, x2, x3] -> [x2, x3, x1])
opcode OP_SWAP  = arrange 2 (\[x1, x2] -> [x2, x1])
opcode OP_TUCK  = arrange 2 (\[x1, x2] -> [x2, x1, x2])
-- Data manipulation
opcode OP_CAT   = binary BS.append
opcode OP_SPLIT = terminate (Unimplemented OP_SPLIT)
opcode OP_NUM2BIN =
  popn 2
    >>= arith
    >>= (\[x1, x2] -> maybe (terminate ConversionError) push (num2bin x1 x2))
opcode OP_BIN2NUM =
  pop >>= maybe (terminate ConversionError) ((>>= push) . bin) . bin2num
opcode OP_SIZE   = peek >>= \bs -> pushint $ BS.length bs
-- Bitwise logic
opcode OP_INVERT = unary (BS.map complement)
opcode OP_AND    = binary ((BS.pack .) . BS.zipWith (.&.))
opcode OP_OR     = binary ((BS.pack .) . BS.zipWith (.|.))
opcode OP_XOR    = binary ((BS.pack .) . BS.zipWith xor)
opcode OP_EQUAL  = binary (btruth (==))
-- Arithmetic
{-
opcode OP_1ADD      = pop >>= \x1 -> arith [x1] >> push $ succ x1
opcode OP_1SUB      = unary pred
opcode OP_2MUL      = unary (flip shiftL 1)
opcode OP_2DIV      = unary (flip shiftR 1)
opcode OP_NEGATE    = unary negate
opcode OP_ABS       = unary abs
opcode OP_NOT       = unary (truth . (== 0))
opcode OP_0NOTEQUAL = unary (truth . (/= 0))
opcode OP_ADD       = binary (+)
opcode OP_SUB       = binary (-)
opcode OP_MUL       = binary (*)
opcode OP_DIV       = binary div
opcode OP_MOD       = binary mod
opcode OP_LSHIFT    = do
  b <- pop
  a <- pop
  if b <= toInteger (maxBound :: Int)
    then push $ shiftL a (fromIntegral b)
    else terminate $ TooMuchToLShift b
opcode OP_RSHIFT = binary
  (\a b ->
    if b <= toInteger (maxBound :: Int) then shiftR a (fromIntegral b) else 0
  )
opcode OP_BOOLAND            = binary (\a b -> truth (a /= 0 && b /= 0))
opcode OP_BOOLOR             = binary (\a b -> truth (a /= 0 || b /= 0))
opcode OP_NUMEQUAL           = binary (btruth (==))
opcode OP_NUMNOTEQUAL        = binary (btruth (/=))
opcode OP_LESSTHAN           = binary (btruth (<))
opcode OP_GREATERTHAN        = binary (btruth (>))
opcode OP_LESSTHANOREQUAL    = binary (btruth (<=))
opcode OP_GREATERTHANOREQUAL = binary (btruth (>=))
opcode OP_MIN                = binary min
opcode OP_MAX                = binary max
opcode OP_WITHIN = arrange 3 (\[x, min, max] -> [truth (min <= x && x < max)])
-}
opcode scriptOp  = terminate (Unimplemented scriptOp)