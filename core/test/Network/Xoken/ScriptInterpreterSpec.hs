module Network.Xoken.ScriptInterpreterSpec
  ( spec
  )
where

import qualified Data.ByteString               as BS
import qualified Data.Sequence                 as Seq
import           Test.Hspec
import           Network.Xoken.Script.Common
import           Network.Xoken.Script.Interpreter
import           Network.Xoken.Script.Interpreter.Commands
import           Network.Xoken.Script.Interpreter.OpenSSL_BN

spec :: Spec
spec = do
  describe "interpret whole script" $ do
    it "returns [] given []" $ test [] []
    it "returns [1] given [OP_1]" $ test [OP_1] [1]
    it "returns [1, 2] given [OP_1, OP_2]" $ test [OP_1, OP_2] [1, 2]
    it "returns [] given [OP_1, OP_DROP] " $ test [OP_1, OP_DROP] []
    it "returns [1, 1] given [OP_1, OP_DUP]" $ test [OP_1, OP_DUP] [1, 1]
    it "returns [2] given [OP_1, OP_2, OP_NIP]" $ test [OP_1, OP_2, OP_NIP] [2]
    it "returns [1, 2, 1] given [OP_1, OP_2, OP_OVER]"
      $ test [OP_1, OP_2, OP_OVER] [1, 2, 1]
    it "returns [1, 1] given [OP_1, OP_0, OP_PICK]"
      $ test [OP_1, OP_0, OP_PICK] [1, 1]
    it "returns [1, 2, 1] given [OP_1, OP_2, OP_1, OP_PICK]"
      $ test [OP_1, OP_2, OP_1, OP_PICK] [1, 2, 1]
    it "returns [1, 1] given [OP_1, OP_0, OP_ROLL]"
      $ test [OP_1, OP_0, OP_ROLL] [1]
    it "returns [1, 2, 1] given [OP_1, OP_2, OP_1, OP_ROLL]"
      $ test [OP_1, OP_2, OP_1, OP_ROLL] [2, 1]
    it "returns [1] given [OP_1, OP_TOALTSTACK, OP_FROMALTSTACK]"
      $ test [OP_1, OP_TOALTSTACK, OP_FROMALTSTACK] [1]
    it "returns [2, 1] given [OP_1, OP_TOALTSTACK, OP_2, OP_FROMALTSTACK]"
      $ test [OP_1, OP_TOALTSTACK, OP_2, OP_FROMALTSTACK] [2, 1]
    {-
    it "returns [3] given [OP_1, OP_2, OP_ADD]" $ test [OP_1, OP_2, OP_ADD] [3]
    it "returns [-1] given [OP_3, OP_4, OP_SUB]"
      $ test [OP_3, OP_4, OP_SUB] [-1]
    it "returns [0] given [OP_1, OP_2, OP_3, OP_WITHIN]"
      $ test [OP_1, OP_2, OP_3, OP_WITHIN] [0]
    it "returns [1] given [OP_2, OP_1, OP_3, OP_WITHIN]"
      $ test [OP_2, OP_1, OP_3, OP_WITHIN] [1]
    it "returns [16] given [OP_1, OP_4, OP_LSHIFT]"
      $ test [OP_1, OP_4, OP_LSHIFT] [16]
    it "returns [8] given [OP_16, OP_2DIV]" $ test [OP_16, OP_2DIV] [8]
    -}
  describe "interpret failure" $ do
    it "returns StackUnderflow given [OP_DROP]"
      $          interpret (Script [OP_DROP])
      `shouldBe` (empty_env, Just StackUnderflow)
    it "returns NoDecoding given [OP_PUSHDATA BS.empty OPDATA1]"
      $          interpret (Script [OP_PUSHDATA BS.empty OPDATA1])
      `shouldBe` (empty_env, Just $ NoDecoding 1 BS.empty)
    it "returns NoDecoding given [OP_PUSHDATA BS.empty OPDATA2]"
      $          interpret (Script [OP_PUSHDATA BS.empty OPDATA2])
      `shouldBe` (empty_env, Just $ NoDecoding 2 BS.empty)
    it "returns NoDecoding given [OP_PUSHDATA BS.empty OPDATA4]"
      $          interpret (Script [OP_PUSHDATA BS.empty OPDATA4])
      `shouldBe` (empty_env, Just $ NoDecoding 4 BS.empty)
    it "returns NotEnoughBytes given [OP_PUSHDATA (BS.pack [2, 0]) OPDATA1]"
      $          interpret (Script [OP_PUSHDATA (BS.pack [2, 0]) OPDATA1])
      `shouldBe` (empty_env, Just $ NotEnoughBytes { expected = 2, actual = 1 })
    unbalancedConditional [OP_IF]
    unbalancedConditional [OP_0, OP_IF, OP_ELSE, OP_ELSE, OP_ENDIF]
    unbalancedConditional [OP_ELSE]
    unbalancedConditional [OP_ENDIF]
    it "returns InvalidAltstackOperation given [OP_FROMALTSTACK]"
      $          interpret (Script [OP_FROMALTSTACK])
      `shouldBe` (empty_env, Just InvalidAltstackOperation)
    {-
    it
        "returns TooMuchToLShift given\
        \[ OP_1\
        \, OP_PUSHDATA (S.encode $ succ (fromIntegral (maxBound :: Int) :: Integer)) OPCODE\
        \, OP_LSHIFT\
        \]"
      $          interpret
                   (Script
                     [ OP_1
                     , OP_PUSHDATA
                       (S.encode $ succ (fromIntegral (maxBound :: Int) :: Integer))
                       OPCODE
                     , OP_LSHIFT
                     ]
                   )
      `shouldBe` (Seq.empty, Just $ TooMuchToLShift (2 ^ 63))
    -}
  describe "interpret control flow" $ do
    it "returns [2] given [OP_0, OP_IF, OP_1, OP_ELSE, OP_2, OP_ENDIF]"
      $          interpret (Script [OP_0, OP_IF, OP_1, OP_ELSE, OP_2, OP_ENDIF])
      `shouldBe` (empty_env { stack = Seq.singleton $ int2bin $ 2 }, Nothing)
    it "returns [1] given [OP_1, OP_IF, OP_1, OP_ELSE, OP_2, OP_ENDIF]"
      $          interpret (Script [OP_1, OP_IF, OP_1, OP_ELSE, OP_2, OP_ENDIF])
      `shouldBe` (empty_env { stack = Seq.singleton $ int2bin $ 1 }, Nothing)

test :: [ScriptOp] -> [Int] -> Expectation
test ops expected_elems =
  interpret (Script ops)
    `shouldBe` ( empty_env { stack = Seq.fromList $ int2bin <$> expected_elems }
               , Nothing
               )

unbalancedConditional :: [ScriptOp] -> SpecWith (Arg Expectation)
unbalancedConditional ops =
  it ("returns UnbalancedConditional given " ++ show ops)
    $          interpret (Script ops)
    `shouldBe` (empty_env, Just UnbalancedConditional)
