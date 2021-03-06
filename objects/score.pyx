from typing import Optional, Any

from time import time

from objects import beatmap
from common.constants import gameModes
from common.log import logUtils as log
from common.ripple import userUtils
from constants import rankedStatuses
from common.ripple import scoreUtils
from objects import glob
from pp import rippoppai
from pp import wifipiano2
from pp import cicciobello
from common import generalUtils

class score:
    PP_CALCULATORS = {
        gameModes.STD:   rippoppai.oppai,
        gameModes.TAIKO: rippoppai.oppai,
        gameModes.CTB:   cicciobello.Cicciobello,
        gameModes.MANIA: wifipiano2.piano
    }
    __slots__ = ["scoreID", "playerName", "score", "maxCombo", "c50", "c100", "c300", "cMiss", "cKatu", "cGeki",
                 "fullCombo", "mods", "playerUserID", "rank", "date", "hasReplay", "fileMd5", "passed", "playDateTime",
                 "gameMode", "completed", "accuracy", "pp", "oldPersonalBest", "rankedScoreIncrease"]
    def __init__(self, scoreID: Optional[int] = None, rank: Optional[Any] = None, setData: bool = True):
        """
        Initialize a (empty) score object.

        scoreID -- score ID, used to get score data from db. Optional.
        rank -- score rank. Optional
        setData -- if True, set score data from db using scoreID. Optional.
        """

        self.scoreID: Optional[int] = 0
        self.playerName = "nospe"
        self.score: int = 0
        self.maxCombo: int = 0
        self.c50: int = 0
        self.c100: int = 0
        self.c300: int = 0
        self.cMiss: int = 0
        self.cKatu: int = 0
        self.cGeki: int = 0
        self.fullCombo: bool = False
        self.mods: int = 0
        self.playerUserID: int = 0
        self.rank: Optional[Any] = rank # TODO: type hint | can be empty string too
        self.date: int = 0
        self.hasReplay: int = 0

        self.fileMd5 = None
        self.passed = False
        self.playDateTime: int = 0
        self.gameMode: int = 0
        self.completed: int = 0

        self.accuracy: float = 0.00

        self.pp: float = 0.00

        self.oldPersonalBest: int = 0
        self.rankedScoreIncrease: int = 0

        if scoreID is not None and setData:
            self.setDataFromDB(scoreID, rank)

    def calculateAccuracy(self) -> None:
        """
        Calculate and set accuracy for that score.
        """

        if self.gameMode == 0:
            # std
            totalPoints = self.c50 * 50 + self.c100 * 100+self.c300 * 300
            totalHits = self.c300 + self.c100 + self.c50 + self.cMiss
            if totalHits == 0:
                self.accuracy = 1
            else:
                self.accuracy = totalPoints / (totalHits * 300)
        elif self.gameMode == 1:
            # taiko
            totalPoints = (self.c100 * 50) + (self.c300 * 100)
            totalHits = self.cMiss + self.c100 + self.c300
            if totalHits == 0:
                self.accuracy = 1
            else:
                self.accuracy = totalPoints / (totalHits * 100)
        elif self.gameMode == 2:
            # ctb
            fruits = self.c300 + self.c100 + self.c50
            totalFruits = fruits + self.cMiss + self.cKatu
            if totalFruits == 0:
                self.accuracy = 1
            else:
                self.accuracy = fruits / totalFruits
        elif self.gameMode == 3:
            # mania
            totalPoints = self.c50 * 50 + self.c100 * 100 + self.cKatu * 200 + self.c300 * 300 + self.cGeki * 300
            totalHits = self.cMiss + self.c50 + self.c100 + self.c300 + self.cGeki + self.cKatu
            self.accuracy = totalPoints / (totalHits * 300)
        else:
            # unknown gamemode
            self.accuracy = 0

    def setRank(self, rank: Optional[Any]) -> None:
        """
        Force a score rank.

        rank -- new score rank
        """

        self.rank = rank

    def setDataFromDB(self, scoreID: int, rank: Optional[Any] = None) -> None:
        """
        Set this object's score data from db.
        Sets playerUserID too

        scoreID -- score ID
        rank -- rank in scoreboard. Optional.
        """

        data = glob.db.fetch("SELECT scores.*, users.username FROM scores LEFT JOIN users ON users.id = scores.userid WHERE scores.id = %s LIMIT 1", [scoreID])
        if data is not None:
            self.setDataFromDict(data, rank)

    def setDataFromDict(self, data, rank: Optional[Any] = None) -> None:
        """
        Set this object's score data from dictionary.
        Doesn't set playerUserID

        data -- score dictionarty
        rank -- rank in scoreboard. Optional.
        """

        self.scoreID: int = data["id"]
        self.playerName: str = userUtils.getUsername(data["userid"]) # note: it passes username but no need to use.
        self.playerUserID: int = data["userid"]
        self.score: int = data["score"]
        self.maxCombo: int = data["max_combo"]
        self.gameMode: int = data["play_mode"]
        self.c50: int = data["50_count"]
        self.c100: int = data["100_count"]
        self.c300: int = data["300_count"]
        self.cMiss: int = data["misses_count"]
        self.cKatu: int = data["katus_count"]
        self.cGeki: int = data["gekis_count"]
        self.fullCombo: bool = bool(data["full_combo"] == 1)
        self.mods: int = data["mods"]
        self.rank: Optional[Any] = rank if rank is not None else ""
        self.date: int = data["time"]
        self.fileMd5: str = data["beatmap_md5"]
        self.completed: int = data["completed"]
        #if "pp" in data:
        self.pp: float = data["pp"]
        self.calculateAccuracy()

    def setDataFromScoreData(self, scoreData) -> None:
        """
        Set this object's score data from scoreData list (submit modular).

        scoreData -- scoreData list
        """

        if len(scoreData) >= 16:
            self.fileMd5: str = scoreData[0]
            self.playerName: str = scoreData[1].strip()
            # %s%s%s = scoreData[2]
            self.c300: int = int(scoreData[3])
            self.c100: int = int(scoreData[4])
            self.c50: int = int(scoreData[5])
            self.cGeki: int = int(scoreData[6])
            self.cKatu: int = int(scoreData[7])
            self.cMiss: int = int(scoreData[8])
            self.score: int = int(scoreData[9])
            self.maxCombo: int = int(scoreData[10])
            self.fullCombo: bool = True if scoreData[11] == 'True' else False
            #self.rank: Optional[Any] = scoreData[12]
            self.mods: int = int(scoreData[13])
            self.passed: bool = True if scoreData[14] == 'True' else False
            self.gameMode: int = int(scoreData[15])
            #self.playDateTime: int = int(scoreData[16])
            self.playDateTime: int = int(time())
            self.calculateAccuracy()
            #osuVersion: str = scoreData[17]
            self.calculatePP()
            # Set completed status
            self.setCompletedStatus()


    def getData(self, pp: bool = False) -> str:
        # Return score row relative to this score for getscores
        return "{}|{}|{}|{}|{}|{}|{}|{}|{}|{}|{}|{}|{}|{}|{}|1\n".format(
            self.scoreID,
            userUtils.getClan(self.playerUserID), #self.playerName,
            int(self.pp) if pp else self.score,
            self.maxCombo,
            self.c50,
            self.c100,
            self.c300,
            self.cMiss,
            self.cKatu,
            self.cGeki,
            self.fullCombo,
            self.mods,
            self.playerUserID,
            self.rank,
            self.date)

    def setCompletedStatus(self, b = None) -> None:
        """
        Set this score completed status and rankedScoreIncrease.
        """

        self.completed = 0

        # Create beatmap object
        if b is None:
            b = beatmap.beatmap(self.fileMd5, 0)

        if self.passed and scoreUtils.isRankable(self.mods, b.maxCombo):
            # Get userID
            userID = userUtils.getID(self.playerName)

            # Make sure we don't have another score identical to this one
            duplicate = glob.db.fetch("SELECT id FROM scores WHERE userid = %s AND beatmap_md5 = %s AND play_mode = %s AND score = %s LIMIT 1", [userID, self.fileMd5, self.gameMode, self.score])
            if duplicate is not None:
                # Found same score in db. Don't save this score.
                self.completed = -1
                return

            # No duplicates found.
            # Get right "completed" value
            personalBest = glob.db.fetch("SELECT id, pp, score FROM scores WHERE userid = %s AND beatmap_md5 = %s AND play_mode = %s AND completed = 3 LIMIT 1", [userID, self.fileMd5, self.gameMode])
            if personalBest is None:
                # This is our first score on this map, so it's our best score
                self.completed = 3
                self.rankedScoreIncrease = self.score
                self.oldPersonalBest = 0
            else:
                # Compare personal best's score with current score
                if b.rankedStatus in [rankedStatuses.RANKED, rankedStatuses.APPROVED, rankedStatuses.QUALIFIED]:
                    if self.pp > personalBest["pp"]:
                        # New best score
                        self.completed = 3
                        self.rankedScoreIncrease = self.score-personalBest["score"]
                        self.oldPersonalBest = personalBest["id"]
                    else:
                        self.completed = 2
                        self.rankedScoreIncrease = 0
                        self.oldPersonalBest = 0
                elif b.rankedStatus == rankedStatuses.LOVED \
                or (b.rankedStatus == rankedStatuses.PENDING and generalUtils.stringToBool(glob.conf.config["extra"]["unrank_leaderboard"]) == True):
                    if self.score > personalBest["score"]:
                        # New best score
                        self.completed = 3
                        self.rankedScoreIncrease = self.score-personalBest["score"]
                        self.oldPersonalBest = personalBest["id"]
                    else:
                        self.completed = 2
                        self.rankedScoreIncrease = 0
                        self.oldPersonalBest = 0

        #log.info("Completed status: {}".format(self.completed))

    def saveScoreInDB(self) -> None:
        """
        Save this score in DB (if passed and mods are valid).
        """

        # Add this score

        query = "INSERT INTO scores (id, beatmap_md5, userid, score, max_combo, full_combo, mods, 300_count, 100_count, 50_count, katus_count, gekis_count, misses_count, time, play_mode, completed, accuracy, pp) VALUES (NULL, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s);"
        self.scoreID = int(glob.db.execute(query, [self.fileMd5, userUtils.getID(self.playerName), self.score, self.maxCombo, 1 if self.fullCombo else 0, self.mods, self.c300, self.c100, self.c50, self.cKatu, self.cGeki, self.cMiss, self.playDateTime, self.gameMode, self.completed, self.accuracy * 100, self.pp]))
        if self.completed >= 2:
            # Set old personal best to completed = 2
            if self.oldPersonalBest != 0:
                glob.db.execute("UPDATE scores SET completed = 2 WHERE id = %s", [self.oldPersonalBest])

    def calculatePP(self, b = None) -> None:
        """
        Calculate this score's pp value if completed == 3.
        """

        # Create beatmap object
        if b is None:
            b = beatmap.beatmap(self.fileMd5, 0)

        # Calculate pp
        if  b.rankedStatus >= rankedStatuses.PENDING        \
        and b.rankedStatus != rankedStatuses.NEED_UPDATE    \
        and scoreUtils.isRankable(self.mods, b.maxCombo)    \
        and self.passed                                     \
        and self.gameMode in score.PP_CALCULATORS:
            calculator = score.PP_CALCULATORS[self.gameMode](b, self)
            if b.rankedStatus == rankedStatuses.LOVED \
            or (b.rankedStatus == rankedStatuses.PENDING and generalUtils.stringToBool(glob.conf.config["extra"]["unrank_leaderboard"]) == True):
                if self.gameMode != gameModes.MANIA:
                    self.score = int(calculator.pp)
                self.pp = 0.001
            else:
                self.pp = calculator.pp
        else:
            self.pp = 0
