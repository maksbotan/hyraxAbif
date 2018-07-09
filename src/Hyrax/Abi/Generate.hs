{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections #-}
{-|
Module      : Hyax.Abi.Generate
Description : Generate AB1 from a weighted FASTA
Copyright   : (c) HyraxBio, 2018
License     : BSD3
Maintainer  : andre@hyraxbio.co.za

Functionality for generating AB1 files from an input FASTA

= Weighted reads

The input FASTA files have "weighted" reads. The name for each read is an value between 0 and 1
 which specifies the height of the peak relative to a full peak. 


== Single read

The most simple example is a single FASTA with a single read with a weight of 1

@
> 1
ACTG
@

<<docs/eg_actg.png>>

The chromatogram for this AB1 shows perfect traces for the input `ACTG` nucleotides with a full height peak.


== Mixes & multiple reads 

The source FASTA can have multiple reads, which results in a chromatogram with mixes

@
> 1
ACAG
> 0.3
ACTG
@

<<docs/eg_acag_acgt_mix.png>>

There is an `AT` mix at the third nucleotide. The first read has a weight of 1 and the second a weight of 0.3.
The chromatogram shows the mix and the `T` with a lower peak (30% of the `A` peak)

== Only adding a single mix

Rather than the above the could have been written as

@
> 1
ACAG
> 0.3
__T
@

i.e.

 - The second read is shorter than the first, it only goes as far as the required mix
 - `_` used when not adding any data


__ TODO image __

== Summing weights

 - The weigh of a read specifies the intensity of the peak from 0 to 1. 
 - Weights for each position are added to a maximum of 1 per nucleotide
 - You can use `_` as a "blank" nucleotide, in which only the nucleotides from other reads will be considered

See README.md for additional details and examples
-}
module Hyrax.Abi.Generate
    ( generateAb1s
    , generateAb1
    , readWeightedFasta
    , iupac
    , unIupac
    ) where

import           Protolude
import qualified Data.Text as Txt
import qualified Data.Text.Encoding as TxtE
import qualified Data.List as Lst
import qualified Data.Binary.Put as B
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BSL
import qualified System.FilePath as FP
import           System.FilePath ((</>))
import qualified System.Directory as Dir

import           Hyrax.Abi
import           Hyrax.Abi.Write
import           Hyrax.Abi.Fasta

data TraceData = TraceData { trData09G :: ![Int16]
                           , trData10A :: ![Int16]
                           , trData11T :: ![Int16]
                           , trData12C :: ![Int16]
                           , trValsPerBase :: !Int
                           , trFasta :: !Text
                           } deriving (Show)

generateAb1s :: FilePath -> FilePath -> IO ()
generateAb1s source dest = do
  Dir.createDirectoryIfMissing True dest
  weighted <- readWeightedFastas source

  case weighted of
    Left e -> putText e
    Right rs -> do
      let ab1s = (\(n, r) -> (n, generateAb1 (n, r))) <$> rs
      traverse_ (\(name, ab1) -> BS.writeFile (dest </> Txt.unpack name <> ".ab1") $ BSL.toStrict ab1) ab1s


generateTraceData :: [(Double, Text)] -> TraceData
generateTraceData weighted =
  let
    weightedNucs' = (\(w, ns) -> (w,) . unIupac <$> Txt.unpack ns) <$> weighted
    weightedNucs = Lst.transpose weightedNucs'
  
    -- Values for a base that was present. This defines the shape of the chromatogram curve, and defines the number of values per base
    curve = [0, 0, 128, 512, 1024, 1024, 512, 128, 0, 0]
    valsPerBase = length curve

    -- Create the G & A & T & C traces
    data09G = concat $ getWeightedTrace curve 'G' <$> weightedNucs
    data10A = concat $ getWeightedTrace curve 'A' <$> weightedNucs
    data11T = concat $ getWeightedTrace curve 'T' <$> weightedNucs
    data12C = concat $ getWeightedTrace curve 'C' <$> weightedNucs

    -- Create fasta sequence for the trace
    fastaSeq = concat <$> (snd <<$>> weightedNucs)
    fasta = Txt.pack $ iupac fastaSeq
  in      
  TraceData { trData09G = data09G
            , trData10A = data10A
            , trData11T = data11T
            , trData12C = data12C
            , trFasta = fasta
            , trValsPerBase = valsPerBase
            }

  where
    getWeightedTrace :: [Int] -> Char -> [(Double, [Char])] -> [Int16]
    getWeightedTrace curve nuc ws =
      let
        found = filter ((nuc `elem`) . snd) ws
        score' = foldl' (+) 0 $ fst <$> found
        score = min 1 . max 0 $ score'
        wave = floor . (score *) . fromIntegral <$> curve
      in
      wave


generateAb1 :: (Text, [(Double, Text)]) -> BSL.ByteString
generateAb1 (fName, sourceFasta) = 
  let
    tr = generateTraceData sourceFasta
    valsPerBase = trValsPerBase tr
    generatedFastaLen = (Txt.length $ trFasta tr)

    -- The point that is the peak of the trace, i.e. mid point of trace for a single base
    midPeek = valsPerBase `div` 2
    -- Get the peak locations for all bases
    peakLocations = take generatedFastaLen [midPeek, valsPerBase + midPeek..]

    -- Sample name (from the FASTA name)
    sampleName = fst . Txt.breakOn "_" $ fName

    dirs = [ mkData  9 $ trData09G tr -- G
           , mkData 10 $ trData10A tr -- A
           , mkData 11 $ trData11T tr -- T
           , mkData 12 $ trData12C tr -- C
           , mkBaseOrder BaseG BaseA BaseC BaseT -- Base order, should be GACT for 3500
           , mkLane 1 -- Lane or capliary number
           , mkCalledBases $ trFasta tr -- Called bases
           , mkMobilityFileName 1 "KB_3500_POP7_BDTv3.mob" -- Mobility file name
           , mkMobilityFileName 2 "KB_3500_POP7_BDTv3.mob" -- Mobility file name
           , mkPeakLocations $ fromIntegral <$> peakLocations -- Peak locations
           , mkDyeSignalStrength 53 75 79 48 -- Signal strength per dye
           , mkSampleName sampleName  -- Sample name
           , mkComment "Generated by HyraxBio AB1 generator"
           ]

    abi = Abi { aHeader = mkHeader
              , aRootDir = mkRoot
              , aDirs = dirs
              }
            
  in
  B.runPut (putAbi abi)


readWeightedFastas :: FilePath -> IO (Either Text [(Text, [(Double, Text)])])
readWeightedFastas source = do
  files <- getFiles source
  let names = Txt.pack . FP.takeBaseName <$> files
  contents <- traverse BS.readFile files
  
  case sequenceA $ readWeightedFasta <$> contents of
    Left e -> pure . Left $ e
    Right rs -> pure . Right $ zip names rs

  
readWeightedFasta :: ByteString -> Either Text [(Double, Text)]
readWeightedFasta fastaData = 
  case parseFasta $ TxtE.decodeUtf8 fastaData of
    Left e -> Left e
    Right fs -> getWeightedFasta fs

  where
    getWeightedFasta :: [Fasta] -> Either Text [(Double, Text)]
    getWeightedFasta fs = 
      case sequenceA $ readWeighted <$> fs of
        Left e -> Left e
        Right r -> Right r

    readWeighted :: Fasta -> Either Text (Double, Text)
    readWeighted (Fasta hdr dta) =
      case (readMaybe . Txt.unpack $ hdr :: Maybe Double) of
        Just weight -> Right (min 1 . max 0 $ weight, Txt.strip dta)
        Nothing -> Left $ "Invalid header reading, expecting numeric weight, got: " <> hdr

  

getFiles :: FilePath -> IO [FilePath]
getFiles p = do
  entries <- (p </>) <<$>> Dir.listDirectory p
  filterM Dir.doesFileExist entries


unIupac :: Char -> [Char]
unIupac c =
  case c of
    'T' -> "T"
    'C' -> "C"
    'A' -> "A"
    'G' -> "G"
   
    'U' -> "T"
    'M' -> "AC"
    'R' -> "AG"
    'W' -> "AT"
    'S' -> "CG"
    'Y' -> "CT"
    'K' -> "GT"
    'V' -> "ACG"
    'H' -> "ACT"
    'D' -> "AGT"
    'B' -> "CGT"
    'N' -> "GATC"
  
    'X' -> "GATC"
    _   -> ""

iupac :: [[Char]] -> [Char]
iupac ns =
  go <$> ns

  where
    go cs =
      let
        a = 'A' `elem` cs
        c = 'C' `elem` cs
        g = 'G' `elem` cs
        t = 'T' `elem` cs
      in
      case (a, c, g, t) of
        (True,  False, False, False) -> 'A'
        (False, True,  False, False) -> 'C'
        (False, False, True,  False) -> 'G'
        (False, False, False, True ) -> 'T'
        (True,  True,  False, False) -> 'M'
        (True,  False, True,  False) -> 'R'
        (True,  False, False, True ) -> 'W'
        (False, True,  True,  False) -> 'S'
        (False, True,  False, True ) -> 'Y'
        (False, False, True,  True ) -> 'K'
        (True,  True,  True,  False) -> 'V'
        (True,  True,  False, True ) -> 'H'
        (True,  False, True,  True ) -> 'D'
        (False, True,  True,  True ) -> 'B'
        (True,  True,  True,  True ) -> 'N'
        _ -> '_'