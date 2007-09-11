{-# OPTIONS -Wall -fno-warn-name-shadowing #-}
module CmmLiveZ
    ( CmmLive
    , cmmLivenessZ
    , liveLattice
    , middleLiveness, lastLiveness
    ) 
where

import Cmm
import CmmExpr
import CmmTx
import DFMonad
import Maybes
import PprCmm()
import PprCmmZ()
import UniqSet
import ZipDataflow
import ZipCfgCmmRep

-----------------------------------------------------------------------------
-- Calculating what variables are live on entry to a basic block
-----------------------------------------------------------------------------

-- | The variables live on entry to a block
type CmmLive = RegSet

-- | The dataflow lattice
liveLattice :: DataflowLattice CmmLive
liveLattice = DataflowLattice "live LocalReg's" emptyUniqSet add False
    where add new old =
            let join = unionUniqSets new old in
            (if sizeUniqSet join > sizeUniqSet old then aTx else noTx) join

-- | A mapping from block labels to the variables live on entry
type BlockEntryLiveness = BlockEnv CmmLive

-----------------------------------------------------------------------------
-- | Calculated liveness info for a CmmGraph
-----------------------------------------------------------------------------
cmmLivenessZ :: CmmGraph -> BlockEntryLiveness
cmmLivenessZ g = env
    where env = runDFA liveLattice $
                do run_b_anal transfer g
                   allFacts
          transfer = BComp "liveness analysis" exit last middle first
          exit         = emptyUniqSet
          first live _ = live
          middle       = flip middleLiveness
          last         = flip lastLiveness

-- | The transfer equations use the traditional 'gen' and 'kill'
-- notations, which should be familiar from the dragon book.
gen, kill :: UserOfLocalRegs a => a -> RegSet -> RegSet
gen  a live = foldRegsUsed extendRegSet      live a
kill a live = foldRegsUsed delOneFromUniqSet live a

middleLiveness :: Middle -> CmmLive -> CmmLive
middleLiveness m = middle m
  where middle (MidNop)                      = id
        middle (MidComment {})               = id
        middle (MidAssign lhs expr)          = gen expr . kill lhs
        middle (MidStore addr rval)          = gen addr . gen rval
        middle (MidUnsafeCall tgt ress args) = gen tgt . gen args . kill ress
        middle (CopyIn _ formals _)          = kill formals
        middle (CopyOut _ formals)           = gen formals

lastLiveness :: Last -> (BlockId -> CmmLive) -> CmmLive
lastLiveness l env = last l
  where last (LastReturn ress)             = gen ress emptyUniqSet
        last (LastJump e args)             = gen e $ gen args emptyUniqSet
        last (LastBranch id args)          = gen args $ env id
        last (LastCall tgt args (Just k))  = gen tgt $ gen args $ env k
        last (LastCall tgt args Nothing)   = gen tgt $ gen args $ emptyUniqSet
        last (LastCondBranch e t f)        = gen e $ unionUniqSets (env t) (env f)
        last (LastSwitch e tbl) = gen e $ unionManyUniqSets $ map env (catMaybes tbl)
