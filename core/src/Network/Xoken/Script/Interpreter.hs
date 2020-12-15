{-# LANGUAGE LambdaCase #-}

module Network.Xoken.Script.Interpreter where

import           Control.Monad                  ( unless
                                                , when
                                                )
import           Crypto.Hash                    ( RIPEMD160(..)
                                                , SHA1(..)
                                                , SHA256(..)
                                                , hashWith
                                                )
import           Crypto.Secp256k1               ( importPubKey
                                                , importSig
                                                )
import           Data.Bits                      ( complement
                                                , shiftL
                                                , shiftR
                                                , xor
                                                , (.&.)
                                                , (.|.)
                                                )
import           Data.Bits.ByteString           ( )
import qualified Data.ByteArray                as BA
import qualified Data.ByteString               as BS
import           Data.EnumBitSet                ( disjoint
                                                , empty
                                                , fromEnums
                                                , get
                                                , put
                                                )
import           Data.Functor                   ( (<&>) )
import           Data.List                      ( unfoldr )
import qualified Data.Sequence                 as Seq
import qualified Data.Serialize                as S
import           Data.Serialize.Get             ( getWord64le
                                                , runGet
                                                )
import           Data.Word                      ( Word32
                                                , Word64
                                                , Word8
                                                )
import           Network.Xoken.Script.Common
import           Network.Xoken.Script.SigHash
import           Network.Xoken.Script.Interpreter.Commands
import           Network.Xoken.Script.Interpreter.Util

fixed_shiftR :: BS.ByteString -> Int -> BS.ByteString
fixed_shiftR bs 0 = bs
fixed_shiftR bs i
  | i `mod` 8 == 0
  = BS.take (BS.length bs) $ BS.append
    (BS.replicate (i `div` 8) 0)
    (BS.take (BS.length bs - (i `div` 8)) bs)
  | i `mod` 8 /= 0
  = BS.pack
    $  take (BS.length bs)
    $  (replicate (i `div` 8) (0 :: Word8))
    ++ (go (i `mod` 8) 0 $ BS.unpack (BS.take (BS.length bs - (i `div` 8)) bs))
 where
  go _ _  []         = []
  go j w1 (w2 : wst) = (maskR j w1 w2) : go j w2 wst
  maskR j w1 w2 = (shiftL w1 (8 - j)) .|. (shiftR w2 j)
{-# INLINE fixed_shiftR #-}

maxScriptElementSizeBeforeGenesis = 520

sequenceLocktimeDisableFlag = 2 ^ 31

maxPubKeysPerMultiSig :: Integral a => Bool -> Bool -> a
maxPubKeysPerMultiSig genesis consensus
  | not genesis = 20
  | otherwise   = fromIntegral (maxBound :: Word32)

mandatoryScriptFlags :: ScriptFlags
mandatoryScriptFlags = fromEnums
  [ VERIFY_P2SH
  , VERIFY_STRICTENC
  , ENABLE_SIGHASH_FORKID
  , VERIFY_LOW_S
  , VERIFY_NULLFAIL
  ]

standardScriptFlags :: ScriptFlags
standardScriptFlags = fromEnums
  [ VERIFY_DERSIG
  , VERIFY_MINIMALDATA
  , VERIFY_NULLDUMMY
  , VERIFY_DISCOURAGE_UPGRADABLE_NOPS
  , VERIFY_CLEANSTACK
  , VERIFY_CHECKLOCKTIMEVERIFY
  , VERIFY_CHECKSEQUENCEVERIFY
  ]

verifyScript :: Env -> Script -> Script -> Maybe InterpreterError
verifyScript e sigScript pubKeyScript
  | get VERIFY_SIGPUSHONLY fs && not (isPushOnly sigScript) = Just SigPushOnly
  | error_sig /= Nothing                    = error_sig
  | error_pubkey /= Nothing                 = error_pubkey
  | empty_or_0_top (stack env_after_pubkey) = Just EvalFalse
  | not (check_P2SH && isP2SH pubKeyScript) = checkCleanStack env_after_pubkey
  | not (isPushOnly sigScript)              = Just SigPushOnly
  | error_pubkey2 /= Nothing                = error_pubkey2
  | empty_or_0_top (stack env_after_pubkey2) = Just EvalFalse
  | otherwise                               = checkCleanStack env_after_pubkey2
 where
  fs = put VERIFY_STRICTENC (get ENABLE_SIGHASH_FORKID flags) flags
    where flags = script_flags e
  genesis = get UTXO_AFTER_GENESIS fs
  env     = flags_equal fs e
  go env script = interpretWith $ script_equal script env
  (env_after_sig    , error_sig    ) = go env sigScript
  (env_after_pubkey , error_pubkey ) = go env_after_sig pubKeyScript
  (env_after_pubkey2, error_pubkey2) = case Seq.viewr $ stack e' of
    rest Seq.:> x ->
      either (const (e', Just VerifyScriptAssertion)) (go $ stack_equal rest e')
        $ S.decode x
    _ -> (e', Just VerifyScriptAssertion)
    where e' = if check_P2SH then env_after_sig else env
  empty_or_0_top s = case Seq.viewr s of
    _ Seq.:> x -> isZero x
    _          -> True
  check_P2SH = get VERIFY_P2SH fs && not genesis
  checkCleanStack final_env
    | not (get VERIFY_CLEANSTACK fs) = Nothing
    | not (get VERIFY_P2SH fs) = Just VerifyScriptAssertion
    | otherwise = ifso (Just CleanStack) $ length (stack final_env) /= 1

interpretWith :: Env -> (Env, Maybe InterpreterError)
interpretWith env = go (script env) env
 where
  go (op : rest) e
    | signal_disabled = (e, Just DisabledOpcode)
    | execute = next
      (increment_ops op)
      (if op == OP_CODESEPARATOR then e { script = rest } else e)
    | otherwise = case op of
      OP_IF       -> next (add_to_opcount 1 >> push_branch failed_branch) e
      OP_NOTIF    -> next (add_to_opcount 1 >> push_branch failed_branch) e
      OP_VERIF    -> next (increment_ops op) e
      OP_VERNOTIF -> next (increment_ops op) e
      OP_ELSE     -> next (increment_ops op) e
      OP_ENDIF    -> next (increment_ops op) e
      _           -> next (increment_ops OP_NOP) e
   where
    signal_disabled =
      (op `elem` [OP_2MUL, OP_2DIV])
        && (not (get UTXO_AFTER_GENESIS $ script_flags e) || execute)
    execute =
      (failed_branches e == 0)
        && (not (non_top_level_return e) || op == OP_RETURN)
    next cmd e = case interpretCmd (add_to_opcount 1 >> cmd) e of
      (e', OK         ) -> go rest e'
      (e', Error error) -> (e', Just error)
      (e', Return     ) -> (e', Nothing)
    failed_branch = Branch { satisfied = False, is_else_branch = False }
    increment_ops op | isPush op = opcode op
                     | otherwise = add_to_opcount 1 >> opcode op
  go [] e = (e, Nothing)

empty_env :: Script -> BaseSignatureChecker -> Env
empty_env script checker = Env { stack                  = Seq.empty
                               , alt_stack              = Seq.empty
                               , branch_stack           = Seq.empty
                               , failed_branches        = 0
                               , non_top_level_return   = False
                               , script_flags           = empty
                               , base_signature_checker = checker
                               , script                 = scriptOps script
                               , consensus              = True
                               , op_count               = 0
                               }

opcode :: ScriptOp -> Cmd ()
-- Pushing Data
opcode OP_0                  = push BS.empty
opcode (OP_PUSHDATA bs size) = pushdata bs size
opcode OP_1NEGATE            = pushint (-1)
opcode OP_1                  = pushint 1
opcode OP_2                  = pushint 2
opcode OP_3                  = pushint 3
opcode OP_4                  = pushint 4
opcode OP_5                  = pushint 5
opcode OP_6                  = pushint 6
opcode OP_7                  = pushint 7
opcode OP_8                  = pushint 8
opcode OP_9                  = pushint 9
opcode OP_10                 = pushint 10
opcode OP_11                 = pushint 11
opcode OP_12                 = pushint 12
opcode OP_13                 = pushint 13
opcode OP_14                 = pushint 14
opcode OP_15                 = pushint 15
opcode OP_16                 = pushint 16
-- Flow control
opcode OP_NOP                = pure ()
opcode OP_VER                = terminate (Unimplemented OP_VER)
opcode OP_IF                 = ifcmd (not . isZero)
opcode OP_NOTIF              = ifcmd isZero
opcode OP_VERIF              = terminate (Unimplemented OP_VERIF)
opcode OP_VERNOTIF           = terminate (Unimplemented OP_VERNOTIF)
opcode OP_ELSE               = pop_branch >>= \branch ->
  flag UTXO_AFTER_GENESIS >>= \genesis -> do
    when (is_else_branch branch && genesis) (terminate UnbalancedConditional)
    push_branch
      $ Branch { satisfied = not $ satisfied branch, is_else_branch = True }
opcode OP_ENDIF  = pop_branch >> pure ()
opcode OP_VERIFY = pop >>= \x -> when (isZero x) (terminate Verify)
opcode OP_RETURN = flag UTXO_AFTER_GENESIS >>= \genesis -> if genesis
  then stack_size >>= \s -> when (s == 0) success >> set_non_top_level_return
  else terminate OpReturn
-- Stack operations
opcode OP_TOALTSTACK   = pop >>= push_alt
opcode OP_FROMALTSTACK = pop_alt >>= push
opcode OP_2DROP        = pop >> pop >> pure ()
opcode OP_2DUP         = arrangepeek 2 (\[x1, x2] -> [x1, x2])
opcode OP_3DUP         = arrangepeek 3 (\[x1, x2, x3] -> [x1, x2, x3])
opcode OP_2OVER        = arrangepeek 4 (\[x1, x2, x3, x4] -> [x1, x2])
opcode OP_2ROT =
  arrange 6 (\[x1, x2, x3, x4, x5, x6] -> [x3, x4, x5, x6, x1, x2])
opcode OP_2SWAP = arrange 4 (\[x1, x2, x3, x4] -> [x3, x4, x1, x2])
opcode OP_IFDUP = peek >>= \x1 -> unless (isZero x1) (push x1)
opcode OP_DEPTH = stack_size >>= push . int2BS
opcode OP_DROP  = pop >> pure ()
opcode OP_DUP   = peek >>= push
opcode OP_NIP   = arrange 2 (\[x1, x2] -> [x2])
opcode OP_OVER  = arrangepeek 2 (\[x1, x2] -> [x1])
opcode OP_PICK  = pop >>= num' >>= bn2u32 >>= peek_nth >>= push
opcode OP_ROLL  = pop >>= num' >>= bn2u32 >>= pop_nth >>= push
opcode OP_ROT   = arrange 3 (\[x1, x2, x3] -> [x2, x3, x1])
opcode OP_SWAP  = arrange 2 (\[x1, x2] -> [x2, x1])
opcode OP_TUCK  = arrange 2 (\[x1, x2] -> [x2, x1, x2])
-- Data manipulation
opcode OP_CAT   = pop_n 2 >>= \[x1, x2] ->
  isOverMaxElemSize (BS.length x1 + BS.length x2) >>= \case
    True -> terminate PushSize
    _    -> push (BS.append x1 x2)
opcode OP_SPLIT = pop_n 2 >>= \[x1, x2] -> do
  n <- num' x2
  if n < 0 || n > fromIntegral (BS.length x1)
    then terminate InvalidSplitRange
    else let (y1, y2) = BS.splitAt (fromIntegral n) x1 in push_n [y1, y2]
opcode OP_NUM2BIN = pop_n 2 >>= arith >>= \[x1, x2] ->
  isOverMaxElemSize x2 >>= \tooBig ->
    if x2 < 0 || x2 > fromIntegral (maxBound :: Int) || tooBig
      then terminate PushSize
      else maybe (terminate ImpossibleEncoding)
                 push
                 (num2binpad x1 (fromIntegral x2))
opcode OP_BIN2NUM = pop >>= \x -> do
  maxNumLength <- apply_genesis_and_consensus maxScriptNumLength
  let bs = bin (bin2num x)
  if isMinimallyEncoded bs maxNumLength
    then push bs
    else terminate InvalidNumberRange
opcode OP_SIZE   = peek >>= pushint . BS.length
-- Bitwise logic
opcode OP_INVERT = unary (BS.map complement)
opcode OP_AND    = binarybitwise (.&.)
opcode OP_OR     = binarybitwise (.|.)
opcode OP_XOR    = binarybitwise xor
opcode OP_EQUAL  = pop_n 2 >>= push . bin . \[x1, x2] -> truth $ x1 == x2
opcode OP_EQUALVERIFY =
  pop_n 2 >>= \[x1, x2] -> when (x1 /= x2) (terminate EqualVerify)
-- Arithmetic
opcode OP_1ADD      = unaryarith succ
opcode OP_1SUB      = unaryarith pred
opcode OP_2MUL      = unaryarith (`shiftL` 1)
opcode OP_2DIV      = unaryarith (`shiftR` 1)
opcode OP_NEGATE    = unaryarith negate
opcode OP_ABS       = unaryarith abs
opcode OP_NOT       = unaryarith (truth . (== 0))
opcode OP_0NOTEQUAL = unaryarith (truth . (/= 0))
opcode OP_ADD       = binaryarith (+)
opcode OP_SUB       = binaryarith (-)
opcode OP_MUL       = binaryarith (*)
opcode OP_DIV       = pop_n 2 >>= arith >>= \[x1, x2] ->
  if x2 == 0 then terminate DivByZero else push $ bin (x1 `div` x2)
opcode OP_MOD = pop_n 2 >>= arith >>= \[x1, x2] ->
  if x2 == 0 then terminate ModByZero else push $ bin (x1 `mod` x2)
opcode OP_LSHIFT         = shift shiftL
opcode OP_RSHIFT         = shift fixed_shiftR
opcode OP_BOOLAND        = binaryarith (\a b -> truth (a /= 0 && b /= 0))
opcode OP_BOOLOR         = binaryarith (\a b -> truth (a /= 0 || b /= 0))
opcode OP_NUMEQUAL       = binaryarith (btruth (==))
opcode OP_NUMEQUALVERIFY = pop_n 2 >>= arith >>= \[x1, x2] ->
  when (x1 /= x2) (terminate NumEqualVerify)
opcode OP_NUMNOTEQUAL        = binaryarith (btruth (/=))
opcode OP_LESSTHAN           = binaryarith (btruth (<))
opcode OP_GREATERTHAN        = binaryarith (btruth (>))
opcode OP_LESSTHANOREQUAL    = binaryarith (btruth (<=))
opcode OP_GREATERTHANOREQUAL = binaryarith (btruth (>=))
opcode OP_MIN                = binaryarith min
opcode OP_MAX                = binaryarith max
opcode OP_WITHIN = pop_n 3 >>= arith >>= push . bin . \[x, min, max] ->
  truth $ min <= x && x < max
-- Crypto
opcode OP_RIPEMD160 = unary (BA.convert . hashWith RIPEMD160)
opcode OP_SHA1      = unary (BA.convert . hashWith SHA1)
opcode OP_SHA256    = unary (BA.convert . hashWith SHA256)
opcode OP_HASH160   = unary (BA.convert . hashWith RIPEMD160 . hashWith SHA256)
opcode OP_HASH256   = unary (BA.convert . hashWith SHA256 . hashWith SHA256)
opcode OP_CODESEPARATOR =
  terminate (HigherLevelImplementation OP_CODESEPARATOR)
opcode OP_CHECKSIG            = checksig pushbool
opcode OP_CHECKSIGVERIFY      = checksig (verify CheckSigVerify)
opcode OP_CHECKMULTISIG       = checkmultisig pushbool
opcode OP_CHECKMULTISIGVERIFY = checkmultisig (verify CheckMultiSigVerify)
-- Pseudo-words
opcode OP_PUBKEYHASH          = terminate (Unimplemented OP_PUBKEYHASH)
opcode OP_PUBKEY              = terminate (Unimplemented OP_PUBKEY)
opcode (OP_INVALIDOPCODE n)   = terminate (BadOpcode (OP_INVALIDOPCODE n))
-- Reserved words
opcode OP_RESERVED            = terminate (BadOpcode OP_RESERVED)
opcode OP_RESERVED1           = terminate (BadOpcode OP_RESERVED1)
opcode OP_RESERVED2           = terminate (BadOpcode OP_RESERVED2)
opcode OP_NOP1                = nop
opcode OP_NOP2 = maybenop VERIFY_CHECKLOCKTIMEVERIFY checkLockTime (const True)
opcode OP_NOP3 = maybenop VERIFY_CHECKSEQUENCEVERIFY checkSequence
  $ \n -> n .&. sequenceLocktimeDisableFlag == 0
opcode OP_NOP4  = nop
opcode OP_NOP5  = nop
opcode OP_NOP6  = nop
opcode OP_NOP7  = nop
opcode OP_NOP8  = nop
opcode OP_NOP9  = nop
opcode OP_NOP10 = nop

pushint :: Int -> Cmd ()
pushint = push . int2BS

pushdata :: BS.ByteString -> PushDataType -> Cmd ()
pushdata bs size = flag VERIFY_MINIMALDATA >>= \case
  True -> maybe
    (terminate MinimalData)
    (\optimal -> if size == optimal then go else terminate MinimalData)
    (pushDataType (BS.length bs))
  _ -> go
 where
  go = isOverMaxElemSize (BS.length bs) >>= \case
    True -> terminate PushSize
    _    -> push bs

isOverMaxElemSize :: Integral a => a -> Cmd Bool
isOverMaxElemSize n = flag UTXO_AFTER_GENESIS <&> isOver . not
  where isOver = (&& n > fromIntegral maxScriptElementSizeBeforeGenesis)

arrange :: Int -> ([Elem] -> [Elem]) -> Cmd ()
arrange n f = pop_n n >>= push_n . f

arrangepeek :: Int -> ([Elem] -> [Elem]) -> Cmd ()
arrangepeek n f = peek_n n >>= push_n . f

unary :: (Elem -> Elem) -> Cmd ()
unary f = pop >>= push . f

unaryarith :: (BN -> BN) -> Cmd ()
unaryarith f = pop >>= num' >>= push . bin . f

binaryarith :: (BN -> BN -> BN) -> Cmd ()
binaryarith f = pop_n 2 >>= arith >>= \[x1, x2] -> push $ bin $ f x1 x2

binarybitwise :: (Word8 -> Word8 -> Word8) -> Cmd ()
binarybitwise f = pop_n 2 >>= \[x1, x2] -> if BS.length x1 == BS.length x2
  then push $ BS.pack $ BS.zipWith f x1 x2
  else terminate InvalidOperandSize

btruth :: (a1 -> a2 -> Bool) -> a1 -> a2 -> BN
btruth = ((truth .) .)

bin :: BN -> Elem
bin = num2bin

shift :: (Elem -> Int -> Elem) -> Cmd ()
shift f = pop_n 2 >>= \[x1, x2] -> do
  let size = BS.length x1
  n <- num' x2
  if n < 0
    then terminate InvalidNumberRange
    else push
      $ if n >= fromIntegral size * 8 then BS.replicate size 0 else go x1 n
 where
  go x n | n <= max  = f x $ fromIntegral n
         | otherwise = go (f x maxInt) (n - max)
  maxInt = maxBound :: Int
  max    = fromIntegral maxInt

ifcmd :: (Elem -> Bool) -> Cmd ()
ifcmd is_satisfied = stack_size >>= \case
  0 -> terminate UnbalancedConditional
  _ -> do
    x  <- pop
    fs <- flags
    let n = BS.length x
    when
      (get VERIFY_MINIMALIF fs && (n > 1 || (n == 1 && x /= BS.singleton 1)))
      (terminate MinimalIf)
    push_branch (Branch { satisfied = is_satisfied x, is_else_branch = False })

nop :: Cmd ()
nop = flags >>= \fs -> when (get VERIFY_DISCOURAGE_UPGRADABLE_NOPS fs)
                            (terminate DiscourageUpgradableNOPs)

maybenop
  :: ScriptFlag
  -> (BaseSignatureChecker -> BN -> Bool)
  -> (BN -> Bool)
  -> Cmd ()
maybenop flag check enabled = flags >>= \fs ->
  if not (get flag fs) || get UTXO_AFTER_GENESIS fs
    then nop
    else pop >>= limited_num 5 >>= \n -> checker >>= \c -> do
      when (n < 0)                  (terminate NegativeLocktime)
      when (enabled n && check c n) (terminate UnsatisfiedLockTime)

checksig :: (Bool -> Cmd ()) -> Cmd ()
checksig finalize = pop_n 2 >>= \[sigBS, pubKeyBS] -> do
  fs     <- flags
  script <- script_end
  c      <- checker
  checkSignatureEncoding fs sigBS
  checkPubKeyEncoding fs pubKeyBS
  let
    forkid  = get ENABLE_SIGHASH_FORKID fs
    sighash = sigHash sigBS
    clean   = cleanupScriptCode script sigBS sighash forkid
    check sig sighash pubKey =
      checkSig c sig sighash pubKey (Script clean) forkid
    verifynull = get VERIFY_NULLFAIL fs
  singlesig finalize check sigBS pubKeyBS verifynull

singlesig finalize check sigBS pubKeyBS verifynull =
  case (importSig (BS.init sigBS), importPubKey pubKeyBS) of
    (Just sig, Just pubKey) -> do
      let success = check sig (sigHash sigBS) pubKey
      when (not success && verifynull && BS.length sigBS > 0)
           (terminate SigNullFail)
      finalize success
    _ -> terminate InvalidSigOrPubKey

checkmultisig :: (Bool -> Cmd ()) -> Cmd ()
checkmultisig finalize = do
  fs               <- flags
  impl             <- checker
  script           <- script_end
  nKeysBN          <- pop
  nKeysCountSigned <- fromIntegral <$> num' nKeysBN
  maxPubKeys       <- apply_genesis_and_consensus maxPubKeysPerMultiSig
  let nKeysCount = fromIntegral nKeysCountSigned :: Word64
  when (nKeysCountSigned < 0 || nKeysCount > maxPubKeys) (terminate PubKeyCount)
  add_to_opcount nKeysCount
  keys             <- pop_n nKeysCountSigned
  nSigsBN          <- pop
  nSigsCountSigned <- fromIntegral <$> num' nSigsBN
  let nSigsCount = fromIntegral nSigsCountSigned :: Word64
  when (nSigsCountSigned < 0 || nSigsCount > nKeysCount) (terminate SigCount)
  sigs <- pop_n nSigsCountSigned
  mapM_ (checkSignatureEncoding fs) sigs
  mapM_ (checkPubKeyEncoding fs)    keys
  let forkid = get ENABLE_SIGHASH_FORKID fs
      clean sigBS ops = cleanupScriptCode ops sigBS (sigHash sigBS) forkid
      script'    = foldr clean script sigs
      verifynull = get VERIFY_NULLFAIL fs
      check sig sighash pubKey =
        checkSig impl sig sighash pubKey (Script script') forkid
  x <- pop -- bug extra value
  when (get VERIFY_NULLDUMMY fs && BS.length x > 0) (terminate SigNullDummy)
  multisig finalize check sigs keys verifynull

multisig finalize check sigs keys verifynull = case (sigs, keys) of
  ([], []) -> finalize True
  (_ , []) -> finalize False
  (sigBS : sigs', keyBS : keys') ->
    singlesig (continuation sigs' keys') check sigBS keyBS verifynull
 where
  continuation sigs' keys' success =
    multisig finalize check (if success then sigs' else sigs) keys' verifynull

verify :: InterpreterError -> Bool -> Cmd ()
verify error x = unless x (terminate error)

pushbool :: Bool -> Cmd ()
pushbool = push . bin . truth

checkPubKeyEncoding :: ScriptFlags -> BS.ByteString -> Cmd ()
checkPubKeyEncoding fs pubKeyBS = do
  when (get VERIFY_STRICTENC fs && not isCompressedOrUncompressedPubKey)
       (terminate PubKeyType)
  when (get VERIFY_COMPRESSED_PUBKEYTYPE fs && not isCompressedPubKey)
       (terminate NonCompressedPubKey)
 where
  isCompressedOrUncompressedPubKey | size < 33                = False
                                   | head == 0x04             = size == 65
                                   | head `elem` [0x02, 0x03] = size == 33
                                   | otherwise                = False
  isCompressedPubKey = size == 33 && head `elem` [0x02, 0x03]
  size               = BS.length pubKeyBS
  head               = BS.unpack pubKeyBS !! 0

checkSignatureEncoding :: ScriptFlags -> BS.ByteString -> Cmd ()
checkSignatureEncoding fs sigBS
  | BS.null sigBS = pure ()
  | not (disjoint fs sigfs || isValidSignatureEncoding sigBS) = terminate SigDER
  | otherwise = do
    when (get VERIFY_LOW_S fs) (checkLowDERSignature sigBS)
    when (get VERIFY_STRICTENC fs) $ do
      when (isSigHashUnknown sh)      (terminate SigHashType)
      when (not forkid && usesForkId) (terminate IllegalForkId)
      when (forkid && not usesForkId) (terminate MustUseForkId)
 where
  sigfs      = fromEnums [VERIFY_DERSIG, VERIFY_LOW_S, VERIFY_STRICTENC]
  sh         = sigHash sigBS
  usesForkId = hasForkIdFlag sh
  forkid     = get ENABLE_SIGHASH_FORKID fs

isValidSignatureEncoding :: BS.ByteString -> Bool
isValidSignatureEncoding sigBS = and
  [ size >= 9 && size <= 73
  , code sig_elem == compound_code
  , length_covers_entire_signature
  , s_length_still_inside_signature
  , sig_len_matches_element_len_sum
  , test_number r_elem
  , test_number s_elem
  ]
 where
  size          = BS.length sigBS
  xs            = BS.unpack sigBS
  x             = fromIntegral . (xs !!)
  compound_code = 0x30
  int_code      = 0x02
  negative byte = byte .&. 0x80 /= 0
  code pos = x pos
  len pos = x (pos + 1)
  sig_elem                        = 0
  r_elem                          = 2
  s_elem                          = r_elem + len r_elem + 2
  length_covers_entire_signature  = len sig_elem == size - 3
  s_length_still_inside_signature = 5 + len r_elem < size
  sig_len_matches_element_len_sum = len r_elem + len s_elem + 7 == size
  test_number elem = and
    [ code elem == int_code
    , len elem /= 0
    , not $ negative $ x (elem + 2)
    , null_start_not_allowed_unless_negative
    ]
   where
    null_start_not_allowed_unless_negative =
      len elem <= 1 || x (elem + 2) /= 0 || negative (x $ elem + 3)

checkLowDERSignature :: BS.ByteString -> Cmd ()
checkLowDERSignature sigBS = do
  unless (isValidSignatureEncoding sigBS) (terminate SigDER)
  unless (isLowS sigBS)                   (terminate SigHighS)

isLowS :: BS.ByteString -> Bool
isLowS sigBS = case ecdsa_signature_parse_der_lax (BS.unpack sigBS) of
  Just (r, s, _) -> not $ highS $ BS.pack s
  _              -> False
 where
  highS s = case unfoldr readWord64 s of
    [x0, x1, x2, x3] -> yes
     where
      no0  = x3 < d
      yes0 = x3 > d
      no   = no0 || ((x2 < c || x1 < b) && not yes0)
      yes  = yes0 || ((x1 > b || x0 > a) && not no)
    _ -> False
  a = 0xDFE92F46681B20A0
  b = 0x5D576E7357A4501D
  c = 0xFFFFFFFFFFFFFFFF
  d = 0x7FFFFFFFFFFFFFFF
  readWord64 bs = case runGet getWord64le bs1 of
    Right x -> Just (x, bs2)
    _       -> Nothing
    where (bs1, bs2) = BS.splitAt 8 bs

ecdsa_signature_parse_der_lax :: [Word8] -> Maybe ([Word8], [Word8], [Word8])
ecdsa_signature_parse_der_lax bytes = case check_type compound_code bytes of
  Just (lenbyte : rest) -> parse_r_and_s $ if negative lenbyte
    then drop (fromIntegral $ lenbyte - 0x80) rest
    else rest
  _ -> Nothing
 where
  compound_code = 0x30
  int_code      = 0x02
  negative byte = byte .&. 0x80 /= 0
  check_type code (x : rest) = if x == code then Just rest else Nothing
  check_type _    _          = Nothing
  parse_r_and_s bytes = do
    (r, after_r) <- parse_int bytes
    (s, after_s) <- parse_int after_r
    pure (r, s, after_s)
  parse_int bytes = case check_type int_code bytes of
    Just (lenbyte : rest) -> do
      (len, after_len) <- if negative lenbyte
        then do
          let (lenbyte', after_zeros) = drop_zeros (lenbyte - 0x80) rest
          when (lenbyte' >= 8) Nothing
          parse_len 0 lenbyte' after_zeros
        else Just (fromIntegral lenbyte, rest)
      when (len >= 8) Nothing
      let (elem, after_elem) = splitAt len after_len
          compact            = dropWhile (== 0) elem
      when (length compact > 32) Nothing
      Just (replicate (32 - length compact) 0 ++ compact, after_elem)
    _ -> Nothing
  drop_zeros 0 bytes      = (0, bytes)
  drop_zeros n (0 : rest) = drop_zeros (n - 1) rest
  drop_zeros n bytes      = (n, bytes)
  parse_len out 0 bytes = Just (out, bytes)
  parse_len out n (x : rest) =
    parse_len (out `shiftL` 8 + fromIntegral x) (n - 1) rest
  parse_len out _ _ = Nothing
