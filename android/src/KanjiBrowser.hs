{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE RecursiveDo #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE PartialTypeSignatures #-}
{-# LANGUAGE AllowAmbiguousTypes #-}
module KanjiBrowser where

import FrontendCommon

import qualified Data.Map as Map
import qualified Data.Text as T
import qualified Data.Set as Set

data VisibleWidget = KanjiFilterVis | KanjiDetailPageVis
  deriving (Eq)

kanjiBrowseWidget
  :: AppMonad t m
  => AppMonadT t m ()
kanjiBrowseWidget = divClass "row" $ do

  ev <- getPostBuild

  rec
    let
      filterEvWithPostBuild = leftmost [def <$ ev,
                                        filterEv]

    searchEv <- debounce 1 filterEvWithPostBuild
    filterResultEv <- getWebSocketResponse searchEv

    let
      (kanjiListEv, validRadicalsEv)
        = splitE $ (\(KanjiFilterResult a b) -> (a,b)) <$> filterResultEv

      -- For empty Filter all radicals are valid
      f (KanjiFilter "" (AdditionalFilter "" _ "") []) _ = Map.keys radicalTable
      f _ r = r

      validRadicals = attachWith f (current filterDyn) validRadicalsEv

    filterDyn <- holdDyn def filterEv

    -- NW 1.1
    filterEv <- divClass "col-sm-8" $ do
      rec
        let visEv = leftmost [KanjiFilterVis <$ closeEv
                             , KanjiDetailPageVis <$ kanjiDetailsEv]
        vis <- holdDyn KanjiFilterVis visEv

        -- Show either the filter options or the kanji details page
        -- NW 1.1.1
        filterEv <- handleVisibility KanjiFilterVis vis $
          kanjiFilterWidget validRadicals

        maybeKanjiDetailsEv <- getWebSocketResponse
          ((flip GetKanjiDetails) def <$> kanjiSelectionEv)

        -- NW 1.1.2
        closeEv <- handleVisibility KanjiDetailPageVis vis $ do
          l <- linkClass "Close Details Page" ""
          return (_link_clicked l)

        let kanjiDetailsEv = fmapMaybe identity maybeKanjiDetailsEv
        -- NW 1.1.3
        handleVisibility KanjiDetailPageVis vis $
          kanjiDetailsWidget kanjiDetailsEv

      return filterEv

    -- NW 1.2

    let listAttr = ("class" =: "col-sm-4")
          <> ("style" =: "height: 1000px;\
                         \overflow-y: auto;")
    kanjiSelectionEv <-
      elAttr "div" listAttr $ do
        kanjiListWidget kanjiListEv

  return ()
-- Widget to show kanjifilter

kanjiFilterWidget
  :: AppMonad t m
  => Event t [RadicalId]
  -> AppMonadT t m (Event t KanjiFilter)
kanjiFilterWidget validRadicalsEv = do

  -- NW 1
  let
    taAttr = constDyn $ (("style" =: "width: 100%;")
                        <> ("rows" =: "4")
                        <> ("class" =: "form-control")
                        <> ("placeholder" =: "Enter text to search all Kanjis in it"))
  sentenceTextArea <- divClass "" $ textArea $ def
    & textAreaConfig_attributes .~ taAttr

  -- TODO Add IME and kana input separate field
  -- NW 2
  -- (readingTextInput, readingSelectionDropDown, meaningTextInput)
  --   <- divClass "" $ do
  --   t <- textInput def
  --   d <- dropdown
  --     KunYomi
  --     (constDyn ((KunYomi =: "Kunyomi") <> (OnYomi =: "Onyomi ")))
  --     def
  --   m <- textInput def
  --   return (t,d,m)
  let
    tiAttr = constDyn $ (("style" =: "width: 100%;")
                        <> ("class" =: "form-control")
                        <> ("placeholder" =: "Search by meaning or reading"))
  t <- textInput $ def
    & textInputConfig_attributes .~ tiAttr

  let filterDyn = AdditionalFilter <$> (value t)
                    <*> pure KunYomi
                    <*> (pure "")

  -- NW 3
  selectedRadicals <- radicalMatrix validRadicalsEv
  let
    kanjiFilter = KanjiFilter <$> (value sentenceTextArea)
          <*> filterDyn
          <*> selectedRadicals

  return $ updated kanjiFilter

radicalMatrix
  :: forall t m . ( DomBuilder t m
     , MonadIO (Performable m)
     , TriggerEvent t m
     , MonadHold t m
     , PostBuild t m
     , PerformEvent t m
     , MonadFix m
     )
  => Event t [RadicalId] -> m (Dynamic t [RadicalId])
radicalMatrix evValid = do

  --- XXX Fix why delay here?
  evDelayed <- delay 1 evValid
  validRadicals <- holdDyn (Map.keysSet radicalTable) (Set.fromList <$> evDelayed)

  rec
    -- disableAll <- holdDyn False $ leftmost
    --   [True <$ (leftmost ev)
    --   , False <$ updated validRadicals]
    let
      disableAll = constDyn False
      renderMatrix = do
        divClass "row well-lg hidden-xs" $ do
          r <- btn "btn-block btn-default btn-xs" "Reset"
          ev1 <- mapM showRadical (Map.toList radicalTable)
          return (ev1, r)

      showRadical :: (RadicalId, RadicalDetails) -> m (Event t RadicalId)
      showRadical (i,(RadicalDetails r _)) = do
        let valid =
              Set.member i <$> validRadicals
            sel =
              -- pure False
              Set.member i <$> selectedRadicals
            -- (Valid, Selected)
            cl (_,True) = " btn-success "
            cl (True, False) = " btn-info "
            cl (False,False) = " btn-info disabled "
            attr = (\c -> ("class" =: (c <> "btn btn-xs" )))
                     <$> (cl <$> zipDyn valid sel)

            spanAttr = ("class" =: "badge")
              <> ("style" =: "color: black;")

        (e,_) <- elDynAttr' "button" attr $
          elAttr "span" spanAttr $ text r
        let ev1 = attachWithMaybe f
                   (current $ zipDyn valid disableAll)
                   (domEvent Click e)
            f (_,True) _ = Nothing
            f (True,_) _ = Just ()
            f _ _ = Nothing
        return (i <$ ev1)

    (ev, resetEv) <- renderMatrix

    let
      h :: RadicalId -> Set RadicalId -> Set RadicalId
      h i s = if Set.member i s then Set.delete i s else Set.insert i s
      foldF = foldDyn h Set.empty (leftmost ev)
    selectedRadicals <- join <$> widgetHold foldF (foldF <$ resetEv)
  return $ Set.toList <$> selectedRadicals


kanjiListWidget
  :: (AppMonad t m)
  => Event t [(KanjiId, Kanji, Maybe Rank, [Meaning])]
  -> AppMonadT t m (Event t KanjiId)
kanjiListWidget listEv = do
  let
    listItem (i, k, r, m) = do
          (e, _) <- el' "tr" $ do
            el "td" $ text $ (unKanji k)
            el "td" $ text $ maybe ""
              (\r1 -> show r1) (unRank <$> r)
            el "td" $ text $ T.intercalate "," $ map unMeaning m
          return (i <$ domEvent Click e)

    liWrap i = do
      ev <- dyn $ listItem <$> i
      switchPromptly never ev

    fun (This l) _ = l
    fun (That ln) l = l ++ ln
    fun (These l _) _ = l

  -- NW 1
  rec
    lmEv <- getWebSocketResponse $ LoadMoreKanjiResults <$ ev
    dynV <- foldDyn fun [] (align listEv lmEv)
    d <- elClass "table" "table table-striped" $ do
      el "thead" $ do
        el "tr" $ do
          el "th" $ text "Kanji"
          el "th" $ text "Rank"
          el "th" $ text "Meanings"
      el "tbody" $  do
        -- NW 1.1
        simpleList dynV liWrap
    ev <- do
      btnLoading "btn-block btn-primary" "Load More" lmEv
  return $ switch . current $ leftmost <$> d

kanjiDetailsWidget
  :: AppMonad t m
  => Event t KanjiSelectionDetails -> AppMonadT t m ()
kanjiDetailsWidget ev = do
  let f1 (KanjiSelectionDetails k _) = k
  let f2 (KanjiSelectionDetails _ v) = v
  _ <- widgetHold (return()) (kanjiDetailWindow <$> (f1 <$> ev))
  vocabListWindow LoadMoreKanjiVocab (f2 <$> ev)

kanjiDetailWindow :: AppMonad t m
  => (KanjiDetails, VocabSrsState, [Text])
  -> AppMonadT t m ()
kanjiDetailWindow (k,vSt,rads) = divClass "well" $ do
  let
    maybeLabel _ Nothing = return ()
    maybeLabel l (Just v) = elClass "span" "label label-default" $
      text l >> text ": " >> text (tshow v)

  divClass "row" $ do
    divClass "col-sm-4" $ el "h1" $ elClass "span" "label label-default" $
      text (unKanji $ k ^. kanjiCharacter)
    divClass "col-sm-8" $ do
      elClass "span" "label label-default" $ do
        text "Radicals: "
        text $ T.intercalate " " $ rads

      addEditSrsEntryWidget (Left $ _kanjiId k) Nothing vSt

      divClass "" $ do
        maybeLabel "Rank" (unRank <$> k ^. kanjiMostUsedRank)
        maybeLabel "JLPT" (unJlptLevel <$> k ^. kanjiJlptLevel)
        maybeLabel "WaniKani Lvl" (unWkLevel <$> k ^. kanjiWkLevel)

      divClass "" $
        text $ T.intercalate ", " $
          map capitalize (map unMeaning $ k ^. kanjiMeanings)

vocabListWindow
  :: (AppMonad t m
     , WebSocketMessage AppRequest req
     , ResponseT AppRequest req ~ [(Entry, VocabSrsState)])
  => req -> Event t VocabList -> AppMonadT t m ()
vocabListWindow req listEv = do
  let
    fun (This l) _ = l
    fun (That ln) l = l ++ ln
    fun (These l _) _ = l

  -- NW 1
  rec
    lmEv <- getWebSocketResponse $ req <$ ev
    lsDyn <- foldDyn fun [] (align listEv lmEv)
    _ <- divClass "" $  do
      -- NW 1.1
      dyn $ (mapM (showEntry Nothing)) <$> lsDyn
      -- NW 1.2
    ev <- do
      btnLoading "btn-block btn-primary" "Load More" lmEv
  return ()

vocabSearchWidget
  :: AppMonad t m
  => AppMonadT t m ()
vocabSearchWidget = divClass "" $ divClass "" $ do

  vocabResEv <- divClass "" $ divClass "field has-addons" $ do
    let
      tiAttr = constDyn $ (("style" =: "")
                          <> ("class" =: "input")
                          <> ("placeholder" =: "Search by meaning or reading"))
    ti <- elClass "p" "control" $ textInput $ def
      & textInputConfig_attributes .~ tiAttr

    rec
      searchEv <- elClass "p" "control" $
        btnLoading "" "Search" res

      filt <- elClass "p" "control" $ elClass "span" "select" $ do

        dropdown Nothing
          (constDyn ((Nothing =: "All")
          <> ((Just PosNoun) =: "Noun Only")
          <> ((Just (PosVerb (Regular Ichidan) NotSpecified))
              =: "Verb Only")
          <> ((Just (PosAdjective NaAdjective)) =: "Adj or Adv only")))
          $ def
            & dropdownConfig_attributes .~ (constDyn ("class" =: ""))

      let vsDyn = VocabSearch <$> (value ti)
                    <*> (value filt)
      res <- getWebSocketResponse (tagDyn vsDyn searchEv)
    return res

  divClass "panel-body" $ do
    vocabListWindow LoadMoreVocabSearchResult vocabResEv
