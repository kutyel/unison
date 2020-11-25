{-# language RankNTypes #-}
{-# language ViewPatterns #-}
{-# language PatternGuards #-}
{-# language PatternSynonyms #-}
{-# language TypeApplications #-}
{-# language OverloadedStrings #-}
{-# language ScopedTypeVariables #-}
{-# language FunctionalDependencies #-}

module Unison.Runtime.Builtin
  ( builtinLookup
  , builtinTermNumbering
  , builtinTypeNumbering
  , builtinTermBackref
  , builtinTypeBackref
  , builtinForeigns
  , numberedTermLookup
  ) where

import Control.Exception (IOException, try)
import Control.Monad.State.Strict (State, modify, execState)

import Unison.ABT.Normalized hiding (TTm)
import Unison.Reference
import Unison.Runtime.ANF as ANF
import Unison.Runtime.ANF.Serialize as ANF
import Unison.Referent (pattern Ref)
import Unison.Var
import Unison.Symbol
import Unison.Runtime.Stack (Closure)
import Unison.Runtime.Foreign (Foreign(Wrap))
import Unison.Runtime.Foreign.Function
import Unison.Runtime.IOSource
import Unison.Runtime.Foreign (HashAlgorithm(..))

import qualified Unison.Type as Ty
import qualified Unison.Builtin as Ty (builtinTypes)
import qualified Unison.Builtin.Decls as Ty
import qualified Crypto.Hash as Hash
import qualified Crypto.MAC.HMAC as HMAC

import Unison.Util.EnumContainers as EC

import Data.ByteString (hGet, hPut)
import Data.Either.Combinators (mapLeft)
import Data.Text as Text (Text, pack, unpack)
import Data.Text.Encoding (encodeUtf8, decodeUtf8')
import Data.Word (Word64, Word16)
import qualified Data.ByteArray as BA

import Data.Set (Set, insert)

import Data.Map (Map)
import qualified Data.Map as Map

import qualified Unison.Util.Bytes as Bytes
import Network.Socket as SYS
  ( accept
  )
import Network.Simple.TCP as SYS
  ( HostPreference(..)
  , bindSock
  , connectSock
  , listenSock
  , closeSock
  , send
  , recv
  )
import System.IO as SYS
  ( openFile
  , hClose
  , hGetBuffering
  , hSetBuffering
  , hIsEOF
  , hIsOpen
  , hIsSeekable
  , hSeek
  , hTell
  , stdin, stdout, stderr
  )
import Data.Text.IO as SYS (hGetLine)
import Control.Concurrent as SYS
  ( threadDelay
  , killThread
  )
import Control.Concurrent.MVar as SYS
import Data.Time.Clock.POSIX as SYS
  ( getPOSIXTime
  , utcTimeToPOSIXSeconds
  )
import System.Directory as SYS
  ( getCurrentDirectory
  , setCurrentDirectory
  , getTemporaryDirectory
  -- , getDirectoryContents
  , doesPathExist
  -- , doesDirectoryExist
  , renameDirectory
  , removeFile
  , renameFile
  , createDirectoryIfMissing
  , removeDirectoryRecursive
  , getModificationTime
  , getFileSize
  )

freshes :: Var v => Int -> [v]
freshes = freshes' mempty

freshes' :: Var v => Set v -> Int -> [v]
freshes' avoid0 = go avoid0 []
  where
  go _     vs 0 = vs
  go avoid vs n
    = let v = freshIn avoid $ typed ANFBlank
       in go (insert v avoid) (v:vs) (n-1)

fls, tru :: Var v => ANormal v
fls = TCon Ty.booleanRef 0 []
tru = TCon Ty.booleanRef 1 []

boolift :: Var v => v -> ANormal v
boolift v
  = TMatch v $ MatchIntegral (mapFromList [(0,fls), (1,tru)]) Nothing

notlift :: Var v => v -> ANormal v
notlift v
  = TMatch v $ MatchIntegral (mapFromList [(1,fls), (0,tru)]) Nothing

unbox :: Var v => v -> Reference -> v -> ANormal v -> ANormal v
unbox v0 r v b
  = TMatch v0
  $ MatchData r (mapSingleton 0 $ ([UN], TAbs v b)) Nothing

unenum :: Var v => Int -> v -> Reference -> v -> ANormal v -> ANormal v
unenum n v0 r v nx
  = TMatch v0 $ MatchData r cases Nothing
  where
  mkCase i = (toEnum i, ([], TLetD v UN (TLit . I $ fromIntegral i) nx))
  cases = mapFromList . fmap mkCase $ [0..n-1]

unop0 :: Var v => Int -> ([v] -> ANormal v) -> SuperNormal v
unop0 n f
  = Lambda [BX]
  . TAbss [x0]
  $ f xs
  where
  xs@(x0:_) = freshes (1+n)

binop0 :: Var v => Int -> ([v] -> ANormal v) -> SuperNormal v
binop0 n f
  = Lambda [BX,BX]
  . TAbss [x0,y0]
  $ f xs
  where
  xs@(x0:y0:_) = freshes (2+n)

unop :: Var v => POp -> Reference -> SuperNormal v
unop pop rf = unop' pop rf rf

unop' :: Var v => POp -> Reference -> Reference -> SuperNormal v
unop' pop rfi rfo
  = unop0 2 $ \[x0,x,r]
 -> unbox x0 rfi x
  . TLetD r UN (TPrm pop [x])
  $ TCon rfo 0 [r]

binop :: Var v => POp -> Reference -> SuperNormal v
binop pop rf = binop' pop rf rf rf

binop'
  :: Var v
  => POp
  -> Reference -> Reference -> Reference
  -> SuperNormal v
binop' pop rfx rfy rfr
  = binop0 3 $ \[x0,y0,x,y,r]
 -> unbox x0 rfx x
  . unbox y0 rfy y
  . TLetD r UN (TPrm pop [x,y])
  $ TCon rfr 0 [r]

cmpop :: Var v => POp -> Reference -> SuperNormal v
cmpop pop rf
  = binop0 3 $ \[x0,y0,x,y,b]
 -> unbox x0 rf x
  . unbox y0 rf y
  . TLetD b UN (TPrm pop [x,y])
  $ boolift b

cmpopb :: Var v => POp -> Reference -> SuperNormal v
cmpopb pop rf
  = binop0 3 $ \[x0,y0,x,y,b]
 -> unbox x0 rf x
  . unbox y0 rf y
  . TLetD b UN (TPrm pop [y,x])
  $ boolift b

cmpopn :: Var v => POp -> Reference -> SuperNormal v
cmpopn pop rf
  = binop0 3 $ \[x0,y0,x,y,b]
 -> unbox x0 rf x
  . unbox y0 rf y
  . TLetD b UN (TPrm pop [x,y])
  $ notlift b

cmpopbn :: Var v => POp -> Reference -> SuperNormal v
cmpopbn pop rf
  = binop0 3 $ \[x0,y0,x,y,b]
 -> unbox x0 rf x
  . unbox y0 rf y
  . TLetD b UN (TPrm pop [y,x])
  $ notlift b

addi,subi,muli,divi,modi,shli,shri,powi :: Var v => SuperNormal v
addi = binop ADDI Ty.intRef
subi = binop SUBI Ty.intRef
muli = binop MULI Ty.intRef
divi = binop DIVI Ty.intRef
modi = binop MODI Ty.intRef
shli = binop' SHLI Ty.intRef Ty.natRef Ty.intRef
shri = binop' SHRI Ty.intRef Ty.natRef Ty.intRef
powi = binop' POWI Ty.intRef Ty.natRef Ty.intRef

addn,subn,muln,divn,modn,shln,shrn,pown :: Var v => SuperNormal v
addn = binop ADDN Ty.natRef
subn = binop' SUBN Ty.natRef Ty.natRef Ty.intRef
muln = binop MULN Ty.natRef
divn = binop DIVN Ty.natRef
modn = binop MODN Ty.natRef
shln = binop SHLN Ty.natRef
shrn = binop SHRN Ty.natRef
pown = binop POWN Ty.natRef

eqi, eqn, lti, ltn, lei, len :: Var v => SuperNormal v
eqi = cmpop EQLI Ty.intRef
lti = cmpopbn LEQI Ty.intRef
lei = cmpop LEQI Ty.intRef
eqn = cmpop EQLN Ty.natRef
ltn = cmpopbn LEQN Ty.natRef
len = cmpop LEQN Ty.natRef

gti, gtn, gei, gen :: Var v => SuperNormal v
gti = cmpopn LEQI Ty.intRef
gei = cmpopb LEQI Ty.intRef
gtn = cmpopn LEQN Ty.intRef
gen = cmpopb LEQN Ty.intRef

inci, incn :: Var v => SuperNormal v
inci = unop INCI Ty.intRef
incn = unop INCN Ty.natRef

sgni, negi :: Var v => SuperNormal v
sgni = unop SGNI Ty.intRef
negi = unop NEGI Ty.intRef

lzeron, tzeron, lzeroi, tzeroi, popn, popi :: Var v => SuperNormal v
lzeron = unop LZRO Ty.natRef
tzeron = unop TZRO Ty.natRef
popn = unop POPC Ty.natRef
popi = unop' POPC Ty.intRef Ty.natRef
lzeroi = unop' LZRO Ty.intRef Ty.natRef
tzeroi = unop' TZRO Ty.intRef Ty.natRef


andn, orn, xorn, compln, andi, ori, xori, compli :: Var v => SuperNormal v
andn = binop ANDN Ty.natRef
orn = binop IORN Ty.natRef
xorn = binop XORN Ty.natRef
compln = unop COMN Ty.natRef
andi = binop ANDN Ty.intRef
ori = binop IORN Ty.intRef
xori = binop XORN Ty.intRef
compli = unop COMN Ty.intRef

addf, subf, mulf, divf, powf, sqrtf, logf, logbf
  :: Var v => SuperNormal v
addf = binop ADDF Ty.floatRef
subf = binop SUBF Ty.floatRef
mulf = binop MULF Ty.floatRef
divf = binop DIVF Ty.floatRef
powf = binop POWF Ty.floatRef
sqrtf = unop SQRT Ty.floatRef
logf = unop LOGF Ty.floatRef
logbf = binop LOGB Ty.floatRef

expf, absf :: Var v => SuperNormal v
expf = unop EXPF Ty.floatRef
absf = unop ABSF Ty.floatRef

cosf, sinf, tanf, acosf, asinf, atanf :: Var v => SuperNormal v
cosf = unop COSF Ty.floatRef
sinf = unop SINF Ty.floatRef
tanf = unop TANF Ty.floatRef
acosf = unop ACOS Ty.floatRef
asinf = unop ASIN Ty.floatRef
atanf = unop ATAN Ty.floatRef

coshf, sinhf, tanhf, acoshf, asinhf, atanhf, atan2f
  :: Var v => SuperNormal v
coshf = unop COSH Ty.floatRef
sinhf = unop SINH Ty.floatRef
tanhf = unop TANH Ty.floatRef
acoshf = unop ACSH Ty.floatRef
asinhf = unop ASNH Ty.floatRef
atanhf = unop ATNH Ty.floatRef
atan2f = binop ATN2 Ty.floatRef

ltf, gtf, lef, gef, eqf, neqf :: Var v => SuperNormal v
ltf = cmpopbn LEQF Ty.floatRef
gtf = cmpopn LEQF Ty.floatRef
lef = cmpop LEQF Ty.floatRef
gef = cmpopb LEQF Ty.floatRef
eqf = cmpop EQLF Ty.floatRef
neqf = cmpopn EQLF Ty.floatRef

minf, maxf :: Var v => SuperNormal v
minf = binop MINF Ty.floatRef
maxf = binop MAXF Ty.floatRef

ceilf, floorf, truncf, roundf, i2f, n2f :: Var v => SuperNormal v
ceilf = unop' CEIL Ty.floatRef Ty.intRef
floorf = unop' FLOR Ty.floatRef Ty.intRef
truncf = unop' TRNF Ty.floatRef Ty.intRef
roundf = unop' RNDF Ty.floatRef Ty.intRef
i2f = unop' ITOF Ty.intRef Ty.floatRef
n2f = unop' NTOF Ty.natRef Ty.floatRef

trni :: Var v => SuperNormal v
trni = unop0 3 $ \[x0,x,z,b]
    -> unbox x0 Ty.intRef x
     . TLetD z UN (TLit $ I 0)
     . TLetD b UN (TPrm LEQI [x, z])
     . TMatch b
     $ MatchIntegral
         (mapSingleton 1 $ TCon Ty.natRef 0 [z])
         (Just $ TCon Ty.natRef 0 [x])

modular :: Var v => POp -> (Bool -> ANormal v) -> SuperNormal v
modular pop ret
  = unop0 3 $ \[x0,x,m,t]
 -> unbox x0 Ty.intRef x
  . TLetD t UN (TLit $ I 2)
  . TLetD m UN (TPrm pop [x,t])
  . TMatch m
  $ MatchIntegral
      (mapSingleton 1 $ ret True)
      (Just $ ret False)

evni, evnn, oddi, oddn :: Var v => SuperNormal v
evni = modular MODI (\b -> if b then fls else tru)
oddi = modular MODI (\b -> if b then tru else fls)
evnn = modular MODN (\b -> if b then fls else tru)
oddn = modular MODN (\b -> if b then tru else fls)

dropn :: Var v => SuperNormal v
dropn = binop0 4 $ \[x0,y0,x,y,b,r]
     -> unbox x0 Ty.natRef x
      . unbox y0 Ty.natRef y
      . TLetD b UN (TPrm LEQN [x,y])
      . TLet (Indirect 1) r UN
          (TMatch b $ MatchIntegral
             (mapSingleton 1 $ TLit $ N 0)
             (Just $ TPrm SUBN [x,y]))
      $ TCon Ty.natRef 0 [r]

appendt, taket, dropt, sizet, unconst, unsnoct :: Var v => SuperNormal v
appendt = binop0 0 $ \[x,y] -> TPrm CATT [x,y]
taket = binop0 1 $ \[x0,y,x]
     -> unbox x0 Ty.natRef x
      $ TPrm TAKT [x,y]
dropt = binop0 1 $ \[x0,y,x]
     -> unbox x0 Ty.natRef x
      $ TPrm DRPT [x,y]
sizet = unop0 1 $ \[x,r]
     -> TLetD r UN (TPrm SIZT [x])
      $ TCon Ty.natRef 0 [r]
unconst = unop0 5 $ \[x,t,c0,c,y,p]
     -> TLetD t UN (TPrm UCNS [x])
      . TMatch t . MatchSum $ mapFromList
      [ (0, ([], TCon Ty.optionalRef 0 []))
      , (1, ([UN,BX], TAbss [c0,y]
                    . TLetD c BX (TCon Ty.charRef 0 [c0])
                    . TLetD p BX (TCon Ty.pairRef 0 [c,y])
                    $ TCon Ty.optionalRef 1 [p]))
      ]
unsnoct = unop0 5 $ \[x,t,c0,c,y,p]
     -> TLetD t UN (TPrm USNC [x])
      . TMatch t . MatchSum $ mapFromList
      [ (0, ([], TCon Ty.optionalRef 0 []))
      , (1, ([BX,UN], TAbss [y,c0]
                    . TLetD c BX (TCon Ty.charRef 0 [c0])
                    . TLetD p BX (TCon Ty.pairRef 0 [y,c])
                    $ TCon Ty.optionalRef 1 [p]))
      ]

appends, conss, snocs :: Var v => SuperNormal v
appends = binop0 0 $ \[x,y] -> TPrm CATS [x,y]
conss = binop0 0 $ \[x,y] -> TPrm CONS [x,y]
snocs = binop0 0 $ \[x,y] -> TPrm SNOC [x,y]

takes, drops, sizes, ats, emptys :: Var v => SuperNormal v
takes = binop0 1 $ \[x0,y,x]
     -> unbox x0 Ty.natRef x
      $ TPrm TAKS [x,y]
drops = binop0 1 $ \[x0,y,x]
     -> unbox x0 Ty.natRef x
      $ TPrm DRPS [x,y]
sizes = unop0 1 $ \[x,r]
     -> TLetD r UN (TPrm SIZS [x])
      $ TCon Ty.natRef 0 [r]
ats = binop0 3 $ \[x0,y,x,t,r]
   -> unbox x0 Ty.natRef x
    . TLetD t UN (TPrm IDXS [x,y])
    . TMatch t . MatchSum $ mapFromList
    [ (0, ([], TCon Ty.optionalRef 0 []))
    , (1, ([BX], TAbs r $ TCon Ty.optionalRef 1 [r]))
    ]
emptys = Lambda [] $ TPrm BLDS []

viewls, viewrs :: Var v => SuperNormal v
viewls = unop0 3 $ \[s,u,h,t]
      -> TLetD u UN (TPrm VWLS [s])
       . TMatch u . MatchSum $ mapFromList
       [ (0, ([], TCon Ty.seqViewRef 0 []))
       , (1, ([BX,BX], TAbss [h,t] $ TCon Ty.seqViewRef 1 [h,t]))
       ]
viewrs = unop0 3 $ \[s,u,i,l]
      -> TLetD u UN (TPrm VWRS [s])
       . TMatch u . MatchSum $ mapFromList
       [ (0, ([], TCon Ty.seqViewRef 0 []))
       , (1, ([BX,BX], TAbss [i,l] $ TCon Ty.seqViewRef 1 [i,l]))
       ]

eqt, neqt, leqt, geqt, lesst, great :: Var v => SuperNormal v
eqt = binop0 1 $ \[x,y,b]
   -> TLetD b UN (TPrm EQLT [x,y])
    $ boolift b
neqt = binop0 1 $ \[x,y,b]
    -> TLetD b UN (TPrm EQLT [x,y])
     $ notlift b
leqt = binop0 1 $ \[x,y,b]
    -> TLetD b UN (TPrm LEQT [x,y])
     $ boolift b
geqt = binop0 1 $ \[x,y,b]
    -> TLetD b UN (TPrm LEQT [y,x])
     $ boolift b
lesst = binop0 1 $ \[x,y,b]
     -> TLetD b UN (TPrm LEQT [y,x])
      $ notlift b
great = binop0 1 $ \[x,y,b]
     -> TLetD b UN (TPrm LEQT [x,y])
      $ notlift b

packt, unpackt :: Var v => SuperNormal v
packt = unop0 0 $ \[s] -> TPrm PAKT [s]
unpackt = unop0 0 $ \[t] -> TPrm UPKT [t]

packb, unpackb, emptyb, appendb :: Var v => SuperNormal v
packb = unop0 0 $ \[s] -> TPrm PAKB [s]
unpackb = unop0 0 $ \[b] -> TPrm UPKB [b]
emptyb
  = Lambda []
  . TLetD es BX (TPrm BLDS [])
  $ TPrm PAKB [es]
  where
  [es] = freshes 1
appendb = binop0 0 $ \[x,y] -> TPrm CATB [x,y]

takeb, dropb, atb, sizeb, flattenb :: Var v => SuperNormal v
takeb = binop0 1 $ \[n0,b,n]
     -> unbox n0 Ty.natRef n
      $ TPrm TAKB [n,b]

dropb = binop0 1 $ \[n0,b,n]
     -> unbox n0 Ty.natRef n
      $ TPrm DRPB [n,b]

atb = binop0 4 $ \[n0,b,n,t,r0,r]
   -> unbox n0 Ty.natRef n
    . TLetD t UN (TPrm IDXB [n,b])
    . TMatch t . MatchSum $ mapFromList
    [ (0, ([], TCon Ty.optionalRef 0 []))
    , (1, ([UN], TAbs r0
               . TLetD r BX (TCon Ty.natRef 0 [r0])
               $ TCon Ty.optionalRef 1 [r]))
    ]

sizeb = unop0 1 $ \[b,n]
     -> TLetD n UN (TPrm SIZB [b])
      $ TCon Ty.natRef 0 [n]

flattenb = unop0 0 $ \[b] -> TPrm FLTB [b]

i2t, n2t, f2t :: Var v => SuperNormal v
i2t = unop0 1 $ \[n0,n]
   -> unbox n0 Ty.intRef n
    $ TPrm ITOT [n]
n2t = unop0 1 $ \[n0,n]
   -> unbox n0 Ty.natRef n
    $ TPrm NTOT [n]
f2t = unop0 1 $ \[f0,f]
   -> unbox f0 Ty.floatRef f
    $ TPrm FTOT [f]

t2i, t2n, t2f :: Var v => SuperNormal v
t2i = unop0 3 $ \[x,t,n0,n]
   -> TLetD t UN (TPrm TTOI [x])
    . TMatch t . MatchSum $ mapFromList
    [ (0, ([], TCon Ty.optionalRef 0 []))
    , (1, ([UN], TAbs n0
               . TLetD n BX (TCon Ty.intRef 0 [n0])
               $ TCon Ty.optionalRef 1 [n]))
    ]
t2n = unop0 3 $ \[x,t,n0,n]
   -> TLetD t UN (TPrm TTON [x])
    . TMatch t . MatchSum $ mapFromList
    [ (0, ([], TCon Ty.optionalRef 0 []))
    , (1, ([UN], TAbs n0
               . TLetD n BX (TCon Ty.natRef 0 [n0])
               $ TCon Ty.optionalRef 1 [n]))
    ]
t2f = unop0 3 $ \[x,t,f0,f]
   -> TLetD t UN (TPrm TTOF [x])
    . TMatch t . MatchSum $ mapFromList
    [ (0, ([], TCon Ty.optionalRef 0 []))
    , (1, ([UN], TAbs f0
               . TLetD f BX (TCon Ty.floatRef 0 [f0])
               $ TCon Ty.optionalRef 1 [f]))
    ]

equ :: Var v => SuperNormal v
equ = binop0 1 $ \[x,y,b]
   -> TLetD b UN (TPrm EQLU [x,y])
    $ boolift b

cmpu :: Var v => SuperNormal v
cmpu = binop0 2 $ \[x,y,c,i]
    -> TLetD c UN (TPrm CMPU [x,y])
     . TLetD i UN (TPrm DECI [c])
     $ TCon Ty.intRef 0 [i]

ltu :: Var v => SuperNormal v
ltu = binop0 1 $ \[x,y,c]
   -> TLetD c UN (TPrm CMPU [x,y])
    . TMatch c
    $ MatchIntegral
        (mapFromList [ (0, TCon Ty.booleanRef 1 []) ])
        (Just $ TCon Ty.booleanRef 0 [])

gtu :: Var v => SuperNormal v
gtu = binop0 1 $ \[x,y,c]
   -> TLetD c UN (TPrm CMPU [x,y])
    . TMatch c
    $ MatchIntegral
        (mapFromList [ (2, TCon Ty.booleanRef 1 []) ])
        (Just $ TCon Ty.booleanRef 0 [])

geu :: Var v => SuperNormal v
geu = binop0 1 $ \[x,y,c]
   -> TLetD c UN (TPrm CMPU [x,y])
    . TMatch c
    $ MatchIntegral
        (mapFromList [ (0, TCon Ty.booleanRef 0 []) ])
        (Just $ TCon Ty.booleanRef 1 [])

leu :: Var v => SuperNormal v
leu = binop0 1 $ \[x,y,c]
   -> TLetD c UN (TPrm CMPU [x,y])
    . TMatch c
    $ MatchIntegral
        (mapFromList [ (2, TCon Ty.booleanRef 0 []) ])
        (Just $ TCon Ty.booleanRef 1 [])

notb :: Var v => SuperNormal v
notb = unop0 0 $ \[b]
    -> TMatch b . flip (MatchData Ty.booleanRef) Nothing
     $ mapFromList [ (0, ([], tru)), (1, ([], fls)) ]

orb :: Var v => SuperNormal v
orb = binop0 0 $ \[p,q]
   -> TMatch p . flip (MatchData Ty.booleanRef) Nothing
    $ mapFromList [ (1, ([], tru)), (0, ([], TVar q)) ]

andb :: Var v => SuperNormal v
andb = binop0 0 $ \[p,q]
    -> TMatch p . flip (MatchData Ty.booleanRef) Nothing
     $ mapFromList [ (0, ([], fls)), (1, ([], TVar q)) ]

-- unsafeCoerce, used for numeric types where conversion is a
-- no-op on the representation. Ideally this will be inlined and
-- eliminated so that no instruction is necessary.
cast :: Var v => Reference -> Reference -> SuperNormal v
cast ri ro
  = unop0 1 $ \[x0,x]
 -> unbox x0 ri x
  $ TCon ro 0 [x]

jumpk :: Var v => SuperNormal v
jumpk = binop0 0 $ \[k,a] -> TKon k [a]

fork'comp :: Var v => SuperNormal v
fork'comp
  = Lambda [BX]
  . TAbs act
  . TLetD unit BX (TCon Ty.unitRef 0 [])
  . TName lz (Right act) [unit]
  $ TPrm FORK [lz]
  where
  [act,unit,lz] = freshes 3

bug :: Var v => SuperNormal v
bug = unop0 0 $ \[x] -> TPrm EROR [x]

watch :: Var v => SuperNormal v
watch
  = binop0 0 $ \[t,v]
 -> TLets Direct [] [] (TPrm PRNT [t])
  $ TVar v

code'missing :: Var v => SuperNormal v
code'missing
  = unop0 1 $ \[link,b]
 -> TLetD b UN (TPrm MISS [link])
  $ boolift b

code'cache :: Var v => SuperNormal v
code'cache = unop0 0 $ \[new] -> TPrm CACH [new]

code'lookup :: Var v => SuperNormal v
code'lookup
  = unop0 2 $ \[link,t,r]
 -> TLetD t UN (TPrm LKUP [link])
  . TMatch t . MatchSum $ mapFromList
  [ (0, ([], TCon Ty.optionalRef 0 []))
  , (1, ([BX], TAbs r $ TCon Ty.optionalRef 1 [r]))
  ]

value'load :: Var v => SuperNormal v
value'load
  = unop0 2 $ \[vlu,t,r]
 -> TLetD t UN (TPrm LOAD [vlu])
  . TMatch t . MatchSum $ mapFromList
  [ (0, ([BX], TAbs r $ TCon Ty.eitherRef 0 [r]))
  , (1, ([BX], TAbs r $ TCon Ty.eitherRef 1 [r]))
  ]

value'create :: Var v => SuperNormal v
value'create = unop0 0 $ \[x] -> TPrm VALU [x]

type ForeignOp = forall v. Var v => FOp -> ([Mem], ANormal v)


maybe'result'direct
  :: Var v
  => FOp -> [v]
  -> v -> v
  -> ANormal v

maybe'result'direct ins args t r
  = TLetD t UN (TFOp ins args)
  . TMatch t . MatchSum $ mapFromList
  [ (0, ([], TCon Ty.optionalRef 0 []))
  , (1, ([BX], TAbs r $ TCon Ty.optionalRef 1 [r]))
  ]

enum'decode :: Var v => Reference -> String -> Int -> v -> ANormal v
enum'decode rf err n v
  = TMatch v $ MatchIntegral cases (Just dflt)
  where
  dflt = TLetD v BX (TLit . T $ pack err) $ TPrm EROR [v]
  cases = mapFromList $ fmap mkCase $ [0..n]
  mkCase i = (toEnum i, TCon rf (toEnum i) [])

io'error'result0
  :: Var v
  => FOp -> [v]
  -> v -> [Mem] -> [v] -> v
  -> ANormal v -> ANormal v
io'error'result0 ins args ior ccs vs e nx
  = TLetD ior UN (TFOp ins args)
  . TMatch ior . MatchSum
  $ mapFromList
  [ (0, ([UN], TAbs e
             . TLet (Indirect 1) e BX (enum'decode Ty.ioErrorRef err 7 e)
             $ TCon eitherReference 0 [e]))
  , (1, (ccs, TAbss vs nx))
  ]
  where
  err = "unrecognized IOError"

io'error'result'let
  :: Var v
  => FOp -> [v]
  -> v -> [Mem] -> [v] -> v -> v -> Direction Word16 -> ANormal v
  -> ANormal v
io'error'result'let ins args ior ccs vs e r d m
  = io'error'result0 ins args ior ccs vs e
  . TLet d r BX m
  $ TCon eitherReference 1 [r]

io'error'result'direct
  :: Var v
  => FOp -> [v]
  -> v -> v -> v
  -> ANormal v
io'error'result'direct ins args ior e r
  = io'error'result0 ins args ior [BX] [r] e
  $ TCon eitherReference 1 [r]

io'error'result'unit
  :: Var v
  => FOp -> [v]
  -> v -> v -> v
  -> ANormal v
io'error'result'unit ins args ior e r
  = io'error'result'let ins args ior [] [] e r Direct
  $ TCon Ty.unitRef 0 []

io'error'result'bool
  :: Var v
  => FOp -> [v]
  -> v -> (v -> ANormal v) -> v -> v -> v -> ANormal v
io'error'result'bool ins args ior encode b e r
  = io'error'result'let ins args ior [UN] [b] e r (Indirect 1)
  $ encode b

open'file :: ForeignOp
open'file instr
  = ([BX,BX],)
  . TAbss [fp,m0]
  . unenum 4 m0 ioModeReference m
  $ io'error'result'direct instr [fp,m] ior e r
  where
  [m0,fp,m,ior,e,r] = freshes 6

close'file :: ForeignOp
close'file instr
  = ([BX],)
  . TAbss [h]
  $ io'error'result'unit instr [h] ior e r
  where
  [h,ior,e,r] = freshes 4

is'file'eof :: ForeignOp
is'file'eof instr
  = ([BX],)
  . TAbss [h]
  $ io'error'result'bool instr [h] ior boolift b e r
  where
  [h,b,ior,e,r] = freshes 5

is'file'open :: ForeignOp
is'file'open instr
  = ([BX],)
  . TAbss [h]
  $ io'error'result'bool instr [h] ior boolift b e r
  where
  [h,b,ior,e,r] = freshes 5

is'seekable :: ForeignOp
is'seekable instr
  = ([BX],)
  . TAbss [h]
  $ io'error'result'bool instr [h] ior boolift b e r
  where
  [h,b,ior,e,r] = freshes 5

standard'handle :: ForeignOp
standard'handle instr
  = ([BX],)
  . TAbss [h0]
  . unenum 3 h0 Ty.stdHandleRef h
  $ TFOp instr [h]
  where
  [h0,h] = freshes 2

seek'handle :: ForeignOp
seek'handle instr
  = ([BX,BX,BX],)
  . TAbss [h,sm0,po0]
  . unenum 3 sm0 Ty.seekModeRef sm
  . unbox po0 Ty.natRef po
  $ io'error'result'unit instr [h,sm,po] ior e r
  where
  [sm0,po0,h,sm,po,ior,e,r] = freshes 8

handle'position :: ForeignOp
handle'position instr
  = ([BX],)
  . TAbss [h]
  . io'error'result'let instr [h] ior [UN] [i] e r Direct
  $ (TCon Ty.intRef 0 [i])
  where
  [h,i,ior,e,r] = freshes 5

get'buffering :: ForeignOp
get'buffering instr
  = ([BX],)
  . TAbss [h]
  . io'error'result'let instr [h] ior [UN] [bu] e r (Indirect 1)
  . TMatch bu . MatchSum
  $ mapFromList
  [ (0, ([], TCon Ty.optionalRef 0 []))
  , (1, ([], line))
  , (2, ([], block'nothing))
  , (3, ([UN], TAbs n $ block'n))
  ]
  where
  [h,bu,ior,e,r,m,n,b] = freshes 8
  final = TCon Ty.optionalRef 1 [b]
  block = TLetD b BX (TCon bufferModeReference 1 [m]) $ final

  line
    = TLetD b BX (TCon bufferModeReference 0 []) $ final
  block'nothing
    = TLetD m BX (TCon Ty.optionalRef 0 [])
    $ block
  block'n
    = TLetD m BX (TCon Ty.optionalRef 1 [n])
    $ block

set'buffering :: ForeignOp
set'buffering instr
  = ([BX,BX],)
  . TAbss [h,bm0]
  . TMatch bm0 . flip (MatchData Ty.optionalRef) Nothing
  $ mapFromList
  [ (0, ([], none'branch))
  , (1, ([BX], TAbs bm just'branch'0))
  ]
  where
  [t,ior,e,r,h,mbs,bs0,bs,bm0,bm] = freshes 10
  none'branch
    = TLetD t UN (TLit $ I 0)
    $ io'error'result'unit instr [h,t] ior e r
  just'branch'0
    = TMatch bm . flip (MatchData bufferModeReference) Nothing
    $ mapFromList
    [ (0, ([]
        , TLetD t UN (TLit $ I 1)
        $ io'error'result'unit instr [h,t] ior e r
        ))
    , (1, ([BX], TAbs mbs just'branch'1))
    ]
  just'branch'1
    = TMatch mbs
      . flip (MatchData Ty.optionalRef) Nothing
      $ mapFromList
      [ (0, ([]
          , TLetD t UN (TLit $ I 2)
          $ io'error'result'unit instr [h,t] ior e r))
      , (1, ([BX]
          , TAbs bs0
          . unbox bs0 Ty.natRef bs
          . TLetD t UN (TLit $ I 3)
          $ io'error'result'unit instr [h,t,bs] ior e r))
      ]

get'line :: ForeignOp
get'line instr
  = ([BX],)
  . TAbss [h]
  $ io'error'result'direct instr [h] ior e r
  where
  [h,ior,e,r] = freshes 4

get'bytes :: ForeignOp
get'bytes instr
  = ([BX, BX],)
  . TAbss [h,n0]
  . unbox n0 Ty.natRef n
  $ io'error'result'direct instr [h,n] ior e r
  where
  [h,n0,n,ior,e,r] = freshes 6

put'bytes :: ForeignOp
put'bytes instr
  = ([BX,BX],)
  . TAbss [h,tx]
  $ io'error'result'direct instr [h,tx] ior e r
  where
  [h,tx,ior,e,r] = freshes 5

system'time :: ForeignOp
system'time instr
  = ([],)
  . io'error'result'let instr [] ior [UN] [n] e r Direct
  $ TCon Ty.natRef 0 [n]
  where
  [n,ior,e,r] = freshes 4

get'temp'directory :: ForeignOp
get'temp'directory instr
  = ([],)
  . io'error'result'let instr [] ior [BX] [t] e r Direct
  $ TCon filePathReference 0 [t]
  where
  [t,ior,e,r] = freshes 4

get'current'directory :: ForeignOp
get'current'directory instr
  = ([],)
  . io'error'result'let instr [] ior [BX] [t] e r Direct
  $ TCon filePathReference 0 [r]
  where
  [t,e,r,ior] = freshes 4

set'current'directory :: ForeignOp
set'current'directory instr
  = ([BX],)
  . TAbs fp
  $ io'error'result'unit instr [fp] ior e r
  where
  [fp,ior,e,r] = freshes 4

-- directory'contents
-- instr
--   directoryContents_ : io.FilePath -> Either io.Error [io.FilePath]


file'exists :: ForeignOp
file'exists instr
  = ([BX],)
  . TAbs fp
  $ io'error'result'bool instr [fp] ior boolift b e r
  where
  [fp,b,ior,e,r] = freshes 5

is'directory :: ForeignOp
is'directory instr
  = ([BX],)
  . TAbs fp
  $ io'error'result'bool instr [fp] ior boolift b e r
  where
  [fp,b,ior,e,r] = freshes 5

create'directory :: ForeignOp
create'directory instr
  = ([BX],)
  . TAbs fp
  $ io'error'result'unit instr [fp] ior e r
  where
  [fp,ior,e,r] = freshes 4

remove'directory :: ForeignOp
remove'directory instr
  = ([BX],)
  . TAbs fp
  $ io'error'result'unit instr [fp] ior e r
  where
  [fp,ior,e,r] = freshes 4

rename'directory :: ForeignOp
rename'directory instr
  = ([BX,BX],)
  . TAbss [from,to]
  $ io'error'result'unit instr [from,to] ior e r
  where
  [from,to,ior,e,r] = freshes 5

remove'file :: ForeignOp
remove'file instr
  = ([BX],)
  . TAbs fp
  $ io'error'result'unit instr [fp] ior e r
  where
  [fp,ior,e,r] = freshes 4

rename'file :: ForeignOp
rename'file instr
  = ([BX,BX],)
  . TAbss [from,to]
  $ io'error'result'unit instr [from,to] ior e r
  where
  [from,to,ior,e,r] = freshes 5

get'file'timestamp :: ForeignOp
get'file'timestamp instr
  = ([BX],)
  . TAbs fp
  . io'error'result'let instr [fp] ior [UN] [n] e r Direct
  $ TCon Ty.natRef 0 [n]
  where
  [fp,n,ior,e,r] = freshes 5

get'file'size :: ForeignOp
get'file'size instr
  = ([BX],)
  . TAbs fp
  . io'error'result'let instr [fp] ior [UN] [n] e r Direct
  $ TCon Ty.natRef 0 [n]
  where
  [fp,n,ior,e,r] = freshes 5

server'socket :: ForeignOp
server'socket instr
  = ([BX,BX],)
  . TAbss [mhn,sn]
  . TMatch mhn . flip (MatchData Ty.optionalRef) Nothing
  $ mapFromList
  [ (0, ([], none'branch))
  , (1, ([BX], TAbs hn just'branch))
  ]
  where
  [mhn,sn,hn,t,ior,e,r] = freshes 7
  none'branch
    = TLetD t UN (TLit $ I 0)
    $ io'error'result'direct instr [t,sn] ior e r
  just'branch
    = TLetD t UN (TLit $ I 1)
    $ io'error'result'direct instr [t,hn,sn] ior e r

listen :: ForeignOp
listen instr
  = ([BX],)
  . TAbs sk
  $ io'error'result'direct instr [sk] ior e r
  where
  [sk,ior,e,r] = freshes 4

client'socket :: ForeignOp
client'socket instr
  = ([BX,BX],)
  . TAbss [hn,sn]
  $ io'error'result'direct instr [hn,sn] ior e r
  where
  [hn,sn,r,ior,e] = freshes 5

close'socket :: ForeignOp
close'socket instr
  = ([BX,BX],)
  . TAbs sk
  $ io'error'result'unit instr [sk] ior e r
  where
  [sk,ior,e,r] = freshes 4

socket'accept :: ForeignOp
socket'accept instr
  = ([BX],)
  . TAbs sk
  $ io'error'result'direct instr [sk] ior e r
  where
  [sk,r,e,ior] = freshes 4

socket'send :: ForeignOp
socket'send instr
  = ([BX,BX],)
  . TAbss [sk,by]
  $ io'error'result'unit instr [sk,by] ior e r
  where
  [sk,by,ior,e,r] = freshes 5

socket'receive :: ForeignOp
socket'receive instr
  = ([BX,BX],)
  . TAbss [sk,n0]
  . unbox n0 Ty.natRef n
  $ io'error'result'direct instr [sk,n] ior e r
  where
  [n0,sk,n,ior,e,r] = freshes 6

delay'thread :: ForeignOp
delay'thread instr
  = ([BX],)
  . TAbs n0
  . unbox n0 Ty.natRef n
  $ io'error'result'unit instr [n] ior e r
  where
  [n0,n,ior,e,r] = freshes 5

kill'thread :: ForeignOp
kill'thread instr
  = ([BX],)
  . TAbs tid
  $ io'error'result'unit instr [tid] ior e r
  where
  [tid,ior,e,r] = freshes 4

mvar'new :: ForeignOp
mvar'new instr
  = ([BX],)
  . TAbs init
  $ TFOp instr [init]
  where
  [init] = freshes 1

mvar'empty :: ForeignOp
mvar'empty instr = ([],) $ TFOp instr []

mvar'take :: ForeignOp
mvar'take instr
  = ([BX],)
  . TAbs mv
  $ io'error'result'direct instr [mv] ior e r
  where
  [mv,ior,e,r] = freshes 4

mvar'try'take :: ForeignOp
mvar'try'take instr
  = ([BX],)
  . TAbs mv
  $ maybe'result'direct instr [mv] t r
  where
  [mv,t,r] = freshes 3

mvar'put :: ForeignOp
mvar'put instr
  = ([BX,BX],)
  . TAbss [mv,x]
  $ io'error'result'unit instr [mv,x] ior e r
  where
  [mv,x,ior,e,r] = freshes 5

mvar'try'put :: ForeignOp
mvar'try'put instr
  = ([BX,BX],)
  . TAbss [mv,x]
  . TLetD b UN (TFOp instr [mv,x])
  $ boolift b
  where
  [mv,x,b] = freshes 3

mvar'swap :: ForeignOp
mvar'swap instr
  = ([BX,BX],)
  . TAbss [mv,x]
  $ io'error'result'direct instr [mv,x] ior e r
  where
  [mv,x,ior,e,r] = freshes 5

mvar'is'empty :: ForeignOp
mvar'is'empty instr
  = ([BX],)
  . TAbs mv
  . TLetD b UN (TFOp instr [mv])
  $ boolift b
  where
  [mv,b] = freshes 2

mvar'read :: ForeignOp
mvar'read instr
  = ([BX],)
  . TAbs mv
  $ io'error'result'direct instr [mv] ior e r
  where
  [mv,ior,e,r] = freshes 4

mvar'try'read :: ForeignOp
mvar'try'read instr
  = ([BX],)
  . TAbs mv
  $ maybe'result'direct instr [mv] t r
  where
  [mv,t,r] = freshes 3

-- Pure ForeignOp taking two boxed values
pfopbb :: ForeignOp
pfopbb instr
  = ([BX,BX],)
  . TAbss [b1,b2]
  $ TFOp instr [b1,b2]
  where
  [b1,b2] = freshes 2

pfopbbb :: ForeignOp
pfopbbb instr
  = ([BX,BX,BX],)
  . TAbss [b1,b2,b3]
  $ TFOp instr [b1,b2,b3]
  where
  [b1,b2,b3] = freshes 3

-- Pure ForeignOp taking no values
pfop0 :: ForeignOp
pfop0 instr = ([],) $ TFOp instr []

-- Pure ForeignOp taking 1 boxed value and returning 1 boxed value
pfopb :: ForeignOp
pfopb instr
  = ([BX],)
  . TAbs t
  $ TFOp instr [t]
  where [t] = freshes 1

-- Pure ForeignOp taking 1 boxed value and returning 1 Either, both sides boxed
pfopb_ebb :: ForeignOp
pfopb_ebb instr
  = ([BX],)
  . TAbss [b]
  . TLetD e UN (TFOp instr [b])
  . TMatch e . MatchSum
  $ mapFromList
  [ (0, ([BX], TAbs ev $ TCon eitherReference 0 [ev]))
  , (1, ([BX], TAbs ev $ TCon eitherReference 1 [ev]))
  ]
  where
  [e,b,ev] = freshes 3

builtinLookup :: Var v => Map.Map Reference (SuperNormal v)
builtinLookup
  = Map.fromList
  . map (\(t, f) -> (Builtin t, f)) $
  [ ("Int.+", addi)
  , ("Int.-", subi)
  , ("Int.*", muli)
  , ("Int./", divi)
  , ("Int.mod", modi)
  , ("Int.==", eqi)
  , ("Int.<", lti)
  , ("Int.<=", lei)
  , ("Int.>", gti)
  , ("Int.>=", gei)
  , ("Int.increment", inci)
  , ("Int.signum", sgni)
  , ("Int.negate", negi)
  , ("Int.truncate0", trni)
  , ("Int.isEven", evni)
  , ("Int.isOdd", oddi)
  , ("Int.shiftLeft", shli)
  , ("Int.shiftRight", shri)
  , ("Int.trailingZeros", tzeroi)
  , ("Int.leadingZeros", lzeroi)
  , ("Int.and", andi)
  , ("Int.or", ori)
  , ("Int.xor", xori)
  , ("Int.complement", compli)
  , ("Int.pow", powi)
  , ("Int.toText", i2t)
  , ("Int.fromText", t2i)
  , ("Int.toFloat", i2f)
  , ("Int.popCount", popi)

  , ("Nat.+", addn)
  , ("Nat.-", subn)
  , ("Nat.sub", subn)
  , ("Nat.*", muln)
  , ("Nat./", divn)
  , ("Nat.mod", modn)
  , ("Nat.==", eqn)
  , ("Nat.<", ltn)
  , ("Nat.<=", len)
  , ("Nat.>", gtn)
  , ("Nat.>=", gen)
  , ("Nat.increment", incn)
  , ("Nat.isEven", evnn)
  , ("Nat.isOdd", oddn)
  , ("Nat.shiftLeft", shln)
  , ("Nat.shiftRight", shrn)
  , ("Nat.trailingZeros", tzeron)
  , ("Nat.leadingZeros", lzeron)
  , ("Nat.and", andn)
  , ("Nat.or", orn)
  , ("Nat.xor", xorn)
  , ("Nat.complement", compln)
  , ("Nat.pow", pown)
  , ("Nat.drop", dropn)
  , ("Nat.toInt", cast Ty.natRef Ty.intRef)
  , ("Nat.toFloat", n2f)
  , ("Nat.toText", n2t)
  , ("Nat.fromText", t2n)
  , ("Nat.popCount", popn)

  , ("Float.+", addf)
  , ("Float.-", subf)
  , ("Float.*", mulf)
  , ("Float./", divf)
  , ("Float.pow", powf)
  , ("Float.log", logf)
  , ("Float.logBase", logbf)
  , ("Float.sqrt", sqrtf)

  , ("Float.min", minf)
  , ("Float.max", maxf)

  , ("Float.<", ltf)
  , ("Float.>", gtf)
  , ("Float.<=", lef)
  , ("Float.>=", gef)
  , ("Float.==", eqf)
  , ("Float.!=", neqf)

  , ("Float.acos", acosf)
  , ("Float.asin", asinf)
  , ("Float.atan", atanf)
  , ("Float.cos", cosf)
  , ("Float.sin", sinf)
  , ("Float.tan", tanf)

  , ("Float.acosh", acoshf)
  , ("Float.asinh", asinhf)
  , ("Float.atanh", atanhf)
  , ("Float.cosh", coshf)
  , ("Float.sinh", sinhf)
  , ("Float.tanh", tanhf)

  , ("Float.exp", expf)
  , ("Float.abs", absf)

  , ("Float.ceiling", ceilf)
  , ("Float.floor", floorf)
  , ("Float.round", roundf)
  , ("Float.truncate", truncf)
  , ("Float.atan2", atan2f)

  , ("Float.toText", f2t)
  , ("Float.fromText", t2f)

  -- text
  , ("Text.empty", Lambda [] $ TLit (T ""))
  , ("Text.++", appendt)
  , ("Text.take", taket)
  , ("Text.drop", dropt)
  , ("Text.size", sizet)
  , ("Text.==", eqt)
  , ("Text.!=", neqt)
  , ("Text.<=", leqt)
  , ("Text.>=", geqt)
  , ("Text.<", lesst)
  , ("Text.>", great)
  , ("Text.uncons", unconst)
  , ("Text.unsnoc", unsnoct)
  , ("Text.toCharList", unpackt)
  , ("Text.fromCharList", packt)

  , ("Boolean.not", notb)
  , ("Boolean.or", orb)
  , ("Boolean.and", andb)

  , ("bug", bug)
  , ("todo", bug)
  , ("Debug.watch", watch)

  , ("Char.toNat", cast Ty.charRef Ty.natRef)
  , ("Char.fromNat", cast Ty.natRef Ty.charRef)

  , ("Bytes.empty", emptyb)
  , ("Bytes.fromList", packb)
  , ("Bytes.toList", unpackb)
  , ("Bytes.++", appendb)
  , ("Bytes.take", takeb)
  , ("Bytes.drop", dropb)
  , ("Bytes.at", atb)
  , ("Bytes.size", sizeb)
  , ("Bytes.flatten", flattenb)

  , ("List.take", takes)
  , ("List.drop", drops)
  , ("List.size", sizes)
  , ("List.++", appends)
  , ("List.at", ats)
  , ("List.cons", conss)
  , ("List.snoc", snocs)
  , ("List.empty", emptys)
  , ("List.viewl", viewls)
  , ("List.viewr", viewrs)
--
--   , B "Debug.watch" $ forall1 "a" (\a -> text --> a --> a)
  , ("Universal.==", equ)
  , ("Universal.compare", cmpu)
  , ("Universal.>", gtu)
  , ("Universal.<", ltu)
  , ("Universal.>=", geu)
  , ("Universal.<=", leu)

  , ("jumpCont", jumpk)

  , ("IO.forkComp", fork'comp)

  , ("Code.isMissing", code'missing)
  , ("Code.cache_", code'cache)
  , ("Code.lookup", code'lookup)
  , ("Value.load", value'load)
  , ("Value.value", value'create)
  ] ++ foreignWrappers

type FDecl v
  = State (Word64, [(Text, SuperNormal v)], EnumMap Word64 ForeignFunc)

declareForeign
  :: Var v => Text -> ForeignOp -> ForeignFunc -> FDecl v ()
declareForeign name op func
  = modify $ \(w, cs, fs)
      -> (w+1, (name, uncurry Lambda (op w)) : cs, mapInsert w func fs)

mkForeignIOE
  :: (ForeignConvention a, ForeignConvention r)
  => (a -> IO r) -> ForeignFunc
mkForeignIOE f = mkForeign $ \a -> tryIOE (f a)
  where
  tryIOE :: IO a -> IO (Either IOException a)
  tryIOE = try

dummyFF :: ForeignFunc
dummyFF = FF ee ee ee
  where
  ee = error "dummyFF"


declareForeigns :: Var v => FDecl v ()
declareForeigns = do
  declareForeign "IO.openFile" open'file
    $ mkForeignIOE (uncurry openFile)
  declareForeign "IO.closeFile" close'file $ mkForeignIOE hClose
  declareForeign "IO.isFileEOF" is'file'eof $ mkForeignIOE hIsEOF
  declareForeign "IO.isFileOpen" is'file'open $ mkForeignIOE hIsOpen
  declareForeign "IO.isSeekable" is'seekable $ mkForeignIOE hIsSeekable
  declareForeign "IO.seekHandle" seek'handle
    . mkForeignIOE $ \(h,sm,n) -> hSeek h sm (fromIntegral (n :: Int))
  declareForeign "IO.handlePosition" handle'position
    -- TODO: truncating integer
    . mkForeignIOE $ \h -> fromInteger @Word64 <$> hTell h
  declareForeign "IO.getBuffering" get'buffering
    $ mkForeignIOE hGetBuffering
  declareForeign "IO.setBuffering" set'buffering
    . mkForeignIOE $ uncurry hSetBuffering
  declareForeign "IO.getLine" get'line $ mkForeignIOE hGetLine
  declareForeign "IO.getBytes" get'bytes .  mkForeignIOE $ \(h,n) -> fmap Bytes.fromArray $ hGet h n
  declareForeign "IO.putBytes" put'bytes .  mkForeignIOE $ \(h,bs) -> hPut h (Bytes.toArray bs)
  declareForeign "IO.systemTime" system'time
    $ mkForeignIOE $ \() -> getPOSIXTime
  declareForeign "IO.getTempDirectory" get'temp'directory
    $ mkForeignIOE $ \() -> getTemporaryDirectory
  declareForeign "IO.getCurrentDirectory" get'current'directory
    . mkForeignIOE $ \() -> getCurrentDirectory
  declareForeign "IO.setCurrentDirectory" set'current'directory
    $ mkForeignIOE setCurrentDirectory
  -- declareForeign ANF.DCNTNS
  --   . mkForeignIOE $ fmap (fmap Text.pack) . getDirectoryContents
  declareForeign "IO.fileExists" file'exists
    $ mkForeignIOE doesPathExist
  declareForeign "IO.isDirectory" is'directory dummyFF
  declareForeign "IO.createDirectory" create'directory
    $ mkForeignIOE $ createDirectoryIfMissing True
  declareForeign "IO.removeDirectory" remove'directory
    $mkForeignIOE removeDirectoryRecursive
  declareForeign "IO.renameDirectory" rename'directory
    . mkForeignIOE $ uncurry renameDirectory
  declareForeign "IO.removeFile" remove'file $ mkForeignIOE removeFile
  declareForeign "IO.renameFile" rename'file
    . mkForeignIOE $ uncurry renameFile
  declareForeign "IO.getFileTimestamp" get'file'timestamp
    . mkForeignIOE $ fmap utcTimeToPOSIXSeconds . getModificationTime
  declareForeign "IO.getFileSize" get'file'size
    -- TODO: truncating integer
    . mkForeignIOE $ \fp -> fromInteger @Word64 <$> getFileSize fp
  declareForeign "IO.serverSocket" server'socket
    . mkForeignIOE $ \(mhst,port) ->
        fst <$> SYS.bindSock (hostPreference mhst) port
  declareForeign "IO.listen" listen
    . mkForeignIOE $ \sk -> SYS.listenSock sk 2048
  declareForeign "IO.clientSocket" client'socket
    . mkForeignIOE $ fmap fst . uncurry SYS.connectSock
  declareForeign "IO.closeSocket" close'socket
    $ mkForeignIOE SYS.closeSock
  declareForeign "IO.socketAccept" socket'accept
    . mkForeignIOE $ fmap fst . SYS.accept
  declareForeign "IO.socketSend" socket'send
    . mkForeignIOE $ \(sk,bs) -> SYS.send sk (Bytes.toArray bs)
  declareForeign "IO.socketReceive" socket'receive
    . mkForeignIOE $ \(hs,n) ->
       fmap (maybe Bytes.empty Bytes.fromArray) $ SYS.recv hs n
  declareForeign "IO.kill" kill'thread $ mkForeignIOE killThread
  declareForeign "IO.delay" delay'thread $ mkForeignIOE threadDelay
  declareForeign "IO.stdHandle" standard'handle
    . mkForeign $ \(n :: Int) -> case n of
        0 -> pure (Just SYS.stdin)
        1 -> pure (Just SYS.stdout)
        2 -> pure (Just SYS.stderr)
        _ -> pure Nothing

  declareForeign "MVar.new" mvar'new
    . mkForeign $ \(c :: Closure) -> newMVar c
  declareForeign "MVar.empty" mvar'empty
    . mkForeign $ \() -> newEmptyMVar @Closure
  declareForeign "MVar.take" mvar'take
    . mkForeignIOE $ \(mv :: MVar Closure) -> takeMVar mv
  declareForeign "MVar.tryTake" mvar'try'take
    . mkForeign $ \(mv :: MVar Closure) -> tryTakeMVar mv
  declareForeign "MVar.put" mvar'put
    . mkForeignIOE $ \(mv :: MVar Closure, x) -> putMVar mv x
  declareForeign "MVar.tryPut" mvar'try'put
    . mkForeign $ \(mv :: MVar Closure, x) -> tryPutMVar mv x
  declareForeign "MVar.swap" mvar'swap
    . mkForeignIOE $ \(mv :: MVar Closure, x) -> swapMVar mv x
  declareForeign "MVar.isEmpty" mvar'is'empty
    . mkForeign $ \(mv :: MVar Closure) -> isEmptyMVar mv
  declareForeign "MVar.read" mvar'read
    . mkForeignIOE $ \(mv :: MVar Closure) -> readMVar mv
  declareForeign "MVar.tryRead" mvar'try'read
    . mkForeign $ \(mv :: MVar Closure) -> tryReadMVar mv

  declareForeign "Code.dependencies" pfopb
    . mkForeign $ \(sg :: SuperGroup Symbol)
        -> pure $ Wrap Ty.termLinkRef . Ref <$> groupTermLinks sg
  declareForeign "Code.serialize" pfopb
    . mkForeign $ \(sg :: SuperGroup Symbol)
        -> pure . Bytes.fromArray $ serializeGroup sg
  declareForeign "Code.deserialize" pfopb_ebb
    . mkForeign $ pure . deserializeGroup @Symbol . Bytes.toArray
  declareForeign "Value.dependencies" pfopb
    . mkForeign $
        pure . fmap (Wrap Ty.termLinkRef . Ref) . valueTermLinks
  declareForeign "Value.serialize" pfopb
    . mkForeign $ pure . Bytes.fromArray . serializeValue
  declareForeign "Value.deserialize" pfopb_ebb
    . mkForeign $ pure . deserializeValue . Bytes.toArray
  declareForeign "Text.toUtf8" pfopb . mkForeign $ pure . Bytes.fromArray . encodeUtf8
  declareForeign "Text.fromUtf8" pfopb_ebb . mkForeign $ pure . mapLeft (pack . show) . decodeUtf8' . Bytes.toArray

  -- Hashing functions
  let declareHashAlgorithm :: forall v alg . Var v => Hash.HashAlgorithm alg => Text -> alg -> FDecl v ()
      declareHashAlgorithm txt alg = do
        let algoRef = Builtin ("crypto.HashAlgorithm." <> txt)
        declareForeign ("crypto.HashAlgorithm." <> txt) pfop0 . mkForeign $ \() ->
          pure (HashAlgorithm algoRef alg)

  declareHashAlgorithm "Sha3_512" Hash.SHA3_512
  declareHashAlgorithm "Sha3_256" Hash.SHA3_256
  declareHashAlgorithm "Sha2_512" Hash.SHA512
  declareHashAlgorithm "Sha2_256" Hash.SHA256
  declareHashAlgorithm "Blake2b_512" Hash.Blake2b_512
  declareHashAlgorithm "Blake2b_256" Hash.Blake2b_256
  declareHashAlgorithm "Blake2s_256" Hash.Blake2s_256

  -- declareForeign ("crypto.hash") pfopbb . mkForeign $ \(HashAlgorithm _ref _alg, _a :: Closure) ->
  --   pure $ Bytes.empty -- todo : implement me

  declareForeign "crypto.hashBytes" pfopbb . mkForeign $
    \(HashAlgorithm _ alg, b :: Bytes.Bytes) ->
        let ctx = Hash.hashInitWith alg
        in pure . Bytes.fromArray . Hash.hashFinalize $ Hash.hashUpdates ctx (Bytes.chunks b)

  declareForeign "crypto.hmacBytes" pfopbbb
    . mkForeign $ \(HashAlgorithm _ alg, key :: Bytes.Bytes, msg :: Bytes.Bytes) ->
        let out = u alg $ HMAC.hmac (Bytes.toArray @BA.Bytes key) (Bytes.toArray @BA.Bytes msg)
            u :: a -> HMAC.HMAC a -> HMAC.HMAC a
            u _ h = h -- to help typechecker along
        in pure $ Bytes.fromArray out

  declareForeign "Bytes.toBase16" pfopb . mkForeign $ pure . Bytes.toBase16
  declareForeign "Bytes.toBase32" pfopb . mkForeign $ pure . Bytes.toBase32
  declareForeign "Bytes.toBase64" pfopb . mkForeign $ pure . Bytes.toBase64
  declareForeign "Bytes.toBase64UrlUnpadded" pfopb . mkForeign $ pure . Bytes.toBase64UrlUnpadded

  declareForeign "Bytes.fromBase16" pfopb_ebb . mkForeign $ pure . Bytes.fromBase16
  declareForeign "Bytes.fromBase32" pfopb_ebb . mkForeign $ pure . Bytes.fromBase32
  declareForeign "Bytes.fromBase64" pfopb_ebb . mkForeign $ pure . Bytes.fromBase64
  declareForeign "Bytes.fromBase64UrlUnpadded" pfopb . mkForeign $ pure . Bytes.fromBase64UrlUnpadded

hostPreference :: Maybe Text -> SYS.HostPreference
hostPreference Nothing = SYS.HostAny
hostPreference (Just host) = SYS.Host $ Text.unpack host

typeReferences :: [(Reference, Word64)]
typeReferences = zip rs [1..]
  where
  rs = [ r | (_,r) <- Ty.builtinTypes ]
    ++ [ DerivedId i | (_,i,_) <- Ty.builtinDataDecls @Symbol ]
    ++ [ DerivedId i | (_,i,_) <- Ty.builtinEffectDecls @Symbol ]

foreignDeclResults
  :: Var v
  => (Word64, [(Text, SuperNormal v)], EnumMap Word64 ForeignFunc)
foreignDeclResults = execState declareForeigns (0, [], mempty)

foreignWrappers :: Var v => [(Text, SuperNormal v)]
foreignWrappers | (_, l, _) <- foreignDeclResults = reverse l

numberedTermLookup :: Var v => EnumMap Word64 (SuperNormal v)
numberedTermLookup
  = mapFromList . zip [1..] . Map.elems $ builtinLookup

builtinTermNumbering :: Map Reference Word64
builtinTermNumbering
  = Map.fromList (zip (Map.keys $ builtinLookup @Symbol) [1..])

builtinTermBackref :: EnumMap Word64 Reference
builtinTermBackref
  = mapFromList . zip [1..] . Map.keys $ builtinLookup @Symbol

builtinTypeNumbering :: Map Reference Word64
builtinTypeNumbering = Map.fromList typeReferences

builtinTypeBackref :: EnumMap Word64 Reference
builtinTypeBackref = mapFromList $ swap <$> typeReferences
  where swap (x, y) = (y, x)

builtinForeigns :: EnumMap Word64 ForeignFunc
builtinForeigns | (_, _, m) <- foreignDeclResults @Symbol = m
